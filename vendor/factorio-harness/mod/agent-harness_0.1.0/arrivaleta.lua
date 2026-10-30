-- Arrival on the current leg: its direction-aware distance at the speed now, not a cruise projection.
return function(leg)
  if not leg then return nil, 'current flight leg is unavailable' end
  local left, speed = leg.left_km, leg.speed_now_kms
  if type(left) ~= 'number' or left ~= left or left < 0 or left == math.huge then
    return nil, 'distance left on current leg is unavailable'
  end
  if type(speed) ~= 'number' or speed ~= speed or speed <= 0 or speed == math.huge then
    return nil, 'current platform speed is zero or unavailable'
  end
  local motion = leg.motion
  local trend = motion and motion.state or 'unknown'
  local basis = string.format('%.0f km left toward %s / speed now %.3f km/s; assumes this speed is maintained, excludes later legs',
    left, leg.to, speed)
  if trend == 'accelerating' or trend == 'decelerating' then
    basis = basis .. string.format('; uncertain: %s (%.3f -> %.3f km/s over %.2f s)', trend,
      motion.from_kms, motion.to_kms, motion.seconds)
  elseif trend == 'unknown' then basis = basis .. '; uncertain: no fresh speed comparison' end
  return {seconds=left/speed, basis=basis, uncertain=trend~='steady', speed_trend=trend,
    leg_left_km=math.floor(left+0.5), speed_kms=speed, heading_to=leg.to}
end
