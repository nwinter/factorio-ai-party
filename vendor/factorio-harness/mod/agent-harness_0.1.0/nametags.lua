-- Who is who on stream: every bot's character is tinted in its colour and carries
-- a name tag (glyph and name) and, when the mod has the avatar sprites (data.lua,
-- a world started with this mod), its pixel avatar above the tag. All of it is
-- rendering attached to the character, so it moves with it at no per-tick cost and
-- every client (directors too) sees it. Drawn on spawn and on a profile change;
-- every RECHECK_TICKS the bots are checked, which also covers a hot-deployed
-- runtime and a character the harness did not spawn.
return function(api)
  local M = {}
  local RECHECK_TICKS = 300
  local TAG_Y, TAG_SCALE, LINE = -2.2, 1.15, 0.5   -- text bottom above the feet; height of one tag line
  local BADGE = 1.0                                  -- avatar size in tiles
  local avatar = api.avatar
  local function store()
    local s = api.state()
    s.nametags = s.nametags or {}
    return s.nametags
  end
  local sprites_ok
  function M.sprites()
    if sprites_ok == nil then
      local ok, valid = pcall(function() return helpers.is_valid_sprite_path(api.parts.prefix .. '1') end)
      sprites_ok = ok and valid == true
    end
    return sprites_ok
  end
  local function key(b, pr)
    local c = b.character
    local av = pr and pr.avatar or {}
    local parts = {}
    for _, f in ipairs(api.parts.fields) do parts[#parts+1] = av[f] or '' end
    return table.concat({c.unit_number or 0, b.name, pr and pr.display_name or '', pr and pr.glyph or '', pr and pr.color or '',
      table.concat(parts, ','), av.accent or '', M.sprites() and 'a' or ''}, '|')
  end
  local function destroy(ids)
    for _, id in ipairs(ids or {}) do
      local ok, obj = pcall(rendering.get_object_by_id, id)
      if ok and obj and obj.valid then obj.destroy() end
    end
  end
  -- Readable text on dark ground: very dark colours are lifted toward white.
  local function text_colour(rgb)
    local l = rgb.r * 0.299 + rgb.g * 0.587 + rgb.b * 0.114
    if l >= 0.35 then return rgb end
    local t = 0.55
    return {r=rgb.r + (1 - rgb.r) * t, g=rgb.g + (1 - rgb.g) * t, b=rgb.b + (1 - rgb.b) * t}
  end
  -- Where speech bubbles start (their bottom line), above whatever is drawn.
  function M.bubble_y(index)
    local rec = store()[index]
    if not rec then return -2.6 end
    return rec.avatar and TAG_Y - LINE - BADGE - 0.15 or TAG_Y - LINE - 0.1
  end
  function M.refresh(b)
    local all = store()
    local rec = all[b.index]
    if rec then destroy(rec.ids) end
    all[b.index] = nil
    local c = b.character
    if not (c and c.valid) then return nil end
    local pr = api.profile(b.index)
    local layers, spec = avatar.layers(b.name, pr and pr.color, pr and pr.avatar)
    local colour = pr and pr.rgb or avatar.rgb(spec.color)
    pcall(function() c.color = colour end)
    rec = {ids={}, key=key(b, pr)}
    local label = (pr and pr.display_name) or b.name
    if pr and pr.glyph then label = pr.glyph .. ' ' .. label end
    local ok, tag = pcall(rendering.draw_text, {text=label, surface=c.surface, target={entity=c, offset={0, TAG_Y}},
      color=text_colour(colour), scale=TAG_SCALE, alignment='center', vertical_alignment='bottom', use_rich_text=false})
    if ok and tag then rec.ids[#rec.ids+1] = tag.id end
    if M.sprites() then
      local size = BADGE / (api.parts.cell * api.parts.scale / 32)
      local y = TAG_Y - LINE - BADGE / 2 - 0.05
      for _, layer in ipairs(layers) do
        local drawn, obj = pcall(rendering.draw_sprite, {sprite=layer.sprite, surface=c.surface, target={entity=c, offset={0, y}},
          tint=layer.tint, x_scale=size, y_scale=size})
        if drawn and obj then rec.ids[#rec.ids+1] = obj.id end
      end
      rec.avatar = true
    end
    all[b.index] = rec
    return rec
  end
  -- Redraw what is missing or stale: a character without tags, a dead tag, a
  -- changed profile. Bounded: one pass over the bots every RECHECK_TICKS.
  function M.tick(tick)
    if tick % RECHECK_TICKS ~= 0 then return end
    local all, seen = store(), {}
    for _, b in ipairs(api.bots()) do
      seen[b.index] = true
      local c = b.character
      local rec = all[b.index]
      if c and c.valid then
        local stale = not rec or rec.key ~= key(b, api.profile(b.index))
        if not stale then
          local ok, obj = pcall(rendering.get_object_by_id, rec.ids[1])
          stale = not (ok and obj and obj.valid)
        end
        if stale then M.refresh(b) end
      elseif rec then
        destroy(rec.ids); all[b.index] = nil
      end
    end
    for index, rec in pairs(all) do
      if not seen[index] then destroy(rec.ids); all[index] = nil end
    end
  end
  return M
end
