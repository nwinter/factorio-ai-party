-- Where our factory already holds an item: machine outputs and storage
-- chests. Hand-crafting what a nearby assembler has already made wastes the
-- character's time, so craft and construct point here, and `collect` with a
-- radius walks the stock back.
return function(api)
  local M={}
  -- temporary-container: a cargo pod landed with no pad (a player opens it; freight_audit counted 45 solar panels in one
  -- that stock left out, Sol 15:22).
  local TYPES={'assembling-machine','furnace','agricultural-tower','container','logistic-container','cargo-landing-pad','temporary-container'}
  -- Gathering leaves plain chests alone unless asked: they are usually feed
  -- chests the player stocked for machines, not stock to collect.
  local NO_CHESTS={'assembling-machine','furnace','agricultural-tower','cargo-landing-pad'}
  -- An agricultural tower's harvest is its output, as an assembler's product is (Gleba).
  local CRAFTER={['assembling-machine']=true,furnace=true,['agricultural-tower']=true}
  local CHEST={container=true,['logistic-container']=true,['temporary-container']=true}
  local MAX_PLACES=32
  local function output_of(e)
    if CRAFTER[e.type] then
      local ok,inv=pcall(e.get_output_inventory); return ok and inv or nil
    end
    local id=e.type=='cargo-landing-pad' and defines.inventory.cargo_landing_pad_main or defines.inventory.chest
    local ok,inv=pcall(e.get_inventory,id); return ok and inv or nil
  end
  local function makes(e,item)
    if not CRAFTER[e.type] then return false end
    local ok,recipe=pcall(e.get_recipe)
    if not (ok and recipe) then return false end
    for _,product in ipairs(recipe.products or {}) do if product.name==item then return true end end
    return false
  end
  -- Every own entity within radius of centre holding the item, nearest first,
  -- plus the crafters set to make it (whether or not they hold any now).
  -- opts.surface: another surface than the character's (stock {surface, position}; Sonnet 12:20: the surface was
  -- ignored); opts.whole: every place on it (a platform's), no radius.
  function M.scan(p,item,opts)
    opts=opts or {}
    local centre=opts.position or p.position
    local quality=opts.quality or 'normal'
    local places,total,groups,makers={},0,{},{}
    local spoils=api.spoil and api.spoil.spoils(item)
    local f={force=p.force,type=opts.types or TYPES}
    if not opts.whole then f.position=centre; f.radius=opts.radius or 128 end
    for _,e in pairs((opts.surface or p.surface).find_entities_filtered(f)) do
      if e.valid then
        if makes(e,item) then makers[e.name]=(makers[e.name] or 0)+1 end
        local inv=output_of(e)
        local n=inv and inv.get_item_count{name=item,quality=quality} or 0
        if n>0 then
          total=total+n
          local g=groups[e.name] or {name=e.name,entities=0,count=0,chest=CHEST[e.type] or nil}
          groups[e.name]=g; g.entities=g.entities+1; g.count=g.count+n
          local place={entity=e,name=e.name,position=e.position,count=n,distance=api.distance(centre,e.position)}
          -- A spoilable item: this place's first stack to spoil (spoil.lua).
          if spoils then
            -- (C7) what of it spoils within 2 minutes here
            for k=1,#inv do
              local st=inv[k]
              if st.valid_for_read and st.name==item then
                local okt,t=pcall(function() return st.spoil_tick end)
                if okt and type(t)=='number' and t>0 and t-game.tick<=7200 then place.soon2=(place.soon2 or 0)+st.count end
              end
            end
            for _,r in ipairs(api.spoil.inventory(inv,{})) do
              if r.name==item and (not place.spoil_tick or r.tick<place.spoil_tick) then place.spoil_tick,place.spoil_percent,place.soon=r.tick,r.percent,r.soon end
            end
          end
          places[#places+1]=place
        end
      end
    end
    table.sort(places,function(x,y) return x.distance<y.distance end)
    local list={}
    for _,g in pairs(groups) do list[#list+1]=g end
    table.sort(list,function(x,y) return x.count>y.count end)
    return {item=item,total=total,groups=list,places=places,makers=next(makers) and makers or nil}
  end
  -- One line an agent cannot skim past: how much, in what, and where.
  function M.line(s,centre)
    if s.total==0 then return nil end
    local parts={}
    for i,g in ipairs(s.groups) do
      if i>3 then parts[#parts+1]='...'; break end
      parts[#parts+1]=string.format('%d in %d %s',g.count,g.entities,g.name)
    end
    local near,big=s.places[1],s.places[1]
    for _,x in ipairs(s.places) do if x.count>big.count then big=x end end
    local largest=big~=near and string.format('; largest %d in %s at (%g,%g) %d tiles away',big.count,big.name,big.position.x,big.position.y,math.floor(big.distance+0.5)) or ''
    local chests=false
    for _,g in ipairs(s.groups) do if g.chest then chests=true end end
    local first
    for _,x in ipairs(s.places) do if x.spoil_tick and (not first or x.spoil_tick<first.spoil_tick) then first=x end end
    local spoil=first and string.format('; the first %s in %s at (%g,%g) in %s (%d%% spoiled)',api.spoil.hatch(s.item) and 'hatches into '..api.spoil.hatch(s.item).entity or 'spoils',
      first.name,first.position.x,first.position.y,api.spoil.secs(first.spoil_tick-game.tick),math.floor(first.spoil_percent*100+0.5)) or ''
    return string.format('%d %s held by our factory (%s); nearest %d at (%g,%g) %d tiles away%s%s; collect item=%s radius=%d%s gathers it',
      s.total,s.item,table.concat(parts,', '),near.count,near.position.x,near.position.y,math.floor(near.distance+0.5),largest,spoil,
      s.item,math.max(8,math.ceil(math.max(s.places[math.min(#s.places,4)].distance,big.distance))+2),chests and ' chests=true' or '')
  end
  -- Without an item: what our machines and chests hold, per item, largest
  -- first (shake2: agents asked `scope=stock` bare and got an error).
  function M.summary(p,a,radius,limit,surface)
    local centre=a.position and api.position(a.position) or p.position
    surface=surface or p.surface
    local totals,order={},{}
    local spoil,read={},{}
    for _,e in pairs(surface.find_entities_filtered{position=centre,radius=radius,force=p.force,type=TYPES}) do
      local inv=e.valid and output_of(e)
      for _,s in ipairs(inv and inv.get_contents() or {}) do
        local key=s.quality and s.quality~='normal' and s.name..'@'..s.quality or s.name
        local t=totals[key]
        if not t then t={item=key,count=0,entities=0,chests=0}; totals[key]=t; order[#order+1]=t end
        t.count=t.count+s.count; t.entities=t.entities+1
        if CHEST[e.type] then t.chests=t.chests+1 end
        -- Spoilable items: the first stack to spoil among the places (spoil.lua).
        if api.spoil and api.spoil.spoils(s.name) and not read[e] then read[e]=true; api.spoil.inventory(inv,spoil) end
      end
    end
    table.sort(order,function(x,y) return x.count>y.count or (x.count==y.count and x.item<y.item) end)
    local items={}
    for i=1,math.min(limit,#order) do
      local t=order[i]
      local r=spoil[t.item]
      local h=r and api.spoil.hatch(r.name)
      items[i]=string.format('%s %d in %d %s%s%s',t.item,t.count,t.entities,t.entities==1 and 'entity' or 'entities',
        t.chests>0 and string.format(' (%d chest%s)',t.chests,t.chests==1 and '' or 's') or '',
        r and string.format('; the first %s in %s (%d%% spoiled)',h and 'hatches into '..h.entity or 'spoils',api.spoil.secs(r.tick-game.tick),math.floor(r.percent*100+0.5)) or '')
    end
    return {radius=radius,items=items,more=#order>limit and #order-limit or nil,
      covered=string.format('our machine outputs and chests within %d tiles of (%g,%g) on %s',radius,math.floor(centre.x),math.floor(centre.y),surface.name),
      as_of=string.format('live (tick %d)',game.tick),
      note=#order>0 and 'machine outputs and chests within radius; scope=stock item=NAME lists the places and a collect line' or 'no machine output or chest within radius holds anything'}
  end
  -- What kind of holder a place is (Muse 09:24: 3-4 stock calls to find a provider robots had not committed): provider
  -- (active or passive), storage, requester, buffer, chest (no logistics), machine, or the entity type.
  local KINDS={provider=true,storage=true,requester=true,buffer=true,chest=true,machine=true,wagon=true,pad=true,vehicle=true}
  function M.holder_kind(e)
    local mode=e.type=='logistic-container' and (pcall(function() return e.prototype.logistic_mode end) and e.prototype.logistic_mode)
    if mode=='active-provider' or mode=='passive-provider' then return 'provider' end
    if mode then return mode end
    if CHEST[e.type] then return 'chest' end
    if e.type=='assembling-machine' or e.type=='furnace' or e.type=='lab' or e.type=='mining-drill' or e.type=='agricultural-tower' then return 'machine' end
    if e.type=='cargo-wagon' then return 'wagon' end
    if e.type=='cargo-landing-pad' then return 'pad' end
    if e.type=='car' or e.type=='spider-vehicle' then return 'vehicle' end
    return e.type
  end
  -- opts: surface (the one named), whole (a platform: every place aboard).
  function M.view(p,a,opts)
    local radius=api.integer(a.radius,128,1,1024,'radius')
    if a.item==nil then return M.summary(p,a,radius,api.integer(a.limit,16,1,64,'limit'),opts and opts.surface) end
    assert(type(a.item)=='string' and prototypes.item[a.item],'item must be a known item name')
    local limit=api.integer(a.limit,8,1,MAX_PLACES,'limit')
    local centre=a.position and api.position(a.position) or p.position
    local surface=opts and opts.surface or p.surface
    local whole=opts and opts.whole
    local s=M.scan(p,a.item,{position=centre,radius=radius,quality=a.quality,surface=surface,whole=whole})
    -- holders: only those kinds of place (the total and groups stay the whole stock).
    local want
    if a.holders~=nil then
      local list=type(a.holders)=='string' and {a.holders} or a.holders
      assert(type(list)=='table' and #list>=1,'holders is a list of kinds: provider, storage, requester, buffer, chest, machine, wagon, pad, vehicle')
      want={}
      for _,k in ipairs(list) do assert(KINDS[k],'holders: unknown kind '..tostring(k)..' (provider, storage, requester, buffer, chest, machine, wagon, pad, vehicle)'); want[k]=true end
      local kept={}
      for _,x in ipairs(s.places) do if want[M.holder_kind(x.entity)] then kept[#kept+1]=x end end
      s={item=s.item,total=s.total,groups=s.groups,places=kept,makers=s.makers}
    end
    -- page (A9, Muse: places past 128 tiles unfindable): places limit at a time, nearest first, from page 1.
    local pages=math.max(1,math.ceil(#s.places/limit))
    local page=api.integer(a.page,1,1,pages,'page')
    local skip=(page-1)*limit
    local places={}
    for i=1,math.min(limit,#s.places-skip) do
      local x=s.places[skip+i]
      local reserved=api.reserved and api.reserved(x.entity,a.item) or 0
      places[i]={name=x.name,position=x.position,count=x.count,distance=math.floor(x.distance+0.5),kind=M.holder_kind(x.entity),
        reserved=reserved>0 and reserved or nil,
        first_spoils_in=x.spoil_tick and api.spoil.secs(x.spoil_tick-game.tick) or nil,spoiled_percent=x.spoil_tick and math.floor(x.spoil_percent*100+0.5) or nil,
        within_5_min=x.soon and x.soon>0 and x.soon or nil,within_2_min=x.soon2}
    end
    -- (C7) the places read: how much spoils within 2 minutes
    local soon2
    if api.spoil and api.spoil.spoils(a.item) then
      soon2=0
      for _,x in ipairs(s.places) do soon2=soon2+(x.soon2 or 0) end
    end
    local h=api.spoil and api.spoil.hatch(a.item)
    return {item=a.item,total=s.total,by_entity=s.groups,places=places,more=#s.places>skip+limit and #s.places-skip-limit or nil,
      spoils_within_2_min=soon2,
      page=pages>1 and page or nil,pages=pages>1 and pages or nil,
      covered=whole and string.format('every machine output and chest of ours on %s',surface.name)
        or string.format('our machine outputs and chests within %d tiles of (%g,%g) on %s',radius,math.floor(centre.x),math.floor(centre.y),surface.name),
      as_of=string.format('live (tick %d)',game.tick),
      made_by=s.makers,held=p.get_main_inventory().get_item_count{name=a.item,quality=a.quality or 'normal'},summary=M.line(s,centre),
      hatches_into=h and string.format('%s (an enemy, %s) when it spoils: first_spoils_in is when the first hatches',h.entity,api.spoil.per_text(h)) or nil}
  end
  -- Gathering: visit stock places nearest-neighbour from the character and
  -- take the item from each until `want` is met.
  local function route(start,places,limit)
    local left,out,at={},{},start
    for i,x in ipairs(places) do left[i]=x end
    while #left>0 and #out<(limit or MAX_PLACES) do
      local best,bd=1,math.huge
      for i,x in ipairs(left) do local d=api.distance(at,x.position); if d<bd then best,bd=i,d end end
      local x=table.remove(left,best)
      out[#out+1]={entity=x.entity,position=x.position}
      at=x.position
    end
    return out
  end
  -- Another agent's claimed places stay put; returns the places kept and the skipped_claims lines.
  local function unclaimed(p,places,what)
    local skipped,kept={},{}
    for _,place in ipairs(places) do
      local c=api.claims and api.claims.other(p,place.position)
      if c then
        local key=api.claims.label(c,p)
        if not skipped[key] then skipped[key]={places=0,count=0}; skipped[#skipped+1]=key end
        skipped[key].places=skipped[key].places+1; skipped[key].count=skipped[key].count+place.count
      else kept[#kept+1]=place end
    end
    if #skipped==0 then return places,nil end
    local lines={}
    for i,key in ipairs(skipped) do
      if i<=4 then lines[i]=string.format('%d %s in %d places of %s; ask the owner',skipped[key].count,what,skipped[key].places,key) end
    end
    return kept,lines
  end
  -- Without an item (Gemini, after the courier tools): every assembler and furnace output in the radius, all items,
  -- output slots only (never inputs or fuel); count caps the total.
  local OUTPUT={['assembling-machine']='assembling_machine_output',furnace='furnace_result',['agricultural-tower']='agricultural_tower_output'}
  function M.start_all(p,a,ticks)
    assert(a.chests==nil or a.chests==false,'collect with radius and no item takes machine outputs only; name an item to take from chests')
    assert(a.quality==nil,'quality goes with item')
    for _,t in ipairs(a.types or {}) do assert(OUTPUT[t],'collect with radius and no item takes machine outputs: types may be assembling-machine and furnace') end
    local radius=api.integer(a.radius,32,1,256,'radius')
    local want=api.integer(a.count,1000000,1,1000000,'count')
    local places,total={},0
    for _,e in pairs(p.surface.find_entities_filtered{position=p.position,radius=radius,force=p.force,type=a.types or {'assembling-machine','furnace'}}) do
      local inv=e.valid and output_of(e)
      local n=0
      for _,s in ipairs(inv and inv.get_contents() or {}) do n=n+s.count end
      if n>0 then
        total=total+n
        places[#places+1]={entity=e,name=e.name,position=e.position,count=n}
      end
    end
    local skipped
    places,skipped=unclaimed(p,places,'items')
    local action={kind='gather',all=true,want=want,got=0,visited=0,items={},targets=route(p.position,places),index=1,until_tick=game.tick+ticks,min_fresh=a.min_fresh}
    local out={items='all',want=want<1000000 and want or nil,stock=total,places=#action.targets,skipped_claims=skipped}
    if total==0 then out.note='no assembler or furnace output in radius holds anything' end
    return action,out
  end
  function M.start(p,a,ticks)
    if a.item==nil then return M.start_all(p,a,ticks) end
    assert(type(a.item)=='string' and prototypes.item[a.item],'collect with radius requires a known item')
    local radius=api.integer(a.radius,32,1,256,'radius')
    local want=api.integer(a.count,10000,1,100000,'count')
    local chests=a.chests==true
    local s=M.scan(p,a.item,{radius=radius,quality=a.quality,types=a.types or (chests and TYPES or NO_CHESTS)})
    -- Another agent's claimed stock stays put; the result says whose it is.
    local skipped
    s.places,skipped=unclaimed(p,s.places,a.item)
    local action={kind='gather',item=a.item,quality=a.quality,outputs_only=a.outputs_only,want=want,got=0,visited=0,min_fresh=a.min_fresh,
      targets=route(p.position,s.places),index=1,until_tick=game.tick+ticks,avoid_enemies=a.avoid_enemies,unsafe_goal=a.unsafe_goal}
    M.guard(action)
    local left=M.screen_action(p,action,'every place holding '..a.item..' there')
    local out={item=a.item,want=want,stock=s.total,places=#action.targets,skipped_claims=skipped}
    M.left_out_into(out,left)
    if not chests and not a.types then
      -- Say how much sits in chests that this trip leaves alone.
      local all=M.scan(p,a.item,{radius=radius,quality=a.quality})
      if all.total>s.total then out.left_in_chests=all.total-s.total; out.note='chests are skipped; pass chests=true to take from them too' end
    end
    return action,out
  end
  -- Waiting at one machine (Muse, operator 09:31: a collect from a machine's
  -- output lost to its output inserters about four times): walk into reach,
  -- then take each product from its output the tick it is there, for up to
  -- wait ticks or until count, as a player standing there does. The machine's
  -- products_finished gives what it made meanwhile; what it made and what
  -- the output held less what was taken and what is left went to inserters.
  local WAIT_TYPES={['assembling-machine']=true,furnace=true}
  function M.start_wait(p,a,e,wait)
    if not WAIT_TYPES[e.type] then error(e.name..' is no assembler or furnace: wait_ticks waits at a machine\'s output',0) end
    if e.force~=p.force then error(e.name..' is not ours',0) end
    if a.item~=nil then assert(type(a.item)=='string' and prototypes.item[a.item],'item must be a known item') end
    local want=a.count and api.integer(a.count,nil,1,100000,'count') or 1000000
    local walk=api.integer(a.ticks,3600,1,36000,'ticks')
    local action={kind='gather',wait=wait,item=a.item,quality=a.quality,all=a.item==nil or nil,want=want,got=0,visited=0,items={},min_fresh=a.min_fresh,
      targets={{entity=e,position=e.position}},index=1,until_tick=game.tick+walk+wait}
    local recipe=pcall(e.get_recipe) and e.get_recipe()
    local okt,tk=pcall(M.output_takers,e,a.item); tk=okt and tk or nil
    return action,{machine=string.format('%s (%g,%g)',e.name,e.position.x,e.position.y),recipe=recipe and recipe.name or nil,wait_ticks=wait,
      count=a.count and want or nil,item=a.item,in_reach=p.can_reach_entity(e),
      taken_by_inserters=tk and tk.line or nil,follow_chests=tk and #tk.chests>0 and 'follow: true takes from '..tk.chests[1].name..string.format(' (%g,%g)',tk.chests[1].position.x,tk.chests[1].position.y)..' instead' or nil}
  end
  local function counts(inv)
    local out={}
    for _,st in ipairs(inv and inv.get_contents() or {}) do out[st.name]=(out[st.name] or 0)+st.count end
    return out
  end
  -- What one craft of the machine's recipe yields per item (the expected amount for a ranged or chance product).
  local function per_craft(e)
    local ok,recipe=pcall(e.get_recipe)
    if not (ok and recipe) and e.type=='furnace' then ok,recipe=pcall(function() return e.previous_recipe end) end
    local out={}
    for _,pr in ipairs(ok and recipe and recipe.products or {}) do
      if pr.type=='item' then
        local amount=pr.amount or ((pr.amount_min or 0)+(pr.amount_max or 0))/2
        out[pr.name]=(out[pr.name] or 0)+amount*(pr.probability or 1)
      end
    end
    return out
  end
  local function finished(e) local ok,n=pcall(function() return e.products_finished end); return ok and n or nil end
  -- What the wait saw, counted each tick (Sol, shift12 12:41: a wait at an assembler on iron-bacteria reported "made
  -- iron-bacteria*2, inserters_took iron-bacteria*2" from 16 crafts times the product's 10% chance, while its only
  -- output inserter takes spoilage and iron ore; nothing was taken because none was made). Per tick, before the take:
  -- what arrived in the output since the tick before, what the inserters picking from it took into their hands, and
  -- what left it otherwise (spoiled, or another player took it). On 2.0.77 the take reaches a product the tick it is
  -- there before an inserter waiting at the output does (a burner inserter at a stone furnace took none of 6 plates).
  local function takers(e)
    local ok,list=pcall(function()
      local b=e.bounding_box
      return e.surface.find_entities_filtered{area={{b.left_top.x-3,b.left_top.y-3},{b.right_bottom.x+3,b.right_bottom.y+3}},type='inserter',force=e.force}
    end)
    local out={}
    for _,ins in ipairs(ok and list or {}) do
      local okt,t=pcall(function() return ins.pickup_target end)
      if ins.valid and okt and t==e then out[#out+1]=ins end
    end
    return out
  end
  local function hand(ins)
    local ok,name,count=pcall(function()
      local st=ins.held_stack
      if st and st.valid_for_read then return st.name,st.count end
    end)
    if ok then return name,count end
  end
  -- The inserters that take a machine's output and where they put it (Sol, shift18: twice collect wait_ticks waited
  -- while inserters moved every lithium plate into an output chest): {rows, chests, line}. item: only inserters
  -- whose filter lets it through (a whitelist naming it, a blacklist not naming it, or no filter in use).
  local function passes(ins,item)
    if not item then return true end
    local ok,use=pcall(function() return ins.use_filters end)
    if not (ok and use) then return true end
    local okm,mode=pcall(function() return ins.inserter_filter_mode end)
    local named=false
    for i=1,5 do
      local okf,f=pcall(function() return ins.get_filter(i) end)
      -- (a filter's name, or the filter itself, may be a prototype: a table in tests, userdata in 2.0)
      local n=okf and f and (type(f)=='string' and f or (pcall(function() return f.name end)) and f.name)
      if n and type(n)~='string' then local okn,nm=pcall(function() return n.name end); n=okn and nm or nil end
      if n==item then named=true end
    end
    if okm and mode=='blacklist' then return not named end
    return named
  end
  function M.output_takers(e,item)
    local rows,chests,seen={},{},{}
    for _,ins in ipairs(takers(e)) do
      if passes(ins,item) then
        local okd,drop=pcall(function() return ins.drop_target end)
        local held=0
        local into='the ground'
        if okd and drop then
          into=string.format('%s (%g,%g)',drop.name,drop.position.x,drop.position.y)
          if item then held=(pcall(function() return drop.get_item_count(item) end)) and drop.get_item_count(item) or 0 end
          if (drop.type=='container' or drop.type=='logistic-container') and not seen[drop.unit_number] then
            seen[drop.unit_number]=true
            chests[#chests+1]={entity=drop,position={x=drop.position.x,y=drop.position.y},name=drop.name,holds=held}
          end
        end
        rows[#rows+1]=string.format('%s (%g,%g) into %s%s',ins.name,ins.position.x,ins.position.y,into,
          okd and drop and item and string.format(' (holds %d %s)',held,item) or '')
      end
    end
    if #rows==0 then return nil end
    return {rows=rows,chests=chests,
      line=string.format('%d inserter%s take%s %s from its output as it is made: %s',#rows,#rows==1 and '' or 's',#rows==1 and 's' or '',
        item or 'its products',table.concat(rows,'; '))}
  end
  local function watch(w,e)
    if not w.takers or game.tick>=w.takers_tick then w.takers=takers(e); w.takers_tick=game.tick+300 end
    local grabbed={}
    for _,ins in ipairs(w.takers) do
      if ins.valid then
        local name,count=hand(ins)
        local prev=w.hands[ins.unit_number]
        if name and (not prev or prev.name~=name) then grabbed[name]=(grabbed[name] or 0)+count
        elseif name and count>prev.count then grabbed[name]=(grabbed[name] or 0)+count-prev.count end
        w.hands[ins.unit_number]=name and {name=name,count=count} or nil
      end
    end
    local now=counts(output_of(e))
    local names={}
    for k in pairs(now) do names[k]=true end
    for k in pairs(w.last) do names[k]=true end
    for k in pairs(grabbed) do names[k]=true end
    for name in pairs(names) do
      local d=(now[name] or 0)-(w.last[name] or 0)+(grabbed[name] or 0)
      if d>0 then w.arrived[name]=(w.arrived[name] or 0)+d elseif d<0 then w.gone[name]=(w.gone[name] or 0)-d end
      if grabbed[name] then w.grabbed[name]=(w.grabbed[name] or 0)+grabbed[name] end
    end
    w.last=now
  end
  function M.wait_tick(p,action)
    local t=action.targets[1]
    local e=t.entity
    if not (e and e.valid) then action.why='the machine is gone'; return action.got>0 and 'collected' or 'nothing_collected' end
    if not p.can_reach_entity(e) then
      if not action.nav then
        action.nav={position=t.position,tolerance=t.pickup_reach and math.max(0.1,t.pickup_reach-0.2) or math.max(1,(p.reach_distance or 10)-3),max_stalls=6,replans=0,stalled=0,last_position=p.position}
        -- an entity stop: arrived once within its transfer reach (A5, Gemini 21:29: a silo's centre lies inside it)
        if t.entity and t.entity.valid and not t.pickup_reach and api.reach_target then
          local okr,rt=pcall(api.reach_target,p,t.entity)
          if okr and rt then action.nav.reach_target=rt end
        end
        api.request_path(p,action.nav)
      end
      local outcome=api.navigate(p,action.nav)
      if outcome then
        api.stop_walking(p); action.unreached=1
        action.why=(action.followed_to and action.followed_to..'; ' or '')..'the walk to it ended '..outcome..' out of reach'
        return action.got>0 and 'collected' or 'unreached'
      end
      return nil
    end
    if not action.waiting then
      api.stop_walking(p); action.nav=nil; action.visited=1
      local now=counts(output_of(e))
      action.waiting={since=game.tick,finished=finished(e),output=now,per_craft=per_craft(e),last=now,arrived={},grabbed={},gone={},hands={}}
      -- (a followed chest keeps the wait's end: D1)
      action.wait_end=action.wait_end or game.tick+action.wait
    end
    -- follow during the wait (D1, Sol 00:20: one finished barrel sat in an output chest out of reach while the wait stood
    -- at the machine until a rescue by hand): every half second, the chests its output inserters fill; one in reach that
    -- holds the item is taken from, one out of reach becomes where the wait stands (walked to, as into reach of the
    -- machine), and a walk that ends out of reach ends the wait unreached, saying where the items are.
    if action.follow and action.machine==nil and game.tick>=(action.follow_next or 0) then
      action.follow_next=game.tick+30
      local okt,tk=pcall(M.output_takers,e,action.item)
      for _,c in ipairs(okt and tk and tk.chests or {}) do
        local ch=c.entity
        local inv=ch.valid and output_of(ch)
        local n=inv and (action.item and inv.get_item_count{name=action.item,quality=action.quality or 'normal'} or (not inv.is_empty() and 1 or 0)) or 0
        if n>0 then
          if p.can_reach_entity(ch) then
            action.trash_tally=action.trash_tally or {}
            local ok,out=pcall(api.take,p,ch,action.item,action.quality,math.min(10000,action.want-action.got),nil,action.trash_tally)
            if ok and out.transferred>0 then
              action.got=action.got+out.transferred
              for _,st in ipairs(out.items or {{name=action.item,count=out.transferred}}) do
                if st.name and st.count and st.count>0 then action.items[st.name]=(action.items[st.name] or 0)+st.count end
              end
              local k=string.format('%s (%g,%g)',ch.name,ch.position.x,ch.position.y)
              action.followed_took=action.followed_took or {}
              action.followed_took[k]=(action.followed_took[k] or 0)+out.transferred
              if out.inventory_full then return 'inventory_full' end
            end
          else
            action.machine=string.format('%s (%g,%g)',e.name,e.position.x,e.position.y)
            action.followed_to=string.format('its output inserters put %s into %s (%g,%g), out of reach: the wait walked there and takes from it',
              action.item or 'its products',ch.name,ch.position.x,ch.position.y)
            action.targets[1]={entity=ch,position=ch.position}
            action.waiting=nil; action.nav=nil
            return nil
          end
        end
      end
    end
    local w=action.waiting
    pcall(watch,w,e)
    local inv=output_of(e)
    local here=inv and (action.item and inv.get_item_count{name=action.item,quality=action.quality or 'normal'} or (not inv.is_empty() and 1 or 0)) or 0
    if here>0 then
      action.trash_tally=action.trash_tally or {}
      local ok,out=pcall(api.take,p,e,action.item,action.quality,math.min(10000,action.want-action.got),OUTPUT[e.type],action.trash_tally)
      if ok then
        action.got=action.got+out.transferred
        for _,st in ipairs(out.items or {{name=action.item,count=out.transferred}}) do
          if st.name and st.count and st.count>0 then
            action.items[st.name]=(action.items[st.name] or 0)+st.count
            -- (taken out of the output now: not gone otherwise at the next tick)
            if w.last then w.last[st.name]=math.max(0,(w.last[st.name] or 0)-st.count) end
          end
        end
        if out.inventory_full then return 'inventory_full' end
      else action.take_error=tostring(out) end
    end
    -- The other machines (collect positions with wait_ticks): each reached from here, taken from the same way.
    for _,x in ipairs(action.also or {}) do
      if action.got>=action.want then break end
      if x.valid and p.can_reach_entity(x) then
        local xi=output_of(x)
        local n=xi and (action.item and xi.get_item_count{name=action.item,quality=action.quality or 'normal'} or (not xi.is_empty() and 1 or 0)) or 0
        if n>0 then
          action.trash_tally=action.trash_tally or {}
          local ok,out=pcall(api.take,p,x,action.item,action.quality,math.min(10000,action.want-action.got),OUTPUT[x.type],action.trash_tally)
          if ok then
            action.got=action.got+out.transferred
            local k=string.format('%s (%g,%g)',x.name,x.position.x,x.position.y)
            action.also_took=action.also_took or {}
            action.also_took[k]=(action.also_took[k] or 0)+out.transferred
            for _,st in ipairs(out.items or {{name=action.item,count=out.transferred}}) do
              if st.name and st.count and st.count>0 then action.items[st.name]=(action.items[st.name] or 0)+st.count end
            end
            if out.inventory_full then return 'inventory_full' end
          end
        end
      elseif x.valid then
        action.also_unreached=action.also_unreached or {}
        action.also_unreached[string.format('%s (%g,%g)',x.name,x.position.x,x.position.y)]=true
      end
    end
    if action.got>=action.want then return 'collected' end
    if game.tick>=action.wait_end then return action.got>0 and 'collected' or 'nothing_collected' end
  end
  -- The wait's count: what it took, what the machine made, what its inserters took (per item, as name*count lines).
  -- A wait carried over a harness update (carry.lua) from a runtime that did not count its output each tick (before
  -- shift12 13:45): counting starts now, from what the output holds.
  function M.carried(action)
    local w=action.wait and action.waiting
    if type(w)~='table' or w.arrived then return end
    local t=action.targets and action.targets[1]
    local e=t and t.entity
    local now=e and e.valid and counts(output_of(e)) or {}
    w.last=now; w.arrived={}; w.grabbed={}; w.gone={}; w.hands={}; w.counted_from=game.tick
  end
  function M.wait_report(action)
    local w=action.waiting
    if not w then return nil end
    local e=action.targets[1].entity
    local function line(t)
      local parts={}
      for name,n in pairs(t) do if n>0 then parts[#parts+1]={name=name,n=n} end end
      table.sort(parts,function(x,y) return x.n>y.n or (x.n==y.n and x.name<y.name) end)
      for i,v in ipairs(parts) do parts[i]=v.name..'*'..math.floor(v.n+0.5) end
      return #parts>0 and table.concat(parts,' ') or 'none'
    end
    local out={took=line(action.items),waited_s=math.floor((game.tick-w.since)/6+0.5)/10}
    -- follow during the wait (D1)
    if action.followed_took then
      local parts={}
      for k,n in pairs(action.followed_took) do parts[#parts+1]=k..' '..n end
      table.sort(parts)
      out.followed_took=table.concat(parts,', ')
    end
    out.followed_to=action.followed_to and action.followed_to..' (from '..tostring(action.machine)..')' or nil
    if action.also then
      local parts={}
      for k,n in pairs(action.also_took or {}) do parts[#parts+1]=k..' '..n end
      table.sort(parts)
      local far={}
      for k in pairs(action.also_unreached or {}) do if not (action.also_took or {})[k] then far[#far+1]=k end end
      table.sort(far)
      out.also=(#parts>0 and 'from the others: '..table.concat(parts,', ') or 'from the others: none')..(#far>0 and '; out of reach from where it stood: '..table.concat(far,', ') or '')
    end
    local now=e and e.valid and finished(e)
    local crafts=now and w.finished and now-w.finished or nil
    out.crafts=crafts
    -- Counted in the output each tick (watch), not estimated from crafts.
    if w.arrived then
      out.made=line(w.arrived); out.inserters_took=line(w.grabbed)
      out.left_otherwise=next(w.gone) and line(w.gone)..' (spoiled, or another player took it)' or nil
      -- Carried over a harness update from a runtime that did not count (M.carried).
      if w.counted_from then
        out.counted_from=string.format('made, inserters_took and left_otherwise are counted from tick %d (a harness update); the wait began at tick %d',
          w.counted_from,w.since)
      end
    end
    -- Products a craft makes only by chance: how often.
    local chance,odds={},{}
    local ok,recipe=pcall(function() return e.get_recipe() or (e.type=='furnace' and e.previous_recipe) end)
    for _,pr in ipairs(ok and recipe and recipe.products or {}) do
      if pr.type=='item' and pr.probability and pr.probability<1 then
        odds[pr.name]=pr.probability
        chance[#chance+1]=string.format('%s comes from %g%% of crafts',pr.name,pr.probability*100)
      end
    end
    out.chance=#chance>0 and table.concat(chance,'; ') or nil
    -- Nothing taken: why.
    if action.got==0 and w.arrived then
      local function sum(t) local n=0; for _,v in pairs(t) do n=n+v end; return n end
      local item=action.item
      local made=item and (w.arrived[item] or 0) or sum(w.arrived)
      local by=item and (w.grabbed[item] or 0) or sum(w.grabbed)
      local gone=item and (w.gone[item] or 0) or sum(w.gone)
      local what=item or 'products'
      if action.take_error then out.why='taking from its output failed: '..action.take_error
      elseif made==0 then
        local why=string.format('the machine made no %s in %g s (%d craft%s)',what,out.waited_s,crafts or 0,crafts==1 and '' or 's')
        local p=item and odds[item]
        if p and crafts and crafts>0 then why=why..string.format('; %s comes from %g%% of crafts: about %.1f expected',item,p*100,crafts*p) end
        if crafts==0 then
          local okst,status=pcall(function() return e.status end)
          for k,v in pairs(okst and defines.entity_status or {}) do if v==status then why=why..'; its status: '..k end end
        end
        out.why=why
      else
        local parts={}
        if by>0 then parts[#parts+1]=string.format('its output inserters took %d',by) end
        if gone>0 then parts[#parts+1]=string.format('%d left the output otherwise (spoiled, or another player took it)',gone) end
        out.why=string.format('the machine made %d %s%s',made,what,#parts>0 and '; '..table.concat(parts,'; ') or '')
      end
    end
    return out
  end
  -- Tours: the same walk through given entities (turrets, burners), topping
  -- each up; op names the runtime's visit ('rearm' or 'refuel').
  local MAX_TOUR=128
  function M.start_tour(p,op,entities,ticks,fields)
    local places={}
    for i,e in ipairs(entities) do places[i]={entity=e,position=e.position} end
    -- ordered: the caller's walking order (rearm's clusters, nearest first), never re-routed.
    local targets
    if fields and fields.ordered then
      targets={}
      for i=1,math.min(#places,MAX_TOUR) do targets[i]=places[i] end
    else targets=route(p.position,places,MAX_TOUR) end
    local action={kind='gather',op=op,got=0,visited=0,want=math.huge,targets=targets,index=1,until_tick=game.tick+ticks}
    for k,v in pairs(fields or {}) do if k~='ordered' and k~='screened' then action[k]=v end end
    M.guard(action)
    -- (screened: the caller checked its places itself: rearm's clusters, recover's corpses)
    local left=not (fields and fields.screened) and M.screen_action(p,action,'every place of this tour') or nil
    local out={op=op,item=action.item,places=#action.targets,skipped=#entities>MAX_TOUR and #entities-MAX_TOUR or nil,
      avoid_enemies=action.avoid_mode and api.describe_avoid and api.describe_avoid(action.avoid_mode) or nil}
    M.left_out_into(out,left)
    return action,out
  end
  -- round2120a (Haiku, shift14 03:58: rearm surface=true walked into a big worm's range, the character and 50
  -- explosives lost): every stop is checked at the call too, as each leg is (M.tick). One inside a worm's range,
  -- within 40 tiles of a spawner or in an area under attack now is left out and named, unless unsafe_goal; the first
  -- SCREEN stops of the walk, the rest when the walk comes to them. places: {position, entity?, name?}; returns the
  -- kept places in their order and {lines (the first 8), count}, or nil when none is left out.
  local SCREEN=64
  function M.screen(p,places,mode,unsafe)
    if not mode or unsafe or not api.goal_inside then return places,nil end
    local drop,lines,n={},{},0
    local passing,staying,first_at=0,0,nil
    for i=1,math.min(SCREEN,#places) do
      local pl=places[i]
      local ok,c=pcall(api.goal_inside,p,pl.position,mode)
      if ok and c then
        drop[i]=true; n=n+1
        -- (d17 batch13 A2) what holds it: a worm or spawner stays; an attack, units or a group seen now pass
        if c.m and c.m.attack then passing=passing+1; first_at=first_at or pl.position else staying=staying+1 end
        if #lines<8 then
          local e=pl.entity
          local name=(e and e.valid and e.name) or pl.name or 'place'
          lines[#lines+1]=api.goal_text(name,pl.position,c)
        end
      end
    end
    if n==0 then return places,nil end
    local kept={}
    for i,pl in ipairs(places) do if not drop[i] then kept[#kept+1]=pl end end
    local left={lines=lines,count=n,passing=passing,staying=staying,at=first_at}
    M.last_refusal={tick=game.tick,passing=passing,staying=staying,at=first_at}
    return kept,left
  end
  -- What holds the places left out (A2, Haiku: three rearms refused "within 40 tiles of biter-spawner", retried by
  -- hand): those a worm or spawner holds (it stays) and those passing enemies hold (they go), with the way on.
  function M.blocker_text(left)
    if not left then return '' end
    local parts={}
    if (left.staying or 0)>0 then parts[#parts+1]=string.format('%d held by a worm or spawner (it stays: unsafe_goal: true goes anyway)',left.staying) end
    if (left.passing or 0)>0 then parts[#parts+1]=string.format('%d by passing enemies, an attack or units seen now (retry_when_clear: true waits until they are gone near (%g,%g), then runs again)',
      left.passing,left.at and left.at.x or 0,left.at and left.at.y or 0) end
    return #parts>0 and ' ['..table.concat(parts,'; ')..']' or ''
  end
  -- An action's targets screened in place; none left: refused, naming them (what: 'every turret under 5 rounds there').
  function M.screen_action(p,action,what)
    local had=#action.targets
    local kept,left=M.screen(p,action.targets,action.avoid_mode,action.unsafe_goal)
    if not left then return nil end
    if #kept==0 and had>0 then
      error(string.format('%s lies in enemy reach the map shows: %s%s%s: unsafe_goal: true to go anyway, avoid_enemies: false for no check',
        what,table.concat(left.lines,'; '),left.count>#left.lines and string.format('; +%d more',left.count-#left.lines) or '',M.blocker_text(left)),0)
    end
    action.targets=kept
    action.left_out=left.lines; action.left_out_count=left.count
    return left
  end
  function M.left_out_into(out,left)
    if not left then return end
    out.left_out=left.lines
    out.left_out_more=left.count>#left.lines and left.count-#left.lines or nil
    out.left_out_note='left out of the walk: inside the enemy reach the map shows (unsafe_goal: true walks there too)'
  end
  -- Every tour walks with the enemy check (round1950a, Haiku 45h02m: a rearm tour walked past a nest into an attack
  -- and died): avoid_enemies as move_to's (default worms, spawners within 40 tiles and the areas under attack now;
  -- false: none), its legs round them, and a place inside one left out unless unsafe_goal (M.tick).
  function M.guard(action)
    if action.avoid_mode == nil and action.avoid_enemies ~= false and api.avoid_mode then action.avoid_mode = api.avoid_mode(action.avoid_enemies) end
    action.avoid_enemies = nil
  end
  -- A courier's legs (runtime.lua M.pick_source): its places in the given order, never re-routed; a place without
  -- an entity (find) is resolved on arrival, when the character comes within reach of its position.
  function M.start_legs(p,places,ticks,fields)
    local action={kind='gather',op='transfer',got=0,visited=0,want=math.huge,targets=places,index=1,until_tick=game.tick+ticks}
    for k,v in pairs(fields or {}) do action[k]=v end
    M.guard(action)
    -- A courier goes to both places or to none (round2120a): either inside the enemy reach refuses it.
    local _,left=M.screen(p,places,action.avoid_mode,action.unsafe_goal)
    if left then
      error(string.format('%s of this courier lie%s in enemy reach the map shows: %s: unsafe_goal: true to go anyway, avoid_enemies: false for no check',
        left.count==1 and 'a place' or 'both places',left.count==1 and 's' or '',table.concat(left.lines,'; ')),0)
    end
    return action
  end
  local function done(action)
    -- Nothing moved and every place failed or was not reached (Astra 08:47: every target failed read as a success):
    -- failed (the first reason in first_error), or unreached when none was reached.
    local errors,unreached=action.errors or 0,action.unreached or 0
    if action.got==0 and errors+unreached>0 and errors>=action.visited then
      return errors>0 and 'failed' or 'unreached'
    end
    -- load_silo {walk} (rocketload.lua): its silo stop ends it (loaded, launched, short, no_rocket); the stops ran out
    -- before that when the silo was not reached or its load failed.
    if action.op=='load_silo' then return action.final or (unreached>0 and 'unreached') or (errors>0 and 'failed') or 'short' end
    -- transfer {walk=true}: what moved, or nothing to take, or nothing the targets wanted
    if action.op=='transfer' then
      -- collect {walk=true} names its outcome as a collect does.
      if action.got>0 then return action.collect and 'collected' or 'transferred' end
      if (action.unreached or 0)>0 and action.visited==0 then return 'unreached' end
      return action.transfer.direction=='to_player' and 'nothing_collected' or 'nothing_to_do'
    end
    if action.op then return action.visited>0 and 'topped_up' or 'nothing_to_do' end
    return action.got>0 and 'collected' or 'nothing_collected'
  end
  -- The walk of a tour (C5, Luna 18:20: a 39-tile transfer was split into a walk and two calls; "report the actual
  -- route"): where the character stood at each via point and stop, and the tiles it moved, for last.route.
  local function r1(x) return math.floor(x*10+0.5)/10 end
  local function walked(p,action,label)
    action.walked=action.walked or {}
    if #action.walked<24 then action.walked[#action.walked+1]=string.format('%s (%g,%g)',label,r1(p.position.x),r1(p.position.y)) end
  end
  function M.route_text(action)
    if not action.walk_from or (action.tiles or 0)<1 and not action.via then return nil end
    return string.format('from (%g,%g)%s: %d tiles walked',r1(action.walk_from.x),r1(action.walk_from.y),
      action.walked and ' -> '..table.concat(action.walked,' -> ') or '',math.floor((action.tiles or 0)+0.5))
  end
  -- via: points walked in order before the first stop, each reached within 1.5 tiles; one not reached ends the tour
  -- unreached. Returns an outcome, or nil while walking them.
  local function via_tick(p,action)
    local i=action.via_i or 1
    local v=action.via[i]
    if not action.nav then
      if api.distance(p.position,v)<=1.5 then walked(p,action,'via '..i); action.via_i=i+1; return nil end
      action.nav={position=v,tolerance=1,max_stalls=6,replans=0,stalled=0,last_position=p.position}
      if action.avoid_mode and api.avoid_start then api.avoid_start(p,action.nav,action.avoid_mode) end
      api.request_path(p,action.nav)
    end
    local outcome=api.navigate(p,action.nav)
    if outcome and action.nav.foes and api.leg_done and api.leg_done(p,action.nav,outcome) then outcome=nil end
    if not outcome then return nil end
    local why=action.nav.why
    action.nav=nil; api.stop_walking(p)
    if outcome=='arrived' or outcome=='arrived_near' or api.distance(p.position,v)<=1.5 then walked(p,action,'via '..i); action.via_i=i+1; return nil end
    action.unreached=(action.unreached or 0)+1
    action.first_unreached=action.first_unreached or string.format('via point %d (%g,%g): %s%s',i,v.x,v.y,outcome,why and ': '..why or '')
    return 'unreached'
  end
  -- Returns an outcome when the gathering is over.
  -- (backlog #820, Opus 105h09: a recover ended "collected" standing on the rails at its stop and a locomotive killed him
  -- 2.3 tiles on) a tour that ends on a ground rail walks off it first, to the nearest free tile off the rails (the
  -- train guard keeps watch on that walk), then ends with its outcome; last.off_rails says where.
  local function ending(p,action,outcome)
    if outcome==nil or action.rail_exit or not (api.rail_under and api.off_rail_spot) then return outcome end
    if not api.rail_under(p,p.position) then return outcome end
    local spot=api.off_rail_spot(p)
    if not spot then return outcome end
    action.rail_exit={position=spot,outcome=outcome,tick=game.tick,from={x=p.position.x,y=p.position.y}}
    action.nav={position=spot,tolerance=0.3,max_stalls=6,replans=0,stalled=0,last_position=p.position,off_belts=true}
    api.request_path(p,action.nav)
    return nil
  end
  local function rail_exit_tick(p,action)
    local r=action.rail_exit
    local outcome=api.navigate(p,action.nav)
    if outcome or game.tick-r.tick>300 then
      api.stop_walking(p)
      action.off_rails=string.format('the tour ended on a rail at (%.1f,%.1f): walked off the rails to (%.1f,%.1f)%s',r.from.x,r.from.y,p.position.x,p.position.y,
        api.rail_under(p,p.position) and ' (still on a rail: the walk off was cut short)' or '')
      return r.outcome
    end
    return nil
  end
  function M.tick(p,action)
    if action.rail_exit then return rail_exit_tick(p,action) end
    return ending(p,action,M.tour_tick(p,action))
  end
  function M.tour_tick(p,action)
    if action.wait then return M.wait_tick(p,action) end
    local pos=p.position
    if action.walk_last then action.tiles=(action.tiles or 0)+api.distance(action.walk_last,pos) else action.walk_from={x=pos.x,y=pos.y} end
    action.walk_last={x=pos.x,y=pos.y}
    if action.via and (action.via_i or 1)<=#action.via then return via_tick(p,action) end
    while true do
      if action.got>=action.want then return 'collected' end
      -- transfer {walk} filling a count over several chests (from: "nearest"): done once it is taken.
      if action.fill and action.got>=action.fill then return 'transferred' end
      local t=action.targets[action.index]
      if not t then return done(action) end
      if t.find and not t.entity and api.near(p,t.position) then
        local ok,e=pcall(api.find,p,t.position)
        t.find=nil
        if ok then t.entity=e
        else
          local why=tostring(e):gsub('^[^:]*:%d+: ','')
          action.rows=action.rows or {}
          action.rows[#action.rows+1]={position=t.position,error=why}
          action.errors=(action.errors or 0)+1
          action.first_error=action.first_error or string.format('(%g,%g): %s',t.position.x,t.position.y,why)
        end
      end
      if t.find and not t.entity then
        break
      elseif not (t.entity and t.entity.valid) then
        action.index=action.index+1; action.nav=nil
      elseif (t.pickup_reach and api.distance(p.position,t.position)<=t.pickup_reach) or (not t.pickup_reach and p.can_reach_entity(t.entity)) then
        local ok,out
        if action.op then ok,out=pcall(api.visit,p,action,t.entity)
        else
          -- tally: what each take puts over the personal request max (trash.lua)
          action.trash_tally=action.trash_tally or {}
          ok,out=pcall(api.take,p,t.entity,action.item,action.quality,math.min(10000,action.want-action.got),(action.all or action.outputs_only) and OUTPUT[t.entity.type] or nil,action.trash_tally)
        end
        if not (ok and out.wait) then action.index=action.index+1; action.visited=action.visited+1; if action.walk_from and (action.tiles or 0)>=1 then walked(p,action,t.entity.valid and t.entity.name or 'stop') end end
        action.nav=nil
        if ok then
          action.got=action.got+out.transferred
          if out.transferred>0 then action.touched=(action.touched or 0)+1 end
          for _,st in ipairs(action.all and out.items or {}) do
            local key=st.name..(st.quality and '@'..st.quality or '')
            action.items[key]=(action.items[key] or 0)+st.count
          end
          if out.inventory_full then return 'inventory_full' end
          if out.stop then return out.stop end
          if out.wait then api.stop_walking(p);return nil end
        else
          action.errors=(action.errors or 0)+1
          action.first_error=action.first_error or string.format('(%g,%g): %s',t.position.x,t.position.y,(tostring(out):gsub('^[^:]*:%d+: ','')))
          -- A courier whose take failed goes no further (round1650d: Luna's walked on to the give).
          if action.legs and action.index==2 then return 'failed' end
        end
      else
        break
      end
    end
    local t=action.targets[action.index]
    if not action.nav then
      -- A place inside a worm's range, within 40 tiles of a spawner or in an area under attack now is not walked to
      -- (round1950a: Haiku's rearm cluster lay in attack #1548): left out, named, unless unsafe_goal.
      if action.avoid_mode and not action.unsafe_goal and api.goal_check then
        local okc,c=pcall(api.goal_check,p,p.position,t.position,action.avoid_mode)
        if okc and c then
          local why=api.goal_text('place',t.position,c)
          action.danger=(action.danger or 0)+1
          action.dangers=action.dangers or {}
          if #action.dangers<8 then action.dangers[#action.dangers+1]=why end
          action.first_unreached=action.first_unreached or string.format('(%g,%g): %s (unsafe_goal: true walks there)',t.position.x,t.position.y,why)
          action.index=action.index+1; action.unreached=(action.unreached or 0)+1
          if action.legs and action.index==2 then return 'unreached' end
          return nil
        end
      end
      action.nav={position=t.position,tolerance=t.pickup_reach and math.max(0.1,t.pickup_reach-0.2) or math.max(1,(p.reach_distance or 10)-3),max_stalls=6,replans=0,stalled=0,last_position=p.position}
      -- an entity stop: arrived once within its transfer reach (A5, Gemini 21:29: a silo's centre lies inside it)
      if t.entity and t.entity.valid and not t.pickup_reach and api.reach_target then
        local okr,rt=pcall(api.reach_target,p,t.entity)
        if okr and rt then action.nav.reach_target=rt end
      end
      -- avoid_mode (recover; transfer from: "nearest" walking, friction3: worms killed Opus on such a tour along a turret
      -- line): the walk keeps out of the enemy reach the map shows, as move_to's.
      if action.avoid_mode and api.avoid_start then api.avoid_start(p,action.nav,action.avoid_mode) end
      api.request_path(p,action.nav)
    end
    local outcome=api.navigate(p,action.nav)
    -- A leg round a nest ended: the next one starts.
    if outcome and action.nav.foes and api.leg_done and api.leg_done(p,action.nav,outcome) then outcome=nil end
    -- Arrived yet still out of reach, or blocked (or no way round the worms): skip this place (the first one's why in
    -- first_unreached).
    if outcome then
      if outcome=='no_safe_route' then
        action.unsafe=(action.unsafe or 0)+1
        local report={}
        if api.avoid_report then api.avoid_report(report,action.nav) end
        action.route_failures=action.route_failures or {}
        if #action.route_failures<8 then report.position=t.position;action.route_failures[#action.route_failures+1]=report end
        action.nav.why=report.why or action.nav.why
        if report.smaller_margins then action.nav.why=(action.nav.why or 'no route at requested clearance')..'; '..report.smaller_margins.line end
      end
      action.first_unreached=action.first_unreached or string.format('(%g,%g): %s%s',t.position.x,t.position.y,outcome,
        action.nav.why and ': '..action.nav.why or '')
      action.index=action.index+1; action.nav=nil; action.unreached=(action.unreached or 0)+1; api.stop_walking(p)
      -- A courier's take not reached: nothing taken, so no give either (it gave from the inventory before).
      if action.legs and action.index==2 then return 'unreached' end
    end
  end
  return M
end
