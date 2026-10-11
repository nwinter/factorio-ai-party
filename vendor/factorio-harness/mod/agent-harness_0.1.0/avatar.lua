-- The pixel avatar drawn in game: the same choices as tools/stream/static/avatar.js
-- (parts from the profile, unset ones from the name; suit and accent palette),
-- as a list of sprite layers and tints. avatar_parts.lua (generated) names the
-- layers; data.lua turns them into sprites.
return function(parts)
  local M = {}
  local TWO32 = 4294967296
  -- 32-bit operations without bit32 (the tests run on Lua 5.4+); Factorio has bit32.
  local function bitop(a, b, keep)
    local out, place = 0, 1
    for _ = 1, 32 do
      local x, y = a % 2, b % 2
      if keep(x, y) then out = out + place end
      a = (a - x) / 2; b = (b - y) / 2; place = place * 2
    end
    return out
  end
  local bxor = bit32 and bit32.bxor or function(a, b) return bitop(a, b, function(x, y) return x ~= y end) end
  local bor = bit32 and bit32.bor or function(a, b) return bitop(a, b, function(x, y) return x == 1 or y == 1 end) end
  local function shr(a, n) return math.floor(a / 2 ^ n) end
  local function imul(a, b)
    local lo, hi = b % 65536, math.floor(b / 65536)
    return (a * lo + (a * hi % 65536) * 65536) % TWO32
  end
  -- FNV-1a over the name's bytes, then mulberry32 (avatar.js hash/rng).
  function M.hash(text)
    local h = 2166136261
    for i = 1, #text do h = imul(bxor(h, text:byte(i)), 16777619) end
    return h
  end
  local function rng(seed)
    local a = seed
    return function()
      a = (a + 1831565813) % TWO32
      local t = a
      t = imul(bxor(t, shr(t, 15)), bor(t, 1))
      t = bxor(t, (t + imul(bxor(t, shr(t, 7)), bor(t, 61))) % TWO32)
      return bxor(t, shr(t, 14)) % 1000003
    end
  end
  local function parse(hex)
    local r, g, b = tostring(hex or ''):match('^#?(%x%x)(%x%x)(%x%x)$')
    if r then return {tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)} end
  end
  local function mix(a, b, t)
    return {math.floor(a[1] + (b[1] - a[1]) * t + 0.5), math.floor(a[2] + (b[2] - a[2]) * t + 0.5), math.floor(a[3] + (b[3] - a[3]) * t + 0.5)}
  end
  local function luma(c) return (c[1] * 299 + c[2] * 587 + c[3] * 114) / 255000 end
  local function dist(a, b) return math.abs(a[1] - b[1]) + math.abs(a[2] - b[2]) + math.abs(a[3] - b[3]) end
  local BLACK, WHITE = {0, 0, 0}, {255, 255, 255}
  local function listed(list, value)
    for _, v in ipairs(list) do if v == value then return true end end
    return false
  end
  -- The spec actually drawn: {base=..., ..., color={r,g,b 0..255}, accent={...}}.
  function M.resolve(name, color, avatar)
    name = (name and name ~= '') and name or 'agent'
    local av = type(avatar) == 'table' and avatar or {}
    local nextr = rng(M.hash(name))
    local out = {}
    for _, f in ipairs(parts.fields) do
      local list, r = parts.options[f], nextr()
      out[f] = listed(list, av[f]) and av[f] or list[r % #list + 1]
    end
    local color_pick, accent_pick = nextr(), nextr()
    local suit = parse(type(color) == 'string' and color:match('^#%x%x%x%x%x%x$') and color) or parse(parts.colors[color_pick % #parts.colors + 1])
    local accent = type(av.accent) == 'string' and av.accent:match('^#%x%x%x%x%x%x$') and parse(av.accent)
    if not accent then
      local n = #parts.accents
      for i = 0, n - 1 do
        local c = parse(parts.accents[(accent_pick + i) % n + 1])
        if dist(c, suit) >= 180 then accent = c; break end
      end
      accent = accent or parse(parts.accents[accent_pick % n + 1])
    end
    out.color, out.accent = suit, accent
    return out
  end
  local function palette(spec)
    local suit, accent = spec.color, spec.accent
    local dark = luma(suit) < 0.16
    return {
      o = dark and mix(suit, WHITE, 0.42) or parse(parts.outline),
      s = dark and mix(suit, WHITE, 0.1) or suit,
      S = dark and mix(suit, WHITE, 0.04) or mix(suit, BLACK, 0.32),
      h = mix(suit, WHITE, dark and 0.26 or 0.38),
      a = accent, A = mix(accent, BLACK, 0.3), b = mix(accent, WHITE, 0.4), g = mix(accent, WHITE, 0.2),
      G = mix(accent, WHITE, 0.72), V = mix(accent, WHITE, 0.62),
    }
  end
  function M.rgb(c) return {r=c[1] / 255, g=c[2] / 255, b=c[3] / 255} end
  -- The layers bottom to top: {sprite=name, tint={r,g,b} or nil}.
  function M.layers(name, color, avatar)
    local spec = M.resolve(name, color, avatar)
    local pal = palette(spec)
    local base = parts.bases[spec.base]
    local h = M.hash((name and name ~= '') and name or 'agent')
    local glow = parse(parts.glow_bg)
    local out = {}
    local function add(key)
      for _, layer in ipairs(parts.parts[key] or {}) do
        local index, k = layer[1], layer[2]
        local tint, skip = nil, false
        if pal[k] then tint = M.rgb(pal[k])
        elseif k:sub(1, 4) == 'glow' then tint = M.rgb(mix(glow, spec.color, parts.glow_t[tonumber(k:sub(5))]))
        elseif k:sub(1, 4) == 'star' then skip = math.floor(h / 2 ^ tonumber(k:sub(5))) % 2 == 1 end
        if not skip then out[#out+1] = {sprite=parts.prefix .. index, tint=tint} end
      end
    end
    local acc = spec.accessory ~= 'none' and spec.accessory or nil
    add('backdrop/' .. spec.backdrop)
    if acc and parts.accessory_layer[acc] == 'back' then add('accessory/' .. acc .. '/' .. base.top) end
    add('base/' .. spec.base)
    if spec.emblem ~= 'none' then add('emblem/' .. spec.emblem .. '/' .. base.chest) end
    if spec.helmet ~= 'none' then add('helmet/' .. spec.helmet .. '/' .. base.top) end
    if spec.visor ~= 'none' then add('visor/' .. spec.visor .. '/' .. base.eye) end
    if acc and parts.accessory_layer[acc] == 'front' then add('accessory/' .. acc .. '/' .. base.top) end
    return out, spec
  end
  return M
end
