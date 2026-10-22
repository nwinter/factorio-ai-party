-- Blueprint metadata is free in vanilla; only ghosts are placed here. Physical
-- construction remains the player's/robots' job and consumes real inventory.
-- The factory is pure so the same module can be bundled into a hot reload.
return function(api)
  local H = {}
  local MAX_ENTITIES, MAX_TILES, MAX_STRING, MAX_SLOTS = 4096, 8192, 1000000, 32
  -- Factorio 2.0 remote view can place ghosts and order deconstruction on any
  -- charted chunk; robots still have to fly there and use real items.
  local MAX_AREA, MAX_AREA_ENTITIES = 256, 16384
  -- A compass name or the number inspect prints (friction1300).
  local directions = {north=0,east=4,south=8,west=12,[0]=0,[4]=4,[8]=8,[12]=12}
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
  -- kept in the save for every agent and every later shift, or imported from a string (blueprint_import {name}).
  -- (d20 batch59 U2, Astra #1446: 64 entries full after 48 shifts) 256 entries and 8 MB of strings. Measured on the
  -- private copy (an 18 MB save): the 64 entries of shift49 hold 416 KB (the largest 52 KB: 2636 entities and 6417
  -- tiles; Astra's 2123 entities and 6978 tiles 52 KB); 7.6 MB more strings made the save 4.8 MB larger and its save
  -- time stayed 0.6-0.7 s. A string costs nothing between saves; the operator read pages them (MAX_READ_BYTES).
  local MAX_LIBRARY, MAX_LIBRARY_BYTES, MAX_NAME, MAX_DESCRIPTION = 256, 8000000, 40, 300
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
  -- The strings' bytes, all entries but `except` (a name being replaced).
  local function library_bytes(except)
    local n, count = 0, 0
    for name, e in pairs(library().entries) do
      count = count + 1
      if name ~= except then n = n + #(e.string or '') end
    end
    return n, count
  end
  local function kb(n) return math.floor(n / 102.4 + 0.5) / 10 end
  -- A new or replaced entry fits the library's count and bytes, or the call fails naming both.
  local function room_for(name, bytes)
    local used, count = library_bytes(name)
    local old = library().entries[name]
    assert(old or count < MAX_LIBRARY, string.format('the library holds %d entries, its limit (%g of %g KB of strings used); blueprint_delete frees one',
      MAX_LIBRARY, kb(used), kb(MAX_LIBRARY_BYTES)))
    assert(used + bytes <= MAX_LIBRARY_BYTES, string.format('this blueprint\'s string is %g KB and the library holds %g of its %g KB of strings; blueprint_delete frees room',
      kb(bytes), kb(used), kb(MAX_LIBRARY_BYTES)))
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
  -- (d20 batch59 U4, viewer Aurora) a retired entry: who retired it, why, and the entry that replaces it, kept beside
  -- the description (which stays as written). A list row, an export and a paste (dry run or real) of it say so and go
  -- on; nothing is refused for it.
  local MAX_REASON = 200
  local function retired_line(e)
    local r = e and e.retired
    if not r then return nil end
    local new = library().entries[r.replaced_by]
    return string.format('retired by %s: %s; replaced by %s%s', r.by, r.reason, r.replaced_by,
      not new and ' (no entry of that name now)' or new.retired and ' (retired too; replaced by ' .. new.retired.replaced_by .. ')' or '')
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
  -- The shift that rebases captured world coordinates: an even one about the area's centre (it keeps the rail grid),
  -- or a space-platform-hub's own position. The engine keeps a blueprint's hub at 0,0 whatever set_blueprint_entities
  -- is given (checked on 2.0.77), so any other shift moved every entity but the hub (Astra 05:15: Tern saved with the
  -- collector at (-0.5,-15.5) for (-0.5,-13.5), a y -35..40 area's shift of 2).
  local function rebase_origin(box,entities)
    for _,e in ipairs(entities) do
      if e.name=='space-platform-hub' then return {x=e.position.x,y=e.position.y} end
    end
    return {x=math.floor((box.left_top.x+box.right_bottom.x)/4)*2,y=math.floor((box.left_top.y+box.right_bottom.y)/4)*2}
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
      local entities=stack.get_blueprint_entities() or {}
      local origin=rebase_origin(box,entities)
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
  -- (d20 batch65 AA8) {entity_number=needs}: blueprint entities whose circuit settings act on a signal (circuits.lua
  -- signal_needs) with no red or green wire to them in the blueprint.
  local function unwired_needs(entities)
    local C=api.circuits and api.circuits()
    if not C then return {} end
    local W=defines.wire_connector_id
    local circuit={[W.circuit_red]=true,[W.circuit_green]=true,[W.combinator_output_red]=true,[W.combinator_output_green]=true}
    local out,wired
    for _,e in ipairs(entities) do
      if type(e.control_behavior)=='table' then
        local needs=C.signal_needs(e.name,e.control_behavior,true)
        if #needs>0 then
          if not wired then
            wired={}
            for _,w in ipairs(wire_list(entities)) do
              if circuit[w[2]] then wired[w[1]]=true end
              if circuit[w[4]] then wired[w[3]]=true end
            end
          end
          if not wired[e.entity_number] then out=out or {}; out[e.entity_number]=needs end
        end
      end
    end
    return out or {}
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
    local direction=directions[a.direction or 'north']; assert(direction, 'blueprint direction must be north, east, south, or west (or 0, 4, 8, 12)')
    local mode=a.mode or 'normal'
    assert(MODES[mode],'paste mode must be normal, forced or superforced')
    local build_mode=defines.build_mode[mode]
    assert(build_mode~=nil,'this game has no '..mode..' build mode')
    if api.turretammo then api.turretammo.check(a.ammo) end
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
        -- The requests of entities the blueprint lands on (hub, requester
        -- chests, landing pads): kept, reported after, put back if a paste
        -- changed them while the blueprint carried none (keep.lua).
        local kept
        if api.keep then
          local spots={}
          for _,e in ipairs(entities) do if api.keep.TYPES[prototypes.entity[e.name].type] then spots[#spots+1]=e end end
          if #spots>0 then
            local where=locate(p,a,entities,pos,direction,box,c)
            for i,e in ipairs(spots) do
              spots[i]={name=e.name,position=where(e),own=api.keep.bp_sections(e),construction=e.request_missing_construction_materials==true}
            end
            kept=api.keep.before(p.surface,spots)
          end
        end
        -- preserve_existing_settings_and_wires (B5, Astra 2x: restoring missing hull undid live circuit and filter
        -- settings, so the blueprint JSON was merged by hand): what already stands where the blueprint puts the same entity
        -- (built, or a ghost of it) is left out of this paste, keeping its settings and wires; the rest is pasted, and a
        -- wire from a new ghost to a left-out entity is joined to the one standing there. The paste position moves by the
        -- change of the blueprint's center, so everything lands where the whole blueprint would.
        local preserved,rewire
        if a.preserve_existing_settings_and_wires~=nil then
          assert(type(a.preserve_existing_settings_and_wires)=='boolean','preserve_existing_settings_and_wires must be true or false')
        end
        if a.preserve_existing_settings_and_wires then
          local where=locate(p,a,entities,pos,direction,box,c)
          local keep,standing,num={},{},{}
          for _,e in ipairs(entities) do
            local w=where(e)
            local here
            for _,o in ipairs(w and p.surface.find_entities_filtered{position=w,radius=0.3,force=p.force} or {}) do
              local name=o.type=='entity-ghost' and o.ghost_name or o.name
              if o.valid and name==e.name and o.type~='tile-ghost' then here=o end
            end
            if here then standing[e.entity_number]=here else keep[#keep+1]=e; num[e.entity_number]=#keep end
          end
          preserved=#entities-#keep
          rewire={}
          for _,e in ipairs(keep) do
            local wires={}
            for _,w in ipairs(e.wires or {}) do
              if num[w[3]] then wires[#wires+1]={num[e.entity_number],w[2],num[w[3]],w[4]}
              elseif standing[w[3]] then rewire[#rewire+1]={at=where(e),name=e.name,conn=w[2],other=standing[w[3]],other_conn=w[4]} end
            end
            e.wires=#wires>0 and wires or nil
          end
          for _,e in ipairs(keep) do e.entity_number=num[e.entity_number] end
          assert(#keep>0 or #tiles>0,string.format('every one of the blueprint\'s %d entities already stands there (built or as its ghost): nothing to paste',#entities))
          stack.set_blueprint_entities(keep)
          local c2=center(keep,tiles)
          local dx,dy=api.placewhy.rotate(c2.x-c.x,c2.y-c.y,direction)
          if a.flip_horizontal then dx=-dx end
          if a.flip_vertical then dy=-dy end
          pos={x=pos.x+dx,y=pos.y+dy}
          entities=keep
        end
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
        if type(p)=='table' and (rawget(p,'__platform') or rawget(p,'__bot') or rawget(p,'__remote')) then
          -- A platform is built from remote view: place the blueprint's ghosts
          -- on its surface directly; the cursor lives on the player's surface.
          -- A bot has no cursor at all. Another planet by name (surface=, d20 batch62 X5) is built the same way.
          assert(not a.flip_horizontal and not a.flip_vertical, 'flips are not supported when pasting on a platform, on another surface or as a bot')
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
        local inserters,chests={},{}
        local ammo_rows
        for _, e in pairs(ghosts()) do
          if e.valid and not before[ghost_key(e)] then
            if e.type=='entity-ghost' and e.ghost_type=='inserter' then inserters[#inserters+1]=e end
            if e.type=='entity-ghost' and e.ghost_type=='logistic-container' then chests[#chests+1]=e end
            -- A turret ghost requests ammo unless the blueprint's own request is there (turretammo.lua).
            if api.turretammo and e.type=='entity-ghost' then
              local got=api.turretammo.request(e,a.ammo)
              if got then ammo_rows=ammo_rows or {}; api.turretammo.add(ammo_rows,got) end
            end
            out.count=out.count+1
            out.by_name[e.ghost_name]=(out.by_name[e.ghost_name] or 0)+1
            -- The build log (efficiency.lua): a planned machine is its planner's.
            if api.placed and e.type=='entity-ghost' then pcall(api.placed,p,e) end
            local x,y=e.position.x,e.position.y
            if out.bounds then
              local b=out.bounds
              b.left=math.min(b.left,x); b.top=math.min(b.top,y); b.right=math.max(b.right,x); b.bottom=math.max(b.bottom,y)
            else out.bounds={left=x,top=y,right=x,bottom=y} end
            if a.details then out.ghosts[#out.ghosts+1]={name=e.ghost_name,position=e.position,unit_number=e.unit_number,type=e.type} end
          end
        end
        if kept and #kept>0 then out.requests_kept=api.keep.after(kept) end
        if preserved then
          local joined=0
          for _,r in ipairs(rewire or {}) do
            for _,g in ipairs(p.surface.find_entities_filtered{position=r.at,radius=0.3,force=p.force}) do
              local name=g.type=='entity-ghost' and g.ghost_name or g.name
              if g.valid and name==r.name and r.other.valid then
                local ok=pcall(function() return g.get_wire_connector(r.conn,true).connect_to(r.other.get_wire_connector(r.other_conn,true)) end)
                if ok then joined=joined+1 end
              end
            end
          end
          out.preserved=string.format('%d of the blueprint\'s entities already stood there (built or as their ghost) and were left as they are, their settings and wires kept; %d wire%s from new ghosts joined to them',
            preserved,joined,joined==1 and '' or 's')
        end
        out.ammo_requests=ammo_rows
        -- Inserter ghosts with nothing to take from or put into on their
        -- points (Astra's bypass inserter that reached no crusher; targets.lua).
        if api.targets then out.inserters_without_target,out.inserters_without_target_count=api.targets.check(inserters,16) end
        -- Logistic chest ghosts no roboport's logistic area covers (the blueprint's own roboports count: ghosts now).
        if api.build_notes and #chests>0 then out.outside_logistic_coverage=api.build_notes(p,chests) end
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
        -- (AA8) blueprint entities whose settings act on a signal with no red or green wire in the blueprint, and none on
        -- what stands there after the paste
        local needs=unwired_needs(entities)
        if next(needs) then
          local at_of=locate(p,a,entities,pos,direction,box,c)
          local check=api.unwired_check(p.surface,p.force)
          local plan={}
          for _,be in ipairs(entities) do
            if needs[be.entity_number] then plan[#plan+1]={name=be.name,position=at_of(be),needs=needs[be.entity_number]} end
          end
          local oku,u=pcall(api.circuits().unwired_plan,plan,check,true)
          if oku then out.unwired=u end
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
          out.retired=retired_line(e)
          -- (d20 batch55 P2) where the paste put each entity, for a blueprint check (checks.lua): position and facing
          -- (none compared on a flipped paste), the first 400
          if api.checks_placed then pcall(function()
            local at_of=locate(p,a,entities,pos,direction,box,c)
            local flipped=a.flip_horizontal or a.flip_vertical
            local rec={surface=p.surface.index,entities={},count=#entities,saved_tick=e.saved_tick}  -- (d21 batch68 AD2) the save placed
            local l,t,r,b
            for i,be in ipairs(entities) do
              if i>400 then rec.capped=true; break end
              local q=at_of(be)
              local d=((be.direction or 0)+direction)%16
              rec.entities[#rec.entities+1]={name=be.name,x=q.x,y=q.y,d=not flipped and d or nil}
              local proto=prototypes.entity[be.name]
              local w,h=proto and proto.tile_width or 1,proto and proto.tile_height or 1
              if d%8==4 then w,h=h,w end
              l,t=math.min(l or q.x-w/2,q.x-w/2),math.min(t or q.y-h/2,q.y-h/2)
              r,b=math.max(r or q.x+w/2,q.x+w/2),math.max(b or q.y+h/2,q.y+h/2)
            end
            if l then rec.box={l=l,t=t,r=r,b=b}; api.checks_placed(p,a.name,rec) end
          end) end
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
    assert(not (type(p)=='table' and (rawget(p,'__platform') or rawget(p,'__bot') or rawget(p,'__remote')) and (a.flip_horizontal or a.flip_vertical)),
      'flips are not supported when pasting on a platform, on another surface or as a bot')
    assert(a.anchor==nil or a.anchor=='hub' or a.anchor=='center' or a.anchor=='saved','anchor must be hub, center or saved')
    local pos=a.position~=nil and api.position(a.position) or nil
    local direction=directions[a.direction or 'north']; assert(direction, 'blueprint direction must be north, east, south, or west (or 0, 4, 8, 12)')
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
      local needs=unwired_needs(entities)
      for i,e in ipairs(entities) do
        local x,y=turn(e.position.x,e.position.y)
        local d=e.direction or 0
        if a.flip_horizontal then d=(16-d)%16 end
        if a.flip_vertical then d=(24-d)%16 end
        list[i]={index=i,name=e.name,position={x=shift.x+x,y=shift.y+y},direction=(d+direction)%16,
          quality=type(e.quality)=='string' and e.quality or nil,requests=api.keep and api.keep.bp_sections(e) or nil,
          construction=e.request_missing_construction_materials==true or nil,
          ug_type=type(e.type)=='string' and e.type or nil,needs=needs[e.entity_number]}
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
        slot=a.name==nil and slot_name(a) or nil,name=a.name,label=stack.label~='' and stack.label or nil,
        retired=a.name~=nil and retired_line(library_entry(a.name)) or nil}
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
  -- On a platform (platformtiles2, Astra 21:55: a marked foundation tile at (-2,8) on Sunward stayed for minutes):
  -- every marked tile there played out by the game's rule (tilecheck.lua): which the hub removes, one at a time and
  -- in what order, and which wait and why. extra: tiles a dry run would mark, counted as marked.
  -- (loaded on first use: only a platform needs it)
  local tilecheck
  local function platform_plan(p,out,extra)
    local ok,pl=pcall(function() return p.surface.platform end)
    if not (ok and pl) then return end
    if tilecheck==nil then
      local okr,m=pcall(require,'tilecheck')
      tilecheck=okr and m() or false
    end
    if not tilecheck then return end
    local marked=tilecheck.marked(p.surface)
    local seen={}
    for _,t in ipairs(marked) do seen[tilecheck.key(t[1],t[2])]=true end
    for _,t in ipairs(extra or {}) do if not seen[tilecheck.key(t[1],t[2])] then marked[#marked+1]=t end end
    if #marked==0 then return end
    local plan=tilecheck.plan_removals(p.surface,marked,pl.hub,{})
    local lines=tilecheck.removal_lines(plan,'marked','on the platform')
    out.tiles_go=lines.go; out.tiles_waiting=#plan.waiting>0 and #plan.waiting or nil
    out.waiting=lines.waiting; out.waiting_more=lines.more
  end
  -- (d17 batch31 B4, Astra: a salvage kept the ends of pipe-to-ground and underground belts but took the floor under
  -- their spans, and both thruster feeds stopped) on a platform, before anything is marked: each underground pair whose
  -- span (the tiles between its ends, paired as platform_plan's floor pairs them) holds a tile this would mark or that
  -- is marked already; a live mark is refused unless cut_spans: true.
  local function spans_cut(p,a,box,dry,out)
    local okp,plat=pcall(function() return p.surface.platform end)
    if not (api.tunnels and okp and plat) then return end
    assert(a.cut_spans==nil or a.cut_spans==true or a.cut_spans==false,'cut_spans is true or false')
    local names,mine=tile_names(a.tiles)
    if #names==0 then return end
    local list=p.surface.find_tiles_filtered{area=box,name=names,limit=MAX_TILES+1}
    local standing={}
    for _,e in ipairs(candidates(p,box)) do
      if e.valid and e.type~='entity-ghost' and e.type~='character' then standing[#standing+1]=e end
    end
    local function under(t) for _,e in ipairs(standing) do if covers(e,t) then return e end end end
    local going={}
    for _,t in ipairs(list) do
      if mine[t.name] and (t.to_be_deconstructed(p.force) or not under(t)) then going[math.floor(t.position.x)..','..math.floor(t.position.y)]=true end
    end
    if not next(going) then return end
    local ghosts=p.surface.find_entities_filtered{type='entity-ghost',ghost_type={'underground-belt','pipe-to-ground'},force=p.force,limit=1024}
    local found,order={},{}
    pcall(api.tunnels,p.surface,p.force,ghosts,function(x,y,e,o)
      if e and going[x..','..y] then
        -- a pipe-to-ground pair is walked from both ends: one key a pair, its ends in either order
        local ka,kb=e.position.x..','..e.position.y,o.position.x..','..o.position.y
        local key=ka<kb and ka..'|'..kb or kb..'|'..ka
        local c=found[key]
        if c and c.e~=e then return end
        if not c then c={e=e,o=o,tiles={}}; found[key]=c; order[#order+1]=key end
        c.tiles[#c.tiles+1]=string.format('(%d,%d)',x,y)
      end
    end)
    if #order==0 then return end
    local cut={}
    local function nm(x) return x.type=='entity-ghost' and 'ghost of '..x.ghost_name or x.name end
    for _,key in ipairs(order) do
      local c=found[key]
      cut[#cut+1]=string.format('%s (%g,%g) to %s (%g,%g): %d tile%s of its span would be empty space: %s',nm(c.e),c.e.position.x,c.e.position.y,
        nm(c.o),c.o.position.x,c.o.position.y,#c.tiles,#c.tiles==1 and '' or 's',table.concat(c.tiles,' ',1,math.min(8,#c.tiles))..(#c.tiles>8 and ' ...' or ''))
    end
    table.sort(cut)
    out.spans_cut=cut
    out.spans_note='an underground belt or pipe-to-ground pair joins through the tiles between its ends; on a platform a span over empty space is cut (Astra, shift34: a salvage kept the ends and both thruster feeds stopped)'
    if not dry and a.cut_spans~=true then
      error(string.format('nothing marked: %d underground pair%s would lose floor under %s span%s: %s; cut_spans: true marks them anyway',#cut,#cut==1 and '' or 's',
        #cut==1 and 'its' or 'their',#cut==1 and '' or 's',table.concat(cut,'; ',1,math.min(4,#cut))..(#cut>4 and '; ...' or '')),0)
    end
  end
  local function deconstruct_tiles(p,a,box,cancel,out,dry)
    local names,mine=tile_names(a.tiles)
    if #names==0 then return end
    -- Our tile ghosts of those tiles go, as a planner in tile mode removes
    -- them (Grok, shift10 06:20: tiles ["landfill"] over water planned with
    -- landfill marked 0; only an unfiltered deconstruct removed its 41 ghosts).
    -- find_entities_filtered's ghost_name takes entity names only: the tile
    -- names are matched here.
    if not cancel then
      local wanted,removed={},0
      for _,name in ipairs(names) do wanted[name]=true end
      local ghosts=p.surface.find_entities_filtered{area=box,type='tile-ghost',force=p.force,limit=MAX_TILES+1}
      assert(#ghosts<=MAX_TILES,'area tile ghost limit exceeded ('..MAX_TILES..'); select a smaller area')
      for _,g in ipairs(ghosts) do
        if g.valid and wanted[g.ghost_name] then
          if dry then removed=removed+1
          else
            local ok,res=pcall(g.order_deconstruction,p.force,real(p))
            if ok and (res or not g.valid) then removed=removed+1 end
          end
        end
      end
      if dry then out.tile_ghosts_would_go=removed else out.tile_ghosts_removed=removed end
    end
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
    local would={}
    local function refuse(why) refused[why]=(refused[why] or 0)+1 end
    for _,t in ipairs(list) do
      if not mine[t.name] then refuse('not_minable')
      elseif t.to_be_deconstructed(p.force) then already=already+1
      elseif dry then
        -- The game refuses a mark under what stands there (on a copy of world n: an edge tile under an inserter).
        if under(t) then refuse('under_entity') else marked=marked+1; would[#would+1]={math.floor(t.position.x),math.floor(t.position.y)} end
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
    if dry then out.tiles_marked=nil; out.tiles_would_mark=marked end
    out.refused=next(refused) and refused or nil
    out.tiles_blocked=blocked
    if blocked>0 then
      local list2={}
      for name in pairs(blockers) do list2[#list2+1]=name end
      table.sort(list2)
      out.note=string.format('%d marked tile(s) lie under entities not marked for deconstruction (%s): robots take a tile once what stands on it is gone; mark those too (entity_names)',
        blocked,table.concat(list2,', '))
    end
    platform_plan(p,out,dry and would or nil)
  end
  local function deconstruct(p,a,cancel)
    permission(p,cancel and 'cancel_deconstruct' or 'deconstruct')
    assert(a.dry_run==nil or type(a.dry_run)=='boolean','dry_run must be true or false')
    local dry=a.dry_run==true
    local filters={}
    for _,key in ipairs({'entity_types','entity_names'}) do
      if a[key] then
        assert(type(a[key])=='table' and #a[key]>0 and #a[key]<=32,key..' requires 1..32 names')
        filters[key]={}
        for _,value in ipairs(a[key]) do assert(type(value)=='string',key..' requires strings'); filters[key][value]=true end
      end
    end
    -- (d19 batch41 A3, Sol seq 863: cancel with entity_types [item-entity] on Fulgora changed 0) an entity filter naming
    -- items on the ground (type item-entity, name item-on-ground) takes the stacks as items_on_ground does; with no other
    -- name the call is about them alone
    local ground_named=(filters.entity_types and filters.entity_types['item-entity']) or (filters.entity_names and filters.entity_names['item-on-ground'])
    local others=false
    for _,key in ipairs({'entity_types','entity_names'}) do
      for v in pairs(filters[key] or {}) do if v~='item-entity' and v~='item-on-ground' then others=true end end
    end
    if ground_named and a.items_on_ground==nil and not dry then
      local b={}
      for k,v in pairs(a) do b[k]=v end
      b.items_on_ground=true; a=b
    end
    local box=area(p,a)
    local out={changed=0,mode=cancel and 'cancel' or (dry and 'dry_run' or 'mark'),tiles=a.tiles~=nil and a.tiles~=false,dry_run=dry or nil}
    -- Items on the ground, as a planner marks them (robots take them to
    -- storage); other entities then only with entity filters.
    if a.items_on_ground~=nil then
      assert(a.items_on_ground==true or a.items_on_ground==false,'items_on_ground must be boolean')
      assert(not out.tiles,'items_on_ground and tiles are separate calls')
    end
    assert(not (dry and a.items_on_ground),'dry_run goes with entities and tiles, not items_on_ground')
    if out.tiles and not cancel then spans_cut(p,a,box,dry,out) end
    if a.items_on_ground then
      api.ground_mark(p,box,cancel,out)
      if not others then return out end
    end
    -- With tiles, entities are taken only when entity filters name them;
    -- they go first, so a tile under one marked now is not counted blocked.
    -- (a tiles-only dry run changes nothing and counts no entities)
    if out.tiles and not (filters.entity_types or filters.entity_names) then
      if dry then out.changed=nil end
      deconstruct_tiles(p,a,box,cancel,out,dry); return out
    end
    local list=candidates(p,box)
    -- (d17 batch35 B3, Sol: moving a melter cut a chemical plant's shared water bridge) the fluid segments marking our
    -- pipes, pipe-to-grounds, tanks and pumps here would split (fluidjoin.lua removal); a part left with machines taking
    -- the fluid and no source refuses a live call unless cut_fluid: true
    if not cancel and api.fluid_removal then
      assert(a.cut_fluid==nil or type(a.cut_fluid)=='boolean','cut_fluid must be true or false')
      local FLUID={pipe=true,['pipe-to-ground']=true,['storage-tank']=true,pump=true}
      local fl={}
      for _,e in ipairs(list) do
        local ok,t,n=pcall(function() return e.valid and e.type,e.valid and e.name end)
        if ok and t and FLUID[t] and e.force==p.force and (not filters.entity_types or filters.entity_types[t]) and (not filters.entity_names or filters.entity_names[n])
          and not e.to_be_deconstructed(p.force) then fl[#fl+1]=e end
      end
      if #fl>0 then
        local okf,lines,starved=pcall(api.fluid_removal,p.force,fl)
        if okf and lines then out.fluid_split=lines end
        if okf and starved and not dry and a.cut_fluid~=true then
          error(string.format('nothing marked: %s%s; cut_fluid: true marks them anyway',starved[1],#starved>1 and string.format(' (+%d more)',#starved-1) or ''),0)
        end
      end
    end
    local changed,by=0,{}
    -- Heat-network parts it marks (Sol, shift19): what their removal does to heat (heating.lua loss).
    local heat_parts,already={},0
    local HEAT_PART={['heat-pipe']=true,reactor=true,boiler=true,['heat-interface']=true}
    -- A ghost given a deconstruction order is removed at once, as a planner removes it (Astra, shift20, 3 times: the next
    -- read of it failed "LuaEntity API call when LuaEntity was invalid"): what is read of an entity is read before the
    -- order, an entity gone by the time it is reached is skipped, and removed ghosts are counted apart.
    local removed,ghost_names,gone=0,{},0
    -- (backlog #247, Astra 89h33: a dry run said would_mark 741 logistic robots, the live call changed 0) robots in flight
    -- are not marked by the game's order (a planner leaves them): counted apart, in the dry run as live
    local FLYING={['logistic-robot']=true,['construction-robot']=true,['combat-robot']=true,['capture-robot']=true}
    local flying,jobs=0,{}
    -- (d20 batch69 AE1, Sol #1642: deconstruct over (276,190)-(280,192) on Fulgora marked the elevated rail at 279 only)
    -- the game reads an elevated rail inside a rail support's run, and a support carrying rails, not minable; a planner
    -- marks nothing over such a rail and, over the support, the support with every rail it carries (railrun.lua). Our
    -- supports here are marked that way first; what is left unmarked is named with why (not_marked).
    local rr=api.railrun and api.railrun()
    local by_support,skipped,support_marks,skipped_more={},{},{},0
    local function allowed(t,n) return (not filters.entity_types or filters.entity_types[t]) and (not filters.entity_names or filters.entity_names[n]) end
    if rr and not cancel then
      for _,e in ipairs(list) do
        local ok,t,n,keep=pcall(function() return e.valid and e.type,e.valid and e.name,e.valid and e.force==p.force and not e.minable and e.minable_flag end)
        if ok and t and rr.SUPPORT[t] and keep and allowed(t,n) and not e.to_be_deconstructed(p.force) then
          -- (AE2) the rails held up only by it, as the game keeps them (the live reply counts what the game marks)
          local carried=rr.dependents(e,nil,true)
          if dry then
            changed=changed+1; by[n]=(by[n] or 0)+1
            for _,r in ipairs(carried) do
              if not r.to_be_deconstructed(p.force) and not by_support[r.unit_number] then by_support[r.unit_number]=true; changed=changed+1; by[r.name]=(by[r.name] or 0)+1 end
            end
          else
            local got,err,nrails,units=rr.mark_support(p,e,real(p))
            if got then
              for nm,c in pairs(got) do changed=changed+c; by[nm]=(by[nm] or 0)+c end
              for u in pairs(units) do by_support[u]=true end
              carried={n=nrails}
            else
              skipped[#skipped+1]=string.format('%s (%g,%g): %s',n,e.position.x,e.position.y,err)
            end
          end
          by_support[e.unit_number]=true
          local nr=carried.n or #carried
          support_marks[#support_marks+1]=string.format('%s (%g,%g) with the %d elevated rail%s %s',n,e.position.x,e.position.y,nr,nr==1 and '' or 's',
            dry and 'held up only by it (the live reply gives the game\'s own count)' or 'the game marked with it')
        end
      end
    end
    for _, e in ipairs(list) do
      -- (AE1) a cancel takes the marks off elevated rails and supports the game reads not minable too
      local ok,t,n,mine=pcall(function() return e.valid and e.type,e.valid and e.name,e.valid and (e.force==p.force or e.force.name=='neutral') and e.type~='character'
        and (e.minable or (cancel and rr and (rr.RAIL[e.type] or rr.SUPPORT[e.type]) and e.minable_flag)) end)
      local unit=ok and t and e.valid and e.unit_number
      if unit and by_support[unit] then
        -- marked (or counted, in a dry run) with its rail support above
      elseif ok and t and not mine and not cancel and t~='item-entity' and not FLYING[t] and allowed(t,n) and #skipped>=12 then
        skipped_more=skipped_more+1  -- (AE1) counted; the reason read for the 12 listed only (railrun.why reads the track round it)
      elseif ok and t and not mine and not cancel and t~='item-entity' and not FLYING[t] and allowed(t,n) then
        -- (AE1) found in the area, not marked: why
        local why
        if e.force~=p.force and e.force.name~='neutral' then why='another force\'s ('..e.force.name..')'
        elseif t=='character' then why='a character'
        else why=rr and rr.why(e) or 'the game reads it not minable' end
        local okp,x,y=pcall(function() return e.position.x,e.position.y end)
        skipped[#skipped+1]=string.format('%s%s%s: %s',n,unit and (' '..unit) or '',okp and string.format(' (%g,%g)',x,y) or '',why)
      end
      if unit and by_support[unit] then
      elseif ok and t and FLYING[t] then
        if mine and (not filters.entity_types or filters.entity_types[t]) and (not filters.entity_names or filters.entity_names[n]) then flying=flying+1 end
      elseif not (ok and t) then gone=gone+1
      -- Items on the ground go with items_on_ground only (Sol, d15: a cancel on Starling said 146 while 12 entities had
      -- been marked; the rest were most likely items on the ground the platform had marked for pickup).
      elseif mine and t~='item-entity' and (not filters.entity_types or filters.entity_types[t]) and (not filters.entity_names or filters.entity_names[n]) then
        if cancel then
          if e.to_be_deconstructed(p.force) then e.cancel_deconstruction(p.force,real(p)); changed=changed+1; by[n]=(by[n] or 0)+1
            if rr and rr.SUPPORT[t] then support_marks[#support_marks+1]=e end end
        elseif dry then
          -- (a dry run: what is not marked yet; ghosts would be removed, as a planner removes them)
          if not e.to_be_deconstructed(p.force) then
            changed=changed+1; by[n]=(by[n] or 0)+1; if HEAT_PART[t] then heat_parts[#heat_parts+1]=e end
            -- (d17 batch34 B3) the robots' trips for it
            if t~='entity-ghost' and t~='tile-ghost' and api.deconstruct_job and #jobs<4096 then local j=api.deconstruct_job(e); if j then jobs[#jobs+1]=j end end
          end
        elseif t~='entity-ghost' and t~='tile-ghost' and (pcall(e.to_be_deconstructed,p.force)) and e.to_be_deconstructed(p.force) then already=already+1
        else
          local ghost_name=(t=='entity-ghost' or t=='tile-ghost') and (select(2,pcall(function() return e.ghost_name end)) or n) or nil
          local okd,done=pcall(e.order_deconstruction,p.force,real(p))
          if okd and done then
            changed=changed+1; by[ghost_name and ('ghost of '..ghost_name) or n]=(by[ghost_name and ('ghost of '..ghost_name) or n] or 0)+1
            if ghost_name then removed=removed+1; ghost_names[ghost_name]=(ghost_names[ghost_name] or 0)+1
            elseif HEAT_PART[t] and e.valid then heat_parts[#heat_parts+1]=e end
            -- (B3) what it frees, for the contested ghosts (one job an item is enough)
            if not ghost_name and e.valid and api.deconstruct_job and api.contested and #jobs<64 then local j=api.deconstruct_job(e); if j then jobs[#jobs+1]=j end end
          elseif not e.valid then gone=gone+1 end
        end
      end
    end
    out.changed=changed
    if cancel and #support_marks>0 then
      -- (AE1) the game's cancel takes only what is in the area: rails a cancelled support carries may stay marked
      local left=0
      for _,e in ipairs(support_marks) do for _,r in ipairs(rr.carried(e)) do if r.valid and r.to_be_deconstructed(p.force) then left=left+1 end end end  -- rails in its reach
      support_marks={}
      if left>0 then out.rails_still_marked=left..' elevated rails in the cancelled rail supports\' reach stay marked (a cancel takes only what is in the area, as the game\'s does)' end
    end
    if #support_marks>0 then out.rail_supports=(dry and 'would mark ' or 'marked ')..table.concat(support_marks,'; ',1,math.min(6,#support_marks))
      ..' (the game marks a rail support with the rails held up only by it; robots take them outermost first, the support last)' end
    if #skipped>0 then
      out.not_marked=skipped
      out.not_marked_count=#skipped+skipped_more
    end
    if not dry and changed>0 then
      local names={}
      for nm,c in pairs(by) do names[#names+1]={nm,c} end
      table.sort(names,function(x,y) return x[2]>y[2] or x[2]==y[2] and x[1]<y[1] end)
      for i,v in ipairs(names) do names[i]=v[2]..' '..v[1] end
      out[cancel and 'cancelled_by_name' or 'marked_by_name']=table.concat(names,', ',1,math.min(12,#names))..(#names>12 and ', ...' or '')
    end
    if removed>0 then
      local parts={}
      for gn,c in pairs(ghost_names) do parts[#parts+1]=c..' '..gn end
      table.sort(parts)
      out.ghosts_removed=removed; out.ghosts_removed_by_name=table.concat(parts,', ')
    end
    if gone>0 then out.gone=gone..' found in the area were gone by the time they were reached (removed with a ghost before them)' end
    if flying>0 then out.flying_robots=flying..' robots in flight in the area the filters name: the game does not mark robots in flight (by hand a robot in flight is mined as any entity in reach; robots in a roboport are taken out of its robot slots)' end
    if already>0 then out.already_marked=already..' already marked for deconstruction (deconstruct {area, cancel: true} or cancel_deconstruction unmarks them)' end
    if dry then
      out.changed=nil; out.would_mark=changed
      local names={}
      for n,c in pairs(by) do names[#names+1]={n,c} end
      table.sort(names,function(x,y) return x[2]>y[2] or x[2]==y[2] and x[1]<y[1] end)
      for i,v in ipairs(names) do names[i]=v[2]..' '..v[1] end
      out.would_mark_by_name=#names>0 and table.concat(names,', ') or nil
      -- (d17 batch34 B3, Opus: two ore chests 450 tiles away sent about 300 robots) the robots' trips
      if api.dispatch and #jobs>0 then
        local okd,lines=pcall(api.dispatch,p.surface,p.force,jobs)
        if okd and lines then out.robot_dispatch=lines end
      end
    end
    -- (d18 batch38 B3, Luna) an item the marked entities free that more ghosts of ours in that network want than it
    -- holds: each such ghost (ghostlist.contested), dry run and live
    if api.contested and #jobs>0 then
      local seen,lines={},{}
      for _,j in ipairs(jobs) do
        if j.item and not seen[j.item] and #lines<2 then
          seen[j.item]=true
          local okc,c=pcall(api.contested,p.surface,p.force,j.item,j.pos)
          if okc and c then lines[#lines+1]=c.line end
        end
      end
      if #lines>0 then out.contested=lines end
    end
    if #heat_parts>0 and api.heat_loss then
      local ok,loss=pcall(api.heat_loss,p.surface,p.force,heat_parts)
      if ok and loss and not (loss.none and not dry) then out.heat_loss=loss end
    end
    if out.tiles then deconstruct_tiles(p,a,box,cancel,out,dry) end
    return out
  end
  -- cancel: true (Grok, shift19: an underground on a 311-tile crude line, already marked, was mined and rebuilt by hand
  -- to undo the mark): the marks in the area are cancelled, as cancel_deconstruction does.
  function H.deconstruct(p,a)
    if a.cancel~=nil then
      assert(type(a.cancel)=='boolean','cancel must be true or false')
      if a.cancel then
        local rest={}
        for k,v in pairs(a) do if k~='cancel' then rest[k]=v end end
        assert(not rest.dry_run,'cancel and dry_run: one or the other')
        local out=deconstruct(p,rest,true)
        -- (A3) the stacks on the ground unmarked count with the entities
        out.cancelled=(out.changed or 0)+(out.item_stacks_cancelled or 0)
        return out
      end
    end
    return deconstruct(p,a,false)
  end
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
      uses=e.uses or 0,surface=e.surface,anchor=e.anchor~=nil or nil,size_kb=kb(#(e.string or '')),imported=e.imported,
      retired=retired_line(e)}
    if full then
      r.description=e.description; r.anchor=e.anchor; r.captured=e.captured
      r.retired_at=e.retired and ago(game.tick-e.retired.tick) or nil
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
      -- (B4, Sol 22:50: standing on Aquilo, an area on Vulcanus read as empty: the surface is named)
      assert(#entities>0,string.format('nothing to save: no entity or ghost of ours %s on %s%s',keep and 'at those positions' or 'in the area',p.surface.name,
        (type(p)=='table' and rawget(p,'__remote')) and '' or ' (your surface; surface=NAME saves an area on another planet by remote view, platform=NAME on a platform)'))
      -- Ghosts go in at their positions as entities of the blueprint, tile ghosts as its tiles (tiles: true).
      local ghosts=0
      for _,e in ipairs(entities) do local w=mapping[e.entity_number]; if w and w.valid and w.type=='entity-ghost' then ghosts=ghosts+1 end end
      -- Rebased as blueprint_capture does (an even shift keeps the rail grid).
      local origin=rebase_origin(box,entities)
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
      room_for(name,#value)
      lib.revision=lib.revision+1
      local entry={name=name,author=api.who(p),string=value,entities=#ents,tiles=#tls,counts=counts,
        footprint={w=r-l,h=b-t},anchor=anchor and {x=anchor.x-origin.x,y=anchor.y-origin.y} or nil,surface=p.surface.name,
        description=a.description and a.description:gsub('%s+',' ') or nil,saved_tick=game.tick,rev=lib.revision,uses=0,
        captured={left_top=box.left_top,right_bottom=box.right_bottom}}
      lib.entries[name]=entry
      local out=row(entry)
      out.replaced=old and old.author or nil
      out.retired_cleared=retired_line(old)
      out.ghosts=ghosts>0 and ghosts or nil
      if a.tiles==true then
        local tg=p.surface.count_entities_filtered{area=box,type='tile-ghost',force=p.force}
        out.tile_ghosts=tg>0 and tg or nil
      end
      if ghosts>0 or out.tile_ghosts then
        out.note=string.format('%d of the %d entities are ghosts%s, saved at their positions as the rest',ghosts,#ents,out.tile_ghosts and string.format(' and %d tiles tile ghosts',out.tile_ghosts) or '')
      end
      return out
    end)
  end
  -- (d20 batch59 U2) a page of entries by name (limit, from), each with its string's size, and the library's size.
  function H.blueprint_list(p,a)
    a=a or {}
    if a.name~=nil then return row(library_entry(a.name),true) end
    local limit=a.limit==nil and 64 or api.integer(a.limit,64,1,MAX_LIBRARY,'limit')
    local from=a.from==nil and 1 or api.integer(a.from,1,1,MAX_LIBRARY,'from')
    local out=slot_list(p)
    local all={}
    for _,e in pairs(library().entries) do all[#all+1]=e end
    table.sort(all,function(x,y) return x.name<y.name end)
    local rows,retired={},0
    for i=from,math.min(#all,from+limit-1) do rows[#rows+1]=row(all[i]) end
    for _,e in ipairs(all) do if e.retired then retired=retired+1 end end
    out.library_retired=retired>0 and retired or nil
    local bytes=library_bytes()
    out.library=rows; out.library_limit=MAX_LIBRARY
    out.library_bytes=bytes; out.library_bytes_limit=MAX_LIBRARY_BYTES
    out.library_size=string.format('%d of %d entries; %g of %g KB of strings',#all,MAX_LIBRARY,kb(bytes),kb(MAX_LIBRARY_BYTES))
    if from>1 or from+limit-1<#all then
      out.library_page=string.format('entries %d-%d of %d by name%s',math.min(from,#all),math.min(#all,from+limit-1),#all,
        from+limit-1<#all and string.format('; blueprint_list {from: %d} reads on',from+limit) or '')
    end
    return out
  end
  function H.blueprint_delete(p,a)
    if a.name==nil then return slot_delete(p,a) end
    assert(a.slot==nil,'give name (a library entry) or slot, not both')
    local e=library_entry(a.name)
    may_change(p,e,'delete')
    local lib=library()
    lib.entries[e.name]=nil; lib.revision=lib.revision+1
    local named={}
    for n,x in pairs(lib.entries) do if x.retired and x.retired.replaced_by==e.name then named[#named+1]=n end end
    table.sort(named)
    return {name=e.name,deleted=true,author=e.author,replacement_for=#named>0 and named or nil}
  end
  -- (d20 batch59 U2, Astra #1446) a string into the team library, as a player imports one into theirs: the importer is
  -- its author, and the same name replaces an entry under blueprint_save's rules. One blueprint (not a book), within
  -- the library's entries and bytes. description and anchor (blueprint coordinates, as blueprint_export gives them)
  -- are kept with it; the string's own description is the default description.
  local function library_import(p,a)
    permission(p,'import_blueprint_string')
    local name=entry_name(a.name)
    assert(a.slot==nil,'give name (a library entry) or slot, not both')
    assert(type(a.blueprint)=='string' and #a.blueprint>0 and #a.blueprint<=MAX_STRING,'blueprint string size out of range')
    assert(a.description==nil or (type(a.description)=='string' and #a.description<=MAX_DESCRIPTION),'description must be text of up to '..MAX_DESCRIPTION..' characters')
    local lib=library()
    local old=lib.entries[name]
    if old then may_change(p,old,'replace') end
    local anchor=a.anchor~=nil and api.position(a.anchor) or nil
    return temporary(function(stack)
      assert(stack.import_stack(a.blueprint)==0,'blueprint import failed or contains missing prototypes')
      assert(stack.valid_for_read and stack.is_blueprint,'a library entry is one blueprint: this string holds '..(stack.valid_for_read and (stack.is_blueprint_book and 'a blueprint book' or stack.name) or 'nothing'))
      local ents,tls=validate(stack)
      local l,t,r,b=extent(ents,tls)
      assert(not anchor or (anchor.x>=l and anchor.x<=r and anchor.y>=t and anchor.y<=b),
        string.format('anchor must lie in the blueprint (%g..%g, %g..%g in blueprint coordinates)',l,r,t,b))
      local desc=a.description
      if desc==nil then
        local own=(function() local ok,v=pcall(function() return stack.blueprint_description end); return ok and v or nil end)()
        if type(own)=='string' and own~='' then desc=own:sub(1,MAX_DESCRIPTION) end
      end
      stack.label=name
      local value=stack.export_stack()
      assert(#value<=MAX_STRING,'blueprint export exceeds size limit')
      room_for(name,#value)
      local counts={}
      for _,e in ipairs(ents) do counts[e.name]=(counts[e.name] or 0)+1 end
      lib.revision=lib.revision+1
      local entry={name=name,author=api.who(p),string=value,entities=#ents,tiles=#tls,counts=counts,footprint={w=r-l,h=b-t},
        anchor=anchor and {x=anchor.x,y=anchor.y} or nil,description=desc and desc:gsub('%s+',' ') or nil,saved_tick=game.tick,
        rev=lib.revision,uses=0,imported=true}
      lib.entries[name]=entry
      local out=row(entry)
      out.replaced=old and old.author or nil
      out.retired_cleared=retired_line(old)
      out.library_size=string.format('%d of %d entries; %g of %g KB of strings',select(2,library_bytes()),MAX_LIBRARY,kb((library_bytes())),kb(MAX_LIBRARY_BYTES))
      return out
    end)
  end
  local slot_import=H.blueprint_import
  function H.blueprint_import(p,a)
    if a.name~=nil then return library_import(p,a) end
    return slot_import(p,a)
  end
  -- A library entry's export (blueprint_export {name}): its string carries the entry's name as label and its
  -- description, as a player's exported string does; the reply gives what blueprint_import {name} takes back.
  local slot_export=H.blueprint_export
  function H.blueprint_export(p,a)
    if a.name==nil or a.layout==true then return slot_export(p,a) end
    permission(p,'export_blueprint')
    local e=library_entry(a.name)
    return load(p,a,function(stack)
      if e.description then pcall(function() stack.blueprint_description=e.description end) end
      local out={name=e.name,author=e.author,kind='blueprint',entities=e.entities,tiles=e.tiles,description=e.description,anchor=e.anchor,
        size_kb=kb(#e.string),retired=retired_line(e),blueprint=stack.export_stack()}
      return out
    end)
  end
  function H.blueprint_rename(p,a)
    local e=library_entry(a.name)
    local new=entry_name(a.new_name,'new_name')
    assert(not library().entries[new],'the library has an entry '..new..' already')
    may_change(p,e,'rename')
    local lib,was=library(),e.name
    lib.entries[was]=nil; e.name=new; lib.entries[new]=e
    lib.revision=lib.revision+1; e.rev=lib.revision
    local named={}
    for n,x in pairs(lib.entries) do if x.retired and x.retired.replaced_by==was then x.retired.replaced_by=new; named[#named+1]=n end end
    table.sort(named)
    return {name=new,was=was,author=e.author,replacement_for=#named>0 and named or nil}
  end
  -- blueprint_retire {name, reason, replaced_by} marks an entry retired (replaced_by an entry of the library that is not
  -- retired itself); {name, clear: true} clears the mark. Who may, as blueprint_rename: its author any time, anyone
  -- after 24 game hours unused.
  function H.blueprint_retire(p,a)
    local e=library_entry(a.name)
    local lib=library()
    if a.clear~=nil then
      assert(a.clear==true,'clear must be true')
      assert(a.reason==nil and a.replaced_by==nil,'clear: true takes name only')
      if not e.retired then return {name=e.name,author=e.author,unchanged=e.name..' is not retired'} end
      may_change(p,e,'clear the retired mark of')
      local was=retired_line(e)
      e.retired=nil; lib.revision=lib.revision+1
      return {name=e.name,author=e.author,cleared=was}
    end
    assert(type(a.reason)=='string' and a.reason:match('%S') and #a.reason<=MAX_REASON,'reason must be text of 1..'..MAX_REASON..' characters')
    local new=library_entry(entry_name(a.replaced_by,'replaced_by'))
    assert(new~=e,'replaced_by names '..e.name..' itself')
    assert(not new.retired,new.name..' is retired itself: '..(retired_line(new) or ''))
    may_change(p,e,'retire')
    local was=retired_line(e)
    e.retired={by=api.who(p),reason=(a.reason:gsub('%s+',' ')),replaced_by=new.name,tick=game.tick}
    lib.revision=lib.revision+1
    return {name=e.name,author=e.author,retired=retired_line(e),was=was,
      note='the description is kept as written; blueprint_list, blueprint_export and a paste of '..e.name..' say it is retired'}
  end
  -- Operator read (tools/bplibrary.py): every entry's facts, and the string of each changed after `since`.
  H.operator={}
  -- (d20 batch59 U2) the strings go MAX_READ_BYTES a read at most (at least one): the JSON of 7.6 MB of strings took
  -- 21.8 ms on the private copy, 416 KB 1.0 ms. strings_after names the last entry whose string came; the next read
  -- passes it as after.
  local MAX_READ_BYTES=1000000
  function H.operator.blueprint_library(args)
    local lib,since=library(),tonumber(args and args.since) or -1
    local after=args and type(args.after)=='string' and args.after or nil
    local budget=tonumber(args and args.max_bytes) or MAX_READ_BYTES
    local rows,sent,last,held={},0,nil,false
    for _,e in pairs(lib.entries) do
      local r=row(e,true)
      r.rev=e.rev; r.saved_tick=e.saved_tick; r.last_used_tick=e.last_used; r.retired_tick=e.retired and e.retired.tick or nil
      rows[#rows+1]=r
    end
    table.sort(rows,function(x,y) return x.name<y.name end)
    for _,r in ipairs(rows) do
      local e=lib.entries[r.name]
      if (e.rev or 0)>since and (not after or r.name>after) then
        if held or (sent>0 and sent+#e.string>budget) then held=true
        else r.string=e.string; sent=sent+#e.string; last=r.name end
      end
    end
    return {revision=lib.revision,tick=game.tick,entries=rows,strings_after=held and last or nil}
  end
  return H
end
