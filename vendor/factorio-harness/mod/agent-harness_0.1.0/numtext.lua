-- (d21 batch73 AI) Numbers as text, fast: in the game's Lua a number turned into text by .. or tostring costs about
-- 8 µs on the private copy, string.format('%d') 0.3 µs; the census pass made three or four such keys for each of
-- about 200,000 entities (fog and belt memory, the map's blocks), most of census.step on world n. num(x) is the text
-- x .. '' gives (checked in the game over 52,000 positions and halves): integers and halves by string.format, -0 and
-- anything else as before. pair(a, b) is a .. ',' .. b.
local M = {}
local fmt, floor = string.format, math.floor
local function num(x)
  if x ~= 0 and x > -1e15 and x < 1e15 then
    local i = floor(x)
    if x == i then return fmt('%d', x) end
    if x - i == 0.5 then
      if x < 0 then return fmt('-%d.5', -x - 0.5) end
      return fmt('%d.5', i)
    end
  end
  return x .. ''
end
M.num = num
function M.pair(a, b) return num(a) .. ',' .. num(b) end
return M
