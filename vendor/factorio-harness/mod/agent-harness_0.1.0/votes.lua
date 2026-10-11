-- The agents' votes, one mechanism for every kind:
--   mute, unmute     a stream viewer (audience.lua): a muted viewer's lines no
--                    longer reach the game, for the rest of the run.
--   kick, ban, trust a human player (players.lua): the operator
--                    (tools/players.py) runs the server's /kick or /ban, or the
--                    move from the guest group to the normal one.
-- A ballot is decided when it is cast: yes from more than half the agents
-- active in the last 10 minutes (the voter always counts as active) carries
-- the vote, no from more than half fails it. A vote is open 10 minutes; after
-- one is decided, the same kind on the same target waits 5 minutes (an expired
-- one may open again at once). Ballots of
-- agents who went quiet stop counting. Every ballot and result is a chat
-- notice from `vote` (chat.lua), which the stream shows on its ticker.
return function(api)
  local M = {handlers={}, operator={}}
  local MINUTE = 3600
  local WINDOW = 10 * MINUTE     -- who counts as active, and how long a vote stays open
  local COOLDOWN = 5 * MINUTE
  local REASON_LEN = 200
  -- Each kind: what it targets, how a target is checked (name and a case-blind
  -- key), and what carrying it does. Operator kinds wait for vote_close.
  local KINDS = {
    mute = {target='viewer', check=function(raw)
      local name, key = api.viewer_name(raw)
      assert(not api.muted(key), 'viewer ' .. name .. ' is already muted')
      return name, key
    end},
    unmute = {target='viewer', check=function(raw)
      local name, key = api.viewer_name(raw)
      local m = api.muted(key)
      assert(m, 'viewer ' .. name .. ' is not muted')
      return m.viewer, key
    end},
    kick = {target='player', operator=true},
    ban = {target='player', operator=true},
    trust = {target='player', operator=true},
  }
  for _, kind in ipairs{'kick', 'ban', 'trust'} do
    KINDS[kind].check = function(raw, opening)
      local p = api.human(raw)
      if kind == 'trust' and opening then
        local group = api.group(p)
        assert(group == 'guest', p.name .. ' is not in the guest group (group ' .. group .. ')')
      end
      return p.name, p.name:lower()
    end
  end
  local KIND_LIST = 'mute, unmute, kick, ban or trust'
  local CLOSING = {done=true, cancelled=true}

  local function store()
    local s = api.state()
    s.votes = s.votes or {seq=0, list={}}
    return s.votes
  end
  local function seconds(ticks) return math.floor(ticks / 60) end
  local function label(v) return KINDS[v.kind].target == 'viewer' and 'viewer ' .. v.target or v.target end
  local function closed(v) return v.outcome ~= 'open' and v.outcome ~= 'carried' end
  -- Open votes past their 10 minutes expire (quietly: nobody voted since).
  local function sweep()
    for _, v in ipairs(store().list) do
      if v.outcome == 'open' and game.tick > v.expires_tick then v.outcome = 'expired'; v.closed_tick = v.expires_tick end
    end
  end
  local function find(kind, key)
    for _, v in ipairs(store().list) do
      if v.kind == kind and v.key == key and (v.outcome == 'open' or v.outcome == 'carried') then return v end
    end
  end
  local function electorate(me)
    local out, seen = {}, {}
    for _, name in ipairs(api.active_agents(WINDOW)) do if not seen[name] then seen[name] = true; out[#out+1] = name end end
    if me and not seen[me] then seen[me] = true; out[#out+1] = me end
    table.sort(out)
    return out, seen
  end
  local function count(v, seen)
    local yes, no = {}, {}
    for voter, b in pairs(v.ballots) do
      if seen[voter] then table.insert(b.yes and yes or no, voter) end
    end
    table.sort(yes); table.sort(no)
    return yes, no
  end
  local function view(v, me)
    local active, seen = electorate(me)
    local yes, no = count(v, seen)
    local voters = {}
    for voter in pairs(v.ballots) do voters[#voters+1] = voter end
    table.sort(voters)
    local out = {id=v.id, kind=v.kind, reason=v.reason, opened_by=v.opened_by, voters=voters, yes=yes, no=no,
      votes=#yes, needed=math.floor(#active / 2) + 1, active=#active, outcome=v.outcome, note=v.note,
      closes_in_s=v.outcome == 'open' and math.max(0, seconds(v.expires_tick - game.tick)) or nil}
    out[KINDS[v.kind].target] = v.target
    if v.outcome ~= 'open' and v.outcome ~= 'expired' then out.result = v.outcome end
    return out
  end
  local function one_line(text)
    if text == nil then return nil end
    assert(type(text) == 'string', 'reason must be a string')
    text = text:gsub('[%c]+', ' '):gsub('%[', '('):gsub('%]', ')'):gsub('^%s+', ''):gsub('%s+$', '')
    if #text > REASON_LEN then text = text:sub(1, REASON_LEN) end
    return #text > 0 and text or nil
  end

  M.schema = {
    vote = {kind=KIND_LIST, viewer='for mute and unmute: the viewer\'s name as in "viewer NAME: ..." (with or without "viewer ")',
      player='for kick, ban and trust: the human player\'s name', reason='1..200 characters (required to open a vote)',
      yes='optional boolean (default true); false votes against an open vote',
      returns='the vote {id,kind,viewer|player,reason,voters,yes,no,votes,needed,active,outcome,result?,closes_in_s}. A majority of the agents active in the last 10 minutes (you included) carries it, a majority against fails it; a vote is open 10 minutes, and after one closes the same kind on the same target waits 5 minutes. mute and unmute act at once (a muted viewer\'s lines stop reaching the game for the rest of the run); kick, ban and trust are carried out by the operator (outcome carried, then done). Every ballot and result is a "vote: ..." notice in chat and on the stream\'s ticker'},
    votes = {returns='open votes, the 10 most recent closed ones, muted viewers {viewer,tick,reason,by}, and active (agents active in the last 10 minutes)'},
  }
  function M.handlers.vote(p, a)
    local kind = KINDS[a.kind]
    assert(kind, 'kind must be ' .. KIND_LIST)
    assert(a.yes == nil or type(a.yes) == 'boolean', 'yes must be true or false')
    local raw = a[kind.target]
    assert(raw ~= nil, a.kind .. ' needs ' .. kind.target .. ': the ' .. kind.target .. '\'s name')
    sweep()
    local yes, reason = a.yes ~= false, one_line(a.reason)
    local me = p.name ~= '' and p.name or ('player' .. p.index)
    local s = store()
    local name, key = kind.check(raw, false)
    local v = find(a.kind, key)
    if v and v.outcome == 'carried' then error(a.kind .. ' ' .. v.target .. ' is carried already; the operator carries it out', 0) end
    if not v then
      assert(yes, 'no open vote to ' .. a.kind .. ' ' .. name .. ' to vote against')
      assert(reason, 'reason is required to open a vote')
      name, key = kind.check(raw, true)
      for _, done in ipairs(s.list) do
        if done.kind == a.kind and done.key == key and closed(done) and done.outcome ~= 'expired' and game.tick - (done.closed_tick or 0) < COOLDOWN then
          error(string.format('vote #%d to %s %s closed %s %ds ago; another can open in %ds', done.id, a.kind, done.target,
            done.outcome, seconds(game.tick - done.closed_tick), seconds(COOLDOWN - (game.tick - done.closed_tick))), 0)
        end
      end
      s.seq = s.seq + 1
      v = {id=s.seq, kind=a.kind, key=key, target=name, reason=reason, opened_by=me, opened_tick=game.tick,
        expires_tick=game.tick + WINDOW, ballots={}, outcome='open'}
      s.list[#s.list+1] = v
      while #s.list > 60 do table.remove(s.list, 1) end
    end
    local before = v.ballots[me]
    v.ballots[me] = {yes=yes, tick=game.tick, reason=reason}
    local active, seen = electorate(me)
    local ayes, noes = count(v, seen)
    local needed = math.floor(#active / 2) + 1
    local who = string.format('%d of %d active agents: %s', yes and #ayes or #noes, #active, table.concat(yes and ayes or noes, ', '))
    if #ayes >= needed then
      v.decided_tick = game.tick
      if a.kind == 'mute' then
        api.mute(key, {viewer=v.target, tick=game.tick, reason=reason or v.reason, by=ayes})
        v.outcome, v.closed_tick = 'muted', game.tick
        api.notice('vote', string.format('viewer %s is muted for the rest of the run (%s)', v.target, who))
      elseif a.kind == 'unmute' then
        api.unmute(key)
        v.outcome, v.closed_tick = 'unmuted', game.tick
        api.notice('vote', string.format('viewer %s is unmuted (%s)', v.target, who))
      else
        v.outcome = 'carried'
        api.notice('vote', string.format('#%d %s %s carried (%s); the operator carries it out', v.id, a.kind, v.target, who))
      end
    elseif #noes >= needed then
      v.outcome, v.closed_tick = 'failed', game.tick
      api.notice('vote', string.format('#%d %s %s failed (%s against)', v.id, a.kind, label(v), who))
    elseif not before or before.yes ~= yes then
      if yes then
        api.notice('vote', string.format('%s votes to %s %s (%d of %d needed)%s', me, a.kind, label(v), #ayes, needed,
          reason and (': ' .. reason) or ''))
      else
        api.notice('vote', string.format('%s votes against: %s %s (%d yes, %d no; %d needed)', me, a.kind, label(v), #ayes, #noes, needed))
      end
    end
    return view(v, me)
  end
  local function votes()
    sweep()
    local open, done = {}, {}
    for _, v in ipairs(store().list) do table.insert(closed(v) and done or open, view(v)) end
    local recent = {}
    for i = math.max(1, #done - 9), #done do recent[#recent+1] = done[i] end
    return {open=open, closed=recent, muted=api.muted_list(), active=(electorate())}
  end
  function M.handlers.votes() return votes() end
  -- Open and carried votes on one kind of target (players.lua's read shows those on players).
  function M.on(target)
    sweep()
    local out = {}
    for _, v in ipairs(store().list) do
      if KINDS[v.kind].target == target and not closed(v) then out[#out+1] = view(v) end
    end
    return out
  end
  -- Operator (RCON, `operator: true` dispatch) ------------------------------
  -- viewers.py reads `muted` every minute; tools/players.py reads votes_pending.
  function M.operator.votes() return votes() end
  -- Carried kick, ban and trust votes the operator has not carried out yet.
  function M.operator.votes_pending()
    local out = {}
    for _, v in ipairs(store().list) do
      if v.outcome == 'carried' then
        local yes = {}
        for voter, b in pairs(v.ballots) do if b.yes then yes[#yes+1] = voter end end
        table.sort(yes)
        out[#out+1] = {id=v.id, kind=v.kind, player=v.target, reason=v.reason, opened_by=v.opened_by, decided_tick=v.decided_tick, yes=yes}
      end
    end
    return {tick=game.tick, votes=out}
  end
  -- done: carried out; cancelled: the operator declined (a protected name), or
  -- withdrew an open vote.
  function M.operator.vote_close(a)
    assert(type(a.id) == 'number', 'id must be a vote id')
    assert(CLOSING[a.outcome], 'outcome must be done or cancelled')
    assert(a.note == nil or type(a.note) == 'string', 'note must be a string')
    local v
    for _, x in ipairs(store().list) do if x.id == a.id then v = x end end
    assert(v, 'no vote ' .. a.id)
    if closed(v) then return view(v) end
    v.outcome, v.closed_tick, v.note = a.outcome, game.tick, a.note and a.note:sub(1, 200)
    api.notice('vote', string.format('#%d %s %s %s%s', v.id, v.kind, label(v), a.outcome, v.note and (': ' .. v.note) or ''))
    return view(v)
  end
  return M
end
