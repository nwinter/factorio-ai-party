-- (mt281, private) Pacts between teams on a multi-team map (docs/mt-diplomacy.md): proposed by one team, accepted by
-- the other; terms: a cease-fire, score shares, a border depot (items moved less a cut), obligations reported as facts.
-- The actions open for a team at its first contact with another (multiteam.lua's record), and only towards a team it
-- has had contact with. Nothing runs on a map without teams.
--   agents: pact_propose, pact_accept, pact_decline, pact_withdraw, pact_amend, pact_end, pacts (read)
--   the human team: the same through chat, "!pact ACTION {json}" (humans.lua's roster)
--   operator: mt_pacts {config?} (settings; the pacts and departures), mt_pacts_tick (test: the step now)
-- Settings (mt_pacts config): cut 0.2, move_s 10, end_notice_s 0, share_max_score 1.4, expires_min 60, check_s 3600.
return function(api)
  local M = {operator={}}
  -- (mt284, Nick d29 14:00) end_notice_s 0: the cease-fire lifts on the tick a side ends the pact; share_max_score 1.4:
  -- no member's allied score above it (the solo edge is 1.5), so no team-up pays more than winning alone
  local DEFAULTS = {cut=0.2, move_s=10, end_notice_s=0, share_max_score=1.4, expires_min=60, check_s=3600,
    terms={cease_fire=true, shares=true, depot=true, obligations=true}}
  local KINDS = {deliver=true, keep_out=true, no_attack=true}
  local MAX_PACTS, MAX_DEPARTURES, NOTE = 64, 50, 500
  local function mt() return api.state().mt end
  local function st()
    local m = mt()
    m.pacts = m.pacts or {next=1, by_id={}, hits={}, departures={}, platforms={}}
    m.pacts.config = m.pacts.config or {}
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
    if t.depot then parts[#parts+1] = string.format('a depot at (%d,%d) on %s, cut %d%%', math.floor(t.depot.x), math.floor(t.depot.y), t.depot.surface or 'nauvis', math.floor(cfg('cut') * 100 + 0.5)) end
    for _, o in ipairs(t.obligations or {}) do
      if o.kind == 'deliver' then parts[#parts+1] = string.format('%s delivers %d %s an hour', o.who, o.count, o.item)
      elseif o.kind == 'keep_out' then parts[#parts+1] = string.format('%s builds nothing within %d of (%d,%d)', o.who, o.r, math.floor(o.x), math.floor(o.y))
      elseif o.kind == 'no_attack' then parts[#parts+1] = string.format('%s hits nothing of %s', o.who, o.target) end
    end
    return #parts > 0 and table.concat(parts, '; ') or 'no terms'
  end

  -- Arguments: the terms checked against the two teams and the settings.
  local function check_terms(t, a, b)
    assert(type(t) == 'table', 'terms: {cease_fire?, shares?, depot?, obligations?}')
    local on = cfg('terms')
    local out = {}
    for k in pairs(t) do assert(on[k], 'terms: no ' .. tostring(k) .. ' (cease_fire, shares, depot, obligations)') end
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
    if t.depot ~= nil then
      local d = t.depot
      assert(type(d) == 'table' and tonumber(d.x) and tonumber(d.y), 'depot: {x, y, surface?}')
      local surface = game.get_surface(d.surface or 'nauvis')
      assert(surface, 'depot: no surface ' .. tostring(d.surface))
      out.depot = {surface=surface.name, x=math.floor(tonumber(d.x)) + 0.5, y=math.floor(tonumber(d.y)) + 0.5}
    end
    if t.obligations ~= nil then
      assert(type(t.obligations) == 'table' and #t.obligations <= 6, 'obligations: a list of at most 6')
      out.obligations = {}
      for i, o in ipairs(t.obligations) do
        assert(type(o) == 'table' and KINDS[o.kind], 'obligation ' .. i .. ': kind deliver, keep_out or no_attack')
        assert(o.who == a or o.who == b, 'obligation ' .. i .. ': who is ' .. a .. ' or ' .. b)
        local r = {id=i, who=o.who, kind=o.kind}
        if o.kind == 'deliver' then
          assert(out.depot, 'obligation ' .. i .. ': a delivery needs a depot in the terms')
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
    local m={kind='diplomacy',seq=c.next,tick=game.tick,from_team=team,to_team=a.to,agent=who,text=text}
    c.next=c.next+1;c.messages[#c.messages+1]=m
    if api.on_message then api.on_message(m) end
    while #c.messages>100 do table.remove(c.messages,1) end
    local line='Diplomacy '..team..' ('..who..') -> '..a.to..': '..text
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
    return {with=a.with,messages=out,last_seq=c.next-1,tick=game.tick,
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

  -- The depot: four steel chests in a row, each team's sending chest and receiving chest, indestructible, not
  -- minable, tagged on each team's map.
  local function place_depot(p, old)
    local d = p.terms.depot
    local previous = old and old.terms.depot
    -- An amendment at the same depot retains the inventories and their ownership.
    if previous and previous.surface == d.surface and previous.x == d.x and previous.y == d.y and previous.chests then
      local n = 0
      for _, c in pairs(previous.chests) do if c.valid then n = n + 1 end end
      if n == 4 then d.chests = previous.chests; return end
    end
    local surface = game.get_surface(d.surface)
    local spots = {{p.a, 'send', 0}, {p.a, 'receive', 1}, {p.b, 'receive', 2}, {p.b, 'send', 3}}
    local chests, created = {}, {}
    local ok, err = pcall(function()
      for _, s in ipairs(spots) do
        local at = {x=d.x + s[3], y=d.y}
        assert(surface.can_place_entity{name='steel-chest', position=at, force=s[1]},
          'depot: the spot (' .. at.x .. ',' .. at.y .. ') is taken')
        local c = surface.create_entity{name='steel-chest', position=at, force=s[1], create_build_effect_smoke=false}
        assert(c, 'depot: the spot (' .. at.x .. ',' .. at.y .. ') is taken')
        created[#created+1] = c
        c.destructible = false
        c.minable_flag = false
        chests[s[1] .. ' ' .. s[2]] = c
      end
    end)
    if not ok then
      for _, c in ipairs(created) do if c.valid then c.destroy() end end
      error(err, 0)
    end
    d.chests = chests
    for _, s in ipairs(spots) do
      pcall(function() game.forces[s[1]].add_chart_tag(surface, {position=chests[s[1] .. ' ' .. s[2]].position, text='pact #' .. p.id .. ' ' .. s[2]}) end)
    end
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
    if p.terms.depot then place_depot(p, old and old.status == 'active' and old or nil) end
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
    p.checks = {}
    p.next_check = game.tick + cfg('check_s') * 60
    both(p, string.format('pact #%d between %s and %s holds from tick %d: %s', p.id, p.a, p.b, game.tick, terms_text(p.terms)), true)
    return {pact=M.view(p)}
  end

  -- Ending: the record at once; the engine cease-fire lifts end_notice_s later (M.tick); depot moves stop.
  local lift   -- below: the cease-fire back as the pact found it
  function M.finish(p, team, who, note, quiet)
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

  -- The depot's move: each send chest's stacks into the other team's receive chest, floor(count x (1 - cut)) arriving,
  -- the rest removed; what does not fit waits in the sending chest. Counted in the ledger by game hour.
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
  local function move(p)
    local ch = p.terms.depot.chests or {}
    local cut = cfg('cut')
    for _, from in ipairs({p.a, p.b}) do
      local to = other_of(p, from)
      local src, dst = ch[from .. ' send'], ch[to .. ' receive']
      if src and src.valid and dst and dst.valid then
        local si, di = src.get_inventory(defines.inventory.chest), dst.get_inventory(defines.inventory.chest)
        for i = 1, #si do
          local stack = si[i]
          if stack.valid_for_read then
            local name, count, quality = stack.name, stack.count, stack.quality and stack.quality.name or 'normal'
            local arrive = math.floor(count * (1 - cut))
            local ins = 0
            if arrive > 0 then
              local spec = {name=name, count=arrive, quality=quality}
              if stack.spoil_percent and stack.spoil_percent > 0 then spec.spoil_percent = stack.spoil_percent end
              ins = di.insert(spec)
            end
            local used = ins >= arrive and count or math.min(count, math.ceil(ins / (1 - cut)))
            if used > 0 then
              stack.count = count - used
              count_to(p, 'sent', from, name, used); count_to(p, 'received', to, name, ins); count_to(p, 'cut', from, name, used - ins)
            end
          end
        end
      end
    end
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
            local active = {}
            for _, p in pairs(s.by_id) do
              if p.status == 'active' and (p.a == team or p.b == team) then
                active[#active+1] = {id=p.id, with=other_of(p, team), cease_fire=p.terms.cease_fire, shares=p.terms.shares}
              end
            end
            s.departures[#s.departures+1] = {team=team, platform=pl.name, from=was, tick=game.tick, pacts=active}
            if #s.departures > MAX_DEPARTURES then table.remove(s.departures, 1) end
          end
          s.platforms[key] = at or ''
        end
      end
    end
  end

  function M.tick(tick)
    local s = mt() and mt().pacts
    if not s then return end
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
    if tick % (cfg('move_s') * 60) == 31 then
      for _, p in pairs(s.by_id) do
        local frozen = mt().humans and mt().humans.state == 'frozen' and (mt().humans.team == p.a or mt().humans.team == p.b)
        if p.status == 'active' and p.terms.depot and not frozen then move(p) end
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
      return {pacts=list(team),contacts=contacts,tick=game.tick,end_notice_s=cfg('end_notice_s'),
        communication='say/tell/board are private to your team. Use diplomacy_send {to: TEAM, text: MESSAGE} to negotiate with a contacted team; diplomacy {with: TEAM} reads that conversation.'}
    end,
  }
  M.reads = {pacts=true,diplomacy=true}
  M.schema = {
    diplomacy_send={to='one contacted team; every agent of that team and your own team receives it',text='1..500 bytes; explicit cross-team negotiation, six messages per team per game minute',
      returns='message with authenticated sender, pair-local seq and game tick; ordinary say/tell/board remain private to your team'},
    diplomacy={with='one contacted team',since='optional nonnegative sequence from this conversation',limit='1..50, default 20; newest messages kept',
      returns='messages for your conversation with that team only, last_seq; no third-team conversations or private chat'},
    pact_propose={with='the other team (a team you have had contact with)', terms='{cease_fire?: true, shares?: {TEAM: fraction, both teams, summing to 1, each at most 0.70}, depot?: {x, y, surface?}, obligations?: [{kind: "deliver", who, item, count (an hour, through the depot)}, {kind: "keep_out", who, x, y, r, surface?}, {kind: "no_attack", who, target}]}',
      note='optional text, 500 bytes', expires_min='optional minutes it stays open (default 60)', returns='pact: its number, terms and status; the other team gets it as a fact line'},
    pact_accept={id='a pact proposed to your team', returns='pact; its terms hold from now (the cease-fire both ways, the depot\'s chests placed)'},
    pact_decline={id='a pact proposed to your team', note='optional text', returns='pact'},
    pact_withdraw={id='your team\'s open proposal', returns='pact'},
    pact_amend={id='an active pact', terms='as pact_propose', note='optional text', expires_min='optional proposal lifetime in minutes', returns='pact: a new proposal that replaces it when accepted'},
    pact_end={id='an active pact', note='optional text', returns='pact; trade ends now; cease-fire lifts at lift_tick if a notice is configured (pacts reports end_notice_s), otherwise immediately'},
    pacts={returns='pacts: your team\'s pacts and proposals, with this hour\'s depot ledger and the obligations\' last measurements'},
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
  return M
end
