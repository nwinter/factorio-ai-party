-- Elevated rails and rail supports the game keeps (d20 batch69 AE1, Sol #1642: elevated-straight-rail 18232890 at
-- (277,191) on Fulgora, "entity is not mineable" from mine, and deconstruct over (276,190)-(280,192) marked the rail at
-- 279 only). Read on 2.0.77: a rail support carries the elevated rails within its reach (support_range, 11 tiles);
-- the game lets a hand take only the rails at the two ends of that run (LuaEntity.minable reads false for the rest,
-- minable_flag stays true, and LuaEntity.mine refuses them); each end taken frees the next one in; the support itself
-- goes once no rail rests on it. A deconstruction planner marks nothing over a rail in the middle of a run, and over
-- the support it marks the support and every rail it carries (robots took a run of 10 and its support end first in
-- 57 s). Rails no support reaches go anywhere.
return function(api)
local M={}
M.RAIL={['elevated-straight-rail']=true,['elevated-half-diagonal-rail']=true,['elevated-curved-rail-a']=true,['elevated-curved-rail-b']=true}
M.SUPPORT={['rail-support']=true}
local MAX_WALK=64

local function at(e) return string.format('(%g,%g)',e.position.x,e.position.y) end
local function dist(a,b) return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2) end
local function range(s)
  local ok,r=pcall(function() return s.prototype.support_range end)
  return ok and r or 11
end

-- The rail supports whose reach takes in rail e (its centre within support_range less one tile), nearest first.
function M.supports(e)
  local out={}
  for _,s in pairs(e.surface.find_entities_filtered{type='rail-support',position=e.position,radius=16}) do
    if s.valid and dist(s.position,e.position)+1<=range(s) then out[#out+1]=s end
  end
  table.sort(out,function(a,b) return dist(a.position,e.position)<dist(b.position,e.position) end)
  return out
end

-- The elevated rails within a support's reach (as supports() takes them in).
function M.carried(s)
  local out={}
  for _,r in pairs(s.surface.find_entities_filtered{type={'elevated-straight-rail','elevated-half-diagonal-rail','elevated-curved-rail-a','elevated-curved-rail-b'},
      position=s.position,radius=range(s)}) do
    if r.valid and dist(s.position,r.position)+1<=range(s) then out[#out+1]=r end
  end
  return out
end

-- The nearest elevated rails joined to e along the rails, each way, that the game lets go now (minable), walking at
-- most MAX_WALK rails.
function M.ends(e)
  local found,seen,frontier,steps={},{[e.unit_number or 0]=true},{e},0
  local D,C=defines.rail_direction,defines.rail_connection_direction
  while #frontier>0 and steps<MAX_WALK do
    local nxt={}
    for _,r in ipairs(frontier) do
      for _,d in ipairs({D.front,D.back}) do
        for _,c in ipairs({C.straight,C.left,C.right}) do
          local ok,n=pcall(r.get_connected_rail,{rail_direction=d,rail_connection_direction=c})
          if ok and n and n.valid and M.RAIL[n.type] and not seen[n.unit_number] then
            seen[n.unit_number]=true; steps=steps+1
            if n.minable then found[#found+1]=n else nxt[#nxt+1]=n end
          end
        end
      end
    end
    frontier=nxt
  end
  return found,steps>=MAX_WALK
end

-- Why the game will not let entity e be mined now (nil when it will): an elevated rail inside a support's run, a
-- support that carries rails, or the game's minable flag.
function M.why(e)
  if not (e and e.valid) or e.minable then return nil end
  local okf,flag=pcall(function() return e.minable_flag end)
  if okf and flag==false then return 'its minable flag is off (set by a script); the game mines it only with the flag on' end
  if M.RAIL[e.type] then
    local sup=M.supports(e)
    local ends,cut=M.ends(e)
    local names={}
    for i=1,math.min(4,#ends) do names[#names+1]=ends[i].name..' '..at(ends[i]) end
    return string.format('the game lets an elevated rail go only from an end of the run a rail support carries%s; taken from an end, the next rail in frees; %s; '
        ..'a deconstruction planner marks nothing over a rail inside a run, and over the support it marks the support and every rail it carries',
      #sup>0 and (': '..sup[1].name..' '..at(sup[1])..(#sup>1 and string.format(' (and %d more)',#sup-1) or '')..' carries this one') or '',
      #names>0 and ('the nearest that can go now along these rails: '..table.concat(names,', ')..(#ends>4 and string.format(' (+%d more)',#ends-4) or ''))
        or ('none can go now within '..MAX_WALK..' rails along these'..(cut and ' (more beyond)' or '')))
  end
  if M.SUPPORT[e.type] then
    return string.format('a rail support goes only once no elevated rail rests on it: %d within its reach (%g tiles); marking it for deconstruction marks them with it',
      #M.carried(e),range(e))
  end
  return 'the game reads it not minable now'..(okf and flag and ' (its minable flag is on)' or '')
end

-- deconstruct: mark support s as a planner does, which marks the rails it carries too. Returns the entities newly
-- marked by name ({name=count}, the rails as the game marked them), nil, the number of rails and {unit_number=true}
-- of all it marked; or nil and the game's error.
local function near_rails(s)
  return s.surface.find_entities_filtered{type={'elevated-straight-rail','elevated-half-diagonal-rail','elevated-curved-rail-a','elevated-curved-rail-b'},
    position=s.position,radius=range(s)+6}
end
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
