-- A bounded operator snapshot for the stream. No watch, background sampling or endurance/feed tracing.
return function(api)
  local M = {}
  local TYPES = {'ammo-turret','electric-turret','fluid-turret','artillery-turret'}
  local function finite(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
  local function contents(e,id)
    local ok,i=pcall(e.get_inventory,id)
    if ok and i then local good,rows=pcall(i.get_contents); if good then return rows end end
  end
  local function target_of(e) return e.shooting_target end
  local function counts_of(e) return e.kills,e.damage_dealt end
  local function ammo_into(out,rows,place)
    for _,r in ipairs(rows or {}) do
      local p=prototypes.item[r.name]
      if p and p.type=='ammo' then
        local a=out[r.name] or {hub=0,turrets=0}; out[r.name]=a; a[place]=a[place]+r.count
      end
    end
  end
  function M.read(a)
    assert(type(a.platform)=='string','platform requires a name')
    local pl=api.platform(a.platform)
    local s,hub=pl.surface,pl.hub
    assert(s and s.valid and hub and hub.valid,'platform has no built hub')
    local out={platform=pl.name,surface=s.name,tick=game.tick,paused=game.tick_paused,game_speed=game.speed,
      platform_paused=pl.paused,speed_kms=pl.speed*60,at=pl.space_location and pl.space_location.name or nil}
    local l=api.leg(pl)
    if pl.space_location and pl.state~=defines.space_platform_state.on_the_path then l=nil end
    local segs=api.segments(pl); local sg=segs[#segs]
    if l then
      out.leg={from=l.from,to=l.to,connection=pl.space_connection.name,back=l.back or false,
        km=l.length,flown_km=l.flown*l.length,left_km=l.left_km,pct=l.flown*100,turned_back=l.turned_back}
      if sg and sg.kind=='leg' and not sg['end'] and sg.from==l.from and sg.to==l.to then
        out.leg.start_tick=sg.start; out.leg.partial=sg.partial or nil
        -- The existing loss ring records buildings, not foundation. Hide a count when its coverage is incomplete.
        local log=api.state().lost_log
        local oldest=log and log.rows and log.rows[log.next]
        if not sg.partial and (not oldest or oldest.t<=sg.start) then
          local _,n=api.losses(pl.force.name,s.name,sg.start); out.losses_leg=n
        end
      end
    end
    local hits=api.hits(pl)
    out.hits_total=hits and hits.hits or 0; out.damage_total=hits and hits.damage or 0
    local ammo={}
    local held=contents(hub,defines.inventory.hub_main)
    if held then
      ammo_into(ammo,held,'hub'); out.repair_packs=0
      for _,r in ipairs(held) do
        if prototypes.item[r.name] and prototypes.item[r.name].type=='repair-tool' then out.repair_packs=out.repair_packs+r.count end
      end
    end
    local turrets=s.find_entities_filtered{force=pl.force,type=TYPES,limit=257}
    if #turrets<=256 then
      out.turrets={}; out.tallies={units={},kills=0,damage=0}
      local tally_unknown=false
      for _,e in ipairs(turrets) do
        local name,kind=e.name,e.type
        local g=out.turrets[name] or {count=0,targeting=0}; out.turrets[name]=g; g.count=g.count+1
        local okt,target=pcall(target_of,e)
        if not okt then g.targeting_unknown=true elseif target and target.valid then g.targeting=g.targeting+1 end
        if kind=='ammo-turret' or kind=='artillery-turret' then
          local rows=contents(e,kind=='artillery-turret' and defines.inventory.artillery_turret_ammo or defines.inventory.turret_ammo)
          if rows then
            g.empty=g.empty or 0; if #rows==0 then g.empty=g.empty+1 end
            ammo_into(ammo,rows,'turrets')
          else out.ammo_unknown=true; g.empty_unknown=true end
        end
        -- The same tooltip counters turret_tally reads, without making a temporary row for every turret.
        local ok,k,d=pcall(counts_of,e)
        if ok and finite(k) and finite(d) then
          local t=out.tallies; t.units[#t.units+1]=e.unit_number; t.kills=t.kills+k; t.damage=t.damage+d
        else tally_unknown=true end
      end
      for _,g in pairs(out.turrets) do
        if g.empty_unknown then g.empty=nil; g.empty_unknown=nil end
        if g.targeting_unknown then g.targeting=nil; g.targeting_unknown=nil end
      end
      if tally_unknown then out.tallies=nil else table.sort(out.tallies.units) end
    else out.turrets_capped=true; out.ammo_unknown=true end
    local stats=pl.force.get_item_production_statistics(s)
    local made,used=stats.input_counts,stats.output_counts
    for _,counts in ipairs({made,used}) do
      for name,n in pairs(counts) do
        if n>0 and prototypes.item[name] and prototypes.item[name].type=='ammo' then ammo[name]=ammo[name] or {hub=0,turrets=0} end
      end
    end
    out.ammo={}
    for name,r in pairs(ammo) do
      r.name=name; r.made=made[name] or 0; r.used=used[name] or 0
      if not held then r.hub=nil end
      if out.ammo_unknown then r.turrets=nil end
      out.ammo[#out.ammo+1]=r
    end
    table.sort(out.ammo,function(x,y) return x.name<y.name end)
    local tanks=s.find_entities_filtered{force=pl.force,type={'thruster','storage-tank'},limit=129}
    if #tanks<=128 then
      out.fuel={['thruster-fuel']=0,['thruster-oxidizer']=0}
      for _,e in ipairs(tanks) do for name,n in pairs(out.fuel) do out.fuel[name]=n+e.get_fluid_count(name) end end
    end
    if a.area~=nil then
      local ar=a.area; local lt=type(ar)=='table' and ar[1]; local rb=type(ar)=='table' and ar[2]
      assert(type(lt)=='table' and type(rb)=='table' and finite(lt[1]) and finite(lt[2]) and finite(rb[1]) and finite(rb[2])
        and rb[1]>lt[1] and rb[2]>lt[2] and rb[1]-lt[1]<=512 and rb[2]-lt[2]<=512,'area requires two corners, at most 512 tiles per side')
      out.asteroids={}; out.area=ar
      for _,size in ipairs({'small','medium','big','huge'}) do
        local names={}
        for _,kind in ipairs({'metallic','carbonic','oxide','promethium'}) do
          local name=size..'-'..kind..'-asteroid'; if prototypes.entity[name] then names[#names+1]=name end
        end
        if #names>0 then
          local n=s.count_entities_filtered{area=ar,name=names,limit=4097}
          if n<=4096 then out.asteroids[size]=n end
        end
      end
    end
    return out
  end
  M.operator={platform_metrics=M.read}
  return M
end
