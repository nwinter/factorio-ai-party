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
  local function load(p, a, fn)
    local value = slots(p)[slot_name(a)]
    assert(value, 'blueprint slot is empty')
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
  function H.blueprint_list(p)
    local out={}
    for name in pairs(slots(p)) do out[#out+1]=name end
    table.sort(out)
    return {slots=out,limit=MAX_SLOTS}
  end
  function H.blueprint_delete(p,a)
    local name=slot_name(a); local s=slots(p); local existed=s[name]~=nil; s[name]=nil
    return {slot=name,deleted=existed}
  end
  function H.blueprint_capture(p,a) return capture(p,a,false) end
  function H.copy(p,a) return capture(p,a,false) end
  function H.cut(p,a) return capture(p,a,true) end

  function H.blueprint_place(p,a)
    permission(p,'build')
    local pos=api.position(a.position)
    local direction=directions[a.direction or 'north']; assert(direction, 'blueprint direction must be north, east, south, or west')
    return load(p,a,function(root)
      -- Moving a nested book entry can invalidate its LuaItemStack slot. Copy
      -- the selected leaf into an independent inventory before cursor swaps.
      local blueprint=selected(root,a).export_stack()
      return temporary(function(stack)
        assert(stack.import_stack(blueprint)==0, 'selected blueprint could not be copied')
        local snapping_disabled=stack.blueprint_snap_to_grid~=nil
        stack.blueprint_snap_to_grid=nil
        local entities, tiles=validate(stack)
        -- Validate a square containing every possible rotated or flipped
        -- footprint: quarter turns and flips keep max(|x|,|y|) invariant.
        local radius=1
        for _, e in ipairs(entities) do
          local proto=prototypes.entity[e.name]
          assert(proto, 'blueprint contains an unavailable entity')
          local box=proto.selection_box
          local margin=0
          for _, corner in ipairs({box.left_top,box.right_bottom}) do
            margin=math.max(margin,math.abs(corner.x),math.abs(corner.y))
          end
          radius=math.max(radius, math.max(math.abs(e.position.x),math.abs(e.position.y))+margin+1)
        end
        for _, tile in ipairs(tiles) do radius=math.max(radius,math.max(math.abs(tile.position.x),math.abs(tile.position.y))+2) end
        local box=area(p,{area={left_top={x=pos.x-radius,y=pos.y-radius},right_bottom={x=pos.x+radius,y=pos.y+radius}}})
        local function ghosts()
          return p.surface.find_entities_filtered{area=box,type={'entity-ghost','tile-ghost'},force=p.force}
        end
        local function ghost_key(e)
          return e.unit_number or (e.type..':'..e.ghost_name..':'..e.position.x..':'..e.position.y)
        end
        local before={}
        for _,e in pairs(ghosts()) do before[ghost_key(e)]=true end
        if type(p)=='table' and rawget(p,'__platform') then
          -- A platform is built from remote view: place the blueprint's ghosts
          -- on its surface directly; the cursor lives on the player's surface.
          assert(not a.flip_horizontal and not a.flip_vertical, 'flips are not supported when pasting on a platform')
          stack.build_blueprint{surface=p.surface,force=p.force,position=pos,direction=direction,
            build_mode=defines.build_mode.normal,skip_fog_of_war=true,by_player=real(p),raise_built=true}
        else
        assert(p.cursor_stack and not p.cursor_stack.valid_for_read, 'cursor must be empty; put held items away before pasting')
        local cursor_ghost=p.cursor_ghost
        assert(p.cursor_stack.swap_stack(stack), 'could not borrow cursor for blueprint')
        local ok,err=pcall(function()
          p.build_from_cursor{position=pos,direction=direction,flip_horizontal=a.flip_horizontal==true,
            flip_vertical=a.flip_vertical==true,build_mode=defines.build_mode.normal,skip_fog_of_war=true}
        end)
        local restored=p.cursor_stack.swap_stack(stack)
        if cursor_ghost then p.cursor_ghost=cursor_ghost end
        -- Only an empty cursor is borrowed: even a failed restore cannot delete
        -- a physical player item when temporary metadata is cleaned up.
        assert(restored, 'could not restore cursor after blueprint placement')
        assert(ok,err)
        end
        -- Per-ghost rows are opt-in: large layouts otherwise flood agent context.
        local out={count=0,by_name={},slot=slot_name(a),snapping_disabled=snapping_disabled}
        if a.details then out.ghosts={} end
        for _, e in pairs(ghosts()) do
          if e.valid and not before[ghost_key(e)] then
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
        -- Explain a short paste: the engine silently skips positions that
        -- already hold a matching ghost or entity, or that collide.
        if out.count<#entities then
          local names={}
          for _,e in ipairs(entities) do names[e.name]=true end
          local ghosts_there,built_there=0,0
          for _,e in pairs(ghosts()) do if e.valid and before[ghost_key(e)] and names[e.ghost_name] then ghosts_there=ghosts_there+1 end end
          for _,e in pairs(p.surface.find_entities_filtered{area=box,force=p.force}) do if e.valid and names[e.name] then built_there=built_there+1 end end
          out.expected=#entities; out.existing_ghosts=ghosts_there; out.existing_entities=built_there
          out.reason=(ghosts_there>0 or built_there>0) and 'matching ghosts or entities already occupy the area (pasted or built before?)'
            or 'placements collided with other entities or terrain'
        end
        return out
      end)
    end)
  end
  H.paste=H.blueprint_place

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
    local list=candidates(p,area(p,a))
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
    return {changed=changed,mode=cancel and 'cancel' or 'mark',tiles=false}
  end
  function H.deconstruct(p,a) return deconstruct(p,a,false) end
  function H.cancel_deconstruction(p,a) return deconstruct(p,a,true) end
  return H
end
