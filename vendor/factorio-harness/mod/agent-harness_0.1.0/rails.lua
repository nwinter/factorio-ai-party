-- Rails in 2.0 (operator task, shift09 00:50: Nauvis had railway researched
-- and no rail; 2.0 rails are not 1.1's). rail_route lays a line of the rail
-- planner's own pieces from one point to another around what blocks it;
-- train_stop puts a stop on the side of a straight rail the game connects it
-- to. The tables below were read from the game (2.0.77 with Space Age) on a
-- test surface. level elevated (d20 batch61 W1) plans rail ramps, elevated
-- rails and rail supports.
local heap=require('heap')
return function(api)
  local M={}
  local NAMES={[0]='north','northnortheast','northeast','eastnortheast','east','eastsoutheast','southeast','southsoutheast',
    'south','southsouthwest','southwest','westsouthwest','west','westnorthwest','northwest','northnorthwest'}
  local LETTERS={[0]='N','NNE','NE','ENE','E','ESE','SE','SSE','S','SSW','SW','WSW','W','WNW','NW','NNW'}
  M.NAMES=NAMES
  local PIECES={'straight-rail','half-diagonal-rail','curved-rail-a','curved-rail-b'}
  local PIECE_INDEX={}
  for i,n in ipairs(PIECES) do PIECE_INDEX[n]=i end
  local CURVE={['curved-rail-a']=true,['curved-rail-b']=true}
  -- Elevated rails (d20 batch61 W1, Sol #1491: Fulgora island links) have the ground pieces' geometry and boxes; read
  -- from the game (2.0.77) on the private copy: a rail ramp (cardinal, 16 tiles) has its ground end 8 tiles behind its
  -- position and its elevated end 8 ahead (the way it rises); a rail support stands on a rail joint, facing the rail
  -- (8 directions); the game builds an elevated rail only where it joins elevated rail and lies wholly within 11 tiles
  -- of one support (9 of a ramp's elevated end): one support alone carried rails out to 10 tiles, and two supports
  -- 20 tiles apart carried the span between, 22 apart did not. Supports stand on land, water and shallow oil ocean;
  -- on deep oil ocean once Rail support foundations is researched.
  local ELEV,BASE={},{}
  for _,n in ipairs(PIECES) do ELEV[n]='elevated-'..n; BASE['elevated-'..n]=n; BASE[n]=n end
  M.ELEV=ELEV
  M.SUPPORT_REACH,M.RAMP_REACH=11,9
  -- What a ghost goes over: never a blocker.
  local CLEARABLE={tree=true,['simple-entity']=true,plant=true}
  -- From a rail end at (x,y) that a train leaves heading d, the pieces the
  -- planner lays next (LuaRailEnd.get_rail_extensions('rail')): name, the
  -- piece's direction, its position from the end, and the new end's offset
  -- and heading. Ends of heading d sit where x%2, y%2 = PARITY[d].
  local EXT={
    [0]={{'straight-rail',0,0,-1,0,-2,0},{'curved-rail-a',0,0,-2,-1,-5,15},{'curved-rail-a',2,0,-2,1,-5,1}},
    [1]={{'curved-rail-a',10,1,-3,1,-5,0},{'curved-rail-b',2,1,-2,3,-4,2},{'half-diagonal-rail',2,1,-2,2,-4,1}},
    [2]={{'straight-rail',2,1,-1,2,-2,2},{'curved-rail-b',10,2,-2,3,-4,1},{'curved-rail-b',12,2,-2,4,-3,3}},
    [3]={{'curved-rail-a',12,3,-1,5,-1,4},{'curved-rail-b',4,2,-1,4,-3,2},{'half-diagonal-rail',4,2,-1,4,-2,3}},
    [4]={{'straight-rail',4,1,0,2,0,4},{'curved-rail-a',4,2,0,5,-1,3},{'curved-rail-a',6,2,0,5,1,5}},
    [5]={{'curved-rail-a',14,3,1,5,1,4},{'curved-rail-b',6,2,1,4,3,6},{'half-diagonal-rail',6,2,1,4,2,5}},
    [6]={{'straight-rail',6,1,1,2,2,6},{'curved-rail-b',0,2,2,3,4,7},{'curved-rail-b',14,2,2,4,3,5}},
    [7]={{'curved-rail-a',0,1,3,1,5,8},{'curved-rail-b',8,1,2,3,4,6},{'half-diagonal-rail',0,1,2,2,4,7}},
    [8]={{'straight-rail',0,0,1,0,2,8},{'curved-rail-a',8,0,2,1,5,7},{'curved-rail-a',10,0,2,-1,5,9}},
    [9]={{'curved-rail-a',2,-1,3,-1,5,8},{'curved-rail-b',10,-1,2,-3,4,10},{'half-diagonal-rail',2,-1,2,-2,4,9}},
    [10]={{'straight-rail',2,-1,1,-2,2,10},{'curved-rail-b',2,-2,2,-3,4,9},{'curved-rail-b',4,-2,2,-4,3,11}},
    [11]={{'curved-rail-a',4,-3,1,-5,1,12},{'curved-rail-b',12,-2,1,-4,3,10},{'half-diagonal-rail',4,-2,1,-4,2,11}},
    [12]={{'straight-rail',4,-1,0,-2,0,12},{'curved-rail-a',12,-2,0,-5,1,11},{'curved-rail-a',14,-2,0,-5,-1,13}},
    [13]={{'curved-rail-a',6,-3,-1,-5,-1,12},{'curved-rail-b',14,-2,-1,-4,-3,14},{'half-diagonal-rail',6,-2,-1,-4,-2,13}},
    [14]={{'straight-rail',6,-1,-1,-2,-2,14},{'curved-rail-b',6,-2,-2,-4,-3,13},{'curved-rail-b',8,-2,-2,-3,-4,15}},
    [15]={{'curved-rail-a',8,-1,-3,-1,-5,0},{'curved-rail-b',0,-1,-2,-3,-4,14},{'half-diagonal-rail',0,-1,-2,-2,-4,15}}}
  M.EXT=EXT
  local PARITY={}
  for d=0,15 do
    if d%4==0 then PARITY[d]=(d%8==0) and {1,0} or {0,1}
    elseif d%2==0 then PARITY[d]={1,1}
    elseif d==1 or d==7 or d==9 or d==15 then PARITY[d]={0,1}
    else PARITY[d]={1,0} end
  end
  M.PARITY=PARITY
  -- Straight and half-diagonal pieces repeat every 8 directions.
  local function norm(name,dir) return (CURVE[name] and dir or dir%8) end
  local function opposite(d) return (d+8)%16 end
  M.opposite=opposite
  -- Each piece's two ends (offset from its position, heading out of it),
  -- from the table above: an extension's start end and its new end.
  local ENDS,LEN={},{}
  for d=0,15 do
    for _,m in ipairs(EXT[d]) do
      local k=m[1]..'/'..norm(m[1],m[2])
      if not ENDS[k] then ENDS[k]={{-m[3],-m[4],opposite(d)},{m[5]-m[3],m[6]-m[4],m[7]}} end
      m.len=(m[5]^2+m[6]^2)^0.5
      LEN[k]=m.len
    end
  end
  function M.ends_of(name,pos,dir)
    name=BASE[name] or name
    local e=ENDS[name..'/'..norm(name,dir)]
    if not e then return nil end
    return {{x=pos.x+e[1][1],y=pos.y+e[1][2],d=e[1][3]},{x=pos.x+e[2][1],y=pos.y+e[2][2],d=e[2][3]}}
  end
  -- The piece's collision box as the game sets it (LuaEntity.bounding_box):
  -- centre offset from the position, half width, half length, orientation.
  local BOX={['straight-rail/0']={0,0,0.6992,0.9883,0},['straight-rail/2']={0,0,0.6992,1.3477,0.125},
    ['straight-rail/4']={0,0,0.6992,0.9883,0.25},['straight-rail/6']={0,0,0.6992,1.3477,0.375},
    ['half-diagonal-rail/0']={0,0,0.75,1.8984,0.926208},['half-diagonal-rail/2']={0,0,0.75,1.8984,0.073792},
    ['half-diagonal-rail/4']={0,0,0.75,1.8984,0.176208},['half-diagonal-rail/6']={0,0,0.75,1.8984,0.323792},
    ['curved-rail-a/0']={-0.3477,-0.5273,0.6992,2.5156,0.968584},['curved-rail-a/2']={0.3477,-0.5273,0.6992,2.5156,0.031416},
    ['curved-rail-a/4']={0.5273,-0.3477,0.6992,2.5156,0.218584},['curved-rail-a/6']={0.5273,0.3477,0.6992,2.5156,0.281416},
    ['curved-rail-a/8']={0.3477,0.5273,0.6992,2.5156,0.468584},['curved-rail-a/10']={-0.3477,0.5273,0.6992,2.5156,0.531416},
    ['curved-rail-a/12']={-0.5273,0.3477,0.6992,2.5156,0.718584},['curved-rail-a/14']={-0.5273,-0.3477,0.6992,2.5156,0.781416},
    ['curved-rail-b/0']={-0.4453,-0.0664,0.6992,2.4375,0.898124},['curved-rail-b/2']={0.4453,-0.0664,0.6992,2.4375,0.101876},
    ['curved-rail-b/4']={0.0664,-0.4453,0.6992,2.4375,0.148124},['curved-rail-b/6']={0.0664,0.4453,0.6992,2.4375,0.351876},
    ['curved-rail-b/8']={0.4453,0.0664,0.6992,2.4375,0.398124},['curved-rail-b/10']={-0.4453,0.0664,0.6992,2.4375,0.601876},
    ['curved-rail-b/12']={-0.0664,0.4453,0.6992,2.4375,0.648124},['curved-rail-b/14']={-0.0664,-0.4453,0.6992,2.4375,0.851876}}
  -- An oriented box {cx, cy, ux, uy (width axis), vx, vy (length axis), hw,
  -- hl} and the box around it (left_top, right_bottom).
  local function oriented(cx,cy,hw,hl,o)
    local t=o*2*math.pi
    local c,s=math.cos(t),math.sin(t)
    local ob={cx=cx,cy=cy,ux=c,uy=s,vx=-s,vy=c,hw=hw,hl=hl}
    local ex,ey=math.abs(c)*hw+math.abs(s)*hl,math.abs(s)*hw+math.abs(c)*hl
    ob.left_top={x=cx-ex,y=cy-ey}; ob.right_bottom={x=cx+ex,y=cy+ey}
    return ob
  end
  M.oriented=oriented
  function M.box(name,pos,dir)
    name=BASE[name] or name
    local b=BOX[name..'/'..norm(name,dir or 0)]
    if not b then return nil end
    return oriented(pos.x+b[1],pos.y+b[2],b[3],b[4],b[5])
  end
  -- Whether an oriented box and an axis-aligned one overlap (separating axes).
  function M.overlaps(ob,l,t,r,b)
    local margin=0.01
    local bx,by,bw,bh=(l+r)/2,(t+b)/2,(r-l)/2,(b-t)/2
    if math.abs(ob.cx-bx)>=bw+(ob.right_bottom.x-ob.left_top.x)/2-margin then return false end
    if math.abs(ob.cy-by)>=bh+(ob.right_bottom.y-ob.left_top.y)/2-margin then return false end
    for _,ax in ipairs({{ob.ux,ob.uy,ob.hw},{ob.vx,ob.vy,ob.hl}}) do
      local nx,ny,half=ax[1],ax[2],ax[3]
      local d=math.abs((bx-ob.cx)*nx+(by-ob.cy)*ny)
      if d>=half+bw*math.abs(nx)+bh*math.abs(ny)-margin then return false end
    end
    return true
  end
  -- Rail signal for trains leaving an end heading d: where it goes (on their
  -- right, LuaRailEnd.out_signal_location) and the signal's direction.
  local SIGNAL={[0]={1.5,0.5,8},{0.5,1.5,9},{0.5,1.5,10},{-0.5,1.5,11},{-0.5,1.5,12},{-1.5,0.5,13},{-1.5,0.5,14},{-1.5,-0.5,15},
    {-1.5,-0.5,0},{-0.5,-1.5,1},{-0.5,-1.5,2},{0.5,-1.5,3},{0.5,-1.5,4},{1.5,-0.5,5},{1.5,-0.5,6},{1.5,0.5,7}}
  M.SIGNAL=SIGNAL
  -- A train stop serving trains heading d beside a straight rail at (x,y):
  -- on their right, two tiles from the rail's centre line.
  local STOP={[0]={2,0},[4]={0,2},[8]={-2,0},[12]={0,-2}}

  local MARGIN,GOAL_R,END_R=32,2,2.5
  local MAX_LEG,MAX_PIECES,MAX_CHECKS,MAX_EXPANSIONS=500,1024,6000,2500
  -- Search costs: a curve piece counts 6 tiles more than its length, a piece
  -- over trees or rocks 1 more; the search weighs the estimate twice (it
  -- finds a good route, not always the shortest).
  M.TUNE={curve=6,clear=1,weight=2,turn_r=13}
  -- Unit vectors of the 16 headings (north is -y).
  local HX,HY={},{}
  for d=0,15 do HX[d]=math.sin(d*math.pi/8); HY[d]=-math.cos(d*math.pi/8) end
  local OFF,K=2^21,2^22
  local function skey(x,y,d) return ((x+OFF)*K+(y+OFF))*16+d end
  local function fmt(x,y) return string.format('(%g,%g)',x,y) end
  local function dist(ax,ay,bx,by) return ((ax-bx)^2+(ay-by)^2)^0.5 end
  -- The nearest point to (x,y) where an end of heading d can sit.
  local function snap(v,par) return 2*math.floor((v-par)/2+0.5)+par end

  local RAIL_TYPES={'straight-rail','half-diagonal-rail','curved-rail-a','curved-rail-b'}
  local ELEV_TYPES={'elevated-straight-rail','elevated-half-diagonal-rail','elevated-curved-rail-a','elevated-curved-rail-b','rail-ramp'}
  -- A cardinal heading's unit step (north is -y).
  local UX,UY={[0]=0,[4]=1,[8]=0,[12]=-1},{[0]=-1,[4]=0,[8]=1,[12]=0}
  -- A ramp rising toward d with its ground end at g: its position, and its ground and elevated ends (each heading out).
  function M.ramp_at(g,d)
    return {position={x=g.x+8*UX[d],y=g.y+8*UY[d]},direction=d,ground={x=g.x,y=g.y,d=(d+8)%16},top={x=g.x+16*UX[d],y=g.y+16*UY[d],d=d}}
  end
  local function piece_ends(name,pos,dir,elevated)
    if name=='rail-ramp' then
      local d=math.floor(dir/4)*4
      local r=M.ramp_at({x=pos.x-8*UX[d],y=pos.y-8*UY[d]},d)
      return elevated and {r.top} or {r.ground}
    end
    return M.ends_of(name,pos,dir)
  end
  -- Our rails and rail ghosts around pos (radius r): every end, and whether
  -- another rail meets it there. elevated: elevated rails and ramps' elevated ends.
  function M.ends_near(p,pos,r,elevated)
    local s,force=p.surface,p.force
    local area={left_top={x=pos.x-r-6,y=pos.y-r-6},right_bottom={x=pos.x+r+6,y=pos.y+r+6}}
    local found={}
    local types=elevated and ELEV_TYPES or RAIL_TYPES
    for _,e in pairs(s.find_entities_filtered{area=area,type=types,force=force}) do found[#found+1]={e=e,name=e.name} end
    for _,e in pairs(s.find_entities_filtered{area=area,ghost_type=types,force=force}) do found[#found+1]={e=e,name=e.ghost_name,ghost=true} end
    local all,list={},{}
    for _,f in ipairs(found) do
      if f.e.valid then
        for _,en in ipairs(piece_ends(f.name,f.e.position,f.e.direction,elevated) or {}) do
          all[skey(en.x,en.y,en.d)]=true
          en.rail=f
          list[#list+1]=en
        end
      end
    end
    local out={}
    for _,en in ipairs(list) do
      local dd=dist(en.x,en.y,pos.x,pos.y)
      if dd<=r then
        en.free=not all[skey(en.x,en.y,opposite(en.d))]
        en.dist=dd
        out[#out+1]=en
      end
    end
    -- Free ends first, nearest first.
    table.sort(out,function(a,b)
      if a.free~=b.free then return a.free end
      return a.dist<b.dist
    end)
    return out
  end

  -- What blocks one piece: entities in its footprint (rails crossing it do
  -- not, nor trees and rocks a ghost goes over) and tiles it cannot stand on.
  function M.blockers(p,name,x,y,dir)
    local s=p.surface
    local ob=M.box(name,{x=x,y=y},dir)
    if not ob then return {} end
    local out,seen={},{}
    local function add(t) if not seen[t] and #out<4 then seen[t]=true; out[#out+1]=t end end
    local area={left_top=ob.left_top,right_bottom=ob.right_bottom}
    -- Only what the rail collides with (a robot flying over does not count).
    local mine=prototypes.entity[name] and prototypes.entity[name].collision_mask
    local function collides(e)
      local ok,om=pcall(function() return (e.type=='entity-ghost' and e.ghost_prototype or e.prototype).collision_mask end)
      if not (ok and om and mine) then return true end
      for k in pairs(om.layers or {}) do if mine.layers and mine.layers[k] then return true end end
      return false
    end
    local function at(pos) return fmt(math.floor(pos.x*10+0.5)/10,math.floor(pos.y*10+0.5)/10) end
    for _,e in pairs(s.find_entities_filtered{area=area,limit=24}) do
      if e.valid and e.type~='resource' and e.type~='corpse' and e.type~='item-entity' and e.type~='fish' and e.type~='character' and collides(e) then
        local nm=e.type=='entity-ghost' and e.ghost_name or e.name
        local rail=PIECE_INDEX[nm]~=nil
        local same=rail and nm==name and math.abs(e.position.x-x)<0.01 and math.abs(e.position.y-y)<0.01 and norm(nm,e.direction)==norm(name,dir)
        local b=e.bounding_box
        local hit=b and (b.orientation==nil or b.orientation==0) and M.overlaps(ob,b.left_top.x,b.left_top.y,b.right_bottom.x,b.right_bottom.y)
        if b and b.orientation and b.orientation~=0 then hit=true end
        if same then add((e.type=='entity-ghost' and 'a ghost of the same rail ' or 'the same rail ')..at(e.position))
        elseif hit and not rail and not CLEARABLE[e.type] then
          local what=e.type=='entity-ghost' and 'ghost '..nm or nm
          if e.force and e.force.name~='neutral' and e.force~=p.force then what=what..' of force '..e.force.name end
          add(what..' '..at(e.position))
        end
      end
    end
    for _,t in pairs(s.find_tiles_filtered{area=area,limit=32}) do
      local layers=t.prototype.collision_mask and t.prototype.collision_mask.layers or {}
      if (layers.water_tile or layers.lava_tile or layers.empty_space or layers.out_of_map) and M.overlaps(ob,t.position.x,t.position.y,t.position.x+1,t.position.y+1) then
        add(t.name)
      end
    end
    return out
  end

  -- The plan. a: from, to, via (up to 16 points in order), signals (every N
  -- tiles). Returns entities to place, in order, and what describes them.
  function M.plan(p,a)
    local s,force=p.surface,p.force
    assert(not (s.platform~=nil),'rails cannot be built on a space platform')
    -- (d18 batch36 D2) each missing end named, with its shape
    if a.from==nil or a.to==nil then
      local miss={}
      if a.from==nil then miss[#miss+1]='from' end
      if a.to==nil then miss[#miss+1]='to' end
      error('rail_route needs '..table.concat(miss,' and ')..': from {x, y} (where the rails start) and to {x, y} (where they end); via [{x, y}, ...] optional',0)
    end
    local points={api.position(a.from)}
    if a.via~=nil then
      assert(type(a.via)=='table' and #a.via>=1 and #a.via<=16,'via is 1..16 {x,y} points passed in order')
      for _,v in ipairs(a.via) do points[#points+1]=api.position(v) end
    end
    points[#points+1]=api.position(a.to)
    for i=1,#points-1 do
      local d=dist(points[i].x,points[i].y,points[i+1].x,points[i+1].y)
      assert(d<=MAX_LEG,string.format('%s to %s is %d tiles; each leg (from, via points, to) is at most %d tiles',
        fmt(points[i].x,points[i].y),fmt(points[i+1].x,points[i+1].y),math.floor(d+0.5),MAX_LEG))
    end
    local from_d=a.from_direction~=nil and api.directions[a.from_direction]
    assert(a.from_direction==nil or from_d,'from_direction must be a compass name (16 directions: north, northnortheast, northeast, ...)')
    -- (d20 batch61 W1) level elevated: a ramp up at from, elevated rails, a ramp down at to, supports between
    local level=a.level
    if a.elevated~=nil then
      assert(type(a.elevated)=='boolean','elevated must be true or false')
      assert(level==nil or (level=='elevated')==a.elevated,'level and elevated differ; give one of them')
      level=a.elevated and 'elevated' or 'ground'
    end
    level=level or 'ground'
    assert(level=='ground' or level=='elevated','level is ground (the default) or elevated (rail ramps, elevated rails and rail supports)')
    local elevated=level=='elevated'
    local to_d=a.to_direction~=nil and api.directions[a.to_direction]
    assert(a.to_direction==nil or (elevated and to_d and to_d%4==0),'to_direction (level elevated: the way trains run down the ramp at to) is north, east, south or west')
    assert(not (elevated and a.signals~=nil),'signals: rail_route places rail signals on ground rails only, not on level elevated')
    local every
    if a.signals~=nil then
      every=type(a.signals)=='number' and a.signals or type(a.signals)=='string' and tonumber(a.signals:match('%d+%.?%d*'))
      assert(every and every>=4 and every<=1000,'signals is the spacing in tiles, 4..1000 (a number, or text such as "every 30 tiles")')
    end

    local charted,chunk={},{x=0,y=0}
    local function is_charted(x,y)
      local cx,cy=math.floor(x/32),math.floor(y/32)
      local k=cx*65536+cy
      local v=charted[k]
      if v==nil then chunk.x,chunk.y=cx,cy; v=force.is_chunk_charted(s,chunk); charted[k]=v end
      return v
    end
    -- Per piece placement: 0 free, 1 over trees or rocks (a ghost marks them
    -- for removal), false blocked. One engine check; when it refuses, the
    -- forced check (what a ghost may go over) and the tiles: the forced check
    -- takes ghosts over water too, which the route keeps off.
    local fits,checks,blocked_list={},0,{}
    local args={position={x=0,y=0},force=force,build_check_type=defines.build_check_type.manual_ghost}
    local wet={area={left_top={x=0,y=0},right_bottom={x=0,y=0}},collision_mask='water_tile',limit=1}
    local function fit(name,dir,x,y)
      local k=((x+OFF)*K+(y+OFF))*128+PIECE_INDEX[name]*16+dir
      local v=fits[k]
      if v~=nil then return v end
      if not is_charted(x,y) then v=false
      elseif elevated then
        -- Elevated rails go over ground, water and buildings; other elevated rails and ramps decide.
        checks=checks+1
        args.name=ELEV[name]; args.direction=dir; args.position.x=x; args.position.y=y; args.forced=nil
        v=s.can_place_entity(args) and 0 or false
        if not v then
          -- the same piece of ours there already (a call before laid it): the route goes along it
          local at={x=x,y=y}
          for _,list in ipairs({s.find_entities_filtered{position=at,radius=0.1,name=args.name,force=force,limit=2},
            s.find_entities_filtered{position=at,radius=0.1,ghost_name=args.name,force=force,limit=2}}) do
            for _,e in ipairs(list) do if e.valid and norm(name,e.direction)==norm(name,dir) then v=0 end end
          end
        end
      else
        checks=checks+1
        args.name=name; args.direction=dir; args.position.x=x; args.position.y=y; args.forced=nil
        if s.can_place_entity(args) then v=0
        else
          checks=checks+1
          args.forced=true
          v=false
          if s.can_place_entity(args) then
            local ob=M.box(name,args.position,dir)
            wet.area.left_top=ob.left_top; wet.area.right_bottom=ob.right_bottom
            checks=checks+1
            if s.count_tiles_filtered(wet)==0 then v=1 end
          end
        end
      end
      fits[k]=v
      if v==false and #blocked_list<4096 then blocked_list[#blocked_list+1]={name=name,dir=dir,x=x,y=y} end
      return v
    end

    -- The start: an end of our rails near from (a free end continues the
    -- line, an end where rails meet branches off it), else any heading.
    local starts,extends={},nil
    local ramps={}
    -- A ramp rising toward d with its ground end at g, if the game takes its ghost there (and its ends are charted).
    local function ramp_fits(g,d)
      local r=M.ramp_at(g,d)
      if not (is_charted(r.ground.x,r.ground.y) and is_charted(r.top.x,r.top.y)) then return nil,'not charted' end
      checks=checks+1
      args.name='rail-ramp'; args.direction=d; args.position.x=r.position.x; args.position.y=r.position.y; args.forced=nil
      if s.can_place_entity(args) then return r end
      return nil,api.ramp_why and api.ramp_why(p,r.position,d) or 'the game refuses a ramp there'
    end
    -- Cardinal headings, those pointing from a toward b first.
    local function cardinals(pa,pb,fixed)
      local list={}
      for _,d in ipairs({0,4,8,12}) do if not fixed or d==fixed then list[#list+1]={d=d,c=(pb.x-pa.x)*UX[d]+(pb.y-pa.y)*UY[d]} end end
      table.sort(list,function(u,v) return u.c>v.c end)
      return list
    end
    -- A ramp at one end of an elevated route: from a free end of our ground rail there (cardinal, continued), else on
    -- free ground at the point, rising toward the other end (up) or toward the start (down).
    local function place_ramp(pt,toward,fixed,role)
      local tried={}
      -- our ramp (built or a ghost) with its ground end at the point: a call before placed it; the route goes on from it
      local area={left_top={x=pt.x-END_R-9,y=pt.y-END_R-9},right_bottom={x=pt.x+END_R+9,y=pt.y+END_R+9}}
      local own={}
      for _,e in pairs(s.find_entities_filtered{area=area,type='rail-ramp',force=force}) do own[#own+1]=e end
      for _,e in pairs(s.find_entities_filtered{area=area,ghost_type='rail-ramp',force=force}) do own[#own+1]=e end
      for _,e in ipairs(own) do
        local d=math.floor(e.direction/4)*4
        local r=M.ramp_at({x=e.position.x-8*UX[d],y=e.position.y-8*UY[d]},d)
        if e.valid and dist(r.ground.x,r.ground.y,pt.x,pt.y)<=END_R and (not fixed or (role=='up' and d==fixed) or (role=='down' and d==opposite(fixed))) then
          r.existing=e.type=='entity-ghost' and 'a ghost of your rail ramp' or 'your rail ramp'
          return r
        end
      end
      local near_ground=M.ends_near(p,pt,END_R)
      for _,en in ipairs(near_ground) do
        if en.free and en.d%4==0 and (not fixed or (role=='up' and en.d==fixed) or (role=='down' and en.d==opposite(fixed))) then
          local r,why=ramp_fits(en,en.d)
          if r then r.joins={position={x=en.x,y=en.y},rail=en.rail.name,ghost=en.rail.ghost or nil}; return r end
          tried[#tried+1]=string.format('continuing the rail end %s heading %s: %s',fmt(en.x,en.y),NAMES[en.d],why)
        end
      end
      for _,c in ipairs(cardinals(pt,toward,fixed and (role=='up' and fixed or opposite(fixed)))) do
        local par=PARITY[c.d]
        local g={x=snap(pt.x,par[1]),y=snap(pt.y,par[2])}
        if dist(g.x,g.y,pt.x,pt.y)<=GOAL_R then
          local r,why=ramp_fits(g,c.d)
          if r then return r end
          tried[#tried+1]=string.format('rising %s from %s: %s',NAMES[c.d],fmt(g.x,g.y),why)
        end
      end
      error(string.format('no rail route: no rail ramp fits at %s %s (a ramp is 16 tiles long, north, east, south or west, its ground end at the point): %s',
        role=='up' and 'from' or 'to',fmt(pt.x,pt.y),table.concat(tried,'; ')),0)
    end
    local near=M.ends_near(p,points[1],END_R,elevated)
    if elevated and #near==0 then
      local r=place_ramp(points[1],points[2],from_d,'up')
      r.role='up'; ramps[1]=r
      starts[1]={x=r.top.x,y=r.top.y,d=r.direction,g=0}
    elseif #near>0 then
      local want_free=near[1].free
      for _,en in ipairs(near) do
        if en.free==want_free and (not from_d or en.d==from_d) then starts[#starts+1]={x=en.x,y=en.y,d=en.d,g=0,joined=en} end
      end
      assert(#starts>0,string.format('no end of your rails near %s heads %s; the ends there head %s',fmt(points[1].x,points[1].y),NAMES[from_d or 0],
        (function() local t={} for _,en in ipairs(near) do t[#t+1]=NAMES[en.d] end return table.concat(t,', ') end)()))
      extends={position={x=near[1].x,y=near[1].y},heading=NAMES[near[1].d],rail=near[1].rail.name,ghost=near[1].rail.ghost or nil,
        mode=want_free and 'continues the line' or 'branches off where rails meet'}
    else
      for d=0,15 do
        if not from_d or d==from_d then
          local par=PARITY[d]
          starts[#starts+1]={x=snap(points[1].x,par[1]),y=snap(points[1].y,par[2]),d=d,g=0}
        end
      end
    end
    -- The end: an end of our rails near to (joined head on), else any end
    -- within GOAL_R tiles.
    local goal_ends=M.ends_near(p,points[#points],END_R,elevated)
    local joins
    if elevated and #goal_ends==0 then
      local r=place_ramp(points[#points],points[#points-1],to_d,'down')
      r.role='down'; ramps[#ramps+1]=r
      goal_ends={r.top}
    elseif #goal_ends>0 then
      local want_free=goal_ends[1].free
      local list={}
      for _,en in ipairs(goal_ends) do if en.free==want_free then list[#list+1]=en end end
      goal_ends=list
      joins={position={x=list[1].x,y=list[1].y},rail=list[1].rail.name,ghost=list[1].rail.ghost or nil,
        mode=want_free and 'joins the end of a line' or 'joins where rails meet'}
    end

    local expansions,total_pieces=0,0
    local steps={}
    local closest
    -- One leg: A* over rail ends (position and heading).
    local function leg(starts_, target, exact)
      local box={left=math.min(starts_[1].x,target.x)-MARGIN,right=math.max(starts_[1].x,target.x)+MARGIN,
        top=math.min(starts_[1].y,target.y)-MARGIN,bottom=math.max(starts_[1].y,target.y)+MARGIN}
      local open,best={},{}
      local goal_keys
      if exact then
        goal_keys={}
        for _,en in ipairs(exact) do goal_keys[skey(en.x,en.y,opposite(en.d))]=en end
      end
      local CURVE_COST,CLEAR_COST,WEIGHT,TURN_R=M.TUNE.curve,M.TUNE.clear,M.TUNE.weight,M.TUNE.turn_r
      -- Distance to the target, plus what turning toward it costs at the
      -- planner's curve radius (about 13 tiles: four curve pieces per 90
      -- degrees) and the curve pieces that turn takes.
      local tx,ty=target.x,target.y
      local function h(x,y,d)
        local dx,dy=tx-x,ty-y
        local dd=(dx*dx+dy*dy)^0.5
        if dd<=GOAL_R and not exact then return 0 end
        if dd<0.001 then return 0 end
        local c=(dx*HX[d]+dy*HY[d])/dd
        if c>1 then c=1 elseif c<-1 then c=-1 end
        local turn=math.acos(c)
        return dd+TURN_R*(turn-math.sin(turn))+CURVE_COST*math.floor(turn/(math.pi/8)+0.001)
      end
      for _,st in ipairs(starts_) do
        local n={x=st.x,y=st.y,d=st.d,g=st.g or 0,f=WEIGHT*h(st.x,st.y,st.d),start=st}
        best[skey(n.x,n.y,n.d)]=n.g
        heap.push(open,n)
      end
      local nearest
      while #open>0 do
        local n=heap.pop(open)
        -- A route ending in a curve, put back at a higher cost: one ending
        -- straight a little dearer wins.
        if n.final then return n end
        local k=skey(n.x,n.y,n.d)
        if best[k]~=nil and best[k]>=0 and n.g<=best[k] then
          best[k]=-1
          local hn=dist(n.x,n.y,target.x,target.y)
          if not nearest or hn<nearest.h then nearest={x=n.x,y=n.y,d=n.d,h=hn} end
          if goal_keys then
            if goal_keys[k] then return n end
          elseif hn<=GOAL_R then
            if not (n.move and CURVE[n.move[1]]) then return n end
            heap.push(open,{x=n.x,y=n.y,d=n.d,g=n.g,f=n.g+2*CURVE_COST,parent=n.parent,move=n.move,clear=n.clear,final=true})
          end
          expansions=expansions+1
          if expansions>MAX_EXPANSIONS or checks>MAX_CHECKS then closest=nearest; return nil,'budget' end
          for _,m in ipairs(EXT[n.d]) do
            local gx,gy=n.x+m[5],n.y+m[6]
            if gx>=box.left and gx<=box.right and gy>=box.top and gy<=box.bottom then
              local f=fit(m[1],m[2],n.x+m[3],n.y+m[4])
              if f then
                local g=n.g+m.len+(CURVE[m[1]] and CURVE_COST or 0)+(f==1 and CLEAR_COST or 0)
                local nk=skey(gx,gy,m[7])
                local b=best[nk]
                if b==nil or (b>=0 and g<b) then
                  best[nk]=g
                  heap.push(open,{x=gx,y=gy,d=m[7],g=g,f=g+WEIGHT*h(gx,gy,m[7]),parent=n,move=m,clear=f==1})
                end
              end
            end
          end
        end
      end
      closest=nearest
      return nil,'none'
    end

    local function fail(why,target)
      local c=closest
      local text={why}
      if c then
        text[#text+1]=string.format('the nearest end reached is %s heading %s, %.1f tiles from %s',fmt(c.x,c.y),NAMES[c.d],c.h,fmt(target.x,target.y))
        -- What blocks the pieces tried around there: each kind once, with
        -- where it stands and how many more.
        local kinds,order,seen_at={},{},{}
        table.sort(blocked_list,function(u,v) return dist(u.x,u.y,c.x,c.y)<dist(v.x,v.y,c.x,c.y) end)
        local seen=0
        for _,b in ipairs(blocked_list) do
          if dist(b.x,b.y,c.x,c.y)>12 or seen>=8 then break end
          seen=seen+1
          local list
          if not is_charted(b.x,b.y) then list={'an uncharted chunk'}
          else
            local ok,l=pcall(M.blockers,p,b.name,b.x,b.y,b.dir)
            list=ok and l or {}
          end
          for _,t in ipairs(list) do
            if not seen_at[t] then
              seen_at[t]=true
              local kind,at=t:match('^(.-) (%(.*%))$')
              kind=kind or t
              if not kinds[kind] then kinds[kind]={at=at,n=0}; order[#order+1]=kind end
              kinds[kind].n=kinds[kind].n+1
            end
          end
        end
        local names={}
        for i=1,math.min(6,#order) do
          local k=kinds[order[i]]
          names[i]=order[i]..(k.at and ' '..k.at or '')..(k.n>1 and ' and '..(k.n-1)..' more' or '')
        end
        if #names>0 then text[#text+1]='blocked there by '..table.concat(names,', ') end
      end
      text[#text+1]=string.format('the search keeps within %d tiles of each leg\'s ends; %d placement checks',MARGIN,checks)
      error('no rail route: '..table.concat(text,'; '),0)
    end

    -- A free point no piece can start or end at fails at once (water, a
    -- building, uncharted), before any search.
    local function open_at(pt)
      for d=0,15 do
        local par=PARITY[d]
        local ex,ey=snap(pt.x,par[1]),snap(pt.y,par[2])
        if dist(ex,ey,pt.x,pt.y)<=GOAL_R then
          for _,m in ipairs(EXT[d]) do
            if fit(m[1],m[2],ex+m[3],ey+m[4]) then return true end
          end
        end
      end
      return false
    end
    for i,pt in ipairs(points) do
      local joined=(i==1 and (extends or ramps[1])) or (i==#points and (joins or (elevated and ramps[#ramps] and ramps[#ramps].role=='down')))
      if not joined and not open_at(pt) then
        local what=i==1 and 'from' or i==#points and 'to' or 'via point '..(i-1)
        local why
        if not is_charted(pt.x,pt.y) then why='it is not charted'
        else
          local ok,list=pcall(M.blockers,p,'straight-rail',snap(pt.x,1),snap(pt.y,1),0)
          why=ok and #list>0 and 'blocked by '..table.concat(list,', ') or 'no rail piece fits there'
        end
        error(string.format('no rail route: %s %s: %s',what,fmt(pt.x,pt.y),why),0)
      end
    end
    local current=starts
    for i=2,#points do
      local target=points[i]
      local last=i==#points
      if last and elevated and goal_ends[1] then target={x=goal_ends[1].x,y=goal_ends[1].y} end
      local node,why=leg(current,target,last and #goal_ends>0 and goal_ends or nil)
      if not node then
        fail(why=='budget' and string.format('the search budget (%d placement checks) ran out on the leg to %s',MAX_CHECKS,fmt(target.x,target.y))
          or string.format('no way through on the leg to %s',fmt(target.x,target.y)),target)
      end
      local legsteps={}
      local n=node
      while n.parent do table.insert(legsteps,1,n); n=n.parent end
      if i==2 then steps.first=n end
      for _,st in ipairs(legsteps) do st.leg=i-1; steps[#steps+1]=st end
      total_pieces=total_pieces+#legsteps
      assert(total_pieces<=MAX_PIECES,string.format('the route needs more than %d pieces; split it into shorter routes',MAX_PIECES))
      current={{x=node.x,y=node.y,d=node.d,g=0}}
    end

    assert(#steps>0,string.format('from %s is already within %d tiles of to: no piece to lay',fmt(points[1].x,points[1].y),GOAL_R))
    -- Describe it, and the entities to place in order.
    local entities,pieces,length,clear={},{},0,0
    local runs,last={},nil
    for _,st in ipairs(steps) do
      local m=st.move
      local px,py=st.parent.x+m[3],st.parent.y+m[4]
      local name=elevated and ELEV[m[1]] or m[1]
      entities[#entities+1]={name=name,position={x=px,y=py},direction=NAMES[m[2]]}
      pieces[name]=(pieces[name] or 0)+1
      length=length+m.len
      if st.clear then clear=clear+1 end
      if last and last.d==st.d then last.len=last.len+m.len
      else last={d=st.d,len=m.len}; runs[#runs+1]=last end
    end
    local words={}
    for _,r in ipairs(runs) do words[#words+1]=LETTERS[r.d]..math.floor(r.len+0.5) end
    local rails_n=0
    for name,n in pairs(pieces) do
      local proto=prototypes.entity[name]
      local per=1
      for _,it in ipairs(proto and proto.items_to_place_this or {}) do if it.name=='rail' then per=it.count or 1 end end
      rails_n=rails_n+n*per
    end
    local items={rail=rails_n}
    local entities_rails=entities
    local lifted=elevated and M.lift(p,{steps=steps,ramps=ramps,is_charted=is_charted,count=function() checks=checks+1 end}) or nil
    if lifted then
      local front={}
      for _,e in ipairs(lifted.entities) do front[#front+1]=e end
      for _,e in ipairs(entities) do front[#front+1]=e end
      entities=front
      local new_ramps=0
      for _,r in ipairs(ramps) do if not r.existing then new_ramps=new_ramps+1 end end
      if new_ramps>0 then items['rail-ramp']=new_ramps end
      if lifted.supports.count>0 then items['rail-support']=lifted.supports.count end
      lifted.rails=entities_rails
    end
    -- Signals at the joints between pieces, every so many tiles of track.
    local signals={}
    if every then
      local run=0
      for i,st in ipairs(steps) do
        run=run+st.move.len
        if run>=every-0.01 and i<#steps then
          local sg=SIGNAL[st.d]
          signals[#signals+1]={name='rail-signal',position={x=st.x+sg[1],y=st.y+sg[2]},direction=NAMES[sg[3]]}
          run=0
        end
      end
      if #signals>0 then items['rail-signal']=#signals end
    end
    for _,sg in ipairs(signals) do entities[#entities+1]=sg end
    local first,lastst=steps.first,steps[#steps]
    local out={route=table.concat(words,' '),pieces=pieces,length=math.floor(length+0.5),items=items,
      start={position={x=first.x,y=first.y},heading=NAMES[first.d]},
      ['end']={position={x=lastst.x,y=lastst.y},heading=NAMES[lastst.d]},
      extends=extends,joins=joins,legs=#points-1,
      signals=every and {count=#signals,every=every,side='on the right of trains heading from start to end: trains heading the other way have no path through them, and the game refuses stops serving them on this line'} or nil,
      over_trees_or_rocks=clear>0 and clear or nil,
      cost={placement_checks=checks,expansions=expansions}}
    if lifted then
      out.level='elevated'; out.ramps=lifted.ramps; out.supports=lifted.supports; out.research=lifted.research
      out.unsupported=lifted.unsupported; out.unsupported_note=lifted.unsupported_note
      local cap=M.per_call(checks)
      lifted.cap=cap
      out.per_call={pieces=cap,calls=M.calls(lifted,cap)}
    end
    return {entities=entities,out=out,steps=steps,lifted=lifted,points=points}
  end

  -- An elevated route's ramps and supports (level elevated). t.steps: the route's pieces as planned (each with its
  -- joint after it, heading, length); t.ramps: the ramp up at the start and the ramp down at the end, either may be
  -- missing (joined to elevated rail of ours). Supports go on joints, each as far on as keeps every piece within reach of
  -- one support (or a ramp's elevated end); a span with no joint the game takes a support on is named with why.
  local function researched(force,name)
    local ok,v=pcall(function() return force.technologies[name].researched end)
    return ok and v==true
  end
  local SUPPORT_HALF=1.39
  function M.lift(p,t)
    local s,force=p.surface,p.force
    local steps,ramps=t.steps,t.ramps
    local deep_ok=researched(force,'rail-support-foundations')
    local joints={{x=steps.first.x,y=steps.first.y,d=steps.first.d,s=0}}
    for _,st in ipairs(steps) do joints[#joints+1]={x=st.x,y=st.y,d=st.d,s=joints[#joints].s+st.move.len} end
    local n=#joints
    local args={name='rail-support',position={x=0,y=0},direction=0,force=force,build_check_type=defines.build_check_type.manual_ghost}
    local spot,why_at={},{}
    local function under_ramp(j)
      for _,r in ipairs(ramps) do
        local hx,hy=1.6,7.6
        if r.direction%8==4 then hx,hy=7.6,1.6 end
        if math.abs(j.x-r.position.x)<hx+SUPPORT_HALF and math.abs(j.y-r.position.y)<hy+SUPPORT_HALF then return r end
      end
    end
    local function box(j) return {left_top={x=j.x-SUPPORT_HALF,y=j.y-SUPPORT_HALF},right_bottom={x=j.x+SUPPORT_HALF,y=j.y+SUPPORT_HALF}} end
    -- Why the game refuses a support on joint j: deep oil ocean without the research, what stands there, the tiles.
    local function why(j)
      if not t.is_charted(j.x,j.y) then return 'not charted' end
      local r=under_ramp(j)
      if r then return 'the planned rail ramp at '..fmt(r.position.x,r.position.y) end
      local area=box(j)
      if not deep_ok and s.count_tiles_filtered{area=area,name='oil-ocean-deep',limit=1}>0 then
        return 'oil-ocean-deep (the game takes rail supports there once Rail support foundations is researched)'
      end
      local mask=prototypes.entity['rail-support'] and prototypes.entity['rail-support'].collision_mask
      local layers=mask and mask.layers or {}
      for _,e in pairs(s.find_entities_filtered{area=area,limit=8}) do
        local ty=e.valid and e.type
        if ty and ty~='resource' and ty~='corpse' and ty~='item-entity' and ty~='entity-ghost' and ty~='tile-ghost' and ty~='character' then
          local ok,om=pcall(function() return e.prototype.collision_mask.layers end)
          local hit=not ok
          for k in pairs(ok and om or {}) do if layers[k] then hit=true end end
          if hit then return e.name..' '..fmt(e.position.x,e.position.y) end
        end
      end
      for _,tl in pairs(s.find_tiles_filtered{area=area,limit=16}) do
        local ok,tlay=pcall(function() return tl.prototype.collision_mask.layers end)
        for k in pairs(ok and tlay or {}) do if layers[k] then return tl.name end end
      end
      return 'the game refuses a rail support there'
    end
    local function ok_at(k)
      local v=spot[k]
      if v~=nil then return v end
      local j=joints[k]
      if not t.is_charted(j.x,j.y) or under_ramp(j) then v=false
      else
        t.count()
        args.position.x=j.x; args.position.y=j.y; args.direction=j.d%8
        v=s.can_place_entity(args)
        if not v then
          -- a support of ours on this joint already (a call before placed it)
          local at={left_top={x=j.x-0.1,y=j.y-0.1},right_bottom={x=j.x+0.1,y=j.y+0.1}}
          v=#s.find_entities_filtered{area=at,name='rail-support',force=force,limit=1}>0 or #s.find_entities_filtered{area=at,ghost_name='rail-support',force=force,limit=1}>0
        end
      end
      spot[k]=v
      return v
    end
    local R,RR=M.SUPPORT_REACH-0.5,M.RAMP_REACH-0.5
    -- The last joint a support on joint k carries rail to.
    local function reach(k)
      local c,lim=k,joints[k].s+R
      while c<n and joints[c+1].s<=lim do c=c+1 end
      return c
    end
    -- Pieces up to joint covered are carried; from joint e on, the ramp down carries them.
    local covered,e=1,n
    local up=ramps[1] and ramps[1].role=='up'
    local down=ramps[#ramps] and ramps[#ramps].role=='down'
    if up then while covered<n and joints[covered+1].s<=RR do covered=covered+1 end end
    -- (W2) continuing from where a call before stopped: its support on the start joint, or on the joint a piece back,
    -- carries the line on (as far as its reach less the way to the start)
    local start_support
    if not up then
      local j=joints[1]
      local at={left_top={x=j.x-3,y=j.y-3},right_bottom={x=j.x+3,y=j.y+3}}
      local near
      for _,list in ipairs({s.find_entities_filtered{area=at,name='rail-support',force=force,limit=4},s.find_entities_filtered{area=at,ghost_name='rail-support',force=force,limit=4}}) do
        for _,e in ipairs(list) do
          local d=dist(e.position.x,e.position.y,j.x,j.y)
          if e.valid and (not near or d<near) then near=d end
        end
      end
      if near then
        start_support=true
        while covered<n and joints[covered+1].s<=R-near do covered=covered+1 end
      end
    end
    if down then while e>1 and joints[n].s-joints[e-1].s<=RR do e=e-1 end end
    local chosen,gaps,widest={},{},0
    while covered<e do
      local base,best=joints[covered].s,nil
      for k=covered,n do
        if joints[k].s-R>base+0.001 then break end
        if ok_at(k) and reach(k)>covered then best=k end
      end
      if best then
        if #chosen>0 then widest=math.max(widest,joints[best].s-joints[chosen[#chosen]].s) end
        chosen[#chosen+1]=best; covered=reach(best)
      else
        local nxt
        for k=covered+1,n do if ok_at(k) then nxt=k; break end end
        local stop=e
        if nxt and nxt<e then
          stop=nxt
          while stop>covered+1 and joints[nxt].s-joints[stop-1].s<=R do stop=stop-1 end
        end
        local kinds,order={},{}
        for k=covered,stop do
          if not ok_at(k) then
            local w=why(joints[k])
            if not kinds[w] then kinds[w]={n=0,at=fmt(joints[k].x,joints[k].y)}; order[#order+1]=w end
            kinds[w].n=kinds[w].n+1
          end
        end
        local text={}
        for i=1,math.min(3,#order) do local w=kinds[order[i]]; text[i]=string.format('%d joint%s: %s (first at %s)',w.n,w.n==1 and '' or 's',order[i],w.at) end
        gaps[#gaps+1]={from={x=joints[covered].x,y=joints[covered].y},to={x=joints[stop].x,y=joints[stop].y},tiles=math.floor(joints[stop].s-joints[covered].s+0.5),
          pieces=stop-covered,why='no rail support fits on '..table.concat(text,'; ')}
        if nxt and nxt<e then chosen[#chosen+1]=nxt; covered=math.max(reach(nxt),stop) else covered=e end
      end
    end
    local entities,rows={},{}
    local up_entity,down_entity,support_list
    for _,r in ipairs(ramps) do
      if not r.existing then
        entities[#entities+1]={name='rail-ramp',position=r.position,direction=NAMES[r.direction]}
        if r.role=='up' then up_entity=entities[#entities] else down_entity=entities[#entities] end
      end
      rows[#rows+1]={role=r.role=='up' and 'up at from' or 'down at to',position=r.position,rises_toward=NAMES[r.direction],
        ground_end={x=r.ground.x,y=r.ground.y},elevated_end={x=r.top.x,y=r.top.y},joins=r.joins,existing=r.existing}
    end
    support_list={}
    for _,k in ipairs(chosen) do
      local j=joints[k]
      entities[#entities+1]={name='rail-support',position={x=j.x,y=j.y},direction=NAMES[j.d%8]}
      support_list[#support_list+1]={e=entities[#entities],k=k}
    end
    local out={entities=entities,ramps=#rows>0 and rows or nil,joints=joints,steps=steps,
      up_entity=up_entity,down_entity=down_entity,support_list=support_list,

      supports={count=#chosen,reach=M.SUPPORT_REACH,ramp_reach=M.RAMP_REACH,widest=widest>0 and math.floor(widest+0.5) or nil,
        at_start=start_support and 'a rail support of yours on the start joint carries the line on' or nil,
        on='rail joints, every piece within 11 tiles of one support or 9 of a ramp\'s elevated end'},
      research={elevated_rail=researched(force,'elevated-rail') and 'researched' or 'not researched',
        rail_support_foundations=deep_ok and 'researched' or 'not researched'}}
    if #gaps>0 then
      out.unsupported=gaps
      out.unsupported_note='the game builds an elevated rail only where it joins elevated rail and lies within 11 tiles of one rail support (9 of a ramp\'s elevated end): the rails of these spans stay ghosts'
    end
    return out
  end

  -- (d20 batch61 W2, operator 23:25) an elevated call places at most ELEVATED_PER_CALL pieces (ramps, supports, rails),
  -- which keeps it near 10 ms on the private copy, and stops on one of its own supports: the next call from that end
  -- starts carried. The cut after joint k0 (support i0 there; the first call: k0=1, i0=0, with the ramp up): the
  -- farthest support within the count, else the first one past it; none at all: the count of rails.
  M.ELEVATED_PER_CALL=24
  -- Measured on the copy (warm): a call costs about 3.4 ms, 0.007 ms a placement check of its search and 0.18 ms a
  -- piece placed (86 tiles straight, 155 checks: 22 pieces in 7.5-9.1 ms; 101 tiles with a 90 degree turn, 778
  -- checks: 21 pieces in 12-13 ms). Pieces for one call near 10 ms: 24 at most, 6 at least.
  function M.per_call(checks) return math.max(6,math.min(M.ELEVATED_PER_CALL,math.floor(34-(checks or 0)/26))) end
  local function next_cut(L,cap,k0,i0,first)
    local list,nj=L.support_list,#L.joints
    local up=(first and L.up_entity) and 1 or 0
    if up+(#list-i0)+(nj-k0)+(L.down_entity and 1 or 0)<=cap then return nil end
    local best
    for i=i0+1,#list do
      local c=list[i]
      if c.k>k0 and c.k<nj then
        local n=up+(i-i0)+(c.k-k0)
        if n<=cap or not best then best={k=c.k,i=i} end
        if n>cap then break end
      end
    end
    if not best then
      local k=math.min(nj-1,k0+math.max(1,cap-up))
      best={k=k,i=i0}
      for i=i0+1,#list do if list[i].k<=k then best.i=i end end
    end
    return best
  end
  function M.calls(L,cap)
    local n,k0,i0=1,1,0
    local c=next_cut(L,cap,k0,i0,true)
    while c and n<200 do n=n+1; k0,i0=c.k,c.i; c=next_cut(L,cap,k0,i0,false) end
    return n
  end
  -- The first call's part of an elevated plan, or nil when the whole route fits: its entities, and the reply's capped
  -- {placed, of, continue_from, pieces_left, next_call}. a: the call's arguments (to, via, to_direction carried on).
  function M.cut(plan,a)
    local L=plan.lifted
    if not L then return nil end
    local cap=L.cap or M.ELEVATED_PER_CALL
    local c=next_cut(L,cap,1,0,true)
    if not c then return nil end
    local list={}
    if L.up_entity then list[1]=L.up_entity end
    for i=1,c.i do list[#list+1]=L.support_list[i].e end
    local rails=0
    for i=1,c.k-1 do list[#list+1]=L.rails[i]; rails=rails+1 end
    local j=L.joints[c.k]
    -- the via points not passed yet: those after the leg the next piece is on
    local via={}
    local leg=L.steps[c.k] and L.steps[c.k].leg or 1
    for i=leg+1,#plan.points-1 do via[#via+1]=plan.points[i] end
    local items={}
    for _,e in ipairs(list) do
      local proto=prototypes.entity[e.name]
      for _,it in ipairs(proto and proto.items_to_place_this or {}) do items[it.name]=(items[it.name] or 0)+(it.count or 1) end
    end
    local next_call={from={x=j.x,y=j.y},to=a.to,via=#via>0 and via or nil,level='elevated',to_direction=a.to_direction}
    return list,{placed_pieces=#list,of=#plan.entities,continue_from={position={x=j.x,y=j.y},heading=NAMES[j.d]},
      rails_left=#L.rails-rails,pieces_left=#plan.entities-#list,next_call=next_call,items=items,
      note=string.format('this call places %d of the route\'s %d pieces (about %d a call: fewer when the search costs more) and stops on its own elevated end at %s heading %s, on a rail support; rail_route from there to the same to (next_call) continues the line',
        #list,#plan.entities,cap,fmt(j.x,j.y),NAMES[j.d])}
  end

  -- train_stop: beside the nearest straight north-south or east-west rail
  -- (or rail ghost) of ours, on the right of the trains it serves.
  function M.stop_spot(p,a)
    local s,force=p.surface,p.force
    local pos=api.position(a.position)
    local want=a.direction~=nil and api.directions[a.direction]
    assert(a.direction==nil or (want and want%4==0),'direction (the way trains stopping there travel) is north, east, south or west')
    local area={left_top={x=pos.x-6,y=pos.y-6},right_bottom={x=pos.x+6,y=pos.y+6}}
    local rails={}
    for _,e in pairs(s.find_entities_filtered{area=area,name='straight-rail',force=force}) do rails[#rails+1]={e=e,ghost=false} end
    for _,e in pairs(s.find_entities_filtered{area=area,ghost_name='straight-rail',force=force}) do rails[#rails+1]={e=e,ghost=true} end
    local cands={}
    local nearest_other
    for _,r in ipairs(rails) do
      local d=r.e.direction%8
      local rp=r.e.position
      if d==0 or d==4 then
        for _,h in ipairs(d==0 and {0,8} or {4,12}) do
          if not want or want==h then
            local o=STOP[h]
            local spot={x=rp.x+o[1],y=rp.y+o[2]}
            cands[#cands+1]={spot=spot,heading=h,rail=r,dist=dist(spot.x,spot.y,pos.x,pos.y)}
          end
        end
      elseif not nearest_other or dist(rp.x,rp.y,pos.x,pos.y)<nearest_other.dist then
        nearest_other={rail=r,dist=dist(rp.x,rp.y,pos.x,pos.y)}
      end
    end
    if #cands==0 then
      if nearest_other then
        local e=nearest_other.rail.e
        error(string.format('train stops go beside straight north-south or east-west rails; the rail near %s is a diagonal straight-rail at %s',
          fmt(pos.x,pos.y),fmt(e.position.x,e.position.y)),0)
      end
      error(string.format('no straight north-south or east-west rail or rail ghost of yours within 6 tiles of %s%s',fmt(pos.x,pos.y),
        want and ' for trains heading '..NAMES[want] or ''),0)
    end
    table.sort(cands,function(u,v) return u.dist<v.dist end)
    return cands
  end
  -- Why the game refuses a stop with nothing in the way: the rail's segment
  -- has rail signals for trains heading the other way only (a line signalled
  -- on one side runs one way). A built rail asks the engine for the signals
  -- at its segment's ends; a rail ghost looks along its straight line
  -- (64 tiles) for signals beside it.
  function M.line_signals(p,c)
    local want,other=c.heading,opposite(c.heading)
    local mine,theirs={},{}
    local r=c.rail.e
    if not c.rail.ghost and r.valid and r.get_rail_segment_signal then
      local rd={}
      for _,d in pairs(defines.rail_direction) do
        local ok,en=pcall(r.get_rail_end,d)
        if ok and en then rd[en.location.direction]=d end
      end
      if rd[want]==nil or rd[other]==nil then return nil end
      local function add(list,d,in_else_out)
        local ok,sg=pcall(r.get_rail_segment_signal,d,in_else_out)
        if ok and sg then list[#list+1]=sg end
      end
      add(mine,rd[want],false); add(mine,rd[other],true)
      add(theirs,rd[other],false); add(theirs,rd[want],true)
    else
      local rp=r.position
      local ns=want==0 or want==8
      local area=ns and {left_top={x=rp.x-2,y=rp.y-64},right_bottom={x=rp.x+2,y=rp.y+64}}
        or {left_top={x=rp.x-64,y=rp.y-2},right_bottom={x=rp.x+64,y=rp.y+2}}
      local function add(e)
        local off=ns and e.position.x-rp.x or e.position.y-rp.y
        -- North-south: east of the rail serves trains heading north;
        -- east-west: south of it serves trains heading east.
        local h=ns and (off>0 and 0 or 8) or (off>0 and 4 or 12)
        table.insert(h==want and mine or theirs,e)
      end
      for _,e in pairs(p.surface.find_entities_filtered{area=area,type={'rail-signal','rail-chain-signal'},force=p.force}) do add(e) end
      for _,e in pairs(p.surface.find_entities_filtered{area=area,ghost_type={'rail-signal','rail-chain-signal'},force=p.force}) do add(e) end
    end
    if #mine>0 or #theirs==0 then return nil end
    local list={}
    for i,e in ipairs(theirs) do if i<=3 then list[#list+1]=fmt(e.position.x,e.position.y) end end
    return string.format('the rail signals of this line (%s%s) serve only trains heading %s, so it runs one way and the game refuses a stop for trains heading %s',
      table.concat(list,' '),#theirs>3 and ' ...' or '',NAMES[other],NAMES[want])
  end

  M.schema={
    rail_route={from='{x,y}: where the line starts: free ground, or near an end of your rail or rail ghost (within 2.5 tiles: a free end continues that line, a joint between rails branches off it)',
      to='{x,y}: where it ends (within 2 tiles), or near an end of your rail or rail ghost (joined head on)',
      from_direction='optional heading of the first piece (16 compass names: north, northnortheast, northeast, ...); level elevated: the way the ramp at from rises (north, east, south, west)',
      level='optional: ground (default) or elevated: a rail ramp up at from (its ground end there, or continuing a free end of your ground rail there), elevated rails, a ramp down at to, rail supports on joints between; from or to near an end of your elevated rail joins it with no ramp',
      elevated='optional true: the same as level elevated',
      to_direction='optional, level elevated: the way trains run down the ramp at to (north, east, south, west)',
      via='optional 1..16 {x,y} points passed in order (each leg <=500 tiles, the route <=1024 pieces)',
      signals='optional spacing in tiles (4..1000, or text such as "every 30 tiles"): rail signal ghosts at piece joints on the right of trains heading from -> to',
      ghosts='true: place ghosts only; default: ghosts, then the pieces in your build reach are built from your inventory',
      dry_run='plan only, place nothing: the plan with the dry run check of every piece (place_ghosts dry_run)',details='list every piece',
      returns='route (headings with tiles: N24 NNE9 NE34), pieces by kind, length (tiles), items (rail counts: half-diagonal 2, curves 3 each; rail-ramp, rail-support), start/end {position, heading}, extends/joins (an existing rail end), signals, over_trees_or_rocks, placed, built, failed, missing (items short), cost; level elevated: ramps, supports {count, widest}, unsupported (spans with no joint the game takes a support on, and why), research {elevated_rail, rail_support_foundations}; no route: an error with the nearest end reached and what blocks there',
      note='ground rails with the 2.0 rail planner\'s pieces (straight, half-diagonal, curved-rail-a, curved-rail-b; 16 headings); trees and rocks under a piece get marked for removal; water, cliffs and buildings are routed around. level elevated: elevated rails pass over ground, water and buildings; the game builds one only within 11 tiles of a rail support it joins (9 of a ramp\'s elevated end); supports stand on land, water and shallow oil ocean, on deep oil ocean once Rail support foundations is researched'},
    train_stop={position='{x,y} near a straight north-south or east-west rail or rail ghost of yours (within 6 tiles)',
      name='station name (what schedules name)',station='same as name',direction='optional: the way trains stopping there travel (north, east, south, west); default: the side of the rail position is on',
      limit='optional train limit 0..1000',ghosts='true: place a ghost only; default: built from your inventory when in reach, else a ghost',
      returns='stop {name, position, direction, serves (trains heading ...), side (of the rail), rail {position, ghost}, built or ghost, limit}'},
  }
  return M
end
