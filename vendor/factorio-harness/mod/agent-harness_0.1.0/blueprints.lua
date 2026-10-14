-- Blueprint metadata is free in vanilla; only ghosts are placed here. Physical
-- construction remains the player's/robots' job and consumes real inventory.
-- The factory is pure so the same module can be bundled into a hot reload.
return function(api)
  local H = {}
  local MAX_ENTITIES, MAX_TILES, MAX_STRING, MAX_SLOTS = 4096, 8192, 1000000, 32
  -- Factorio 2.0 remote view can place ghosts and order deconstruction on any
  -- charted chunk; robots still have to fly there and use real items.
  local MAX_AREA, MAX_AREA_ENTITIES = 256, 16384
  local directions = {north=0,east=4,south=8,west=12}
  local real = api.real or function(p) return p end

  local function permission(p, action)
    local group = p.permission_group
    assert(not group or group.allows_action(defines.input_action[action]), 'permission denied: '..action)
  end
  local function slot_name(a)
    local name = a.slot or 'clipboard'
    assert(type(name)=='string' and #name>=1 and #name<=64 and name:match('^[%w_-]+$'), 'invalid blueprint slot')
    return name
  end
  local function slots(p)
    local s = storage.agent_harness
    s.blueprints = s.blueprints or {}
    s.blueprints[p.index] = s.blueprints[p.index] or {}
    return s.blueprints[p.index]
  end
  local function save(p, name, value)
    local s = slots(p)
    if not s[name] then
      local count=0; for _ in pairs(s) do count=count+1 end
      assert(count<MAX_SLOTS, 'blueprint slot limit reached; overwrite or delete a slot')
    end
    assert(#value<=MAX_STRING, 'blueprint export exceeds size limit')
    s[name]=value
  end
  local function temporary(fn)
    local inv = game.create_inventory(1)
    local ok, result = pcall(fn, inv[1])
    inv.destroy()
    assert(ok, result)
    return result
  end
  local function validate(stack)
    assert(stack.valid_for_read and stack.is_blueprint, 'an individual blueprint is required')
    assert(stack.is_blueprint_setup(), 'blueprint is empty')
    assert(stack.get_blueprint_entity_count()<=MAX_ENTITIES, 'blueprint entity limit exceeded')
    local entities, tiles = stack.get_blueprint_entities() or {}, stack.get_blueprint_tiles() or {}
    assert(#tiles<=MAX_TILES, 'blueprint tile limit exceeded')
    for _, list in ipairs({entities,tiles}) do
      for _, item in ipairs(list) do
        local pos=api.position(item.position)
        assert(math.abs(pos.x)<=128 and math.abs(pos.y)<=128, 'blueprint extent exceeds limit')
      end
    end
    return entities, tiles
  end
  local function validate_tree(stack, budget, depth)
    assert(depth<=8, 'blueprint book nesting limit exceeded')
    assert(stack.valid_for_read and (stack.is_blueprint or stack.is_blueprint_book), 'only blueprints and blueprint books are supported')
    budget.items=budget.items+1; assert(budget.items<=128, 'blueprint book item limit exceeded')
    if stack.is_blueprint then
      local entities,tiles=validate(stack)
      budget.entities=budget.entities+#entities; budget.tiles=budget.tiles+#tiles
      assert(budget.entities<=4096 and budget.tiles<=8192, 'blueprint book content limit exceeded')
    else
      local inv=stack.get_inventory(defines.inventory.item_main)
      for i=1,#inv do if inv[i].valid_for_read then validate_tree(inv[i],budget,depth+1) end end
    end
  end
  local function selected(stack,a)
    local path=a.book_path or {}
    assert(type(path)=='table' and #path<=8, 'book_path must be an array of at most eight slot indices')
    local depth=1
    while stack.is_blueprint_book do
      assert(depth<=8, 'blueprint book nesting limit exceeded')
      local inv=stack.get_inventory(defines.inventory.item_main)
      local index=path[depth] or stack.active_index
      assert(type(index)=='number' and index==math.floor(index) and index>=1 and index<=#inv, 'invalid blueprint book index')
      stack=inv[index]
      assert(stack.valid_for_read, 'selected blueprint book slot is empty')
      depth=depth+1
    end
    assert(#path<depth, 'book_path extends beyond the selected blueprint')
    validate(stack)
    return stack
  end
  -- The team's blueprint library (operator 00:50): named entries captured from what the team built (blueprint_save),
  -- kept in the save for every agent and every later shift. An entry's string only ever comes from a capture.
  local MAX_LIBRARY, MAX_NAME, MAX_DESCRIPTION = 64, 40, 300
  local STALE = 24 * 60 * 60 * 60 -- 24 game hours unused: anyone may delete or rename the entry
  local function library()
    local s = storage.agent_harness
    s.bplibrary = s.bplibrary or {entries={}, revision=0}
    return s.bplibrary
  end
  local function entry_name(v, what)
    assert(type(v) == 'string' and #v >= 1 and #v <= MAX_NAME and v:match('^[%w][%w_.-]*$'),
      (what or 'name') .. ' must be 1..' .. MAX_NAME .. ' letters, digits, _ . - (starting with a letter or digit)')
    return v
  end
  local function library_entry(name)
    local e = library().entries[entry_name(name)]
    if not e then
      local names = {}
      for n in pairs(library().entries) do names[#names+1] = n end
      table.sort(names)
      error('no library entry ' .. name .. (#names > 0 and '; entries: ' .. table.concat(names, ', ', 1, math.min(#names, 20)) or '; the library is empty'), 0)
    end
    return e
  end
  local function load(p, a, fn)
    local value
    if a.name ~= nil then
      assert(a.slot == nil, 'give name (a library entry) or slot, not both')
      value = library_entry(a.name).string
    else
      value = slots(p)[slot_name(a)]
      assert(value, 'blueprint slot is empty')
    end
    return temporary(function(stack)
      assert(stack.import_stack(value)==0, 'blueprint import failed or contains missing prototypes')
      validate_tree(stack,{items=0,entities=0,tiles=0},0)
      return fn(stack)
    end)
  end
  local function area(p, a)
    assert(type(a.area)=='table', 'area requires left_top and right_bottom')
    local lt, rb = api.position(a.area.left_top), api.position(a.area.right_bottom)
    assert(lt.x<rb.x and lt.y<rb.y and rb.x-lt.x<=MAX_AREA and rb.y-lt.y<=MAX_AREA, 'area must have positive dimensions at most '..MAX_AREA..' by '..MAX_AREA)
    for x=math.floor(lt.x/32),math.floor(rb.x/32) do
      for y=math.floor(lt.y/32),math.floor(rb.y/32) do
        assert((api.own_platform and api.own_platform(p)) or p.force.is_chunk_charted(p.surface,{x=x,y=y}), 'area includes uncharted chunks')
      end
    end
    return {left_top=lt,right_bottom=rb}
  end
  -- Resource tiles are never selected by planners, so they must not consume the budget.
  local function candidates(p, box)
    local list = p.surface.find_entities_filtered{area=box, type='resource', invert=true, limit=MAX_AREA_ENTITIES+1}
    assert(#list<=MAX_AREA_ENTITIES, 'area entity limit exceeded; select a smaller area')
    return list
  end
  local function summary(stack, name)
    if stack.is_blueprint_book then
      local entries={}; local inv=stack.get_inventory(defines.inventory.item_main)
      for i=1,#inv do
        local item=inv[i]
        if item.valid_for_read then entries[#entries+1]={index=i,label=item.label or '',kind=item.is_blueprint_book and 'book' or 'blueprint'} end
      end
      return {slot=name,kind='book',label=stack.label or '',active_index=stack.active_index,entries=entries}
    end
    local entities, tiles = validate(stack)
    return {slot=name,kind='blueprint',entities=#entities,tiles=#tiles,label=stack.label or '',
      snap_to_grid=stack.blueprint_snap_to_grid or false}
  end
  local function capture(p,a,cut)
    permission(p,cut and 'deconstruct' or 'copy')
    permission(p,'select_blueprint_entities')
    local box=area(p,a)
    candidates(p,box) -- Bound work before asking Factorio to capture the region.
    local name=slot_name(a)
    return temporary(function(stack)
      stack.set_stack{name='blueprint',count=1}
      local mapping=stack.create_blueprint{surface=p.surface,force=p.force,area=box,
        always_include_tiles=a.tiles==true,include_entities=true,include_modules=true,
        include_station_names=a.station_names==true,include_trains=false,include_fuel=false}
      -- create_blueprint retains world coordinates. Rebase copied content so
      -- placement bounds and exported blueprints are independent of map origin.
      -- An even translation preserves the rail grid.
      local origin={x=math.floor((box.left_top.x+box.right_bottom.x)/4)*2,
        y=math.floor((box.left_top.y+box.right_bottom.y)/4)*2}
      local entities=stack.get_blueprint_entities() or {}
      for _,e in ipairs(entities) do e.position={x=e.position.x-origin.x,y=e.position.y-origin.y} end
      stack.set_blueprint_entities(entities)
      local tiles=stack.get_blueprint_tiles() or {}
      for _,t in ipairs(tiles) do t.position={x=t.position.x-origin.x,y=t.position.y-origin.y} end
      if #tiles>0 then stack.set_blueprint_tiles(tiles) end
      local result=summary(stack,name)
      save(p,name,stack.export_stack())
      if cut then
        result.marked=0
        -- Cut only the entities captured, never unrelated trees/resources.
        for _, e in pairs(mapping) do
          if e.valid and e.force==p.force and e.order_deconstruction(p.force,real(p)) then result.marked=result.marked+1 end
        end
        result.tiles_marked=false -- Entity cut only: tile removal is not exposed.
      end
      return result
    end)
  end

  function H.blueprint_import(p,a)
    permission(p,'import_blueprint_string')
    assert(type(a.blueprint)=='string' and #a.blueprint>0 and #a.blueprint<=MAX_STRING, 'blueprint string size out of range')
    local name=slot_name(a)
    return temporary(function(stack)
      assert(stack.import_stack(a.blueprint)==0, 'blueprint import failed or contains missing prototypes')
      validate_tree(stack,{items=0,entities=0,tiles=0},0)
      local result=summary(stack,name)
      save(p,name,stack.export_stack())
      return result
    end)
  end
  local function inspect_blueprint(p,a)
    return load(p,a,function(root)
      local stack=selected(root,a)
      local entities,tiles=validate(stack)
      local result=summary(stack,slot_name(a))
      result.layout=entities
      result.tile_layout=tiles
      result.materials=stack.cost_to_build or {}
      result.coordinates='normalized blueprint-relative positions; cursor placement may snap; verify returned ghost positions'
      return result
    end)
  end
  function H.blueprint_export(p,a)
    permission(p,'export_blueprint')
    if a.layout==true then return inspect_blueprint(p,a) end
    return load(p,a,function(stack)
      local result=summary(stack,slot_name(a)); result.blueprint=stack.export_stack(); return result
    end)
  end
  local function slot_list(p)
    local out={}
    for name in pairs(slots(p)) do out[#out+1]=name end
    table.sort(out)
    return {slots=out,limit=MAX_SLOTS}
  end
  local function slot_delete(p,a)
    local name=slot_name(a); local s=slots(p); local existed=s[name]~=nil; s[name]=nil
    return {slot=name,deleted=existed}
  end
  function H.blueprint_capture(p,a) return capture(p,a,false) end
  function H.copy(p,a) return capture(p,a,false) end
  function H.cut(p,a) return capture(p,a,true) end

  -- A short paste, entity by entity (placewhy.lua). Where each blueprint
  -- entity landed: its offset turned with the paste, plus the shift the game
  -- used, read from the ghosts and entities standing where the layout puts
  -- them (the shift most of them agree on), else the paste position snapped
  -- to the grid. Each spot without its entity gets the game's reason;
  -- entities there from before with other settings (recipe, filters,
  -- modules) are listed with the configure call that fixes them.
  local MAX_ROWS=20
  -- Where the paste put each blueprint entity: the shift the game used, and a
  -- function from a blueprint entity to its spot and to what stands there
  -- (a ghost or an entity of its name), or nil; and the shift (where the
  -- blueprint's origin landed). The game puts the blueprint's center (c,
  -- blueprint coordinates) at the paste position.
  local function locate(p,a,entities,pos,direction,box,c)
    local W=api.placewhy
    local function turn(e)
      local x,y=e.position.x,e.position.y
      if a.flip_horizontal then x=-x end
      if a.flip_vertical then y=-y end
      return W.rotate(x,y,direction)
    end
    local cx,cy=turn({position=c})
    local expect={x=pos.x-cx,y=pos.y-cy}
    local found={}
    for _,e in pairs(p.surface.find_entities_filtered{area=box,force=p.force}) do
      if e.valid and e.type~='tile-ghost' then
        local name=e.type=='entity-ghost' and e.ghost_name or e.name
        found[name]=found[name] or {}
        table.insert(found[name],e)
      end
    end
    local votes,shift,best,near={},nil,0,math.huge
    for i,e in ipairs(entities) do
      if i>256 then break end
      local x,y=turn(e)
      for _,f in ipairs(found[e.name] or {}) do
        local ox,oy=f.position.x-x,f.position.y-y
        local k=ox..','..oy
        votes[k]=(votes[k] or 0)+1
        local d=(ox-expect.x)^2+(oy-expect.y)^2
        if votes[k]>best or (votes[k]==best and d<near) then best,near,shift=votes[k],d,{x=ox,y=oy} end
      end
    end
    if not shift then
      local e=entities[1]
      local proto=prototypes.entity[e.name]
      local w,h=proto and proto.tile_width or 1,proto and proto.tile_height or 1
      if ((e.direction or 0)+direction)%8==4 then w,h=h,w end
      local x,y=turn(e)
      local function snap(v,odd) return odd and math.floor(v)+0.5 or math.floor(v+0.5) end
      shift={x=snap(expect.x+x,w%2==1)-x,y=snap(expect.y+y,h%2==1)-y}
    end
    return function(e)
      local x,y=turn(e)
      local at={x=shift.x+x,y=shift.y+y}
      for _,f in ipairs(found[e.name] or {}) do
        if f.valid and math.abs(f.position.x-at.x)<0.01 and math.abs(f.position.y-at.y)<0.01 then return at,f end
      end
      return at,nil
    end, shift, turn
  end
  -- The blueprint's center as the game takes it: the middle of the box around
  -- every entity's tiles and every tile, in blueprint coordinates.
  -- The tiles a layout covers: left, top, right, bottom (nil when empty).
  local function extent(entities,tiles)
    local l,t,r,b
    local function add(x1,y1,x2,y2)
      l,t=math.min(l or x1,x1),math.min(t or y1,y1); r,b=math.max(r or x2,x2),math.max(b or y2,y2)
    end
    for _,e in ipairs(entities) do
      local proto=prototypes.entity[e.name]
      local w,h=proto and proto.tile_width or 1,proto and proto.tile_height or 1
      if (e.direction or 0)%8==4 then w,h=h,w end
      add(e.position.x-w/2,e.position.y-h/2,e.position.x+w/2,e.position.y+h/2)
    end
    for _,tl in ipairs(tiles or {}) do add(tl.position.x,tl.position.y,tl.position.x+1,tl.position.y+1) end
    return l,t,r,b
  end
  local function center(entities,tiles)
    local l,t,r,b=extent(entities,tiles)
    if not l then return {x=0,y=0} end
    return {x=(l+r)/2,y=(t+b)/2}
  end
  -- The blueprint's circuit and copper wires between ends that stand now
  -- (forced paste, Astra 18:51: Sunward's module-audit paste needed its wires
  -- after place_ghosts one by one): each missing one is connected as a player's
  -- paste does, ghost to ghost or to a matching entity from before; a wire
  -- with an end not placed is counted apart.
  local function wire_list(entities)
    local list,seen={},{}
    for _,e in ipairs(entities) do
      for _,w in ipairs(e.wires or {}) do
        local s,sid,t,tid=w[1] or w.source_entity_number or e.entity_number,w[2] or w.source_wire_connector_id,w[3] or w.target_entity_number,w[4] or w.target_wire_connector_id
        if s and sid and t and tid then
          local k1,k2=s..':'..sid,t..':'..tid
          local key=k1<k2 and k1..'-'..k2 or k2..'-'..k1
          if not seen[key] then seen[key]=true; list[#list+1]={s,sid,t,tid} end
        end
      end
    end
    return list
  end
  local function restore_wires(entities,where,out)
    local list=wire_list(entities)
    if #list==0 then return end
    local by_number={}
    for _,e in ipairs(entities) do if e.entity_number then by_number[e.entity_number]=e end end
    local cache={}
    local function stands(n)
      if cache[n]==nil then cache[n]=select(2,where(by_number[n])) or false end
      return cache[n] or nil
    end
    local w={in_blueprint=#list,connected=0,added=0,end_not_placed=0,failed=0}
    local missing={}
    for _,wire in ipairs(list) do
      local e1,e2=by_number[wire[1]],by_number[wire[3]]
      local f1,f2=e1 and stands(wire[1]),e2 and stands(wire[3])
      if not (f1 and f2) then
        w.end_not_placed=w.end_not_placed+1
        local gone=not f1 and e1 or e2
        if gone and #missing<MAX_ROWS then missing[#missing+1]=gone.name..' #'..(not f1 and wire[1] or wire[3]) end
      else
        local ok,res=pcall(function()
          local c1,c2=f1.get_wire_connector(wire[2],true),f2.get_wire_connector(wire[4],true)
          if not (c1 and c2) then return 'failed' end
          if c1.is_connected_to(c2) then return 'connected' end
          return c1.connect_to(c2,false) and 'added' or 'failed'
        end)
        local k=ok and res or 'failed'
        w[k]=w[k]+1
      end
    end
    if #missing>0 then w.ends_not_placed=missing end
    out.wires=w
  end
  local function explain(p,a,entities,direction,before,ghost_key,where,out)
    local W=api.placewhy
    local missing,differ,old_ghosts,old_entities,nmiss,ndiff={},{},0,0,0,0
    for _,e in ipairs(entities) do
      local at,match=where(e)
      local dir=((e.direction or 0)+direction)%16
      if not match then
        nmiss=nmiss+1
        if #missing<MAX_ROWS then
          local ok,why=pcall(function()
            local proto=prototypes.entity[e.name]
            local chunk={x=math.floor(at.x/32),y=math.floor(at.y/32)}
            if not ((api.own_platform and api.own_platform(p)) or p.force.is_chunk_charted(p.surface,chunk)) then
              return string.format('outside the charted area (chunk %d,%d)',chunk.x,chunk.y)
            end
            local rule=W.tile_rules(p.surface,proto,at,dir)
            if rule then return rule end
            if p.surface.can_place_entity{name=e.name,position=at,direction=dir,force=p.force,
                build_check_type=defines.build_check_type.manual_ghost,forced=true} then
              return 'placeable here now: the paste skipped it (place_ghosts it)'
            end
            return api.blocked and api.blocked(p,proto,at,dir) or 'the game refuses it here'
          end)
          missing[#missing+1]={name=e.name,position=at,direction=W.direction_name(dir),reason=ok and why or tostring(why)}
        end
      elseif match.type=='entity-ghost' and before[ghost_key(match)]==nil then
        -- a ghost this paste made
      else
        if match.type=='entity-ghost' then old_ghosts=old_ghosts+1 else old_entities=old_entities+1 end
        local ok,d=pcall(W.settings_diff,match,e)
        if ok and d then
          ndiff=ndiff+1
          if #differ<MAX_ROWS then differ[#differ+1]={name=e.name,position=match.position,ghost=match.type=='entity-ghost' or nil,differs=d.differs,fix=d.fix} end
        end
      end
    end
    out.expected=#entities; out.existing_ghosts=old_ghosts; out.existing_entities=old_entities
    out.not_placed_count=nmiss; out.not_placed=#missing>0 and missing or nil
    out.settings_differ_count=ndiff>0 and ndiff or nil; out.settings_differ=#differ>0 and differ or nil
    local parts={}
    if old_ghosts+old_entities>0 then parts[#parts+1]=string.format('%d already there from before (%d built, %d ghosts)',old_ghosts+old_entities,old_entities,old_ghosts) end
    if nmiss>0 then parts[#parts+1]=string.format('%d not placed: not_placed says why%s',nmiss,nmiss>#missing and ' (first '..#missing..')' or '') end
    if ndiff>0 then parts[#parts+1]=string.format('%d of those from before have other settings than the blueprint: settings_differ, fix with configure',ndiff) end
    out.reason=#parts>0 and table.concat(parts,'; ') or 'the game placed fewer ghosts than the blueprint holds'
  end

  -- normal: all or nothing, as a player's paste; forced (shift-paste): ghosts
  -- where they fit, trees, rocks and the like in the way marked for
  -- deconstruction; superforced (ctrl+shift): our own entities in the way too.
  local MODES={normal=true,forced=true,superforced=true}
  -- A library entry's saved anchor (blueprint_save anchor): position is where that point lands. Returns the paste
  -- position and the anchor reply, or nil when the paste goes by center or hub.
  local function saved_anchor(a,c,direction,pos,anchor)
    if anchor~='saved' then return nil end
    local saved=a.name~=nil and library_entry(a.name).anchor
    assert(saved,'anchor saved: give a library entry saved with an anchor (blueprint_save anchor)')
    assert(not a.flip_horizontal and not a.flip_vertical,'flips do not go with the saved anchor (anchor=center places by the center)')
    assert(pos,'position is required: where the entry\'s anchor lands')
    local ax,ay=api.placewhy.rotate(saved.x-c.x,saved.y-c.y,direction)
    local paste={x=pos.x-ax,y=pos.y-ay}
    return paste,{by='saved',anchor=pos,paste_position=paste}
  end
  local function anchor_of(a,hub_e,on_platform)
    assert(a.anchor==nil or a.anchor=='hub' or a.anchor=='center' or a.anchor=='saved','anchor must be hub, center or saved')
    local saved=a.name~=nil and library().entries[a.name] and library().entries[a.name].anchor
    return a.anchor or (hub_e and on_platform and 'hub') or (saved and 'saved') or 'center'
  end
  function H.blueprint_place(p,a)
    permission(p,'build')
    local on_platform=type(p)=='table' and rawget(p,'__platform')~=nil
    assert(a.anchor==nil or a.anchor=='hub' or a.anchor=='center' or a.anchor=='saved','anchor must be hub, center or saved')
    -- With the hub anchor, position is where the blueprint's hub goes (default: the platform's hub).
    local pos=a.position~=nil and api.position(a.position) or nil
    local direction=directions[a.direction or 'north']; assert(direction, 'blueprint direction must be north, east, south, or west')
    local mode=a.mode or 'normal'
    assert(MODES[mode],'paste mode must be normal, forced or superforced')
    local build_mode=defines.build_mode[mode]
    assert(build_mode~=nil,'this game has no '..mode..' build mode')
    return load(p,a,function(root)
      -- Moving a nested book entry can invalidate its LuaItemStack slot. Copy
      -- the selected leaf into an independent inventory before cursor swaps.
      local blueprint=selected(root,a).export_stack()
      return temporary(function(stack)
        assert(stack.import_stack(blueprint)==0, 'selected blueprint could not be copied')
        local snapping_disabled=stack.blueprint_snap_to_grid~=nil
        stack.blueprint_snap_to_grid=nil
        local entities, tiles=validate(stack)
        local c=center(entities,tiles)
        -- Hub anchoring (Astra 18:55: a 33-entity Sunward paste placed 0, a
        -- 22-entity one landed at another offset): the game puts the
        -- blueprint's center at the paste position, so a blueprint whose hub
        -- is off its center lands shifted and its hub collides with the
        -- platform's own. On a platform a blueprint holding a hub is pasted so
        -- that its hub lands on the platform's hub (or on `position`).
        local hub_e
        for _,e in ipairs(entities) do if e.name=='space-platform-hub' then hub_e=e; break end end
        local anchor=anchor_of(a,hub_e,on_platform)
        local anchored
        if anchor=='saved' then pos,anchored=saved_anchor(a,c,direction,pos,anchor)
        elseif anchor=='hub' then
          assert(hub_e,'anchor hub: this blueprint holds no space-platform-hub')
          assert(on_platform,'anchor hub works on a platform (platform=NAME)')
          local target=pos
          if not target then
            local pl=p.surface.platform
            local hub=pl and pl.hub
            target=hub and hub.valid and {x=hub.position.x,y=hub.position.y} or {x=0,y=0}
          end
          local hx,hy=api.placewhy.rotate(hub_e.position.x-c.x,hub_e.position.y-c.y,direction)
          pos={x=target.x-hx,y=target.y-hy}
          anchored={by='hub',hub=target,paste_position=pos}
        end
        assert(pos,'position is required (the blueprint\'s center goes there; on a platform a blueprint with a hub is placed by its hub)')
        -- Validate a square containing every possible rotated or flipped
        -- footprint around the center: quarter turns and flips keep max(|x|,|y|) invariant.
        local radius=1
        for _, e in ipairs(entities) do
          local proto=prototypes.entity[e.name]
          assert(proto, 'blueprint contains an unavailable entity')
          local box=proto.selection_box
          local margin=0
          for _, corner in ipairs({box.left_top,box.right_bottom}) do
            margin=math.max(margin,math.abs(corner.x),math.abs(corner.y))
          end
          radius=math.max(radius, math.max(math.abs(e.position.x-c.x),math.abs(e.position.y-c.y))+margin+1)
        end
        for _, tile in ipairs(tiles) do radius=math.max(radius,math.max(math.abs(tile.position.x-c.x),math.abs(tile.position.y-c.y))+2) end
        local box=area(p,{area={left_top={x=pos.x-radius,y=pos.y-radius},right_bottom={x=pos.x+radius,y=pos.y+radius}}})
        local function ghosts()
          return p.surface.find_entities_filtered{area=box,type={'entity-ghost','tile-ghost'},force=p.force}
        end
        local function ghost_key(e)
          return e.unit_number or (e.type..':'..e.ghost_name..':'..e.position.x..':'..e.position.y)
        end
        local before={}
        for _,e in pairs(ghosts()) do before[ghost_key(e)]=true end
        -- What stood marked for deconstruction before a forced paste, to tell what it marked.
        local function marked()
          return p.surface.find_entities_filtered{area=box,to_be_deconstructed=true}
        end
        local function mark_key(e) return e.unit_number or (e.name..':'..e.position.x..':'..e.position.y) end
        local marked_before
        if mode~='normal' then
          marked_before={}
          for _,e in pairs(marked()) do marked_before[mark_key(e)]=true end
        end
        if type(p)=='table' and (rawget(p,'__platform') or rawget(p,'__bot')) then
          -- A platform is built from remote view: place the blueprint's ghosts
          -- on its surface directly; the cursor lives on the player's surface.
          -- A bot has no cursor at all.
          assert(not a.flip_horizontal and not a.flip_vertical, 'flips are not supported when pasting on a platform or as a bot')
          stack.build_blueprint{surface=p.surface,force=p.force,position=pos,direction=direction,
            build_mode=build_mode,skip_fog_of_war=true,by_player=real(p),raise_built=true}
        else
        assert(p.cursor_stack and not p.cursor_stack.valid_for_read, 'cursor must be empty; put held items away before pasting')
        local cursor_ghost=p.cursor_ghost
        assert(p.cursor_stack.swap_stack(stack), 'could not borrow cursor for blueprint')
        local ok,err=pcall(function()
          p.build_from_cursor{position=pos,direction=direction,flip_horizontal=a.flip_horizontal==true,
            flip_vertical=a.flip_vertical==true,build_mode=build_mode,skip_fog_of_war=true}
        end)
        local restored=p.cursor_stack.swap_stack(stack)
        if cursor_ghost then p.cursor_ghost=cursor_ghost end
        -- Only an empty cursor is borrowed: even a failed restore cannot delete
        -- a physical player item when temporary metadata is cleaned up.
        assert(restored, 'could not restore cursor after blueprint placement')
        assert(ok,err)
        end
        -- Per-ghost rows are opt-in: large layouts otherwise flood agent context.
        local out={count=0,by_name={},slot=a.name==nil and slot_name(a) or nil,name=a.name,snapping_disabled=snapping_disabled,mode=mode~='normal' and mode or nil}
        if a.details then out.ghosts={} end
        local inserters={}
        for _, e in pairs(ghosts()) do
          if e.valid and not before[ghost_key(e)] then
            if e.type=='entity-ghost' and e.ghost_type=='inserter' then inserters[#inserters+1]=e end
            out.count=out.count+1
            out.by_name[e.ghost_name]=(out.by_name[e.ghost_name] or 0)+1
            local x,y=e.position.x,e.position.y
            if out.bounds then
              local b=out.bounds
              b.left=math.min(b.left,x); b.top=math.min(b.top,y); b.right=math.max(b.right,x); b.bottom=math.max(b.bottom,y)
            else out.bounds={left=x,top=y,right=x,bottom=y} end
            if a.details then out.ghosts[#out.ghosts+1]={name=e.ghost_name,position=e.position,unit_number=e.unit_number,type=e.type} end
          end
        end
        -- Inserter ghosts with nothing to take from or put into on their
        -- points (Astra's bypass inserter that reached no crusher; targets.lua).
        if api.targets then out.inserters_without_target,out.inserters_without_target_count=api.targets.check(inserters,16) end
        -- Explain a short paste: the engine silently skips positions that
        -- already hold a matching ghost or entity, that collide, or whose
        -- tiles break the entity's rules. Per blueprint entity: there now (new
        -- ghost, or one from before), or not placed and why.
        local wired=#wire_list(entities)>0
        if out.count<#entities or wired or anchored then
          local where,shift,turn=locate(p,a,entities,pos,direction,box,c)
          if out.count<#entities then explain(p,a,entities,direction,before,ghost_key,where,out) end
          if wired then restore_wires(entities,where,out) end
          -- Where the blueprint landed: its origin (blueprint 0,0) and center, and its hub against the target.
          local cx,cy=turn({position=c})
          out.origin_at={x=shift.x,y=shift.y}; out.center_at={x=shift.x+cx,y=shift.y+cy}
          if anchored and anchored.by=='saved' then
            local saved=library_entry(a.name).anchor
            local rx,ry=api.placewhy.rotate(saved.x,saved.y,direction)
            local at={x=shift.x+rx,y=shift.y+ry}
            anchored.anchor_landed=at
            anchored.aligned=math.abs(at.x-anchored.anchor.x)<0.01 and math.abs(at.y-anchored.anchor.y)<0.01
            out.anchor=anchored
          elseif anchored then
            local at=where(hub_e)
            anchored.hub_landed=at
            anchored.aligned=math.abs(at.x-anchored.hub.x)<0.01 and math.abs(at.y-anchored.hub.y)<0.01
            out.anchor=anchored
          end
        end
        -- What a forced paste marked for deconstruction (trees, rocks; superforced: our own entities in the way).
        if marked_before then
          local n,by=0,{}
          for _,e in pairs(marked()) do
            if e.valid and not marked_before[mark_key(e)] then n=n+1; by[e.name]=(by[e.name] or 0)+1 end
          end
          if n>0 then out.marked_for_deconstruction=n; out.marked_by_name=by end
        end
        -- A library entry placed: when, by whom, how often (blueprint_list's last used; the 24 h rule).
        if a.name~=nil then
          local e=library_entry(a.name)
          e.last_used=game.tick; e.last_user=api.who(p); e.uses=(e.uses or 0)+1
          local lib=library(); lib.revision=lib.revision+1
        end
        return out
      end)
    end)
  end
  H.paste=H.blueprint_place

  -- Where a paste would put each blueprint entity and tile, placing nothing
  -- (paste dry_run, dryrun.lua): the game puts the blueprint's center at the
  -- paste position (on a platform with the hub anchor, its hub on the hub)
  -- and shifts the whole layout onto the tile grid (rails: the 2-tile grid).
  -- Flips mirror positions and directions before the turn.
  local RAIL={['straight-rail']=true,['half-diagonal-rail']=true,['curved-rail-a']=true,['curved-rail-b']=true,
    ['legacy-straight-rail']=true,['legacy-curved-rail']=true,['train-stop']=true,['rail-signal']=true,['rail-chain-signal']=true,['rail-ramp']=true}
  function H.plan(p,a)
    local on_platform=type(p)=='table' and rawget(p,'__platform')~=nil
    -- As blueprint_place: a platform or a bot pastes without a cursor, unflipped.
    assert(not (type(p)=='table' and (rawget(p,'__platform') or rawget(p,'__bot')) and (a.flip_horizontal or a.flip_vertical)),
      'flips are not supported when pasting on a platform or as a bot')
    assert(a.anchor==nil or a.anchor=='hub' or a.anchor=='center' or a.anchor=='saved','anchor must be hub, center or saved')
    local pos=a.position~=nil and api.position(a.position) or nil
    local direction=directions[a.direction or 'north']; assert(direction, 'blueprint direction must be north, east, south, or west')
    local mode=a.mode or 'normal'
    assert(MODES[mode],'paste mode must be normal, forced or superforced')
    return load(p,a,function(root)
      local stack=selected(root,a)
      local entities,tiles=validate(stack)
      local c=center(entities,tiles)
      local hub_e
      for _,e in ipairs(entities) do if e.name=='space-platform-hub' then hub_e=e; break end end
      local anchor=anchor_of(a,hub_e,on_platform)
      local anchored
      local function turn(x,y)
        if a.flip_horizontal then x=-x end
        if a.flip_vertical then y=-y end
        return api.placewhy.rotate(x,y,direction)
      end
      if anchor=='saved' then pos,anchored=saved_anchor(a,c,direction,pos,anchor)
      elseif anchor=='hub' then
        assert(hub_e,'anchor hub: this blueprint holds no space-platform-hub')
        assert(on_platform,'anchor hub works on a platform (platform=NAME)')
        local target=pos
        if not target then
          local pl=p.surface.platform
          local hub=pl and pl.hub
          target=hub and hub.valid and {x=hub.position.x,y=hub.position.y} or {x=0,y=0}
        end
        local hx,hy=api.placewhy.rotate(hub_e.position.x-c.x,hub_e.position.y-c.y,direction)
        pos={x=target.x-hx,y=target.y-hy}
        anchored={by='hub',hub=target,paste_position=pos}
      end
      assert(pos,'position is required (the blueprint\'s center goes there; on a platform a blueprint with a hub is placed by its hub)')
      local even=false
      for _,e in ipairs(entities) do
        local proto=prototypes.entity[e.name]
        if proto and RAIL[proto.type] then even=true end
      end
      local cx,cy=turn(c.x,c.y)
      local function round(v) if even then return 2*math.floor(v/2+0.5) end return math.floor(v+0.5) end
      local shift={x=round(pos.x-cx),y=round(pos.y-cy)}
      local list={}
      for i,e in ipairs(entities) do
        local x,y=turn(e.position.x,e.position.y)
        local d=e.direction or 0
        if a.flip_horizontal then d=(16-d)%16 end
        if a.flip_vertical then d=(24-d)%16 end
        list[i]={index=i,name=e.name,position={x=shift.x+x,y=shift.y+y},direction=(d+direction)%16,
          quality=type(e.quality)=='string' and e.quality or nil}
      end
      local tlist={}
      for i,t in ipairs(tiles or {}) do
        local x,y=turn(t.position.x+0.5,t.position.y+0.5)
        tlist[i]={index=i,name=t.name,position={x=math.floor(shift.x+x)+0.5,y=math.floor(shift.y+y)+0.5}}
      end
      if anchored and anchored.by=='saved' then
        local saved=library_entry(a.name).anchor
        local rx,ry=turn(saved.x,saved.y)
        anchored.anchor_landed={x=shift.x+rx,y=shift.y+ry}
        anchored.aligned=math.abs(anchored.anchor_landed.x-anchored.anchor.x)<0.01 and math.abs(anchored.anchor_landed.y-anchored.anchor.y)<0.01
      end
      return {entities=list,tiles=tlist,mode=mode,origin_at=shift,center_at={x=shift.x+cx,y=shift.y+cy},anchor=anchored,
        slot=a.name==nil and slot_name(a) or nil,name=a.name,label=stack.label~='' and stack.label or nil}
    end)
  end

  -- Tiles, as a planner in tile mode marks them (request #144: platform
  -- foundation): every minable tile in the area (tiles=true) or the named
  -- ones. The engine decides each (LuaTile.order_deconstruction); the result
  -- counts what it accepted and refused, and why when it can be told.
  local MAX_TILES=16384
  local function tile_names(v)
    local names,mine={},{}
    if v==true then
      for name,t in pairs(prototypes.tile) do
        if t.mineable_properties and t.mineable_properties.minable then names[#names+1]=name; mine[name]=true end
      end
      table.sort(names)
    else
      assert(type(v)=='table' and #v>0 and #v<=32,'tiles requires true or 1..32 tile names')
      for _,name in ipairs(v) do
        assert(type(name)=='string' and prototypes.tile[name],'unknown tile '..tostring(name))
        local t=prototypes.tile[name]
        names[#names+1]=name; mine[name]=t.mineable_properties and t.mineable_properties.minable or nil
      end
    end
    return names,mine
  end
  local function covers(e,t)
    local b,x,y=e.bounding_box,t.position.x,t.position.y
    return b and b.left_top.x<x+1 and b.right_bottom.x>x and b.left_top.y<y+1 and b.right_bottom.y>y
  end
  local function deconstruct_tiles(p,a,box,cancel,out)
    local names,mine=tile_names(a.tiles)
    if #names==0 then return end
    local list=p.surface.find_tiles_filtered{area=box,name=names,limit=MAX_TILES+1}
    assert(#list<=MAX_TILES,'area tile limit exceeded ('..MAX_TILES..' tiles); select a smaller area')
    local standing={}
    for _,e in ipairs(candidates(p,box)) do
      if e.valid and e.type~='entity-ghost' and e.type~='character' then standing[#standing+1]=e end
    end
    local function under(t) for _,e in ipairs(standing) do if covers(e,t) then return e end end end
    if cancel then
      local n=0
      for _,t in ipairs(list) do
        if t.valid and t.to_be_deconstructed(p.force) then t.cancel_deconstruction(p.force,real(p)); n=n+1 end
      end
      out.tiles_cancelled=n
      return
    end
    local marked,already,refused,blocked,blockers=0,0,{},0,{}
    local function refuse(why) refused[why]=(refused[why] or 0)+1 end
    for _,t in ipairs(list) do
      if not mine[t.name] then refuse('not_minable')
      elseif t.to_be_deconstructed(p.force) then already=already+1
      else
        local ok,res=pcall(t.order_deconstruction,p.force,real(p))
        if not ok then refuse('error')
        elseif res then marked=marked+1
        else refuse(under(t) and 'under_entity' or 'engine') end
      end
    end
    -- A marked tile waits for what stands on it: robots take it once that is gone.
    for _,t in ipairs(list) do
      if mine[t.name] and t.to_be_deconstructed(p.force) then
        local e=under(t)
        if e and not e.to_be_deconstructed(p.force) then blocked=blocked+1; blockers[e.name]=true end
      end
    end
    local total=0
    for _,n in pairs(refused) do total=total+n end
    out.tiles_marked,out.tiles_already,out.tiles_refused=marked,already,total
    out.refused=next(refused) and refused or nil
    out.tiles_blocked=blocked
    if blocked>0 then
      local list2={}
      for name in pairs(blockers) do list2[#list2+1]=name end
      table.sort(list2)
      out.note=string.format('%d marked tile(s) lie under entities not marked for deconstruction (%s): robots take a tile once what stands on it is gone; mark those too (entity_names)',
        blocked,table.concat(list2,', '))
    end
  end
  local function deconstruct(p,a,cancel)
    permission(p,cancel and 'cancel_deconstruct' or 'deconstruct')
    local filters={}
    for _,key in ipairs({'entity_types','entity_names'}) do
      if a[key] then
        assert(type(a[key])=='table' and #a[key]>0 and #a[key]<=32,key..' requires 1..32 names')
        filters[key]={}
        for _,value in ipairs(a[key]) do assert(type(value)=='string',key..' requires strings'); filters[key][value]=true end
      end
    end
    local box=area(p,a)
    local out={changed=0,mode=cancel and 'cancel' or 'mark',tiles=a.tiles~=nil and a.tiles~=false}
    -- Items on the ground, as a planner marks them (robots take them to
    -- storage); other entities then only with entity filters.
    if a.items_on_ground~=nil then
      assert(a.items_on_ground==true or a.items_on_ground==false,'items_on_ground must be boolean')
      assert(not out.tiles,'items_on_ground and tiles are separate calls')
    end
    if a.items_on_ground then
      api.ground_mark(p,box,cancel,out)
      if not (filters.entity_types or filters.entity_names) then return out end
    end
    -- With tiles, entities are taken only when entity filters name them;
    -- they go first, so a tile under one marked now is not counted blocked.
    if out.tiles and not (filters.entity_types or filters.entity_names) then deconstruct_tiles(p,a,box,cancel,out); return out end
    local list=candidates(p,box)
    local changed=0
    for _, e in ipairs(list) do
      if e.valid and (e.force==p.force or e.force.name=='neutral') and e.type~='character' and e.minable
        and (not filters.entity_types or filters.entity_types[e.type])
        and (not filters.entity_names or filters.entity_names[e.name]) then
        if cancel then
          if e.to_be_deconstructed(p.force) then e.cancel_deconstruction(p.force,real(p)); changed=changed+1 end
        elseif e.order_deconstruction(p.force,real(p)) then changed=changed+1 end
      end
    end
    out.changed=changed
    if out.tiles then deconstruct_tiles(p,a,box,cancel,out) end
    return out
  end
  function H.deconstruct(p,a) return deconstruct(p,a,false) end
  function H.cancel_deconstruction(p,a) return deconstruct(p,a,true) end

  -- The library's actions: blueprint_save captures, blueprint_list reads, blueprint_place (and paste, dry_run,
  -- blueprint_export) take name, blueprint_delete and blueprint_rename change it. An entry's author changes it any
  -- time; anyone else once it has gone 24 game hours unused (last placed, or saved when never placed).
  local function ago(ticks)
    local m=math.floor(math.max(0,ticks)/3600)
    if m>=60 then return string.format('%dh%02dm ago',math.floor(m/60),m%60) end
    return m..'m ago'
  end
  local function counts_line(counts,limit)
    local list={}
    for n,c in pairs(counts or {}) do list[#list+1]={n=n,c=c} end
    table.sort(list,function(x,y) if x.c~=y.c then return x.c>y.c end return x.n<y.n end)
    local parts={}
    for i=1,math.min(#list,limit or #list) do parts[i]=list[i].n..'*'..list[i].c end
    if limit and #list>limit then parts[#parts+1]='+'..(#list-limit)..' more' end
    return table.concat(parts,' ')
  end
  local function row(e,full)
    local r={name=e.name,author=e.author,entities=e.entities,tiles=e.tiles>0 and e.tiles or nil,
      footprint=string.format('%gx%g',e.footprint.w,e.footprint.h),counts=counts_line(e.counts,not full and 4 or nil),
      saved=ago(game.tick-e.saved_tick),last_used=e.last_used and ago(game.tick-e.last_used)..' by '..e.last_user or 'never',
      uses=e.uses or 0,surface=e.surface,anchor=e.anchor~=nil or nil}
    if full then
      r.description=e.description; r.anchor=e.anchor; r.captured=e.captured
      r.changeable_by_anyone=game.tick-(e.last_used or e.saved_tick)>=STALE
    elseif e.description then r.description=#e.description>60 and e.description:sub(1,57)..'...' or e.description end
    return r
  end
  local function may_change(p,e,verb)
    if e.author==api.who(p) or game.tick-(e.last_used or e.saved_tick)>=STALE then return end
    error(string.format('%s is %s\'s entry; another agent may %s it after 24 game hours unused (%s)',e.name,e.author,verb,
      e.last_used and 'last used '..ago(game.tick-e.last_used) or 'never used, saved '..ago(game.tick-e.saved_tick)),0)
  end
  local function key(e) return e.unit_number or (e.name..'@'..e.position.x..','..e.position.y) end
  function H.blueprint_save(p,a)
    permission(p,'copy'); permission(p,'select_blueprint_entities')
    local name=entry_name(a.name)
    assert((a.area==nil)~=(a.positions==nil),'give area or positions (the entities to keep), one of them')
    assert(a.description==nil or (type(a.description)=='string' and #a.description<=MAX_DESCRIPTION),'description must be text of up to '..MAX_DESCRIPTION..' characters')
    local lib=library()
    local old=lib.entries[name]
    if old then may_change(p,old,'replace')
    else
      local n=0; for _ in pairs(lib.entries) do n=n+1 end
      assert(n<MAX_LIBRARY,'the library holds '..MAX_LIBRARY..' entries, its limit; blueprint_delete frees one')
    end
    local box,keep
    if a.positions~=nil then
      assert(type(a.positions)=='table' and #a.positions>=1 and #a.positions<=256,'positions requires 1..256 entries')
      keep={}
      local l,t,r,b
      for _,pos in ipairs(a.positions) do
        local e=api.entity(p,{position=pos,name=type(pos)=='table' and pos.name or nil,unit_number=type(pos)=='table' and pos.unit_number or nil},true)
        assert(e.force==p.force,string.format('%s at (%g,%g) is not ours',e.name,e.position.x,e.position.y))
        keep[key(e)]=true
        local bb=e.bounding_box
        l,t=math.min(l or bb.left_top.x,bb.left_top.x),math.min(t or bb.left_top.y,bb.left_top.y)
        r,b=math.max(r or bb.right_bottom.x,bb.right_bottom.x),math.max(b or bb.right_bottom.y,bb.right_bottom.y)
      end
      box=area(p,{area={left_top={x=l,y=t},right_bottom={x=r,y=b}}})
    else box=area(p,a) end
    candidates(p,box)
    local anchor=a.anchor~=nil and api.position(a.anchor) or nil
    assert(not anchor or (anchor.x>=box.left_top.x and anchor.x<=box.right_bottom.x and anchor.y>=box.left_top.y and anchor.y<=box.right_bottom.y),
      'anchor must lie in the saved area')
    return temporary(function(stack)
      stack.set_stack{name='blueprint',count=1}
      local mapping=stack.create_blueprint{surface=p.surface,force=p.force,area=box,always_include_tiles=a.tiles==true,
        include_entities=true,include_modules=true,include_station_names=false,include_trains=false,include_fuel=false}
      local entities=stack.get_blueprint_entities() or {}
      if keep then
        -- Only the named entities, renumbered, with the wires between them.
        local renum,kept={},{}
        for _,e in ipairs(entities) do
          local w=mapping[e.entity_number]
          if w and w.valid and keep[key(w)] then kept[#kept+1]=e; renum[e.entity_number]=#kept end
        end
        for _,e in ipairs(kept) do
          local wires
          for _,w in ipairs(e.wires or {}) do
            local s,sid,t,tid=w[1] or w.source_entity_number or e.entity_number,w[2] or w.source_wire_connector_id,w[3] or w.target_entity_number,w[4] or w.target_wire_connector_id
            if renum[s] and renum[t] then wires=wires or {}; wires[#wires+1]={renum[s],sid,renum[t],tid} end
          end
          e.wires=wires; e.entity_number=renum[e.entity_number]
        end
        entities=kept
      end
      assert(#entities>0,'nothing to save: no entity of ours '..(keep and 'at those positions' or 'in the area'))
      -- Rebased as blueprint_capture does (an even shift keeps the rail grid).
      local origin={x=math.floor((box.left_top.x+box.right_bottom.x)/4)*2,y=math.floor((box.left_top.y+box.right_bottom.y)/4)*2}
      for _,e in ipairs(entities) do e.position={x=e.position.x-origin.x,y=e.position.y-origin.y} end
      stack.set_blueprint_entities(entities)
      local tiles=stack.get_blueprint_tiles() or {}
      for _,t in ipairs(tiles) do t.position={x=t.position.x-origin.x,y=t.position.y-origin.y} end
      if #tiles>0 then stack.set_blueprint_tiles(tiles) end
      stack.label=name
      local ents,tls=validate(stack)
      local l,t,r,b=extent(ents,tls)
      local counts={}
      for _,e in ipairs(ents) do counts[e.name]=(counts[e.name] or 0)+1 end
      local value=stack.export_stack()
      assert(#value<=MAX_STRING,'blueprint export exceeds size limit')
      lib.revision=lib.revision+1
      local entry={name=name,author=api.who(p),string=value,entities=#ents,tiles=#tls,counts=counts,
        footprint={w=r-l,h=b-t},anchor=anchor and {x=anchor.x-origin.x,y=anchor.y-origin.y} or nil,surface=p.surface.name,
        description=a.description and a.description:gsub('%s+',' ') or nil,saved_tick=game.tick,rev=lib.revision,uses=0,
        captured={left_top=box.left_top,right_bottom=box.right_bottom}}
      lib.entries[name]=entry
      local out=row(entry)
      out.replaced=old and old.author or nil
      return out
    end)
  end
  function H.blueprint_list(p,a)
    a=a or {}
    if a.name~=nil then return row(library_entry(a.name),true) end
    local out=slot_list(p)
    local rows={}
    for _,e in pairs(library().entries) do rows[#rows+1]=row(e) end
    table.sort(rows,function(x,y) return x.name<y.name end)
    out.library=rows; out.library_limit=MAX_LIBRARY
    return out
  end
  function H.blueprint_delete(p,a)
    if a.name==nil then return slot_delete(p,a) end
    assert(a.slot==nil,'give name (a library entry) or slot, not both')
    local e=library_entry(a.name)
    may_change(p,e,'delete')
    local lib=library()
    lib.entries[e.name]=nil; lib.revision=lib.revision+1
    return {name=e.name,deleted=true,author=e.author}
  end
  function H.blueprint_rename(p,a)
    local e=library_entry(a.name)
    local new=entry_name(a.new_name,'new_name')
    assert(not library().entries[new],'the library has an entry '..new..' already')
    may_change(p,e,'rename')
    local lib,was=library(),e.name
    lib.entries[was]=nil; e.name=new; lib.entries[new]=e
    lib.revision=lib.revision+1; e.rev=lib.revision
    return {name=new,was=was,author=e.author}
  end
  -- Operator read (tools/bplibrary.py): every entry's facts, and the string of each changed after `since`.
  H.operator={}
  function H.operator.blueprint_library(args)
    local lib,since=library(),tonumber(args and args.since) or -1
    local rows={}
    for _,e in pairs(lib.entries) do
      local r=row(e,true)
      r.rev=e.rev; r.saved_tick=e.saved_tick; r.last_used_tick=e.last_used
      if (e.rev or 0)>since then r.string=e.string end
      rows[#rows+1]=r
    end
    table.sort(rows,function(x,y) return x.name<y.name end)
    return {revision=lib.revision,tick=game.tick,entries=rows}
  end
  return H
end
