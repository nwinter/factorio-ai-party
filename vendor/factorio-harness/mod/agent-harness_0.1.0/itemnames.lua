-- Item prototype validation shared by execution parsers and queue preflight.
return function(name, field)
  if type(name) ~= 'string' or not prototypes.item[name] then
    local fluid = type(name) == 'string' and prototypes.fluid and prototypes.fluid[name]
    error(field .. ': ' .. tostring(name) .. ' is not an item (' .. (fluid and 'fluid prototype' or 'unknown item name') .. ')', 0)
  end
end
