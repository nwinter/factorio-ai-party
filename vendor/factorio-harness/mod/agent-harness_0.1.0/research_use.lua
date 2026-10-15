-- Researched recipes against equipped/carried gear and existing building counts. Two factual lines;
-- no entity searches. The only world reads are the small loadout read and engine entity counters.
return function(api)
  local M={}
  local FAMILIES={
    {'furnaces','stone-furnace','steel-furnace','electric-furnace'},
    {'drills','burner-mining-drill','electric-mining-drill','big-mining-drill'},
    {'belts','transport-belt','fast-transport-belt','express-transport-belt','turbo-transport-belt'},
    {'assemblers','assembling-machine-1','assembling-machine-2','assembling-machine-3'},
  }
  local VEHICLES={car=true,['spider-vehicle']=true,locomotive=true,['cargo-wagon']=true,['fluid-wagon']=true,['artillery-wagon']=true}
  local KINDS={'armor','equipment','gun','ammo'}
  local catalogs={}
  local function try(fn) local ok,v=pcall(fn); if ok then return v end end
  local function clean(s) return (tostring(s):gsub('[\r\n]+',' ')) end
  local function sorted(t) local out={}; for k in pairs(t or {}) do out[#out+1]=k end; table.sort(out); return out end
  local function list(t,limit)
    local out={}; limit=limit or 24
    for i=1,math.min(#t,limit) do out[#out+1]=clean(t[i]) end
    if #t>limit then out[#out+1]='+'..(#t-limit)..' names omitted' end
    return #out>0 and table.concat(out,', ') or 'none'
  end
  local function kind(item)
    if not item then return nil end
    if item.type=='armor' or item.type=='gun' or item.type=='ammo' then return item.type end
    if item.place_as_equipment_result then return 'equipment' end
  end
  local function catalog(force)
    if catalogs[force.name] then return catalogs[force.name] end
    local out={gear={armor={},equipment={},gun={},ammo={}},entities={},vehicles={}}
    local function add(t,name,tech)
      t[name]=t[name] or {}; t[name][tech]=true
    end
    for tech,t in pairs(force.technologies or {}) do
      for _,effect in ipairs(try(function() return t.prototype.effects end) or {}) do
        if effect.type=='unlock-recipe' then
          local recipe=(force.recipes or {})[effect.recipe]
          for _,product in ipairs(recipe and recipe.products or {}) do
            local item=product.type~='fluid' and prototypes and prototypes.item and prototypes.item[product.name]
            if item then
              local k=kind(item)
              if k then add(out.gear[k],product.name,tech) end
              local e=item.place_result
              if e then
                add(out.entities,e.name,tech)
                if VEHICLES[e.type] then add(out.vehicles,e.name,tech) end
              end
            end
          end
        end
      end
    end
    -- No cache of an unavailable catalogue (a force may not have been initialized yet).
    if force.technologies and force.recipes then catalogs[force.name]=out end
    return out
  end
  local function unlocked(force,techs)
    for name in pairs(techs or {}) do
      local t=(force.technologies or {})[name]
      if t and t.researched then return true end
    end
    return false
  end
  local function names(force,map)
    local out={}
    for name,techs in pairs(map) do if unlocked(force,techs) then out[#out+1]=name end end
    table.sort(out); return out
  end
  local function add(t,name,n) if name then t[name]=(t[name] or 0)+(n or 1) end end
  local function counted(t,unknown)
    local out={}; for _,name in ipairs(sorted(t)) do out[#out+1]=name..' x'..t[name] end
    local text=list(out)
    if unknown and unknown>0 then text=(#out>0 and text or 'unknown')..'; '..unknown..' unread agent inventories' end
    return text
  end
  local function gear_line(force,c)
    local ok,loadout=pcall(api.loadout,force)
    if not ok or not loadout then
      local parts={}
      for _,k in ipairs(KINDS) do parts[#parts+1]=k..' researched: '..(force.recipes and list(names(force,c.gear[k])) or 'unknown') end
      return 'Agent equipment: loadout unavailable; '..table.concat(parts,' | ')
    end
    local worn,fitted,guns,ammo,carried={},{},{},{},{armor={},equipment={},gun={},ammo={}}
    local unknown={armor=0,equipment=0,gun=0,ammo=0,carried=0}
    local alive,absent=0,0
    for _,a in ipairs(loadout.agents) do
      if not a.alive then absent=absent+1 else
        alive=alive+1
        if a.armor_known then
          add(worn,a.armor and a.armor.name or 'no armor')
        else unknown.armor=unknown.armor+1 end
        if a.equipment_known then
          for _,e in ipairs(a.armor and a.armor.equipment or {}) do add(fitted,e.name,e.count) end
        else unknown.equipment=unknown.equipment+1 end
        for _,x in ipairs{{'gun',a.guns_known,a.guns,guns},{'ammo',a.ammo_known,a.ammo,ammo}} do
          if x[2] then for _,s in ipairs(x[3] or {}) do if s then add(x[4],s.name,s.count) end end
          else unknown[x[1]]=unknown[x[1]]+1 end
        end
        if a.carried then
          for _,s in ipairs(a.carried) do
            local k=kind(prototypes and prototypes.item and prototypes.item[s.name])
            if k then add(carried[k],s.name,s.count) end
          end
        else unknown.carried=unknown.carried+1 end
      end
    end
    local scope=string.format('Agent equipment (loadout now; %d bodies, %d without body',alive,absent)
    if (loadout.force_unknown or 0)>0 then scope=scope..'; '..loadout.force_unknown..' agents with unknown force' end
    scope=scope..'; counts combine qualities): '
    local out={}
    local equipped={armor=worn,equipment=fitted,gun=guns,ammo=ammo}
    local label={armor='worn',equipment='fitted in armor',gun='gun slots',ammo='ammo slots'}
    for _,k in ipairs(KINDS) do
      local researched=force.recipes and force.technologies and list(names(force,c.gear[k])) or 'unknown'
      out[#out+1]=k..' researched: '..researched..'; '..label[k]..': '..counted(equipped[k],unknown[k])..
        '; carried '..k..': '..counted(carried[k],unknown.carried)
    end
    return scope..table.concat(out,' | ')
  end
  local function buildings_line(force,c)
    if not force.recipes or not force.technologies then return 'Building tiers and vehicles: research unlock data unavailable' end
    local families,successors={},{}
    for _,family in ipairs(FAMILIES) do
      local show=false
      for i=3,#family do
        if unlocked(force,c.entities[family[i]]) then show=true; successors[#successors+1]=family[i] end
      end
      if show then families[#families+1]=family end
    end
    local out={}
    if #families>0 then
      out[#out+1]='Building tiers; researched successors: '..list(successors)
      local counts,asof=api.buildings(force)
      if not counts or not asof then out[#out+1]='planet counts unknown (no completed census with tier counts)'
      else
        out[#out+1]=string.format('planet counts from census %ds old',math.max(0,math.floor((game.tick-asof)/60)))
        local planets={}; for _,p in pairs(counts) do planets[#planets+1]=p end
        table.sort(planets,function(a,b) return a.surface<b.surface end)
        for i=1,math.min(#planets,16) do
          local p,parts=planets[i],{}
          for _,family in ipairs(families) do
            local tiers={}
            for j=2,#family do
              local name=family[j]
              if prototypes.entity and prototypes.entity[name] then tiers[#tiers+1]=name..' '..(p.entities[name] or 0) end
            end
            parts[#parts+1]=table.concat(tiers,', ')
          end
          out[#out+1]=clean(p.surface)..': '..table.concat(parts,' / ')
        end
        if #planets==0 then out[#out+1]='no planetary census rows' end
        if #planets>16 then out[#out+1]=(#planets-16)..' more planets omitted' end
      end
    else out[#out+1]='Building tiers: no researched successor in the tracked furnace/drill/belt/assembler families' end
    local vehicles={}
    for _,name in ipairs(names(force,c.vehicles)) do
      local n=try(function() return force.get_entity_count(name) end)
      vehicles[#vehicles+1]=name..' '..(n and tostring(n) or 'unknown')
    end
    out[#out+1]='vehicles researched / built (force engine counts now): '..list(vehicles)
    return table.concat(out,'; ')
  end
  function M.lines(force)
    local c=catalog(force)
    return {clean(gear_line(force,c)),clean(buildings_line(force,c))}
  end
  return M
end
