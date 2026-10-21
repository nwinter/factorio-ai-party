-- Elevated rails and rail supports the game keeps (d20 batch69 AE1, Sol #1642: elevated-straight-rail 18232890 at
-- (277,191) on Fulgora, "entity is not mineable" from mine, and deconstruct over (276,190)-(280,192) marked the rail at
-- 279 only; AE2, Sol 11:29: mined 281 and 279 as cp1 said, and 277 stayed). Read on 2.0.77, Sol's layout rebuilt on a
-- private copy: every elevated rail must be held up by a rail support (support_range 11) or a rail ramp's elevated end
-- (9) within reach along the track: the path from the support's joint to the rail's near end plus the rail's own
-- length (get_rail_end) at most the reach. The game keeps a rail (LuaEntity.minable false, minable_flag true,
-- LuaEntity.mine refuses) while another rail is held up only through it, and a support while a rail is held up only by
-- it. On Sol's line the rails 269 to 275 are held up by the support at (278,191) only through 277: after 281 and 279,
-- 277 went once 269, 271, 273 and 275 had gone, outermost first. A deconstruction planner marks nothing over such a
-- rail, and over a support it marks the support and every rail it holds (robots took a run of 10 and its support,
-- outermost first, in 57 s).
return function(api)
local M={}
M.RAIL={['elevated-straight-rail']=true,['elevated-half-diagonal-rail']=true,['elevated-curved-rail-a']=true,['elevated-curved-rail-b']=true}
M.SUPPORT={['rail-support']=true}
local RAIL_TYPES={'elevated-straight-rail','elevated-half-diagonal-rail','elevated-curved-rail-a','elevated-curved-rail-b'}
local RADIUS=26   -- rails read round the one asked about: a rail held through it lies within one reach of it, its other holder within two
local LIST=6

local function at(e) return string.format('(%g,%g)',e.position.x,e.position.y) end
local function dist(a,b) return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2) end
local function key(p) return string.format('%g,%g',p.x,p.y) end
local function reach(s)
  local ok,r=pcall(function() return s.prototype.support_range end)
  return ok and r or (s.type=='rail-ramp' and 9 or 11)
end

-- The track round position pos on surface: edges {rail, a, b (joint keys), len} for the elevated rails, joints ->
-- edges, and the holders {entity, joint, reach}: each rail support on a joint, each rail ramp at its elevated end.
function M.graph(surface,pos,radius)
  radius=radius or RADIUS
  local g={edges={},by_unit={},joints={},holders={}}
  local D=defines.rail_direction
  local elevated_ends={}
  for _,r in pairs(surface.find_entities_filtered{type=RAIL_TYPES,position=pos,radius=radius}) do
    local ok,a,b=pcall(function() return r.get_rail_end(D.front).location.position,r.get_rail_end(D.back).location.position end)
    if ok and a and b then
      local e={rail=r,a=key(a),b=key(b),len=dist(a,b)}
      g.edges[#g.edges+1]=e; g.by_unit[r.unit_number]=e
      for _,j in ipairs({e.a,e.b}) do g.joints[j]=g.joints[j] or {}; table.insert(g.joints[j],e); elevated_ends[j]=true end
    end
  end
  for _,s in pairs(surface.find_entities_filtered{type={'rail-support','rail-ramp'},position=pos,radius=radius+12}) do
    if s.type=='rail-support' then
      g.holders[#g.holders+1]={entity=s,joint=key(s.position),reach=reach(s)}
    else
      local ok,a,b=pcall(function() return s.get_rail_end(D.front).location.position,s.get_rail_end(D.back).location.position end)
      if ok and a and b then
        local j=elevated_ends[key(a)] and key(a) or elevated_ends[key(b)] and key(b) or nil
        if j then g.holders[#g.holders+1]={entity=s,joint=j,reach=reach(s)} end
      end
    end
  end
  return g
end

-- {unit_number=true} of the rails holder h holds up, with the rails in skip ({unit_number=true}) gone: those whose near
-- end is at most reach - their length along the track from its joint.
local function held_by(g,h,skip)
  skip=skip or {}
  local best={[h.joint]=0}
  local todo={h.joint}
  local held={}
  while #todo>0 do
    -- the nearest joint not done (the graphs are small)
    local bi,bj
    for i,j in ipairs(todo) do if not bi or best[j]<best[bj] then bi,bj=i,j end end
    table.remove(todo,bi)
    for _,e in ipairs(g.joints[bj] or {}) do
      local u=e.rail.valid and e.rail.unit_number
      if u and not skip[u] and best[bj]+e.len<=h.reach+1e-6 then
        held[u]=true
        local other=e.a==bj and e.b or e.a
        local d=best[bj]+e.len
        if best[other]==nil or d<best[other]-1e-9 then
          if best[other]==nil then todo[#todo+1]=other end
          best[other]=d
        end
      end
    end
  end
  return held
end

local function held_all(g,skip,skip_holder)
  local all={}
  for _,h in ipairs(g.holders) do
    if h.entity~=skip_holder and h.entity.valid then
      for u in pairs(held_by(g,h,skip)) do all[u]=true end
    end
  end
  return all
end

-- The rails held up only through rail e (or, for a support, only by it): those the game keeps it for. cascade: also
-- the rails held up only through those, and so on (what a planner marks with a support).
function M.dependents(e,g,cascade)
  g=g or M.graph(e.surface,e.position)
  local before=held_all(g)
  local gone={}
  if not M.SUPPORT[e.type] then gone[e.unit_number]=true end
  local out={}
  repeat
    local after=held_all(g,gone,M.SUPPORT[e.type] and e or nil)
    local added=false
    for u in pairs(before) do
      if not gone[u] and not after[u] then gone[u]=true; added=true; out[#out+1]=g.by_unit[u].rail end
    end
  until not cascade or not added
  table.sort(out,function(a,b) return dist(a.position,e.position)<dist(b.position,e.position) end)
  return out,g
end

-- The holders whose reach holds rail e now.
function M.holders(e,g)
  g=g or M.graph(e.surface,e.position)
  local out={}
  for _,h in ipairs(g.holders) do
    if h.entity.valid and held_by(g,h)[e.unit_number] then out[#out+1]=h.entity end
  end
  table.sort(out,function(a,b) return dist(a.position,e.position)<dist(b.position,e.position) end)
  return out
end

local function names(list)
  local parts={}
  for i=1,math.min(LIST,#list) do parts[#parts+1]=list[i].name..' '..at(list[i]) end
  return table.concat(parts,', ')..(#list>LIST and string.format(' (+%d more)',#list-LIST) or '')
end

-- Why the game will not let entity e be mined now (nil when it will).
function M.why(e)
  if not (e and e.valid) or e.minable then return nil end
  local okf,flag=pcall(function() return e.minable_flag end)
  if okf and flag==false then return 'its minable flag is off (set by a script); the game mines it only with the flag on' end
  if M.RAIL[e.type] or M.SUPPORT[e.type] then
    local deps,g=M.dependents(e)
    local hold=M.RAIL[e.type] and M.holders(e,g) or {}
    local free={}
    for _,r in ipairs(deps) do if r.minable then free[#free+1]=r end end
    local rule='each elevated rail must be held up by a rail support (reach 11) or a rail ramp\'s elevated end (reach 9) within reach along the track'
    local held_by_text=#hold>0 and ('; it is held up by '..names(hold)) or ''
    local via=M.SUPPORT[e.type] and 'by' or 'through'
    if #deps==0 then
      return 'the game reads it not minable now ('..rule..'; no rail within '..RADIUS..' tiles is held up only '..via..' it)'..held_by_text
    end
    return string.format('the game keeps %s while another rail is held up only %s it (%s)%s; held up only %s it: %d rail%s, %s; '
        ..'they go first, outermost first%s',
      M.SUPPORT[e.type] and 'a rail support' or 'an elevated rail',via,rule,held_by_text,via,#deps,#deps==1 and '' or 's',names(deps),
      #free>0 and ('; of those, these can go now: '..names(free)) or '')
  end
  return 'the game reads it not minable now'..(okf and flag and ' (its minable flag is on)' or '')
end

-- The elevated rails support s holds up (within its reach along the track): a planner marks them with it.
function M.carried(s)
  local g=M.graph(s.surface,s.position,reach(s)+4)
  for _,h in ipairs(g.holders) do
    if h.entity==s then
      local out={}
      for u in pairs(held_by(g,h)) do out[#out+1]=g.by_unit[u].rail end
      return out
    end
  end
  return {}
end

local function near_rails(s)
  return s.surface.find_entities_filtered{type=RAIL_TYPES,position=s.position,radius=reach(s)+6}
end
-- deconstruct: mark support s as a planner does, which marks the rails it holds too. Returns the entities newly
-- marked by name ({name=count}, the rails as the game marked them), nil, the number of rails and {unit_number=true}
-- of all it marked; or nil and the game's error.
function M.mark_support(p,s,player)
  local before={}
  for _,r in ipairs(near_rails(s)) do before[r.unit_number]=r.to_be_deconstructed() end
  local inv=game.create_inventory(1)
  local ok,err=pcall(function()
    inv.insert{name='deconstruction-planner'}
    local st=inv[1]
    st.entity_filters={s.name}
    local b=s.bounding_box
    local c={x=(b.left_top.x+b.right_bottom.x)/2,y=(b.left_top.y+b.right_bottom.y)/2}
    p.surface.deconstruct_area{area={left_top={x=c.x-0.25,y=c.y-0.25},right_bottom={x=c.x+0.25,y=c.y+0.25}},force=p.force,player=player,item=st}
  end)
  inv.destroy()
  if not ok then return nil,tostring(err) end
  if not s.to_be_deconstructed() then return nil,'the game did not mark it' end
  local by={[s.name]=1}
  local n,units=0,{[s.unit_number]=true}
  for _,r in ipairs(near_rails(s)) do
    if r.valid and r.to_be_deconstructed() and before[r.unit_number]==false then by[r.name]=(by[r.name] or 0)+1; n=n+1; units[r.unit_number]=true end
  end
  return by,nil,n,units
end

return M
end
