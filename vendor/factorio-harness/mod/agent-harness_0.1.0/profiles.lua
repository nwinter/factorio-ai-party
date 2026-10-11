-- Agent-chosen identity (display name, colour, glyph, pixel avatar, motto) and the
-- speech bubbles `say` draws over the speaker. `profiles` is what the stream
-- overlay polls: every player's and bot's profile, where it is and what it does.
return function(api)
  local M = {handlers={}}
  local BUBBLE_TICKS, WRAP, MAX_LINES = 480, 40, 6
  local function store()
    local s = api.state()
    s.profiles = s.profiles or {}
    return s.profiles
  end
  -- Lua 5.2 has no utf8 library: count code points, leaving out joiners,
  -- variation selectors and skin tones, which belong to the emoji before them.
  local function codepoints(text)
    local n, i = 0, 1
    while i <= #text do
      local c = text:byte(i)
      local len = c < 0x80 and 1 or c >= 0xF0 and 4 or c >= 0xE0 and 3 or c >= 0xC0 and 2 or 1
      local code = c
      if len == 2 then code = (c % 0x20) * 0x40 + (text:byte(i+1) or 0) % 0x40
      elseif len == 3 then code = ((c % 0x10) * 0x40 + (text:byte(i+1) or 0) % 0x40) * 0x40 + (text:byte(i+2) or 0) % 0x40
      elseif len == 4 then code = (((c % 0x08) * 0x40 + (text:byte(i+1) or 0) % 0x40) * 0x40 + (text:byte(i+2) or 0) % 0x40) * 0x40 + (text:byte(i+3) or 0) % 0x40 end
      local combining = code == 0x200D or (code >= 0xFE00 and code <= 0xFE0F) or (code >= 0x1F3FB and code <= 0x1F3FF)
      if not combining then n = n + 1 end
      i = i + len
    end
    return n
  end
  M.codepoints = codepoints
  local function rgb(hex)
    local r, g, b = hex:match('^#(%x%x)(%x%x)(%x%x)$')
    assert(r, 'color must be "#rrggbb"')
    return {r=tonumber(r, 16)/255, g=tonumber(g, 16)/255, b=tonumber(b, 16)/255}
  end
  local function text_arg(value, name, low, high)
    assert(type(value) == 'string', name .. ' must be a string')
    assert(not value:find('[%c]'), name .. ' must be one line')
    local n = codepoints(value)
    assert(n >= low and n <= high and #value <= math.max(32, high * 4),string.format('%s must be %d..%d characters', name, low, high))
    return value
  end
  -- A pixel-art portrait chosen from a few fixed parts. The harness only
  -- validates and stores it; renderers (tools/stream/static/avatar.js and its
  -- Python port) draw it, fill unset parts from the name, and draw a default
  -- from the name and colour when there is none.
  local AVATAR = {
    base={'engineer','robot','biter','drone'},
    helmet={'none','hardhat','armor','power','crest','hood'},
    visor={'none','goggles','slit','wide','mono','grid'},
    emblem={'none','gear','bolt','flask','plate','circuit','rocket','leaf','star'},
    accessory={'none','antenna','headlamp','scarf','tank','horns','earpiece','pipe'},
    backdrop={'dark','grid','hazard','glow','night'},
  }
  local AVATAR_KEYS = {'base','helmet','visor','emblem','accessory','backdrop','accent'}
  M.AVATAR = AVATAR
  local function avatar_arg(value)
    if value == false then return nil end
    assert(type(value) == 'table', 'avatar must be an object like {"base":"robot","visor":"mono"} (or false to clear)')
    local out = {}
    for k, v in pairs(value) do
      assert(type(k) == 'string' and (AVATAR[k] or k == 'accent'), 'avatar: unknown field ' .. tostring(k) .. ' (fields: ' .. table.concat(AVATAR_KEYS, ', ') .. ')')
      if k == 'accent' then
        assert(type(v) == 'string' and v:match('^#%x%x%x%x%x%x$'), 'avatar.accent must be "#rrggbb"')
        out.accent = v:lower()
      else
        local ok = false
        for _, name in ipairs(AVATAR[k]) do if v == name then ok = true end end
        assert(ok, 'avatar.' .. k .. ' must be one of ' .. table.concat(AVATAR[k], '|'))
        out[k] = v
      end
    end
    return out
  end
  function M.get(index) return store()[index] end
  local function public(pr)
    if not pr then return {} end
    return {display_name=pr.display_name, color=pr.color, glyph=pr.glyph, motto=pr.motto, avatar=pr.avatar, voice=pr.voice, pronouns=pr.pronouns}
  end
  -- Paint the character (and, for a player, the player and chat name colour).
  function M.apply(p)
    local pr = store()[p.index]
    if not (pr and pr.rgb) then return end
    local c = p.character
    if c and c.valid then pcall(function() c.color = pr.rgb end) end
    if not api.is_bot(p) then
      pcall(function() p.color = pr.rgb; p.chat_color = pr.rgb end)
    end
  end
  M.schema = {
    profile = {display_name='1..24 characters', color='"#rrggbb" (character and chat name colour)', glyph='1..2 characters: an emoji or letters (a short tag beside your name)',
      motto='0..80 characters',
      voice='your stream voice (Deepgram Aura-2 speaker, lower case): apollo arcas aries atlas hermes hyperion janus jupiter mars neptune odysseus orion orpheus pluto saturn zeus (masculine); amalthea andromeda asteria athena aurora callista cora cordelia delia electra harmonia helena hera iris juno luna minerva ophelia pandora phoebe theia vesta (feminine); unset or unknown: a default picked from your name',
      pronouns='optional, 0..32 characters of free text (e.g. "she/her", "they/them", "it"); casters use them when they talk about you; "" clears',
      avatar='pixel portrait, every field optional (unset ones follow from your name): base engineer|robot|biter|drone, helmet none|hardhat|armor|power|crest|hood, visor none|goggles|slit|wide|mono|grid, emblem none|gear|bolt|flask|plate|circuit|rocket|leaf|star, accessory none|antenna|headlamp|scarf|tank|horns|earpiece|pipe, backdrop dark|grid|hazard|glow|night, accent "#rrggbb" (second colour; suit is your color); false clears',
      returns='your profile; with no arguments just reads it'},
    profiles = {returns='every player and bot (directors excluded): kind bot|player, name, display_name, color, glyph, motto, avatar, voice, pronouns, position, alive, active (current action kind or false), last_said {text,tick}'},
  }
  function M.handlers.profile(p, a)
    local all = store()
    local pr = all[p.index] or {}
    local changed = false
    local avatar = a.avatar ~= nil and avatar_arg(a.avatar) or nil -- validated before anything changes
    if a.display_name ~= nil then pr.display_name = text_arg(a.display_name, 'display_name', 1, 24); changed = true end
    if a.motto ~= nil then pr.motto = text_arg(a.motto, 'motto', 0, 80); changed = true end
    if a.glyph ~= nil then pr.glyph = text_arg(a.glyph, 'glyph', 1, 2); changed = true end
    if a.voice ~= nil then pr.voice = text_arg(a.voice, 'voice', 1, 16):lower(); changed = true end
    if a.pronouns ~= nil then
      local v = text_arg(a.pronouns, 'pronouns', 0, 32)
      pr.pronouns = v:match('%S') and v or nil; changed = true
    end
    if a.avatar ~= nil then pr.avatar = avatar; changed = true end
    if a.color ~= nil then
      assert(type(a.color) == 'string', 'color must be "#rrggbb"')
      pr.rgb = rgb(a.color); pr.color = a.color:lower(); changed = true
    end
    if changed then
      all[p.index] = pr
      M.apply(p)
    end
    local out = public(all[p.index])
    out.name = p.name; out.kind = api.is_bot(p) and 'bot' or 'player'
    return out
  end
  local function row(kind, name, index, character, pos)
    local pr = store()[index]
    local out = public(pr)
    out.kind = kind; out.name = name
    local alive = character ~= nil and character.valid
    out.alive = alive
    out.position = alive and character.position or pos
    out.active = api.active(index)
    out.last_said = pr and pr.last_said or nil
    return out
  end
  function M.handlers.profiles()
    local out = {}
    for _, p in pairs(game.players) do
      if not api.director(p.index) then
        local r = row('player', p.name, p.index, p.character, p.position)
        r.connected = p.connected
        out[#out+1] = r
      end
    end
    for _, b in ipairs(api.bots()) do
      local r = row('bot', b.name, b.index, b.character, b.position)
      r.dead_until_tick = b.dead_until_tick
      out[#out+1] = r
    end
    return {profiles=out, tick=game.tick}
  end
  -- Word wrap at WRAP characters (bytes; long words are cut).
  local function wrap(text)
    local lines, line = {}, ''
    for token in text:gmatch('%S+') do
      local word = token
      while #word > WRAP do
        if #line > 0 then lines[#lines+1] = line; line = '' end
        lines[#lines+1] = word:sub(1, WRAP); word = word:sub(WRAP + 1)
      end
      if #line == 0 then line = word
      elseif #line + 1 + #word <= WRAP then line = line .. ' ' .. word
      else lines[#lines+1] = line; line = word end
    end
    if #line > 0 then lines[#lines+1] = line end
    if #lines > MAX_LINES then
      lines[MAX_LINES] = lines[MAX_LINES]:sub(1, WRAP - 3) .. '...'
      for i = #lines, MAX_LINES + 1, -1 do lines[i] = nil end
    end
    return lines
  end
  M.wrap = wrap
  local function clear(pr)
    for _, id in ipairs(pr.bubble or {}) do
      local ok, obj = pcall(rendering.get_object_by_id, id)
      if ok and obj and obj.valid then obj.destroy() end
    end
    pr.bubble = nil
  end
  -- The bubble rides on the character; the newest line sits lowest.
  function M.say(p, text)
    local all = store()
    local pr = all[p.index] or {}
    all[p.index] = pr
    pr.last_said = {text=text, tick=game.tick}
    clear(pr)
    local c = p.character
    if not (c and c.valid) then return end
    local color = pr.rgb or p.chat_color or {r=1, g=1, b=1}
    local lines = wrap(text)
    pr.bubble = {}
    for i, line in ipairs(lines) do
      local obj = rendering.draw_text{text=line, surface=c.surface, target={entity=c, offset={0, -2.6 - (#lines - i) * 0.55}},
        color=color, scale=1.4, alignment='center', vertical_alignment='bottom', time_to_live=BUBBLE_TICKS, use_rich_text=false}
      pr.bubble[#pr.bubble+1] = obj.id
    end
  end
  return M
end
