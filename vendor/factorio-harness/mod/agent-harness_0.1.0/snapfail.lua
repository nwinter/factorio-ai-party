-- A cached read a background job refreshes (status's factory survey, threat's chart, game_alerts, the ground watch, the
-- census, networks' view and pole map): when a refresh fails the read keeps the tick it was captured at, the failure
-- is kept beside it ({tick, error}) and the next try counts from the failure; a reply says the read's age and the
-- failure. A background result started before the read it would replace was captured is dropped (d20 batch55 P1,
-- viewer Aurora: a failed refresh relabelled the old survey as new, and a slow job overwrote a newer forced read).
local M = {}
local MAX_ERROR = 200
function M.failed(err, tick)
  local e = tostring(err):gsub('[%c]+', ' ')
  return {tick=tick, error=#e > MAX_ERROR and e:sub(1, MAX_ERROR - 3) .. '...' or e}
end
-- The tick the next refresh counts from: the capture, or a failed refresh since.
function M.since(at, failed)
  return failed and failed.tick > at and failed.tick or at
end
-- Whether a job started at `start` is older than the read now held (captured at `at`).
function M.older(start, at)
  return at ~= nil and at > start
end
-- The reply's line when the last refresh failed: nil otherwise.
function M.line(what, at, failed)
  if not (failed and failed.tick >= at) then return nil end
  return string.format('the last refresh of %s failed %ds ago (%s); %s is from %ds ago', what, math.floor((game.tick - failed.tick) / 60),
    failed.error, what, math.floor((game.tick - at) / 60))
end
return M
