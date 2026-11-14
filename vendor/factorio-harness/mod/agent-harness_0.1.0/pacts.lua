-- (mt281, private) Pacts between teams on a multi-team map (docs/mt-diplomacy.md): proposed by one team, accepted by
-- the other; terms: a cease-fire, score shares, obligations reported as facts. Trading Posts own all item settlement.
-- The actions open for a team at its first contact with another (multiteam.lua's record), and only towards a team it
-- has had contact with. Nothing runs on a map without teams.
--   agents: pact_propose, pact_accept, pact_decline, pact_withdraw, pact_amend, pact_end, pacts (read)
--   the human team: the same through chat, "!pact ACTION {json}" (humans.lua's roster)
--   operator: mt_pacts {config?} (settings; the pacts and departures), mt_pacts_tick (test: the step now)
-- Settings (mt_pacts config): end_notice_s 0, share_max_score 1.4, expires_min 60, check_s 3600.
return function(api)
  local M = {operator={}}
  -- (mt284, Nick d29 14:00) end_notice_s 0: the cease-fire lifts on the tick a side ends the pact; share_max_score 1.4:
  -- no member's allied score above it (the solo edge is 1.5), so no team-up pays more than winning alone
  local DEFAULTS = {end_notice_s=0, share_max_score=1.4, expires_min=60, check_s=3600,
    terms={cease_fire=true, shares=true, obligations=true}}
  local KINDS = {deliver=true, keep_out=true, no_attack=true}
  local MAX_PACTS, MAX_DEPARTURES, NOTE = 64, 50, 500
  local function mt() return api.state().mt end
  local function st()
    local m = mt()
    m.pacts = m.pacts or {next=1, by_id={}, hits={}, departures={}, platforms={}}
    m.pacts.config = m.pacts.config or {}
    local s=m.pacts
    if not s.depots_retired then
      s.depots_retired=true;s.config.cut=nil;s.config.move_s=nil
      if type(s.config.terms)=='table' then s.config.terms.depot=nil end
      for _,p in pairs(s.by_id) do if p.terms and p.terms.depot then
        p.legacy_depot=p.terms.depot;p.terms.depot=nil;p.depot_retired_tick=game.tick
        -- Preserve old chests and their exact contents. Never silently change a pending agreement.
        if p.status=='proposed' then p.status='expired';p.ended={tick=game.tick,note='depot term retired'} end
        if api.fact then
          local text='Pact #'..p.id..': automatic depot transfers retired; old chests retain their goods. Use offer at the Trading Post. Cease-fire, shares and active obligations remain.'
          api.fact(p.a,text,true);api.fact(p.b,text,true)
        end
      end end
    end
    return m.pacts
  end
  local function cfg(key)
    local c = st().config
    if c[key] ~= nil then return c[key] end
    return DEFAULTS[key]
  end
  local function teams() return (mt() or {}).teams or {} end
  -- a contact either way between two teams (multiteam.lua's first[]: chart or shot, either direction)
  function M.contacted(a, b)
    local first = (mt() or {}).first or {}
    for _, k in ipairs({'chart ', 'shot '}) do
      if first[k .. a .. '>' .. b] or first[k .. b .. '>' .. a] then return true end
    end
    return false
  end
  function M.open_for(team)
    if not (mt() and teams()[team]) then return false end
    for other in pairs(teams()) do if other ~= team and M.contacted(team, other) then return true end end
    return false
  end
  local function fact(team, text, wake) if api.fact then api.fact(team, text, wake) end end
  local function both(p, text, wake) fact(p.a, text, wake); fact(p.b, text, wake) end
  local function other_of(p, team) return team == p.a and p.b or p.a end
  local function roster(reader,other) return api.roster and api.roster(reader,other) or {} end
  local function identity(team,name)
    for _,r in ipairs(roster(team,team)) do if r.name==name then return r end end
    return {name=name}
  end

  -- The terms in words (fact lines and the status line).
  local function terms_text(t)
    local parts = {}
    if t.cease_fire then parts[#parts+1] = 'cease-fire' end
    if t.shares then
      local s = {}
      for team, v in pairs(t.shares) do s[#s+1] = string.format('%s %.2f', team, v) end
      table.sort(s)
      parts[#parts+1] = 'shares ' .. table.concat(s, ' / ')
    end
    for _, o in ipairs(t.obligations or {}) do
      if o.kind == 'deliver' then parts[#parts+1] = string.format('%s delivers %d %s an hour', o.who, o.count, o.item)
      elseif o.kind == 'keep_out' then parts[#parts+1] = string.format('%s builds nothing within %d of (%d,%d)', o.who, o.r, math.floor(o.x), math.floor(o.y))
      elseif o.kind == 'no_attack' then parts[#parts+1] = string.format('%s hits nothing of %s', o.who, o.target) end
    end
    return #parts > 0 and table.concat(parts, '; ') or 'no terms'
  end

  -- Arguments: the terms checked against the two teams and the settings.
  local function check_terms(t, a, b)
    assert(type(t) == 'table', 'terms: {cease_fire?, shares?, obligations?}')
    local on = cfg('terms')
    local out = {}
    assert(t.depot==nil,'depot retired; call describe {} for offer at the Trading Post')
    for k in pairs(t) do assert(on[k], 'terms: no ' .. tostring(k) .. ' (cease_fire, shares, obligations)') end
    if t.cease_fire ~= nil then assert(type(t.cease_fire) == 'boolean', 'cease_fire: true or false'); out.cease_fire = t.cease_fire or nil end
    if t.shares ~= nil then
      assert(type(t.shares) == 'table', 'shares: {TEAM=fraction} for both teams, summing to 1')
      local sa, sb = tonumber(t.shares[a]), tonumber(t.shares[b])
      local n = 0
      for _ in pairs(t.shares) do n = n + 1 end
      assert(n == 2 and sa and sb and sa >= 0 and sb >= 0 and math.abs(sa + sb - 1) < 1e-6, 'shares: both teams, ' .. a .. ' and ' .. b .. ', summing to 1')
      -- a share is at most share_max_score / N of the allied total (N members x 1.0): two teams, 0.70
      local most = M.share_max(2)
      assert(sa <= most + 1e-9 and sb <= most + 1e-9, string.format('shares: at most %.2f each (no allied score above %.2f, below the solo edge 1.5)', most, cfg('share_max_score')))
      out.shares = {[a]=sa, [b]=sb}
    end
    if t.obligations ~= nil then
      assert(type(t.obligations) == 'table' and #t.obligations <= 6, 'obligations: a list of at most 6')
      out.obligations = {}
      for i, o in ipairs(t.obligations) do
        assert(type(o) == 'table' and KINDS[o.kind], 'obligation ' .. i .. ': kind deliver, keep_out or no_attack')
        assert(o.who == a or o.who == b, 'obligation ' .. i .. ': who is ' .. a .. ' or ' .. b)
        local r = {id=i, who=o.who, kind=o.kind}
        if o.kind == 'deliver' then
          assert(type(o.item) == 'string' and prototypes.item[o.item], 'obligation ' .. i .. ': item, an item name')
          r.item, r.count = o.item, math.floor(tonumber(o.count) or 0)
          assert(r.count >= 1, 'obligation ' .. i .. ': count, 1 or more an hour')
        elseif o.kind == 'keep_out' then
          r.x, r.y, r.r = tonumber(o.x), tonumber(o.y), tonumber(o.r)
          assert(r.x and r.y and r.r and r.r >= 1 and r.r <= 500, 'obligation ' .. i .. ': x, y and r (1..500)')
          r.surface = o.surface or 'nauvis'
        else
          r.target = o.target
          assert(teams()[r.target] and r.target ~= o.who, 'obligation ' .. i .. ': target, another team')
          assert((r.target==a or M.contacted(a,r.target)) and (r.target==b or M.contacted(b,r.target)),
            'obligation target unavailable to both parties')
        end
        out.obligations[i] = r
      end
    end
    return out
  end

  local function caller(p)
    local team = api.team_now()
    assert(teams()[team], 'pacts are between teams')
    assert(M.open_for(team), 'no contact with another team yet')
    return team, api.who and api.who(p) or 'operator'
  end
  local function pact(id, team)
    local p = st().by_id[tonumber(id) or -1]
    assert(p and (p.a == team or p.b == team), 'no pact #' .. tostring(id) .. ' of ours')
    return p
  end

  -- An explicit channel between contacted teams. Ordinary say/tell/board remain private.
  -- Each pair has its own cursor: reading one conversation reveals no other pair's traffic.
  local function conversation(team, other)
    assert(type(other)=='string' and teams()[other] and other~=team, 'with/to: another contacted team')
    assert(M.contacted(team,other), 'no contact with '..other..' yet')
    local s=st()
    s.diplomacy=s.diplomacy or {}
    local key=team<other and team..'>'..other or other..'>'..team
    s.diplomacy[key]=s.diplomacy[key] or {next=1,messages={}}
    return s.diplomacy[key]
  end
  function M.send(team, who, a)
    local c=conversation(team,a.to)
    assert(type(a.text)=='string' and #a.text<=500 and a.text:find('%S'), 'text: 1..500 bytes, not blank')
    local text=a.text:gsub('%s+',' '):match('^%s*(.-)%s*$')
    local s=st();s.diplomacy_sent=s.diplomacy_sent or {}
    local recent={}
    for _,tick in ipairs(s.diplomacy_sent[team] or {}) do
      if game.tick-tick<3600 then recent[#recent+1]=tick end
    end
    assert(#recent<6,'diplomacy rate limit: six messages per team per game minute; wait before sending again')
    recent[#recent+1]=game.tick;s.diplomacy_sent[team]=recent
    local author=identity(team,who)
    local m={kind='diplomacy',seq=c.next,tick=game.tick,from_team=team,to_team=a.to,agent=who,identity=author,text=text}
    c.next=c.next+1;c.messages[#c.messages+1]=m
    if api.on_message then api.on_message(m) end
    while #c.messages>100 do table.remove(c.messages,1) end
    local shown=author.display_name or who
    if author.model then shown=shown..' · '..author.model end
    local line='Diplomacy '..team..' ('..shown..') -> '..a.to..': '..text
    fact(team,line,false);fact(a.to,line,true)
    return {message=m,delivered_to={team,a.to},note='Every agent of these two teams receives this message. Ordinary say/tell/board are private to your team.'}
  end
  function M.messages(team,a)
    local c=conversation(team,a.with)
    local since,limit=a.since or 0,a.limit or 20
    assert(type(since)=='number' and since>=0 and since==math.floor(since),'since: a nonnegative message sequence')
    assert(type(limit)=='number' and limit>=1 and limit<=50 and limit==math.floor(limit),'limit: 1..50')
    local out={}
    for _,m in ipairs(c.messages) do if m.seq>since then out[#out+1]=m end end
    while #out>limit do table.remove(out,1) end
    return {with=a.with,agents=roster(team,a.with),messages=out,last_seq=c.next-1,tick=game.tick,
      note='Only this conversation. To negotiate with the other team, use diplomacy_send; say/tell/board stay within your own team.'}
  end

  function M.propose(team, who, a, replaces)
    local with = a.with
    assert(type(with) == 'string' and teams()[with] and with ~= team, 'with: another team')
    assert(M.contacted(team, with), 'no contact with ' .. with .. ' yet')
    local s = st()
    local n = 0
    for _, q in pairs(s.by_id) do if q.status == 'proposed' or q.status == 'active' then n = n + 1 end end
    assert(n < MAX_PACTS, 'too many open pacts')
    if not replaces then
      for _, q in pairs(s.by_id) do
        if q.status == 'active' and ((q.a == team and q.b == with) or (q.b == team and q.a == with)) then
          error('pact #' .. q.id .. ' with ' .. with .. ' holds: pact_amend replaces it', 0)
        end
      end
    end
    local terms = check_terms(a.terms or {}, team, with)
    local note = a.note and tostring(a.note):sub(1, NOTE) or nil
    local id = s.next
    s.next = id + 1
    local exp = math.floor((tonumber(a.expires_min) or cfg('expires_min')) * 3600)
    local p = {id=id, a=team, b=with, status='proposed', terms=terms, note=note, replaces=replaces,
      proposed_by={team=team, agent=who, tick=game.tick}, expires_tick=game.tick + math.max(3600, exp)}
    s.by_id[id] = p
    fact(with, string.format('%s proposes pact #%d%s: %s; it lapses at tick %d.%s', team, id, replaces and (' (to replace #' .. replaces .. ')') or '',
      terms_text(terms), p.expires_tick, note and (' Note: ' .. note) or ''), true)
    fact(team, string.format('our pact #%d proposed to %s: %s', id, with, terms_text(terms)))
    return {pact=M.view(p)}
  end

  function M.accept(team, who, a)
    local p = pact(a.id, team)
    assert(p.status == 'proposed', 'pact #' .. p.id .. ' is ' .. p.status)
    assert(p.b == team, 'pact #' .. p.id .. ' was proposed by us: the other team accepts it')
    local old = p.replaces and st().by_id[p.replaces]
    assert(not p.replaces or (old and old.status == 'active'), 'the pact this amendment replaces is no longer active')
    for _, q in pairs(st().by_id) do
      if q ~= old and q.status == 'active' and ((q.a == p.a and q.b == p.b) or (q.a == p.b and q.b == p.a)) then
        error('pact #' .. q.id .. ' already holds: withdraw this duplicate proposal and use pact_amend', 0)
      end
    end
    if p.replaces then
      if old and old.status == 'active' then
        M.finish(old, team, who, 'replaced by #' .. p.id, true)
        if p.terms.cease_fire then old.lift_tick = nil end   -- the new pact's cease-fire goes on: nothing lifts
      end
    end
    p.status, p.accepted_by = 'active', {team=team, agent=who, tick=game.tick}
    if p.terms.cease_fire then
      local fa, fb = game.forces[p.a], game.forces[p.b]
      fa.set_cease_fire(fb, true); fb.set_cease_fire(fa, true)
    end
    p.ledger = {}
    if M.market then M.market.capture_sides() end
    p.checks = {}
    p.next_check = game.tick + cfg('check_s') * 60
    both(p, string.format('pact #%d between %s and %s holds from tick %d: %s', p.id, p.a, p.b, game.tick, terms_text(p.terms)), true)
    return {pact=M.view(p)}
  end

  -- Ending: the record at once; the engine cease-fire lifts end_notice_s later (M.tick); market orders are independent.
  local lift   -- below: the cease-fire back as the pact found it
  function M.finish(p, team, who, note, quiet)
    if M.market then M.market.capture_sides() end
    p.status = 'ended'
    p.ended = {team=team, agent=who, tick=game.tick, note=note and tostring(note):sub(1, NOTE) or nil}
    local notice = cfg('end_notice_s')
    if p.terms.cease_fire then p.lift_tick = game.tick + notice * 60 end
    if not quiet then
      both(p, string.format('%s ended pact #%d at tick %d%s%s', team, p.id, game.tick,
        p.lift_tick and (notice > 0 and string.format('; the cease-fire lifts at tick %d (%d s from now)', p.lift_tick, notice)
          or '; the cease-fire lifted now') or '',
        p.ended.note and ('. Note: ' .. p.ended.note) or ''), true)
    end
    if p.lift_tick and notice <= 0 then lift(p, true) end
  end

  lift = function(p, quiet)
    -- A fresh agreement can be accepted during the old pact's notice period.
    -- The old deadline must not turn that newer cease-fire back into war.
    for _,q in pairs(st().by_id) do
      if q.id~=p.id and q.status=='active' and q.terms.cease_fire
        and ((q.a==p.a and q.b==p.b) or (q.a==p.b and q.b==p.a)) then
        p.lift_tick,p.lifted_tick,p.lift_superseded_by=nil,game.tick,q.id
        if not quiet then both(p,string.format('the notice of pact #%d ended; pact #%d keeps the cease-fire',p.id,q.id),false) end
        return
      end
    end
    local fa, fb = game.forces[p.a], game.forces[p.b]
    -- teams are at war but by a pact (mt_setup): a lift is war both ways
    local prev = {ab=false, ba=false}
    -- a frozen human team keeps its cease-fire until it thaws, then puts back what it found: what the pact found
    local h = mt().humans
    if h and h.state == 'frozen' and h.prev and (h.team == p.a or h.team == p.b) then
      local other = h.team == p.a and p.b or p.a
      if h.prev[other] then
        h.prev[other] = h.team == p.a and {mine=prev.ab, theirs=prev.ba} or {mine=prev.ba, theirs=prev.ab}
      end
    else
      fa.set_cease_fire(fb, prev.ab); fb.set_cease_fire(fa, prev.ba)
    end
    p.lift_tick, p.lifted_tick = nil, game.tick
    if not quiet then both(p, string.format('the cease-fire of pact #%d lifted at tick %d', p.id, game.tick), false) end
  end

  -- Arrived market goods count toward delivery obligations by game hour, without a cut.
  local function hour() return math.floor(game.tick / 216000) end
  local function count_to(p, key, team, item, n)
    local h = hour()
    p.ledger[h] = p.ledger[h] or {}
    local l = p.ledger[h]
    l[key] = l[key] or {}
    l[key][team] = l[key][team] or {}
    l[key][team][item] = (l[key][team][item] or 0) + n
    for k in pairs(p.ledger) do if k < h - 24 then p.ledger[k] = nil end end
  end
  -- Obligations: measured each check_s and reported as facts to both teams when short or broken.
  local function check(p)
    local period = cfg('check_s') * 60
    for _, o in ipairs(p.terms.obligations or {}) do
      local line
      if o.kind == 'deliver' then
        local got = 0
        local h = math.floor((game.tick - 1) / 216000)
        -- arrived at the other team in the period: the ledger's hours that overlap it
        for k, l in pairs(p.ledger or {}) do
          if k * 216000 + 216000 > game.tick - period and l.received then
            got = got + ((l.received[other_of(p, o.who)] or {})[o.item] or 0)
          end
        end
        local due = math.floor(o.count * cfg('check_s') / 3600 + 0.5)
        p.checks[o.id] = {tick=game.tick, got=got, due=due}
        if got < due then line = string.format('pact #%d: %s delivered %d of %d %s in the %d s to tick %d', p.id, o.who, got, due, o.item, cfg('check_s'), game.tick) end
      elseif o.kind == 'keep_out' then
        local surface = game.get_surface(o.surface)
        local n = surface and surface.count_entities_filtered{position={o.x, o.y}, radius=o.r, force=o.who} or 0
        p.checks[o.id] = {tick=game.tick, buildings=n}
        if n > 0 then line = string.format('pact #%d: %s has %d entities within %d of (%d,%d)', p.id, o.who, n, o.r, math.floor(o.x), math.floor(o.y)) end
      else
        local t = st().hits[o.who .. '>' .. o.target]
        p.checks[o.id] = {tick=game.tick, last_hit=t}
        if t and t > game.tick - period then line = string.format('pact #%d: %s hit an entity of %s at tick %d', p.id, o.who, o.target, t) end
      end
      if line then both(p, line, false) end
    end
  end

  -- (mt301) a team's active pacts now: the partner, cease-fire and shares
  function M.active_with(team)
    local active = {}
    for _, p in pairs(st().by_id) do
      if p.status == 'active' and (p.a == team or p.b == team) then
        active[#active+1] = {id=p.id, with=other_of(p, team), cease_fire=p.terms.cease_fire, shares=p.terms.shares}
      end
    end
    table.sort(active, function(x, y) return x.id < y.id end)
    return active
  end
  -- Departures: a team's platform leaving a planet's orbit, with the team's active pacts then (the scoring reads the
  -- edge-run platform's last one).
  local function departures()
    local s = st()
    for team in pairs(teams()) do
      local f = game.forces[team]
      for _, pl in pairs(f and f.platforms or {}) do
        if pl.valid then
          local at = pl.space_location and pl.space_location.name or nil
          local key = pl.index
          local was = s.platforms[key]
          if was and was ~= '' and at == nil and prototypes.space_location[was] and prototypes.space_location[was].type == 'planet' then
            local rec = {team=team, platform=pl.name, from=was, tick=game.tick, pacts=M.active_with(team)}
            s.departures[#s.departures+1] = rec
            if #s.departures > MAX_DEPARTURES then table.remove(s.departures, 1) end
            -- (mt301) each platform's last departure from a planet, kept past the list's 50 (multiteam.lua's scoring)
            s.last_departure = s.last_departure or {}
            s.last_departure[team .. '/' .. tostring(key)] = rec
          end
          s.platforms[key] = at or ''
        end
      end
    end
  end

  M.departures_now = function() return departures() end
  function M.last_departure(team, index)
    local s = mt() and mt().pacts
    return s and s.last_departure and s.last_departure[team .. '/' .. tostring(index)] or nil
  end
  function M.tick(tick)
    local s = mt() and mt().pacts
    if not s then return end
    s=st()
    if tick % 60 == 29 then
      for _, p in pairs(s.by_id) do
        if p.status == 'proposed' and tick >= p.expires_tick then
          p.status = 'expired'
          both(p, string.format('pact #%d proposed by %s lapsed unanswered at tick %d', p.id, p.a, tick), false)
        elseif p.lift_tick and tick >= p.lift_tick then lift(p)
        elseif p.status == 'active' and p.next_check and tick >= p.next_check then
          p.next_check = tick + cfg('check_s') * 60
          check(p)
        end
      end
    end
    if tick % 600 == 37 then departures() end
  end

  function M.on_damaged(event)
    local s = mt() and mt().pacts
    if not s then return end
    local by, e = event.force, event.entity
    if by and e and e.valid and by.name ~= e.force.name and teams()[by.name] and teams()[e.force.name] then
      s.hits[by.name .. '>' .. e.force.name] = game.tick
    end
  end

  -- The scoring's allied edge (docs/mt-diplomacy.md): 1.0 x the N members split by shares (none: even). Shares are
  -- bounded when proposed (share_max): no member above share_max_score, so no team-up pays more than winning alone.
  function M.share_max(n) return cfg('share_max_score') / n end
  function M.allied_scores(shares, members)
    local n, out = #members, {}
    for _, t in ipairs(members) do out[t] = n * ((shares and shares[t]) or (1 / n)) end
    return out
  end

  -- A pact as an agent reads it.
  function M.view(p)
    local v = {id=p.id, a=p.a, b=p.b, status=p.status, terms=terms_text(p.terms), note=p.note, proposed_tick=p.proposed_by.tick,
      expires_tick=p.status == 'proposed' and p.expires_tick or nil, accepted_tick=p.accepted_by and p.accepted_by.tick or nil,
      ended_tick=p.ended and p.ended.tick or nil, ended_by=p.ended and p.ended.team or nil, lift_tick=p.lift_tick, replaces=p.replaces}
    v.parties={{team=p.a,agents=roster(p.a,p.a)},{team=p.b,agents=roster(p.a,p.b)}}
    if p.ledger then
      local h = p.ledger[hour()]
      if h then v.this_hour = h end
    end
    if p.checks and next(p.checks) then v.checks = p.checks end
    return v
  end
  local function list(team)
    local out = {}
    for _, p in pairs(st().by_id) do if p.a == team or p.b == team then out[#out+1] = M.view(p) end end
    table.sort(out, function(x, y) return x.id > y.id end)
    return out
  end

  M.handlers = {
    diplomacy_send=function(p,a) local team,who=caller(p);return M.send(team,who,a) end,
    diplomacy=function(p,a) local team=caller(p);return M.messages(team,a) end,
    pact_propose=function(p, a) local team, who = caller(p); return M.propose(team, who, a or {}) end,
    pact_accept=function(p, a) local team, who = caller(p); return M.accept(team, who, a or {}) end,
    pact_decline=function(p, a)
      local team, who = caller(p)
      local q = pact((a or {}).id, team)
      assert(q.status == 'proposed' and q.b == team, 'pact #' .. q.id .. ': only an open proposal to us')
      q.status, q.ended = 'declined', {team=team, agent=who, tick=game.tick, note=a.note and tostring(a.note):sub(1, NOTE) or nil}
      both(q, string.format('%s declined pact #%d%s', team, q.id, q.ended.note and ('. Note: ' .. q.ended.note) or ''), false)
      return {pact=M.view(q)}
    end,
    pact_withdraw=function(p, a)
      local team, who = caller(p)
      local q = pact((a or {}).id, team)
      assert(q.status == 'proposed' and q.a == team, 'pact #' .. q.id .. ': only our own open proposal')
      q.status, q.ended = 'withdrawn', {team=team, agent=who, tick=game.tick}
      both(q, string.format('%s withdrew its proposal #%d', team, q.id), false)
      return {pact=M.view(q)}
    end,
    pact_amend=function(p, a)
      local team, who = caller(p)
      local q = pact((a or {}).id, team)
      assert(q.status == 'active', 'pact #' .. q.id .. ' is ' .. q.status .. ': only an active pact is amended')
      return M.propose(team, who, {with=other_of(q, team), terms=a.terms, note=a.note, expires_min=a.expires_min}, q.id)
    end,
    pact_end=function(p, a)
      local team, who = caller(p)
      local q = pact((a or {}).id, team)
      assert(q.status == 'active', 'pact #' .. q.id .. ' is ' .. q.status)
      M.finish(q, team, who, (a or {}).note)
      return {pact=M.view(q)}
    end,
    pacts=function(p, a)
      local team=caller(p);local contacts={}
      for other in pairs(teams()) do if other~=team and M.contacted(team,other) then contacts[#contacts+1]=other end end
      table.sort(contacts)
      local counterparties={};for _,other in ipairs(contacts) do counterparties[#counterparties+1]={team=other,agents=roster(team,other)} end
      return {pacts=list(team),contacts=contacts,counterparties=counterparties,tick=game.tick,end_notice_s=cfg('end_notice_s'),
        communication='say/tell/board are private to your team. Use diplomacy_send {to: TEAM, text: MESSAGE} to negotiate with a contacted team; diplomacy {with: TEAM} reads that conversation.'}
    end,
  }
  M.reads = {pacts=true,diplomacy=true}
  M.schema = {
    diplomacy_send={to='one contacted team; every agent of that team and your own team receives it',text='1..500 bytes; explicit cross-team negotiation, six messages per team per game minute',
      returns='message with authenticated sender, pair-local seq and game tick; ordinary say/tell/board remain private to your team'},
    diplomacy={with='one contacted team',since='optional nonnegative sequence from this conversation',limit='1..50, default 20; newest messages kept',
      returns='messages for your conversation with that team only, last_seq; no third-team conversations or private chat'},
    pact_propose={with='the other team (a team you have had contact with)', terms='{cease_fire?: true, shares?: {TEAM: fraction, both teams, summing to 1, each at most 0.70}, obligations?: [{kind: "deliver", who, item, count (an hour, arrived through the Trading Post)}, {kind: "keep_out", who, x, y, r, surface?}, {kind: "no_attack", who, target}]}',
      note='optional text, 500 bytes', expires_min='optional minutes it stays open (default 60)', returns='pact: its number, terms and status; the other team gets it as a fact line'},
    pact_accept={id='a pact proposed to your team', returns='pact; its terms hold from now (the cease-fire both ways)'},
    pact_decline={id='a pact proposed to your team', note='optional text', returns='pact'},
    pact_withdraw={id='your team\'s open proposal', returns='pact'},
    pact_amend={id='an active pact', terms='as pact_propose', note='optional text', expires_min='optional proposal lifetime in minutes', returns='pact: a new proposal that replaces it when accepted'},
    pact_end={id='an active pact', note='optional text', returns='pact ends; market orders are separate; cease-fire lifts at lift_tick if a notice is configured (pacts reports end_notice_s), otherwise immediately'},
    pacts={returns='pacts: your team\'s pacts and proposals, with this hour\'s delivered-goods ledger and the obligations\' last measurements'},
  }
  -- Describe's general argument cache can have been built before first contact. Check these
  -- dynamic actions here as well, after the contact gate, without exposing their schemas early.
  for name,fn in pairs(M.handlers) do
    M.handlers[name]=function(p,a)
      caller(p)
      a=a or {};assert(type(a)=='table','arguments: one object')
      for key in pairs(a) do assert(key~='returns' and M.schema[name][key]~=nil,'unknown argument '..tostring(key)..' for '..name) end
      return fn(p,a)
    end
  end
  -- describe: the pact actions for a team with a contact only (none before: nothing says other teams exist)
  function M.describe_into(actions)
    if M.open_for(api.team_now()) then for name, schema in pairs(M.schema) do actions[name] = schema end end
  end

  -- The human team through chat: "!pact ACTION {json}", run as its team; the reply in the team's console.
  function M.on_console_chat(event)
    local h = mt() and mt().humans
    local pl = event.player_index and game.get_player(event.player_index)
    if not (h and pl and h.players[pl.name] and pl.force.name == h.team) then return end
    local action, rest = (event.message or ''):match('^!pact%s+([%w_]+)%s*(.*)$')
    if not action then return end
    local name = action=='message' and 'diplomacy_send' or action=='messages' and 'diplomacy'
      or action:match('^pact') and action or (action == 'list' and 'pacts' or 'pact_' .. action)
    local fn = M.handlers[name]
    local ok, r = pcall(function()
      assert(fn, 'no pact action ' .. action .. ' (propose, accept, decline, withdraw, amend, end, list, message, messages)')
      local args = rest ~= '' and helpers.json_to_table(rest) or {}
      assert(type(args) == 'table', 'arguments: one JSON object')
      return api.as_team(h.team, function() return fn(pl, args) end)
    end)
    pl.force.print('[pact] ' .. (ok and helpers.table_to_json(r) or ('refused: ' .. tostring(r):gsub('^[^:]*:%d+: ', ''))))
  end

  function M.operator.mt_pacts(a)
    local s = st()
    if type(a.config) == 'table' then
      for k, v in pairs(a.config) do
        assert(DEFAULTS[k] ~= nil, 'config: ' .. tostring(k) .. ' is no setting')
        if k=='terms' then
          assert(type(v)=='table','terms settings: a table')
          for name,on in pairs(v) do assert(DEFAULTS.terms[name] and type(on)=='boolean','unknown pact term setting') end
        end
        s.config[k] = v
      end
    end
    local all = {}
    for _, p in pairs(s.by_id) do
      local v = M.view(p)
      if p.status == 'active' and p.terms.cease_fire then v.allied_edge = M.allied_scores(p.terms.shares, {p.a, p.b}) end
      all[#all+1] = v
    end
    table.sort(all, function(x, y) return x.id > y.id end)
    local c = {}
    for k in pairs(DEFAULTS) do c[k] = cfg(k) end
    return {config=c, pacts=all, departures=s.departures}
  end
  function M.operator.mt_pacts_tick(a)
    local ticks = math.floor(tonumber(a.ticks) or 1)
    for i = 0, ticks - 1 do M.tick(a.as_tick and (a.as_tick + i) or game.tick) end
    return {tick=game.tick}
  end
  function M.operator.mt_diplomacy(a)
    local out={}
    for _,c in pairs(st().diplomacy or {}) do for _,m in ipairs(c.messages) do out[#out+1]=m end end
    table.sort(out,function(a,b) if a.tick~=b.tick then return a.tick<b.tick end
      if a.from_team~=b.from_team then return a.from_team<b.from_team end return a.seq<b.seq end)
    while #out>100 do table.remove(out,1) end
    return {messages=out}
  end
  -- mt296: the market factory lives beside pacts so the deployed harness needs no new require.
  -- Only stateless normal items cross this boundary. Cargo is persistent escrow, never an exposed chest.
  M.market = (function()
    local K={handlers={},reads={market=true},operator={}}
    local TECH,POST,COIN='mt-coinage','mt-trading-post','mt-coin'
    local PRICES={['iron-ore']=10,['copper-ore']=10,coal=10,stone=10,['iron-plate']=20,['copper-plate']=20,
      ['steel-plate']=100,['iron-gear-wheel']=40,['copper-cable']=10,['electronic-circuit']=70,
      ['advanced-circuit']=260,['processing-unit']=1400,['plastic-bar']=30,sulfur=30,battery=80,
      ['engine-unit']=180,explosives=20,['pipe']=20,['iron-stick']=10,['stone-brick']=20,
      ['solid-fuel']=20,['electric-engine-unit']=350,['flying-robot-frame']=820,
      ['low-density-structure']=750,['rocket-fuel']=220}
    -- Nominal base-recipe costs on the existing ore=10/plate=20 cards; see docs/mt-markets.md.
    -- Science tools have value for research accounting, but are not stateless market cargo.
    local SCIENCE={['automation-science-pack']=60,['logistic-science-pack']=160,
      ['military-science-pack']=275,['chemical-science-pack']=585,
      ['production-science-pack']=5950/3,['utility-science-pack']=5870/3,['space-science-pack']=12,
      ['metallurgic-science-pack']=712,['electromagnetic-science-pack']=1001,
      ['agricultural-science-pack']=124.6875,['cryogenic-science-pack']=86.872,['promethium-science-pack']=201.552}
    for name,value in pairs(SCIENCE) do PRICES[name]=value end
    local TIERS={['steel-plate']='logistic-science-pack',['advanced-circuit']='chemical-science-pack',
      ['plastic-bar']='chemical-science-pack',sulfur='chemical-science-pack',battery='chemical-science-pack',
      ['engine-unit']='chemical-science-pack',explosives='chemical-science-pack',['processing-unit']='chemical-science-pack',
      ['solid-fuel']='chemical-science-pack',['electric-engine-unit']='chemical-science-pack',
      ['flying-robot-frame']='chemical-science-pack',['low-density-structure']='chemical-science-pack',
      ['rocket-fuel']='chemical-science-pack'}
    -- raid_share: the part of the wallet a destroyed home Post spills (design v3: 25%). wreck: spilled coin goes into a
    -- coin wreck (a character corpse: robots and inserters cannot reach it; any team's character loots it with mine)
    -- instead of items on the ground. Off by default: prepared-base fixtures keep ground spills; the full game's
    -- profile (PROFILES.full) turns it on.
    local CFG={enabled=true,transit_ticks=5400,batch_ticks=600,pair_stacks=10,freight_stacks=20,destructible=false,raid_share=0.25,wreck=false,
      research_enabled=true,growth_coin_per_rate=5,level_rate=0.001,
      grants={['mt-coinage']=10000,['logistic-science-pack']=5000,['chemical-science-pack']=5000,
        ['production-science-pack']=5000,['utility-science-pack']=5000,['space-science-pack']=10000,
        ['metallurgic-science-pack']=5000,['electromagnetic-science-pack']=5000,
        ['agricultural-science-pack']=5000,['cryogenic-science-pack']=5000}}
    -- (mt302) A full game's market in one call: mt_market {profile="full"} (tools/mt/start-mt.sh in POG_RUN_MODE=full).
    -- Home Posts can be destroyed (25% of the wallet spills into a coin wreck), the tier grants at their defaults,
    -- research income on. The pact settings stay at pacts.lua's DEFAULTS; the reply shows them.
    local PROFILES={full={destructible=true,raid_share=0.25,wreck=true,research_enabled=true,enabled=true}}
    local function copy(v)
      if type(v)~='table' then return v end
      local r={} for k,x in pairs(v) do r[k]=copy(x) end return r
    end
    local function state()
      local m=mt();assert(m,'unsupported action; call describe {}')
      m.market=m.market or {teams={},pairs={},requests={},issuance=0,physical=0,spills={}}
      return m.market
    end
    local function config(k)
      local s=mt() and mt().market
      if s and s.config and s.config[k]~=nil then return s.config[k] end
      -- Saved prepared-base fixtures used the old stipend switch. Preserve their opt-out on upgrade.
      if k=='research_enabled' and s and s.config and s.config.growth_enabled==false then return false end
      return CFG[k]
    end
    local function contacts(t)
      local r={}
      for _,u in ipairs((mt() or {}).order or {}) do if t~=u and M.contacted(t,u) then r[#r+1]=u end end
      return r
    end
    function K.contact_count(t) return #contacts(t) end
    function K.rung(t)
      if not config('enabled') or not M.open_for(t) then return 0 end
      local f=game.forces[t];local tech=f and f.technologies[TECH]
      return tech and tech.enabled and tech.researched and 2 or 1
    end
    local function team(t)
      local s=state()
      s.teams[t]=s.teams[t] or {wallet=0,reserved=0,orders={},next=1,granted=false,spills={}}
      return s.teams[t]
    end
    local function metrics(t)
      local s=team(t);s.metrics=s.metrics or {buy_attempts=0,buy_short=0,fills=0,reference_fills=0,trade_coin=0,
        losses={buyer=0,seller=0,third_party=0,unattributed=0,shared=0},destroyed=0}
      return s.metrics
    end
    local function keys(t) local r={} for k in pairs(t) do r[#r+1]=k end table.sort(r) return r end
    local function pair(a,b)
      local key=a<b and a..'>'..b or b..'>'..a
      local s=state()
      s.pairs[key]=s.pairs[key] or {a=a,b=b,next=1,book_next=1,book_ids={},filled_by_order={},transactions={},pending={},usage={}}
      return s.pairs[key]
    end
    local function post(t,id)
      local s=team(t)
      return (id==nil or id==1) and s.post or (s.posts or {})[id]
    end
    local function inv(t,id)
      local p=post(t,id)
      return p and p.valid and p.get_inventory(defines.inventory.chest) or nil
    end
    local function amount(t,item,id)
      local i=inv(t,id);return i and i.get_item_count{name=item,quality='normal'} or 0
    end
    local function frozen(t)
      local h=mt() and mt().humans
      return h and h.team==t and h.state=='frozen' or false
    end
    local function fail(msg,call) error(msg..'; call '..(call or 'status {}'),0) end
    local function news(t,u,kind,text,id)
      if api.on_market then api.on_market({kind=kind,a=t,b=u,id=id,tick=game.tick,text=text}) end
    end
    local function integer(n,lo,hi,label)
      if type(n)~='number' or n~=n or n<lo or n>hi or n~=math.floor(n) then fail(label..': integer '..lo..'..'..hi) end
      return n
    end
    local function researched(t,n)
      local f=game.forces[t];local tech=f and f.technologies[n]
      return tech and tech.researched or false
    end
    function K.freight(t) return K.rung(t)>0 and researched(t,'logistic-science-pack') end
    function K.orbital(t)
      local s=team(t)
      if not s.orbital then
        for _,p in pairs(game.forces[t].platforms or {}) do
          if p.valid and p.hub and p.hub.valid then s.orbital=true;break end
        end
      end
      return s.orbital==true
    end
    local function selected_post(t,id)
      id=id or 1
      if type(id)~='number' or id~=math.floor(id) or id<1 or not (post(t,id) and post(t,id).valid) then
        fail('Post unavailable','status {}')
      end
      return id
    end
    local function available(t,n) return PRICES[n] and not SCIENCE[n] and (not TIERS[n] or researched(t,TIERS[n])) end
    local function item(n,t)
      if type(n)~='string' or not PRICES[n] or SCIENCE[n] then fail('item unavailable; normal, stateless, nonspoiling reference items only') end
      if t and not available(t,n) then fail('item unavailable at your researched tier') end
      local p=prototypes.item[n]
      if not p or (p.get_spoil_ticks and p.get_spoil_ticks() or p.spoil_ticks or 0)>0 then fail('item unavailable') end
      return n
    end
    local function counter(t,v)
      if v~=nil and (#contacts(t)<2 or type(v)~='string' or not teams()[v] or v==t or not M.contacted(t,v)) then
        fail('counterparty unavailable')
      end
      return v or '*'
    end
    local function order_key(side,itemname,other,id)
      return side..'/'..itemname..'/'..other..(id and id~=1 and ('/post/'..id) or '')
    end
    local function can_pair(o,other) return o.status=='open' and (o.other=='*' or o.other==other) end
    local function order_view(o)
      return {id=o.id,side=o.side,item=o.item,price=o.price,keep=o.keep,count=o.count,matched=o.matched,
        remaining=o.count-o.matched,status=o.status,revision=o.revision,created_tick=o.tick,give=copy(o.give),get=copy(o.get),post=o.post}
    end
    local function cancel_order(t,o,reason)
      if o.status~='open' then return end
      if o.side=='buy' then team(t).reserved=team(t).reserved-(o.count-o.matched)*o.price end
      o.status='cancelled';o.revision=o.revision+1;o.ended_tick=game.tick;o.reason=reason
    end
    local function pay(t,id,n,cause,tiers)
      local s=team(t);s.payments=s.payments or {};s.grants=s.grants or {}
      if s.payments[id] then return end
      s.payments[id]={amount=n,cause=cause,tick=game.tick,tiers=tiers}
      for _,name in ipairs(tiers or {}) do s.grants[name]=id end
      s.wallet=s.wallet+n;state().issuance=state().issuance+n
      local line='Wallet +'..n..' coin: '..cause..'; this does not depend on when you research it.'
      fact(t,line,true);news(t,nil,'coinage',line)
    end
    local function grants(t)
      local s=team(t)
      if not researched(t,TECH) then return end
      -- Old saves already received the original Coinage grant. Never issue it again.
      if not s.grants then s.grants={};if s.granted then s.grants[TECH]='legacy-coinage' end end
      local pending,causes,n={},{},0
      for _,name in ipairs(keys(config('grants'))) do
        if researched(t,name) and not s.grants[name] then
          pending[#pending+1]=name;causes[#causes+1]=name==TECH and 'Coinage' or name:gsub('%-',' ')
          n=n+config('grants')[name]
        end
      end
      if #pending>0 then
        local id='research:'..(not s.grants[TECH] and TECH or table.concat(pending,'+'))
        pay(t,id,n,table.concat(causes,' + '),pending)
      end
      s.granted=true
    end
    -- Persist only numbers/tables. Own technologies include saved partial progress, so changing/cancelling the
    -- queue cannot repay work. A level cursor bounds storage even for infinite research. No production statistics.
    local function research_sample(t,r,baseline,scripted)
      local f=game.forces[t];local current=f.current_research;local value=0
      for _,name in ipairs(keys(f.technologies)) do
        local tech=f.technologies[name];local level=tech.level or 1
        local progress=tech.researched and 1 or
          (current and current.name==name and (f.research_progress or 0) or (tech.saved_progress or 0))
        local prior=r.seen[name]
        local unit_value=0
        for _,ing in ipairs(tech.research_unit_ingredients or {}) do
          assert(SCIENCE[ing.name], 'research pack has no reference price: '..ing.name)
          unit_value=unit_value+SCIENCE[ing.name]*ing.amount
        end
        if not baseline and name~=scripted and unit_value>0 then
          local old_level=prior and prior.level or (tech.prototype and tech.prototype.level or 1)
          local old_progress=prior and prior.progress or 0
          if level>=old_level then
            for l=old_level,level do
              local delta=(l<level and 1 or progress)-(l==old_level and old_progress or 0)
              if delta>0 then
                local count=l==level and tech.research_unit_count or api.research_units(tech,l)
                value=value+delta*count*unit_value
              end
            end
          end
        end
        -- Reversing research cannot lower its paid watermark.
        if not prior or level>prior.level then r.seen[name]={level=level,progress=progress}
        elseif level==prior.level then prior.progress=math.max(prior.progress,progress) end
      end
      return value
    end
    -- Compensated sums keep thousands of tiny progress increments/expirations from stranding whole coin.
    local function research_add(r,key,value)
      r.correction=r.correction or {}
      local adjusted=value-(r.correction[key] or 0)
      local sum=r[key]+adjusted
      r.correction[key]=(sum-r[key])-adjusted;r[key]=sum
    end
    local function research_income(t,scripted)
      local s=team(t);local r=s.research_income
      local active=config('research_enabled') and researched(t,TECH)
      if not r then
        r={seen={},window={},first=1,last=0,window_value=0,high_rate=0,value=0,
          growth=0,level=0,paid=0,remainder=0,hour=math.floor(game.tick/216000),hour_coin=0}
        s.research_income=r
      end
      local baseline=not r.active or not active
      local value=research_sample(t,r,baseline,scripted)
      r.active=active
      if not active then r.window={};r.first=1;r.last=0;r.window_value=0;if r.correction then r.correction.window_value=0 end end
      -- Flush the previous game hour before adding this sample. Zero-income hours remain a single fact too.
      local hour=math.floor(game.tick/216000)
      if hour>r.hour then
        if active or r.hour_coin>0 then
          local line='Wallet +'..r.hour_coin..' coin: research income this hour'
          fact(t,line,false);news(t,nil,'research_income',line)
        end
        r.hour=hour;r.hour_coin=0
      end
      if not active then return end
      while r.first<=r.last and r.window[r.first].tick<=game.tick-432000 do
        research_add(r,'window_value',-r.window[r.first].value)
        r.window[r.first]=nil;r.first=r.first+1
      end
      if r.first>4096 then
        local window={};for i=r.first,r.last do window[#window+1]=r.window[i] end
        r.window=window;r.first=1;r.last=#window
      end
      if value>0 then
        local tail=r.window[r.last]
        if tail and tail.tick==game.tick then tail.value=tail.value+value
        else r.last=r.last+1;r.window[r.last]={tick=game.tick,value=value} end
        research_add(r,'window_value',value);research_add(r,'value',value)
      end
      if r.first>r.last then r.window_value=0 end
      -- Full 120-minute denominator from startup: a stockpile burst never receives a short-window windfall.
      local rate=math.max(0,r.window_value)/120
      local growth=math.max(0,rate-r.high_rate)*config('growth_coin_per_rate')
      r.high_rate=math.max(r.high_rate,rate);r.rate=rate
      local level=value*config('level_rate')
      research_add(r,'growth',growth);research_add(r,'level',level)
      local due=r.growth+r.level-r.paid
      -- Tiny floating point noise at an integer must not strand a coin; retain the signed residual.
      local coin=math.floor(due+1e-9);r.remainder=due-coin
      r.paid=r.paid+coin;r.hour_coin=r.hour_coin+coin
      s.wallet=s.wallet+coin;state().issuance=state().issuance+coin
    end
    -- First contact enables red science per force. Creation and grants never run during on_load.
    function K.sync(t,scripted)
      if K.rung(t)==0 or mt().market and mt().market.fault then return end
      local s=team(t);local f=game.forces[t];local tech=f.technologies[TECH]
      if tech then tech.enabled=true;tech.visible_when_disabled=false end
      if not (s.post and s.post.valid) then
        local home=(mt().spawns or {})[t] or {};local surf=game.get_surface('nauvis')
        local at=s.home or home.nauvis or f.get_spawn_position(surf)
        at={x=at.x or at[1],y=at.y or at[2]}
        local pos=surf.find_non_colliding_position(POST,{x=at.x+4,y=at.y},32,.5)
        if pos then
          s.post=assert(surf.create_entity{name=POST,position=pos,force=f},'Trading Post creation failed')
          s.post.minable_flag=false;s.post.destructible=config('destructible');s.home=s.home or copy(at)
          f.add_chart_tag(surf,{position=pos,text='Trading Post'})
          fact(t,'Trading Post at ('..pos.x..','..pos.y..'). Call status {} for stock and item swaps; research {technology="mt-coinage"} opens priced orders.',true)
        end
      end
      if s.post and s.post.valid then s.post.destructible=config('destructible') end
      for _,p in pairs(s.posts or {}) do if p.valid then p.minable_flag=false;p.destructible=config('destructible') end end
      K.orbital(t)
      grants(t)
      research_income(t,scripted)
    end
    function K.on_research_finished(event)
      local tech=event.research
      if tech and tech.force then K.sync(tech.force.name,event.by_script and tech.name or nil) end
    end
    local function canonical(v)
      if type(v)~='table' then return type(v)..':'..tostring(v) end
      local r={} for _,k in ipairs(keys(v)) do r[#r+1]=canonical(k)..'='..canonical(v[k]) end
      return '{'..table.concat(r,',')..'}'
    end
    -- Request receipts never expire. A different payload under a used id cannot mutate anything.
    local function request(t,action,a,fn)
      local id=K.human_request_id or (api.request_id and api.request_id())
      if type(id)~='string' or #id<1 or #id>200 then fail('request id required', 'describe {}') end
      local s=state();s.requests[t]=s.requests[t] or {};local journal=s.requests[t]
      local payload=canonical({action=action,args=a});local rec=journal[id]
      if type(rec)=='number' then   -- (mt301) a slimmed old receipt: committed at that tick, never run again
        return {committed=true,compacted=true,tick=rec,next={action='status',args={}},
          note='this request id already committed at tick '..rec..'; its receipt was compacted'}
      end
      if rec then
        if rec.payload~=payload then fail('request id already used with different arguments') end
        if rec.status=='committed' and rec.compacted then
          return {committed=true,compacted=true,tick=rec.tick,next={action='status',args={}},
            note='this request already committed at tick '..rec.tick..'; its full receipt was compacted'}
        end
        if rec.status=='committed' then return copy(rec.result) end
        error(rec.error or 'request quarantined; call status {}',0)
      end
      rec={payload=payload,status='started',tick=game.tick};journal[id]=rec
      -- (mt301) the ids in order, so old receipts can drop their full result (K.compact)
      s.request_order=s.request_order or {};s.request_order[t]=s.request_order[t] or {next=1,done=0}
      local ro=s.request_order[t];ro[ro.next]=id;ro.next=ro.next+1
      if action=='buy' then local m=metrics(t);m.buy_attempts=m.buy_attempts+1 end
      local ok,res=pcall(fn)
      if not ok then
        if action=='buy' then local m=metrics(t);m.buy_refusals=(m.buy_refusals or 0)+1 end
        rec.status='refused';rec.error=tostring(res);error(res,0)
      end
      rec.status='committed';rec.result=copy(res);return res
    end
    local function add_order(t,side,a)
      local post_id=selected_post(t,a.post)
      local name=item(side=='offer' and type(a.give)=='table' and a.give.item or a.item,t)
      local other=counter(t,side=='buy' and a.from or a.to)
      local n=side=='offer' and 1 or integer(a.count,1,100000,'count')
      local price,keep,give,get
      if side=='offer' then
        give={item=name,count=integer(a.give.count,1,10000,'give.count')}
        if type(a.get)~='table' then fail('get: {item,count}') end
        get={item=item(a.get.item,t),count=integer(a.get.count,1,10000,'get.count')}
        if get.item==name then fail('swap needs different items') end
        local cap=K.freight(t) and config('freight_stacks') or config('pair_stacks')
        if give.count/prototypes.item[give.item].stack_size+get.count/prototypes.item[get.item].stack_size>cap then
          fail('swap exceeds pair capacity; use smaller give/get counts')
        end
        for k in pairs(a.give) do if k~='item' and k~='count' then fail('give: only item,count') end end
        for k in pairs(a.get) do if k~='item' and k~='count' then fail('get: only item,count') end end
      else
        price=integer(a.price,math.ceil(PRICES[name]*.5),PRICES[name]*3,'price')
        if side=='sell' then keep=integer(a.keep,0,100000,'keep') end
      end
      local s=team(t);local key=order_key(side,name,other,post_id);local old=s.orders[key]
      if old and old.status=='open' then
        fail('a shared order already exists',string.format('cancel {"item":"%s","side":"%s","revision":%d%s}',name,side,old.revision,
          (other~='*' and (',"team":"'..other..'"') or '')..(post_id~=1 and (',"post":'..post_id) or '')))
      end
      if side=='buy' then
        local m=metrics(t)
        if n*price>s.wallet-s.reserved then m.buy_short=m.buy_short+1;fail('not enough coin; sell something or lower the count') end
      end
      local o={id=s.next,team=t,side=side,item=name,other=other,count=n,price=price,keep=keep,give=give,get=get,
        matched=0,status='open',revision=old and old.revision+1 or 1,tick=game.tick,post=post_id}
      s.next=s.next+1;s.orders[key]=o
      if side=='buy' then s.reserved=s.reserved+n*price end
      return {order=order_view(o),next={action='status',args={}}}
    end
    local function cancel(t,a)
      local name=item(a.item)
      if K.rung(t)==1 and a.side~='offer' then fail('side: offer') end
      if a.side~='buy' and a.side~='sell' and a.side~='offer' then fail('side: buy, sell or offer') end
      local other=counter(t,a.team);local o=team(t).orders[order_key(a.side,name,other,a.post)]
      if not o or o.status~='open' then fail('no unmatched live order') end
      if a.revision~=nil and a.revision~=o.revision then fail('order changed; read its current revision') end
      cancel_order(t,o,'cancel');return {order=order_view(o),note='Matched cargo still arrives; its payment remains committed.'}
    end
    -- (mt301) transactions stay sorted by id; compaction folds old delivered ones, so the index is no longer the id
    local function txget(p,id)
      local list=p.transactions;local x=list[id]
      if x and x.id==id then return x end
      local lo,hi=1,#list
      while lo<=hi do
        local mid=math.floor((lo+hi)/2);x=list[mid]
        if x.id==id then return x elseif x.id<id then lo=mid+1 else hi=mid-1 end
      end
      return nil
    end
    K.txget=txget
    local function book_id(p,o)
      local key=o.team..'/'..o.id
      if not p.book_ids[key] then p.book_ids[key]=p.book_next;p.book_next=p.book_next+1 end
      return p.book_ids[key]
    end
    local function accepting(t,o,remaining)
      local a,action
      if o.side=='offer' then action='offer';a={give=copy(o.get),get=copy(o.give)}
      elseif o.side=='sell' then
        local s=team(t);local n=math.min(remaining,math.floor((s.wallet-s.reserved)/o.price))
        if n<1 then return false end
        action='buy';a={item=o.item,price=o.price,count=n}
      else action='sell';a={item=o.item,price=o.price,count=remaining,keep=0} end
      if #contacts(t)>1 then a[action=='buy' and 'from' or 'to']=o.team end
      local peer=post(o.team,o.post);local ours=post(t)
      if peer and peer.valid and not (ours and ours.valid and ours.surface.index==peer.surface.index) then
        local id
        for _,n in ipairs(keys(team(t).posts or {})) do local e=post(t,n)
          if e.valid and e.surface.index==peer.surface.index then id=n;break end
        end
        if not id then return false,'no own Post on the settlement surface; designate a chest there with post {position}' end
        a.post=id
      end
      return {action=action,args=a}
    end
    function K.status(t)
      if K.rung(t)==0 then return nil end
      local s=team(t);local p=s.post
      local out={fault=state().fault and {state='quarantined',next={action='status',args={}}} or nil,
        rung=K.rung(t)==2 and 'coinage' or 'swap',post=p and p.valid and {position=copy(p.position),surface=p.surface.name} or false,
        stock={},orders={},offers={},inbound={},fills={},embargoed={},counterparties={},transit_seconds=config('transit_ticks')/60,pair_stacks_per_minute=config('pair_stacks')}
      if K.freight(t) then out.rung=K.orbital(t) and 'orbital' or 'freight';out.transit_seconds=nil;out.posts={}
        out.pair_stacks_per_minute=config('freight_stacks')
        local all={[1]=s.post};for id,e in pairs(s.posts or {}) do all[id]=e end
        for _,id in ipairs(keys(all)) do local e=all[id]
          if e and e.valid then
            local stock={};for _,n in ipairs(keys(PRICES)) do local count=amount(t,n,id);if available(t,n) and count>0 then stock[n]=count end end
            out.posts[#out.posts+1]={id=id,home=id==1,position=copy(e.position),surface=e.surface.name,stock=stock}
          end
        end
        for id,site in pairs(s.post_sites or {}) do if not (s.posts[id] and s.posts[id].valid) then
          out.posts[#out.posts+1]={id=id,available=false,surface=site.surface,position=copy(site.position),
            next={action='post',args={position=copy(site.position)}},note='Place an own chest at this site and designate it to restore committed deliveries.'}
        end end
      end
      if K.rung(t)==2 then
        out.wallet=s.wallet;out.reserved=s.reserved;out.available=s.wallet-s.reserved;out.reference_prices={}
        for n,price in pairs(PRICES) do if available(t,n) then out.reference_prices[n]=price end end
      end
      for _,n in ipairs(keys(PRICES)) do local nstock=amount(t,n);if available(t,n) and nstock>0 then out.stock[n]=nstock end end
      for _,key in ipairs(keys(s.orders)) do
        local o=s.orders[key];local row=order_view(o)
        if #contacts(t)>1 and o.other~='*' then row[o.side=='buy' and 'from' or 'to']=o.other end
        out.orders[#out.orders+1]=row
      end
      for _,u in ipairs(contacts(t)) do
        out.counterparties[#out.counterparties+1]={team=u,agents=roster(t,u)}
        local pairdata=pair(t,u);local us=state().teams[u]
        local blocked=pairdata.embargo and next(pairdata.embargo)~=nil
        if blocked then
          local r={by_us=pairdata.embargo[t]==true,by_counterparty=pairdata.embargo[u]==true}
          if #contacts(t)>1 then r.team=u end
          out.embargoed[#out.embargoed+1]=r
        end
        for _,key in ipairs(keys(us and us.orders or {})) do
          local o=us.orders[key]
          local remaining=o.count-(pairdata.filled_by_order[o.team..'/'..o.id] or 0)
          if o.status~='cancelled' and (o.other=='*' or o.other==t) and remaining>0 and (o.side=='offer' or K.rung(t)==2)
              and available(t,o.item) and (not o.get or available(t,o.get.item)) then
            -- No peer wallet, stock, global order id, rival coordinates, or unrelated fill count.
            local accept,why=accepting(t,o,remaining)
            local row={id=book_id(pairdata,o),side=o.side,item=o.item,price=o.price,give=copy(o.give),get=copy(o.get),accept=accept}
            row.agents=roster(t,u)
            if row.accept==false then row.blocked=why or 'not enough coin; sell something or lower the count';row.next={action='status',args={}} end
            if blocked then row.accept=false;row.blocked='new matches stopped by embargo';row.next={action='status',args={}} end
            if #contacts(t)>1 then row.team=u end
            out.offers[#out.offers+1]=row
          end
        end
        local recent=#pairdata.transactions-20
        for txi,tx in ipairs(pairdata.transactions) do
          local row={id=tx.id,state=tx.status,matched_tick=tx.tick,arrival_tick=not tx.freight and tx.eta or nil,price=tx.price,item=tx.item,count=tx.count}
          if tx.loss then
            local shown_side=tx.loss.side
            if shown_side=='third_party' and not M.contacted(t,tx.loss.killer) then shown_side='unattributed' end
            row.loss={side=shown_side,coin=tx.loss.coin,coin_destination=tx.loss.coin_destination,reason=tx.loss.reason}
            if tx.loss.killer and (tx.loss.killer==t or M.contacted(t,tx.loss.killer)) then row.loss.killer=tx.loss.killer end
            -- Loss coordinates are shown only on the reader's own chart; never disclose a seller's base.
            local sf=game.get_surface(tx.loss.surface);local f=game.forces[t];local at=tx.loss.position
            if sf and at and f.is_chunk_charted and f.is_chunk_charted(sf,{x=math.floor(at.x/32),y=math.floor(at.y/32)}) then
              row.loss.cargo={surface=sf.name,position=copy(at),kind='wreck'}
            else row.loss.cargo={kind='wreck',location='uncharted'} end
          end
          if #contacts(t)>1 then row.team=u end
          if tx.status=='in_transit' or tx.status=='waiting' or tx.status=='quarantined' then
            for _,leg in ipairs(tx.legs) do if leg.to==t and not leg.loss then
              local r=copy(row);r.item=leg.item;r.count=leg.count-leg.delivered;r.delivered=leg.delivered
              r.post=leg.to_post or 1;r.delivery=leg.mode and (leg.mode=='timer' and 'fixed fallback' or 'freight') or 'timer'
              if r.count>0 then
                local destination=post(t,leg.to_post)
                r.next=tx.status=='waiting' and destination and destination.valid and {action='collect',args={position=copy(destination.position),count=100}} or {action='status',args={}}
                out.inbound[#out.inbound+1]=r
              end
            end end
          end
          if txi>recent then out.fills[#out.fills+1]=row end
        end
      end
      if #out.fills>20 then local keep={} for i=#out.fills-19,#out.fills do keep[#keep+1]=out.fills[i] end out.fills=keep end
      if K.rung(t)==1 then out.next={action='research',args={technology=TECH}} end
      return out
    end
    local BASE_SCHEMA={
      post={position='existing own chest within reach on your current surface; designate it as a forward Trading Post',returns='own Post id for offer/sell/buy/cancel; Orbital permits other surfaces and platforms; settlement stays on one surface'},
      offer={give='{item,count}: normal stateless goods from your Post',get='{item,count}: goods wanted; one standing lot',returns='shared order; opposite offer accepts; status shows exact calls'},
      market={returns='wallet, reserved, Post stock, own orders, pair book with accepting calls, inbound cargo and pair-local fills'},
      sell={item='reference item',price='integer coin per item, 0.5..3 times reference',keep='required stock reserve, >=0',count='required lifetime item cap',returns='shared standing order; matched items cannot be cancelled'},
      buy={item='reference item',price='integer maximum coin per item, 0.5..3 times reference',count='required lifetime item cap including cargo already in transit',returns='shared order; count*price reserved'},
      cancel={item='item of the order (give.item for a swap)',side='offer, buy or sell',revision='optional expected shared order revision',returns='unmatched quantity cancelled; cargo already matched still arrives'},
      embargo={team='contacted team to stop new matches with',returns='new matches stopped; existing cargo arrives'},
    }
    function K.open_action(t,name)
      local rung=K.rung(t)
      if name=='post' then return K.freight(t) end
      return BASE_SCHEMA[name] and (rung==2 or rung==1 and (name=='offer' or name=='cancel')) or false
    end
    function K.schema(t)
      local schemas={}
      for n,schema in pairs(BASE_SCHEMA) do if K.open_action(t,n) then schemas[n]=copy(schema) end end
      if K.rung(t)==1 and schemas.cancel then schemas.cancel.side='offer' end
      if K.freight(t) then for _,name in ipairs{'offer','sell','buy','cancel'} do
        if schemas[name] then schemas[name].post='optional own Post id from status {}; default home (1)' end
      end end
      if #contacts(t)>1 then
        if schemas.offer then schemas.offer.to='optional contacted team' end
        if schemas.sell then schemas.sell.to='optional contacted team' end
        if schemas.buy then schemas.buy.from='optional contacted team' end
        if schemas.cancel then schemas.cancel.team='counterparty of the order; omit for the unaddressed order' end
      end
      return schemas
    end
    function K.names() return BASE_SCHEMA end
    local function invoke(t,action,a,actor)
      if not K.open_action(t,action) then fail('unsupported action','describe {}') end
      if type(a)~='table' then fail('arguments: object') end
      local schema=K.schema(t)[action]
      for k in pairs(a) do if not schema[k] or k=='returns' then
        if k=='to' or k=='from' or k=='team' then fail('counterparty unavailable') end
        fail('unsupported argument')
      end end
      if action=='market' then return K.status(t) end
      return request(t,action,a,function()
        if state().fault then fail('market quarantined for operator reconciliation','status {}') end
        if action~='cancel' and frozen(t) then fail('new commitments paused while frozen','status {}') end
        if action=='cancel' then return cancel(t,a) end
        if action=='post' then
          local sf=actor and actor.surface;local at=a.position
          if not (sf and actor.position and type(at)=='table' and type(at.x or at[1])=='number' and type(at.y or at[2])=='number') then
            fail('position: an existing own chest within reach','post {"position":{"x":0,"y":0}}')
          end
          at={x=at.x or at[1],y=at.y or at[2]}
          if (at.x-actor.position.x)^2+(at.y-actor.position.y)^2>100 then fail('move within 10 tiles of your chest','walk {"position":'..helpers.table_to_json(at)..'}') end
          if sf.name~='nauvis' and not K.orbital(t) then fail('Orbital opens at your first platform','status {}') end
          local e=sf.find_entities_filtered{position=at,radius=.5,force=t,type={'container','logistic-container'},limit=1}[1]
          if not (e and e.valid) then fail('place an own chest here first','build {"name":"steel-chest","position":'..helpers.table_to_json(at)..'}') end
          local s=team(t);s.posts=s.posts or {}
          if s.post and e.unit_number==s.post.unit_number then return {post=1} end
          for id,p in pairs(s.posts) do if p.valid and p.unit_number==e.unit_number then return {post=id} end end
          s.post_sites=s.post_sites or {}
          for id,site in pairs(s.post_sites) do
            if not (s.posts[id] and s.posts[id].valid) and site.surface==sf.name
              and (site.position.x-at.x)^2+(site.position.y-at.y)^2<=4 then
              s.posts[id]=e;e.minable_flag=false;e.destructible=config('destructible')
              return {post=id,restored=true,next={action='status',args={}}}
            end
          end
          s.post_next=s.post_next or 2
          if s.post_next>33 then fail('Post limit reached','status {}') end
          local id=s.post_next;s.post_next=id+1;s.posts[id]=e;e.minable_flag=false;e.destructible=config('destructible')
          s.post_sites[id]={surface=sf.name,position=copy(e.position)}
          return {post=id,surface=sf.name,position=copy(e.position),next={action='status',args={}}}
        end
        if action=='embargo' then
          if type(a.team)~='string' or not M.contacted(t,a.team) or not teams()[a.team] or a.team==t then fail('counterparty unavailable') end
          local p=pair(t,a.team);p.embargo=p.embargo or {}
          if not p.embargo[t] then
            p.embargo[t]=true
            local line=t..' embargoes '..a.team..': new matches stop; committed cargo still arrives.'
            fact(t,line,true);fact(a.team,line,true);news(t,a.team,'embargo',line)
          end
          return {embargo=true}
        end
        return add_order(t,action,a)
      end)
    end
    for name in pairs(BASE_SCHEMA) do K.handlers[name]=function(p,a) return invoke(api.team_now(),name,a or {},p) end end
    -- All economic mutations keep a transaction first. Catch only to mark quarantine, then rethrow.
    local function transact(tx,fn)
      local ok,err=pcall(fn)
      if not ok then
        tx.status='quarantined';tx.error=tostring(err);tx.failed_tick=game.tick
        state().fault={tick=game.tick,error=tostring(err),transaction=tx.id}
        error(err,0)
      end
    end
    -- One durable exit path for every custody loss. The entity never holds a second copy of
    -- the manifest, so mining/destruction cannot duplicate cargo before the event arrives.
    local SHIPMENT='mt-shipment'
    local function terminal(tx) return tx.status=='delivered' or tx.status=='lost' end
    local function each_freight(fn)
      local s=mt() and mt().market;if not s then return end
      for _,p in pairs(s.pairs) do for _,id in ipairs(p.pending) do
        local tx=txget(p,id)
        if tx and tx.freight and not terminal(tx) and tx.status~='quarantined' then
          for _,l in ipairs(tx.legs) do fn(p,tx,l) end
        end
      end end
    end
    local function sides(l)
      l.buyer_side=l.buyer_side or {[l.to]=true};l.seller_side=l.seller_side or {[l.from]=true}
      for _,other in pairs(game.forces) do
        local t=other.name
        for _,side in ipairs{{l.to,l.buyer_side},{l.from,l.seller_side}} do
          local f,o=game.forces[side[1]],game.forces[t]
          if f and o and f.get_cease_fire and (f.get_cease_fire(o) or o.get_cease_fire(f)) then side[2][t]=true end
          for _,p in pairs(mt().pacts and mt().pacts.by_id or {}) do
            if p.status=='active' and ((p.a==side[1] and p.b==t) or (p.b==side[1] and p.a==t)) then side[2][t]=true end
          end
        end
      end
    end
    function K.capture_sides() each_freight(function(_,_,l) sides(l) end) end
    local function detach(l)
      local s=state()
      if l.registration then (s.shipment_objects or {})[l.registration]=nil;l.registration=nil end
      if l.path_request then (s.shipment_paths or {})[l.path_request]=nil;l.path_request=nil end
      local e=l.entity;l.entity=nil
      if e and e.valid then e.destroy() end
    end
    local function cargo_wreck(l,n)
      local sf=game.get_surface(l.surface)
      assert(sf and sf.valid~=false,'shipment surface unavailable: reconcile cargo')
      local size=math.max(1,math.ceil(n/prototypes.item[l.item].stack_size))
      local w=assert(sf.create_entity{name='character-corpse',position=l.position,inventory_size=size},'shipment wreck creation failed')
      local i=assert(w.get_inventory(defines.inventory.character_corpse),'shipment wreck inventory missing')
      local put=i.insert{name=l.item,count=n,quality='normal'}
      l.loot=put;assert(put==n,'shipment loot insertion incomplete')
      l.wreck=w
    end
    function K.loss(p,tx,l,killer,reason)
      if terminal(tx) or l.loss then return end
      transact(tx,function()
        sides(l)
        local e=l.entity
        if e and e.valid then l.position=copy(e.position);l.surface=e.surface.name end
        local side
        if killer==l.to then side='buyer'
        elseif killer==l.from then side='seller'
        elseif killer and l.buyer_side[killer] and l.seller_side[killer] then side='shared'
        elseif killer and l.buyer_side[killer] then side='buyer'
        elseif killer and l.seller_side[killer] then side='seller'
        else side=killer and 'third_party' or 'unattributed' end
        local coin=tx.escrow;local dest='destroyed'
        if side=='buyer' then team(l.from).wallet=team(l.from).wallet+coin;dest='seller'
        elseif side=='seller' then team(l.to).wallet=team(l.to).wallet+coin;dest='buyer_refund'
        else state().destroyed=(state().destroyed or 0)+coin end
        tx.escrow=0
        local m=metrics(l.to);m.losses[side]=m.losses[side]+1
        if dest=='destroyed' then m.destroyed=m.destroyed+coin end
        local remaining=l.count-l.delivered
        if remaining>0 then cargo_wreck(l,remaining) end
        l.loss={side=side,killer=killer,reason=reason,coin=coin,coin_destination=dest,position=copy(l.position),surface=l.surface}
        tx.loss=l.loss;tx.status='lost';tx.ended_tick=game.tick
        -- Swaps have two independent manifests: the other leg continues without coin.
        for _,other in ipairs(tx.legs) do if other~=l and not other.loss and other.delivered<other.count then tx.status='in_transit' end end
        detach(l)
      end)
      local coin_outcome=({seller='paid to seller',buyer_refund='refunded to buyer',destroyed='destroyed'})[l.loss.coin_destination]
      local side_label={buyer='buyer',seller='seller',third_party='third party',unattributed='unattributed',shared='both trading'}
      for _,t in ipairs{p.a,p.b} do
        local shown_side=l.loss.side=='third_party' and not M.contacted(t,killer) and 'unattributed' or l.loss.side
        local who=killer and (killer==t or M.contacted(t,killer)) and (killer..' ('..side_label[shown_side]..' side)') or (side_label[shown_side]..' side')
        local sf=game.get_surface(l.surface);local at=l.position;local f=game.forces[t]
        local where='a wreck in uncharted territory'
        if sf and f.is_chunk_charted and f.is_chunk_charted(sf,{x=math.floor(at.x/32),y=math.floor(at.y/32)}) then
          where=string.format('a wreck on %s at (%.1f,%.1f)',sf.name,at.x,at.y)
        end
        fact(t,string.format('Shipment #%d lost: %s; %d coin %s; %d %s in %s. Call embargo {"team":"%s"} to stop new matches.',
          tx.id,who,l.loss.coin,coin_outcome,l.count-l.delivered,l.item,where,t==p.a and p.b or p.a),true)
      end
      news(p.a,p.b,'shipment_loss',string.format('%s shipment from %s lost (%s, %s); %d coin %s; cargo in wreck on %s at (%.1f,%.1f)',
        l.to,l.from,side_label[l.loss.side]..' side',reason,l.loss.coin,coin_outcome,l.surface,l.position.x,l.position.y),tx.id)
    end
    local function safe(l,e)
      if not l.origin or not l.destination then return true end
      local function near(at) return (e.position.x-at.x)^2+(e.position.y-at.y)^2<=65^2 end
      return near(l.origin) or near(l.destination)
    end
    local function fallback(l)
      detach(l);l.mode='timer';l.ready_tick=game.tick+1800
    end
    local function request_path(tx,l)
      local e=l.entity
      if l.path_request then state().shipment_paths[l.path_request]=nil end
      l.path_request=e.surface.request_path{bounding_box=e.prototype.collision_box,collision_mask=e.prototype.collision_mask,
        start=e.position,goal=l.destination,force=e.force,radius=12,can_open_gates=true,entity_to_ignore=e}
      state().shipment_paths=state().shipment_paths or {}
      state().shipment_paths[l.path_request]={a=l.from,b=l.to,id=tx.id,unit=l.unit}
      l.mode='path_pending';l.path_started=game.tick;l.retry_tick=nil
    end
    local function dispatch(tx)
      for _,l in ipairs(tx.legs) do
        if K.freight(l.to) and K.freight(l.from) then
          tx.freight=true;sides(l)
          local src,dst=post(l.from,l.from_post),post(l.to,l.to_post)
          l.surface=src.surface.name;l.origin=copy(src.position);l.destination=copy(dst.position);l.position=copy(src.position)
          local sf=src.surface;local at=sf.find_non_colliding_position(SHIPMENT,src.position,16,.5)
          if not at then fallback(l)
          else
            local e=assert(sf.create_entity{name=SHIPMENT,position=at,force=l.to},'shipment creation failed')
            l.entity=e;l.position=copy(e.position);l.unit=e.unit_number;l.mode='path_pending';l.path_started=game.tick
            e.destructible=false;e.minable_flag=false;e.operable=false
            l.registration=script.register_on_object_destroyed(e)
            state().shipment_objects=state().shipment_objects or {};state().shipment_objects[l.registration]={a=l.from,b=l.to,id=tx.id,unit=l.unit}
            request_path(tx,l)
          end
        end
      end
    end
    local function locate(ref)
      if not ref then return end
      local p=pair(ref.a,ref.b);local tx=txget(p,ref.id)
      if tx then for _,l in ipairs(tx.legs) do if l.unit==ref.unit then return p,tx,l end end end
    end
    function K.on_event(event)
      local s=mt() and mt().market;if not s or s.fault then return end
      local d=defines.events
      if event.name==d.on_force_cease_fire_changed then K.capture_sides();return end
      if event.name==d.on_script_path_request_finished then
        local p,tx,l=locate((s.shipment_paths or {})[event.id])
        if not l or l.loss or terminal(tx) then return end
        s.shipment_paths[event.id]=nil;l.path_request=nil
        if event.try_again_later then l.retry_tick=game.tick+60;return end
        if not (event.path and #event.path>0) then fallback(l);return end
        if l.entity and l.entity.valid then
          l.mode='unit';l.last_progress_tick=game.tick;l.last_progress=copy(l.entity.position)
          l.entity.commandable.set_command{type=defines.command.go_to_location,destination=l.destination,radius=8,distraction=defines.distraction.none}
        end
        return
      end
      if event.name==d.on_object_destroyed then
        local p,tx,l=locate((s.shipment_objects or {})[event.registration_number])
        if l then K.loss(p,tx,l,nil,'script destroy or unattributed removal') end
        return
      end
      if event.name~=d.on_entity_died and event.name~=d.on_entity_damaged and event.name~=d.on_pre_player_mined_item
        and event.name~=d.on_robot_pre_mined and event.name~=d.on_player_mined_entity and event.name~=d.on_robot_mined_entity
        and event.name~=d.on_marked_for_deconstruction and event.name~=d.on_player_driving_changed_state
        and event.name~=d.script_raised_destroy then return end
      local e=event.entity
      if not (e and e.valid and e.name==SHIPMENT) then return end
      each_freight(function(p,tx,l)
        if l.unit~=e.unit_number or l.loss then return end
        l.position=copy(e.position);l.surface=e.surface.name
        if event.name==d.on_entity_damaged then
          if safe(l,e) then e.health=math.min(e.prototype.max_health,e.health+(event.final_damage_amount or 0));e.destructible=false end
          return
        end
        local force=event.force or (event.cause and event.cause.valid and event.cause.force)
          or (event.robot and event.robot.valid and event.robot.force)
        if event.player_index then local pl=game.get_player(event.player_index);force=pl and pl.force or force end
        local reason=event.name==d.on_entity_died and 'death' or event.name==d.on_marked_for_deconstruction and 'deconstruction'
          or event.name==d.on_player_driving_changed_state and 'driver entry'
          or event.name==d.script_raised_destroy and 'script destroy' or 'mining'
        if event.name==d.on_marked_for_deconstruction then e.cancel_deconstruction(force or e.force) end
        if (event.name==d.on_pre_player_mined_item or event.name==d.on_robot_pre_mined or event.name==d.on_marked_for_deconstruction
          or event.name==d.on_player_driving_changed_state) and force and force.name==l.to then
          e.minable_flag=false;e.operable=false
          fact(l.to,'Shipment custody is locked: wait for delivery; call market {}.',false);return
        end
        K.loss(p,tx,l,force and force.name,reason)
      end)
    end
    function K.freight_tick()
      each_freight(function(p,tx,l)
        if l.loss or l.delivered==l.count or not l.mode then return end
        sides(l)
        if l.mode=='timer' then return end
        local e=l.entity
        if not (e and e.valid) then K.loss(p,tx,l,nil,'missing entity');return end
        l.position=copy(e.position);e.destructible=not safe(l,e)
        if api.shipment_seen then api.shipment_seen(e) end
        if (e.position.x-l.destination.x)^2+(e.position.y-l.destination.y)^2<=16^2 then
          l.arrived=true;e.destructible=false;e.commandable.set_command{type=defines.command.stop};return
        end
        if l.mode=='path_pending' and (l.retry_tick and game.tick>=l.retry_tick or game.tick-l.path_started>=1800) then request_path(tx,l)
        elseif l.mode=='unit' then
          local at=l.last_progress
          if (at.x-e.position.x)^2+(at.y-e.position.y)^2>4 then l.last_progress=copy(e.position);l.last_progress_tick=game.tick
          elseif game.tick-l.last_progress_tick>=1800 then request_path(tx,l) end
        end
      end)
    end
    local function unitcost(name) return 1/prototypes.item[name].stack_size end
    local function capacity(p)
      local used=0;local keep={}
      for _,v in ipairs(p.usage) do if game.tick-v.tick<3600 then keep[#keep+1]=v;used=used+v.stacks end end
      local cap=K.freight(p.a) and K.freight(p.b) and config('freight_stacks') or config('pair_stacks')
      p.usage=keep;return math.max(0,cap-used)
    end
    local function matched(o,n)
      o.matched=o.matched+n;o.revision=o.revision+1
      if o.matched==o.count then o.status='filled';o.ended_tick=game.tick end
    end
    local function same_surface(a,b,ap,bp)
      local x,y=post(a,ap),post(b,bp)
      return x and x.valid and y and y.valid and x.surface.index==y.surface.index
    end
    local function newtx(p,legs,price)
      local tx={id=p.next,status='preparing',tick=game.tick,eta=game.tick+config('transit_ticks'),legs=legs,price=price,escrow=0,
        item=legs[1].item,count=legs[1].count}
      p.next=p.next+1;p.transactions[#p.transactions+1]=tx;p.pending[#p.pending+1]=tx.id;return tx
    end
    local function remove_goods(leg)
      local i=assert(inv(leg.from,leg.from_post),'source Post unavailable')
      leg.removed=i.remove{name=leg.item,count=leg.count,quality='normal'}
      assert(leg.removed==leg.count,'short removal: transaction quarantined')
    end
    local function emit_fill(p,tx)
      local l=tx.legs[1]
      local travel=tx.freight and '; shipment dispatched, payment on arrival' or ('; arrival in '..(config('transit_ticks')/60)..' seconds')
      local line=tx.price and string.format('%s sells %d %s to %s at %d',l.from,l.count,l.item,l.to,tx.price)..travel
        or string.format('%s swaps %d %s with %s',l.from,l.count,l.item,l.to)..travel
      fact(p.a,line,true);fact(p.b,line,true)
      news(p.a,p.b,'fill',line,tx.id)
    end
    local function fill(p,ask,bid)
      if not same_surface(ask.team,bid.team,ask.post,bid.post) then return end
      local price=(ask.tick<bid.tick or ask.tick==bid.tick and game.forces[ask.team].index<game.forces[bid.team].index) and ask.price or bid.price
      local n=math.min(ask.count-ask.matched,bid.count-bid.matched,math.max(0,amount(ask.team,ask.item,ask.post)-ask.keep),
        math.floor((capacity(p)+1e-9)/unitcost(ask.item)))
      if n<1 then return end
      local tx=newtx(p,{{from=ask.team,to=bid.team,item=ask.item,count=n,delivered=0,from_post=ask.post,to_post=bid.post}},price)
      transact(tx,function()
        remove_goods(tx.legs[1])
        local b=team(bid.team);local cost=n*price
        assert(b.reserved>=n*bid.price and b.wallet>=cost,'coin reservation invariant')
        b.reserved=b.reserved-n*bid.price;b.wallet=b.wallet-cost;tx.escrow=cost
        matched(ask,n);matched(bid,n)
        for _,o in ipairs({ask,bid}) do local k=o.team..'/'..o.id;p.filled_by_order[k]=(p.filled_by_order[k] or 0)+n end
        for _,t in ipairs{ask.team,bid.team} do local m=metrics(t)
          m.fills=m.fills+1;m.trade_coin=m.trade_coin+cost
          if price==PRICES[ask.item] then m.reference_fills=m.reference_fills+1 end
          local ratio=price/PRICES[ask.item]
          m.price_ratio_count=(m.price_ratio_count or 0)+1;m.price_ratio_sum=(m.price_ratio_sum or 0)+ratio
          m.price_ratio_min=math.min(m.price_ratio_min or ratio,ratio);m.price_ratio_max=math.max(m.price_ratio_max or ratio,ratio)
          m.last_fill={price=price,reference=PRICES[ask.item],ratio=price/PRICES[ask.item],count=n,item=ask.item,tick=game.tick}
        end
        p.usage[#p.usage+1]={tick=game.tick,stacks=n*unitcost(ask.item)};tx.status='in_transit'
        dispatch(tx)
      end)
      emit_fill(p,tx)
    end
    local function swap(p,a,b)
      if not same_surface(a.team,b.team,a.post,b.post) then return end
      if a.give.item~=b.get.item or a.get.item~=b.give.item or a.give.count~=b.get.count or a.get.count~=b.give.count then return end
      local stacks=a.give.count*unitcost(a.give.item)+b.give.count*unitcost(b.give.item)
      if stacks>capacity(p)+1e-9 or amount(a.team,a.give.item,a.post)<a.give.count or amount(b.team,b.give.item,b.post)<b.give.count then return end
      local tx=newtx(p,{{from=a.team,to=b.team,item=a.give.item,count=a.give.count,delivered=0,from_post=a.post,to_post=b.post},
        {from=b.team,to=a.team,item=b.give.item,count=b.give.count,delivered=0,from_post=b.post,to_post=a.post}})
      transact(tx,function()
        for _,leg in ipairs(tx.legs) do remove_goods(leg) end
        matched(a,1);matched(b,1)
        for _,o in ipairs({a,b}) do local k=o.team..'/'..o.id;p.filled_by_order[k]=(p.filled_by_order[k] or 0)+1 end
        p.usage[#p.usage+1]={tick=game.tick,stacks=stacks};tx.status='in_transit'
        dispatch(tx)
      end)
      emit_fill(p,tx)
    end
    local function rank(side)
      return function(a,b)
        if a.price~=b.price then return side=='buy' and a.price>b.price or side=='sell' and a.price<b.price end
        if a.tick~=b.tick then return a.tick<b.tick end
        if a.team~=b.team then return game.forces[a.team].index<game.forces[b.team].index end
        return a.id<b.id
      end
    end
    local function match_pair(p)
      if frozen(p.a) or frozen(p.b) or (p.embargo and next(p.embargo)) then return end
      local orders={}
      for _,t in ipairs({p.a,p.b}) do for _,key in ipairs(keys(team(t).orders)) do
        local o=team(t).orders[key]
        if can_pair(o,t==p.a and p.b or p.a) then orders[#orders+1]=o;book_id(p,o) end
      end end
      for _,a in ipairs(orders) do if a.side=='offer' and a.status=='open' then
        for _,b in ipairs(orders) do if b.side=='offer' and b.team~=a.team and b.status=='open' and a.status=='open' then swap(p,a,b) end end
      end end
      if K.rung(p.a)<2 or K.rung(p.b)<2 then return end
      for _,name in ipairs(keys(PRICES)) do
        local asks,bids={},{}
        for _,o in ipairs(orders) do if o.item==name then
          if o.side=='sell' then asks[#asks+1]=o elseif o.side=='buy' then bids[#bids+1]=o end
        end end
        table.sort(asks,rank('sell'));table.sort(bids,rank('buy'))
        for _,bid in ipairs(bids) do for _,ask in ipairs(asks) do
          if bid.team~=ask.team and bid.status=='open' and ask.status=='open' and bid.price>=ask.price then fill(p,ask,bid) end
        end end
      end
    end
    local function deliver(p,tx)
      if tx.status~='in_transit' and tx.status~='waiting' then return end
      if not tx.freight and game.tick<tx.eta then return end
      transact(tx,function()
        local complete,waiting=true,false
        for _,leg in ipairs(tx.legs) do
          local remaining=leg.count-leg.delivered;local i=inv(leg.to,leg.to_post)
          local ready=not leg.mode or leg.arrived or leg.mode=='timer' and game.tick>=leg.ready_tick
          if remaining>0 and i and ready and not leg.loss then
            local n=i.insert{name=leg.item,count=remaining,quality='normal'}
            assert(n>=0 and n<=remaining and n==math.floor(n),'invalid inserted count')
            leg.delivered=leg.delivered+n
            if tx.price then
              local pay=n*tx.price;assert(tx.escrow>=pay,'payment escrow invariant')
              tx.escrow=tx.escrow-pay;team(leg.from).wallet=team(leg.from).wallet+pay
            end
            if n>0 and K.on_delivery then K.on_delivery(leg.from,leg.to,leg.item,n) end
          end
          if leg.delivered<leg.count and not leg.loss then complete=false
          elseif leg.entity then detach(leg) end
          if ready and not leg.loss and leg.delivered<leg.count then waiting=true end
        end
        tx.status=complete and (tx.loss and 'lost' or 'delivered') or (waiting and 'waiting' or 'in_transit')
        if complete then tx.ended_tick=game.tick end
      end)
    end
    -- The wallet includes unmatched buy reserves. A raid cancels bids if needed to free the stolen amount;
    -- matched purchases have already left that wallet into payment escrow and are irrevocable.
    local deposit
    -- (mt302) Coin out of a destroyed entity into a coin wreck: a character corpse (no force, no collision, never
    -- expires; inserters and robots cannot take from it; any team's character takes it with mine, bots.lua M.mine).
    -- lots: {{count=,quality=}}. Returns the coin put in and where; nil when no wreck could be made (the caller spills
    -- on the ground then, as before).
    local function wreck(surface,position,lots)
      local slots,total=0,0
      for _,l in ipairs(lots) do slots=slots+math.ceil(l.count/1000);total=total+l.count end
      if total<=0 then return nil end
      local ok,w=pcall(surface.create_entity,{name='character-corpse',position=position,inventory_size=math.max(1,slots)})
      if not (ok and w and w.valid) then return nil end
      local i=w.get_inventory(defines.inventory.character_corpse)
      local put=0
      for _,l in ipairs(lots) do put=put+i.insert{name=COIN,count=l.count,quality=l.quality} end
      if put~=total then i.clear();w.destroy();return nil end
      return put,{x=w.position.x,y=w.position.y,surface=surface.name}
    end
    local function ground(surface,position,n,quality)
      local dropped=surface.spill_item_stack{position=position,stack={name=COIN,count=n,quality=quality},enable_looted=true,
        allow_belts=false,use_start_position_on_failure=true,drop_full_stack=true}
      local actual=0
      for _,v in pairs(dropped or {}) do if v.valid and v.stack and v.stack.valid_for_read then actual=actual+v.stack.count end end
      return actual
    end
    local function spill_contents(e)
      -- A character keeps its coin: the game leaves it in the character's corpse (the corpse rule), for any team to loot.
      if e.type=='character' then return end
      local s=state();s.entity_spills=s.entity_spills or {}
      local surface,position=e.surface,e.position -- clearing a ground stack may invalidate its entity
      local key=e.unit_number and tostring(e.unit_number)
      if key and s.entity_spills[key] then return end
      local rec={unit=e.unit_number,tick=game.tick,status='preparing',removed=0,dropped=0}
      local lots={}
      local function take(i,remove)
        for _,v in pairs(i.get_contents()) do if v.name==COIN and v.count>0 then
          local q=type(v.quality)=='table' and v.quality.name or v.quality or 'normal'
          lots[#lots+1]={count=v.count,quality=q,remove=function() return remove{name=COIN,count=v.count,quality=q} end}
        end end
      end
      for id=1,e.get_max_inventory_index() do local i=e.get_inventory(id);if i then take(i,i.remove) end end
      if e.type=='transport-belt' or e.type=='underground-belt' or e.type=='splitter' or e.type=='loader' or e.type=='loader-1x1' then
        for id=1,e.get_max_transport_line_index() do local line=e.get_transport_line(id);take(line,line.remove_item) end
      end
      local stack=e.type=='inserter' and e.held_stack or e.type=='item-entity' and e.stack or nil
      if stack and stack.valid_for_read and stack.name==COIN then
        local n=stack.count;local q=stack.quality and stack.quality.name or 'normal'
        lots[#lots+1]={count=n,quality=q,remove=function() stack.clear();return n end}
      end
      -- A recycler has already consumed its one ingredient during an unfinished craft.
      if e.type=='furnace' and e.crafting_progress>0 then
        local r,q=e.get_recipe()
        if r and r.name=='mt-coin-recycling' then
          lots[#lots+1]={count=1,quality=q and q.name or 'normal',remove=function() e.crafting_progress=0;return 1 end}
        end
      end
      if #lots==0 then return end
      if key then s.entity_spills[key]=rec else s.spills[#s.spills+1]=rec end
      transact(rec,function()
        local taken={}
        for _,lot in ipairs(lots) do
          local n=lot.remove();rec.removed=rec.removed+n;assert(n==lot.count,'coin removal incomplete')
          taken[#taken+1]={count=n,quality=lot.quality}
        end
        local put,at=nil,nil
        if config('wreck') then put,at=wreck(surface,position,taken) end
        if put then rec.dropped=put;rec.wreck=at
        else
          for _,l in ipairs(taken) do
            local actual=ground(surface,position,l.count,l.quality)
            rec.dropped=rec.dropped+actual;assert(actual==l.count,'coin spill incomplete: quarantined')
          end
        end
        rec.status='spilled' -- physical custody moved; issuance and physical supply do not change.
      end)
    end
    function K.on_died(event)
      local e=event.entity
      if not (mt() and mt().market and e and e.valid) or state().fault then return end
      if e.name==SHIPMENT then return end -- handled by the common custody event path
      local t=e.force and e.force.name;local s=t and state().teams[t]
      local home=s and s.post and s.post.unit_number==e.unit_number
      local post_id=home and 1 or nil
      for id,p in pairs(s and s.posts or {}) do if p.valid and p.unit_number==e.unit_number then post_id=id;break end end
      if not post_id then spill_contents(e);return end
      if s.spills[tostring(e.unit_number)] then return end
      if state().fault then return end
      -- Coins just inserted since the last one-second pass already belong to this team.
      -- Credit them before chest destruction can erase their physical stack.
      deposit(t,post_id)
      local n=home and math.floor(s.wallet*config('raid_share')) or 0
      local rec={unit=e.unit_number,count=n,status='preparing',tick=game.tick};s.spills[tostring(e.unit_number)]=rec
      transact(rec,function()
        if s.wallet-s.reserved<n then for _,o in pairs(s.orders) do if o.side=='buy' then cancel_order(t,o,'home Post raided') end end end
        s.wallet=s.wallet-n;rec.debited=n
        local put,at=nil,nil
        local source=e.get_inventory(defines.inventory.chest)
        -- Transfer actual stacks, preserving quality, spoil deadlines, ammo, tags and inventories.
        -- Any nonempty Post always leaves a character corpse, unreachable to robots/inserters.
        local stocked=false
        if source then for slot=1,#source do if source[slot].valid_for_read then stocked=true;break end end end
        if stocked then
          local w=assert(e.surface.create_entity{name='character-corpse',position=e.position,
            inventory_size=#source+math.max(1,math.ceil(n/1000))},'Post wreck creation failed')
          local target=assert(w.get_inventory(defines.inventory.character_corpse),'Post wreck inventory unavailable')
          rec.stock={};rec.wreck_entity=w
          for slot=1,#source do if source[slot].valid_for_read then
            local stack=source[slot];local count=stack.count
            rec.stock[#rec.stock+1]={name=stack.name,count=count,quality=stack.quality and stack.quality.name or 'normal'}
            target[slot].transfer_stack(stack)
            assert(not stack.valid_for_read and target[slot].count==count,'Post stock transfer incomplete')
          end end
          put=n>0 and target.insert{name=COIN,count=n,quality='normal'} or 0
          assert(put==n,'Post raid coin insertion incomplete')
          at={x=e.position.x,y=e.position.y,surface=e.surface.name}
        elseif n>0 and config('wreck') then put,at=wreck(e.surface,e.position,{{count=n,quality='normal'}}) end
        local actual
        if put then actual=put;rec.wreck=at else actual=n>0 and ground(e.surface,e.position,n,'normal') or 0 end
        rec.dropped=actual;state().physical=state().physical+actual
        assert(actual==n,'coin spill incomplete: quarantined');rec.status='spilled'
      end)
      local line=(home and 'Home Trading Post' or ('Trading Post #'..post_id))..' destroyed: '..n..' coin spilled in the wreck; stocked goods are there too.'
      fact(t,line,true);news(t,nil,'raid',t..' '..line)
    end
    deposit=function(t,id)
      local i=inv(t,id);if not i then return end
      local n=i.get_item_count{name=COIN,quality='normal'}
      if n<=0 then return end
      local s=state();local rec={team=t,count=n,status='preparing',tick=game.tick}
      s.deposits=s.deposits or {};s.deposits[#s.deposits+1]=rec
      transact(rec,function()
        local removed=i.remove{name=COIN,count=n,quality='normal'};rec.removed=removed
        assert(removed<=s.physical,'coin deposit exceeds circulating supply')
        s.physical=s.physical-removed;team(t).wallet=team(t).wallet+removed;rec.status='credited'
      end)
    end
    -- (mt301) The market's records over a long game. Receipts never expire (a used id never runs twice), but those
    -- older than the newest KEEP.receipts of a team drop their copied result, and committed ones older than the newest
    -- KEEP.payloads become their tick alone (a replay answers 'committed', with any arguments); delivered transactions older than a
    -- pair's newest KEEP.transactions fold into per-item print counts (last price, count, tick); credited deposits
    -- fold into a count and a coin total; per-order fill counts and book ids of orders no longer held are dropped.
    -- Nothing undelivered, quarantined or holding escrow is folded. The audit totals do not change.
    local KEEP={receipts=256,payloads=4096,transactions=200,deposits=100,slack=64}
    K.KEEP=KEEP
    function K.compact(force)
      local s=state();local out={receipts=0,transactions=0,deposits=0,orders=0}
      for t,ro in pairs(s.request_order or {}) do
        local journal=s.requests[t] or {}
        local upto=ro.next-1-KEEP.receipts
        if force and upto>ro.done or upto-ro.done>=KEEP.slack then
          for i=ro.done+1,upto do
            local rec=journal[ro[i]]
            if type(rec)=='table' and rec.status=='committed' and rec.result~=nil then rec.result=nil;rec.compacted=true;out.receipts=out.receipts+1 end
          end
          ro.done=math.max(ro.done,upto)
        end
        ro.slim=ro.slim or 0
        local slim=ro.next-1-KEEP.payloads
        if force and slim>ro.slim or slim-ro.slim>=KEEP.slack then
          for i=ro.slim+1,slim do
            local id=ro[i];local rec=journal[id]
            if type(rec)=='table' and rec.status=='committed' then journal[id]=rec.tick;out.slimmed=(out.slimmed or 0)+1 end
            ro[i]=nil
          end
          ro.slim=math.max(ro.slim,slim)
        end
      end
      for _,p in pairs(s.pairs) do
        local list=p.transactions
        if #list>KEEP.transactions+(force and 0 or KEEP.slack) then
          local cut,kept=#list-KEEP.transactions,{}
          p.folded=p.folded or {count=0,prints={}}
          for i,tx in ipairs(list) do
            if i<=cut and terminal(tx) and tx.escrow==0 then
              p.folded.count=p.folded.count+1;out.transactions=out.transactions+1
              if tx.price then
                local v=p.folded.prints[tx.item] or {prints=0}
                v.prints,v.price,v.count,v.tick=v.prints+1,tx.price,tx.count,tx.tick
                p.folded.prints[tx.item]=v
              end
            else kept[#kept+1]=tx end
          end
          p.transactions=kept
          local held={}
          for _,t in ipairs({p.a,p.b}) do for _,o in pairs(team(t).orders) do held[o.team..'/'..o.id]=true end end
          for k in pairs(p.filled_by_order) do if not held[k] then p.filled_by_order[k]=nil;out.orders=out.orders+1 end end
          for k in pairs(p.book_ids) do if not held[k] then p.book_ids[k]=nil end end
        end
      end
      local d=s.deposits
      if d and #d>KEEP.deposits+(force and 0 or KEEP.slack) then
        s.deposit_totals=s.deposit_totals or {count=0,coin=0}
        local cut,kept=#d-KEEP.deposits,{}
        for i,rec in ipairs(d) do
          if i<=cut and rec.status=='credited' then
            s.deposit_totals.count=s.deposit_totals.count+1;s.deposit_totals.coin=s.deposit_totals.coin+(rec.removed or 0)
            out.deposits=out.deposits+1
          else kept[#kept+1]=rec end
        end
        s.deposits=kept
      end
      return out
    end
    function K.sizes()
      local s=state();local r={receipts=0,full_receipts=0,transactions=0,folded_transactions=0,deposits=#(s.deposits or {}),
        folded_deposits=s.deposit_totals and s.deposit_totals.count or 0,order_counters=0}
      -- by the id order (a few hundred reads a team); receipts made before mt301 kept no order and are counted whole
      for t,journal in pairs(s.requests) do
        local ro=(s.request_order or {})[t]
        if ro then
          r.receipts=r.receipts+ro.next-1
          for i=ro.done+1,ro.next-1 do local rec=journal[ro[i]];if type(rec)=='table' and rec.result~=nil then r.full_receipts=r.full_receipts+1 end end
        else
          for _,rec in pairs(journal) do r.receipts=r.receipts+1;if type(rec)=='table' and rec.result~=nil then r.full_receipts=r.full_receipts+1 end end
        end
      end
      for _,p in pairs(s.pairs) do
        r.transactions=r.transactions+#p.transactions;r.folded_transactions=r.folded_transactions+(p.folded and p.folded.count or 0)
        for _ in pairs(p.filled_by_order) do r.order_counters=r.order_counters+1 end
      end
      return r
    end
    -- Operator-only measurements. No rival production, rank, issuance or pooled payment enters agent responses.
    function K.measure()
      local rows={};local ranks=api.market_ranks and api.market_ranks() or {}
      local escrow={}
      for _,p in pairs(state().pairs) do for _,id in ipairs(p.pending) do
        local tx=txget(p,id)
        if tx and tx.escrow>0 then local t=tx.legs[1].to;escrow[t]=(escrow[t] or 0)+tx.escrow end
      end end
      for _,t in ipairs(mt().order or {}) do if K.rung(t)>0 then
        local s=team(t);local m=metrics(t);local f=game.forces[t];local produced=0
        if f.get_item_production_statistics then for _,sf in pairs(game.surfaces) do
          local st=f.get_item_production_statistics(sf)
          produced=produced+20*(st.get_input_count('iron-plate')+st.get_input_count('copper-plate'))+100*st.get_input_count('steel-plate')
        end end
        local rate=m.sample and game.tick>m.sample.tick and math.max(0,produced-m.sample.produced)*3600/(game.tick-m.sample.tick) or 0
        local sells,unfilled=0,0
        for _,o in pairs(s.orders) do if o.side=='sell' and o.status=='open' and o.price<=PRICES[o.item] then
          sells=sells+1;if o.matched==0 then unfilled=unfilled+1 end
        end end
        local row={team=t,tick=game.tick,wallet=s.wallet,reserved=s.reserved,plate_coin_per_minute=rate,
          wallet_minutes_of_plate_output=rate>0 and s.wallet/rate or nil,plate_coin_total=produced,
          escrow=escrow[t] or 0,accounted_coin=s.wallet+(escrow[t] or 0),physical_coin_unassigned=state().physical,
          accounted_coin_minutes_of_plate_output=rate>0 and (s.wallet+(escrow[t] or 0))/rate or nil,
          buy_attempts=m.buy_attempts,buy_short=m.buy_short,buy_short_share=m.buy_attempts>0 and m.buy_short/m.buy_attempts or 0,
          buy_refusals=m.buy_refusals or 0,buy_short_refusal_share=(m.buy_refusals or 0)>0 and m.buy_short/m.buy_refusals or 0,
          resting_reference_sells=sells,never_filled_reference_sells=unfilled,never_filled_share=sells>0 and unfilled/sells or 0,
          fills=m.fills,reference_fills=m.reference_fills,last_fill=copy(m.last_fill),trade_coin=m.trade_coin,losses=copy(m.losses),destroyed=m.destroyed,
          price_ratio_min=m.price_ratio_min,price_ratio_max=m.price_ratio_max,
          price_ratio_mean=m.price_ratio_count and m.price_ratio_sum/m.price_ratio_count or nil,
          price_ratio_samples=m.price_ratio_count or 0,
          grants=copy(s.payments or {}),pool_in=0,pool_out=0,agents= #roster(t,t),race_rank=ranks[t],
          assumed_two_agent_factor=.4,issuance=state().issuance}
        m.sample={tick=game.tick,produced=produced};rows[#rows+1]=row
      end end
      table.sort(rows,function(a,b) if a.wallet~=b.wallet then return a.wallet>b.wallet end return a.team<b.team end)
      for i,row in ipairs(rows) do row.coin_rank=(i>1 and rows[i-1].wallet==row.wallet) and rows[i-1].coin_rank or i end
      state().measurements=rows
      if api.market_measure then api.market_measure(rows) end
      return rows
    end
    function K.tick(tick)
      if not mt() or not next(teams()) or not config('enabled') then return end
      if mt().market and mt().market.fault then return end
      K.freight_tick()
      if tick%60~=0 then return end
      if tick%3600==1800 and mt().market then pcall(K.compact) end   -- never a fault: it moves no coin or goods
      for _,t in ipairs(mt().order) do if K.rung(t)>0 then
        K.sync(t);deposit(t)
        for id in pairs(team(t).posts or {}) do deposit(t,id) end
      end end
      -- A single deterministic pass shares the actual Post stock and reserved balance across pairs.
      local list={}
      for i,a in ipairs(mt().order) do for j=i+1,#mt().order do
        local b=mt().order[j];if M.contacted(a,b) then list[#list+1]=pair(a,b) end
      end end
      if #list==0 or state().fault then return end
      for _,p in ipairs(list) do
        local pending={}
        for _,id in ipairs(p.pending) do
          local tx=txget(p,id);deliver(p,tx)
          if tx.status=='in_transit' or tx.status=='waiting' then pending[#pending+1]=id end
        end
        p.pending=pending
      end
      if tick%config('batch_ticks')==0 and state().last_batch~=tick then
        state().last_batch=tick
        for _,p in ipairs(list) do match_pair(p) end
      end
      if tick%3600==0 and state().measure_tick~=tick then state().measure_tick=tick;K.measure() end
    end
    function K.audit()
      local s=state();local wallets,reserved,escrow=0,0,0;local faults={}
      if s.fault then faults[#faults+1]='market quarantined' end
      for t,v in pairs(s.teams) do
        local expected=0
        for _,o in pairs(v.orders) do if o.side=='buy' and o.status=='open' then expected=expected+(o.count-o.matched)*o.price end end
        if expected~=v.reserved or v.reserved<0 or v.wallet<v.reserved then faults[#faults+1]='wallet '..t end
        wallets=wallets+v.wallet;reserved=reserved+v.reserved
      end
      for _,p in pairs(s.pairs) do for _,tx in ipairs(p.transactions) do
        escrow=escrow+tx.escrow;if tx.status=='quarantined' then faults[#faults+1]='transaction '..p.a..'/'..p.b..'/'..tx.id end
      end end
      local total=wallets+escrow+s.physical+(s.destroyed or 0)
      if total~=s.issuance then faults[#faults+1]='coin conservation' end
      return {issuance=s.issuance,wallets=wallets,reserved=reserved,escrow=escrow,physical=s.physical,destroyed=s.destroyed or 0,total=total,faults=faults}
    end
    function K.operator.mt_market(a)
      local s=state()
      if a.profile~=nil then
        local p=PROFILES[a.profile];assert(p,'profile: full (the only profile)')
        assert(a.config==nil,'profile and config: one at a time')
        a.config=copy(p);a.config.grants=copy(CFG.grants)
      end
      if a.config then
        for k,v in pairs(a.config) do
          assert(CFG[k]~=nil,'unknown market setting')
          if k=='grants' then
            assert(type(v)=='table','grants: table')
            for name,n in pairs(v) do assert(CFG.grants[name]~=nil,'unknown grant tier');integer(n,0,1000000,name) end
          elseif k=='raid_share' then
            assert(type(v)=='number' and v>=0 and v<=1,'raid_share: a number 0..1')
          elseif k=='growth_coin_per_rate' or k=='level_rate' then
            assert(type(v)=='number' and v==v and v>=0 and v<=1000000,k..': finite number 0..1000000')
          elseif type(CFG[k])=='boolean' then assert(type(v)=='boolean','boolean setting')
          else
            integer(v,1,216000,k)
            if k=='batch_ticks' or k=='transit_ticks' then assert(v%60==0,'timings must be whole seconds') end
          end
        end
        if a.config.enabled==false then
          for _,p in pairs(s.pairs) do for _,tx in ipairs(p.transactions) do assert(terminal(tx),'cannot disable with unsettled cargo') end end
          for t,v in pairs(s.teams) do for _,o in pairs(v.orders) do cancel_order(t,o,'market disabled') end end
        end
        -- Settle the old rates first. Disabled periods must never earn back-pay on re-enable.
        for _,t in ipairs(mt().order or {}) do K.sync(t) end
        if a.config.enabled==false then
          for _,v in pairs(s.teams) do if v.research_income then v.research_income.active=false end end
        end
        s.config=s.config or {};for k,v in pairs(a.config) do
          if k=='grants' then local merged=copy(config('grants'));for name,n in pairs(v) do merged[name]=n end;s.config.grants=merged
          else s.config[k]=v end
        end
      end
      if a.profile~=nil then s.config.profile=a.profile;s.config.profile_tick=game.tick end
      for _,t in ipairs(mt().order or {}) do K.sync(t) end
      if a.compact==true then K.compact(true) end
      local public_pairs={}
      for key,p in pairs(s.pairs) do
        local row={a=p.a,b=p.b,next=p.next,transactions={},pending=copy(p.pending),folded=copy(p.folded)}
        for _,tx in ipairs(p.transactions) do
          local v={};for k,x in pairs(tx) do if k~='legs' then v[k]=copy(x) end end;v.legs={}
          for _,l in ipairs(tx.legs) do
            local leg={};for k,x in pairs(l) do if k~='entity' and k~='wreck' then leg[k]=copy(x) end end
            v.legs[#v.legs+1]=leg
          end
          row.transactions[#row.transactions+1]=v
        end
        public_pairs[key]=row
      end
      local out={audit=K.audit(),research_reference_prices=copy(SCIENCE),teams={},pairs=public_pairs,markers={},last_prices={},records=K.sizes(),measurements=copy(s.measurements or {})}
      -- (mt302) the settings in force, and the pact settings beside them (a full game uses pacts.lua's DEFAULTS)
      out.settings={profile=s.config and s.config.profile or nil}
      for k in pairs(CFG) do out.settings[k]=copy(config(k)) end
      out.pact_settings={end_notice_s=cfg('end_notice_s'),share_max_score=cfg('share_max_score'),expires_min=cfg('expires_min'),terms=copy(cfg('terms'))}
      for _,p in pairs(s.pairs) do
        local prices={}
        for name,v in pairs(p.folded and p.folded.prints or {}) do
          prices[name]={a=p.a,b=p.b,item=name,price=v.price,count=v.count,tick=v.tick,prints=v.prints}
        end
        for _,tx in ipairs(p.transactions) do
          if tx.price then
            local prior=prices[tx.item]
            prices[tx.item]={a=p.a,b=p.b,item=tx.item,price=tx.price,count=tx.count,tick=tx.tick,prints=(prior and prior.prints or 0)+1}
          end
        end
        for _,v in pairs(prices) do v.thin=v.prints==1;out.last_prices[#out.last_prices+1]=v end
        for _,id in ipairs(p.pending) do
          local tx=txget(p,id)
          for _,leg in ipairs(tx.legs) do
            local from,to=post(leg.from,leg.from_post),post(leg.to,leg.to_post)
            if not leg.loss and leg.delivered<leg.count and from and from.valid and to and to.valid then
              local fraction=math.min(1,math.max(0,(game.tick-tx.tick)/(tx.eta-tx.tick)))
              out.markers[#out.markers+1]={id=tx.id,from=leg.from,to=leg.to,item=leg.item,count=leg.count-leg.delivered,
                x=leg.position and leg.position.x or from.position.x+(to.position.x-from.position.x)*fraction,
                y=leg.position and leg.position.y or from.position.y+(to.position.y-from.position.y)*fraction,
                surface=to.surface.platform and 'platform' or to.surface.name,state=tx.status,arrival_tick=not tx.freight and tx.eta or nil}
            end
          end
        end
      end
      for _,t in ipairs(mt().order or {}) do out.teams[t]=K.status(t) end
      return out
    end
    function K.operator.mt_market_tick() K.tick(game.tick);return K.audit() end
    function K.on_console_chat(event)
      local h=mt() and mt().humans;local pl=event.player_index and game.get_player(event.player_index)
      if not (h and pl and h.players[pl.name] and pl.force.name==h.team) then return end
      local action,rest=(event.message or ''):match('^!market%s*([%w_]*)%s*(.*)$')
      if not action then return end
      if action=='' or action=='list' then action='market' end
      local store=state();store.chat_seq=(store.chat_seq or 0)+1
      K.human_request_id='human/'..pl.name..'/'..store.chat_seq
      local ok,res=pcall(function()
        local a=rest~='' and helpers.json_to_table(rest) or {}
        if not BASE_SCHEMA[action] then fail('unsupported action','describe {}') end
        return api.as_team(h.team,function() return invoke(h.team,action,a,pl) end)
      end)
      K.human_request_id=nil
      pl.force.print('[market] '..(ok and helpers.table_to_json(res) or ('refused: '..tostring(res))))
    end
    K.PRICES=PRICES
    return K
  end)()
  M.market.on_delivery=function(from,to,item,n)
    if not (mt() and mt().pacts) then return end
    for _,p in pairs(st().by_id) do
      if p.status=='active' and ((p.a==from and p.b==to) or (p.b==from and p.a==to)) then
        p.ledger=p.ledger or {}
        count_to(p,'sent',from,item,n);count_to(p,'received',to,item,n)
      end
    end
  end
  return M
end
