-- Non-cardinal building collision boxes (eight/sixteen-way prototype flags).
-- The same shape is used before placement and when reading an existing ghost.
local M = {}
function M.direction(proto, dir)
  local flags = proto.flags or {}
  dir = (dir or 0) % 16
  if flags['building-direction-16-way'] then return dir end
  if flags['building-direction-8-way'] then return math.floor(dir / 2) * 2 end
  return math.floor(dir / 4) * 4
end
function M.shape(proto, pos, dir)
  dir = M.direction(proto, dir)
  if dir % 4 == 0 then return nil end
  local b = proto.collision_box
  local c, s = math.cos(dir * math.pi / 8), math.sin(dir * math.pi / 8)
  local x, y = (b.left_top.x+b.right_bottom.x)/2, (b.left_top.y+b.right_bottom.y)/2
  local hw, hh = (b.right_bottom.x-b.left_top.x)/2, (b.right_bottom.y-b.left_top.y)/2
  local cx, cy = pos.x+x*c-y*s, pos.y+x*s+y*c
  local ex, ey = math.abs(c)*hw+math.abs(s)*hh, math.abs(s)*hw+math.abs(c)*hh
  return {cx=cx, cy=cy, c=c, s=s, hw=hw, hh=hh,
    left_top={x=cx-ex,y=cy-ey}, right_bottom={x=cx+ex,y=cy+ey}}
end
function M.overlaps(b, x, y, r, bottom)
  local dx, dy = (x+r)/2-b.cx, (y+bottom)/2-b.cy
  local hw, hh = (r-x)/2, (bottom-y)/2
  local c, s = math.abs(b.c), math.abs(b.s)
  return math.abs(dx) < hw+c*b.hw+s*b.hh-0.01
    and math.abs(dy) < hh+s*b.hw+c*b.hh-0.01
    and math.abs(dx*b.c+dy*b.s) < b.hw+hw*c+hh*s-0.01
    and math.abs(-dx*b.s+dy*b.c) < b.hh+hw*s+hh*c-0.01
end
return M
