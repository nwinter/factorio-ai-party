-- Board claims seen from gameplay: whose claimed area a position lies in, so
-- collect can leave another agent's stock alone and say whose it is.
return function(api)
  local M = {}
  local ACTIVE = {open=true, claimed=true, doing=true, blocked=true}
  local function inside(area, pos)
    return pos.x >= area.left_top.x and pos.x <= area.right_bottom.x and pos.y >= area.left_top.y and pos.y <= area.right_bottom.y
  end
  -- The active claim by someone other than p that holds pos, or nil.
  function M.other(p, pos)
    local board = api.state().board
    if not board then return nil end
    local me = p.name
    for _, i in pairs(board.items) do
      if i.kind == 'claim' and ACTIVE[i.status] and i.owner and i.owner ~= me and i.area and inside(i.area, pos) then return i end
    end
  end
  -- With reader p: where the owner is when somewhere else (where.lua).
  function M.label(i, p)
    local where = p and api.where_from and api.where_from(p.name)
    local away = where and where(i.owner)
    return string.format('#%d %s (claim by %s%s)', i.id, i.title or '', i.owner, away and ', ' .. away or '')
  end
  return M
end
