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
  -- mt296: the market factory lives beside pacts so the deployed harness needs no new require.
  -- Only stateless normal items cross this boundary. Cargo is persistent escrow, never an exposed chest.
  M.market = (function()
    local K={handlers={},reads={market=true},operator={}}
    local TECH,POST,COIN='mt-coinage','mt-trading-post','mt-coin'
    local PRICES={['iron-ore']=10,['copper-ore']=10,coal=10,stone=10,['iron-plate']=20,['copper-plate']=20,
      ['steel-plate']=100,['iron-gear-wheel']=40,['copper-cable']=10,['electronic-circuit']=70,
      ['advanced-circuit']=260,['processing-unit']=1400,['plastic-bar']=30,sulfur=30,battery=80}
    local CFG={enabled=true,transit_ticks=5400,batch_ticks=600,pair_stacks=10,destructible=false}
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
    local function keys(t) local r={} for k in pairs(t) do r[#r+1]=k end table.sort(r) return r end
    local function pair(a,b)
      local key=a<b and a..'>'..b or b..'>'..a
      local s=state()
      s.pairs[key]=s.pairs[key] or {a=a,b=b,next=1,book_next=1,book_ids={},filled_by_order={},transactions={},pending={},usage={}}
      return s.pairs[key]
    end
    local function inv(t)
      local p=team(t).post
      return p and p.valid and p.get_inventory(defines.inventory.chest) or nil
    end
    local function amount(t,item)
      local i=inv(t);return i and i.get_item_count{name=item,quality='normal'} or 0
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
    local function item(n)
      if type(n)~='string' or not PRICES[n] then fail('item unavailable; normal, stateless, nonspoiling reference items only') end
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
    local function order_key(side,itemname,other) return side..'/'..itemname..'/'..other end
    local function can_pair(o,other) return o.status=='open' and (o.other=='*' or o.other==other) end
    local function order_view(o)
      return {id=o.id,side=o.side,item=o.item,price=o.price,keep=o.keep,count=o.count,matched=o.matched,
        remaining=o.count-o.matched,status=o.status,revision=o.revision,created_tick=o.tick,give=copy(o.give),get=copy(o.get)}
    end
    local function cancel_order(t,o,reason)
      if o.status~='open' then return end
      if o.side=='buy' then team(t).reserved=team(t).reserved-(o.count-o.matched)*o.price end
      o.status='cancelled';o.revision=o.revision+1;o.ended_tick=game.tick;o.reason=reason
    end
    -- First contact enables red science per force. Creation and grants never run during on_load.
    function K.sync(t)
      if K.rung(t)==0 or mt().market and mt().market.fault then return end
      local s=team(t);local f=game.forces[t];local tech=f.technologies[TECH]
      if tech then tech.enabled=true;tech.visible_when_disabled=false end
      if not (s.post and s.post.valid) then
        local home=(mt().spawns or {})[t] or {};local surf=game.get_surface('nauvis')
        local at=s.home or home.nauvis or f.get_spawn_position(surf)
        local pos=surf.find_non_colliding_position(POST,{x=at.x+4,y=at.y},32,.5)
        if pos then
          s.post=assert(surf.create_entity{name=POST,position=pos,force=f},'Trading Post creation failed')
          s.post.minable_flag=false;s.post.destructible=config('destructible');s.home=s.home or copy(at)
          f.add_chart_tag(surf,{position=pos,text='Trading Post'})
          fact(t,'Trading Post at ('..pos.x..','..pos.y..'). Call status {} for stock and item swaps; research {technology="mt-coinage"} opens priced orders.',true)
        end
      end
      if s.post and s.post.valid then s.post.destructible=config('destructible') end
      if tech and tech.researched and not s.granted then
        s.granted=true;s.wallet=s.wallet+10000;state().issuance=state().issuance+10000
        fact(t,'Coinage: 10,000 coin granted once. Call market {} for the book and exact accepting calls. Money never scores.',true)
        news(t,nil,'coinage',t..' researches Coinage: the fixed 10,000 coin grant opens priced orders.')
      end
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
      if rec then
        if rec.payload~=payload then fail('request id already used with different arguments') end
        if rec.status=='committed' then return copy(rec.result) end
        error(rec.error or 'request quarantined; call market {}',0)
      end
      rec={payload=payload,status='started',tick=game.tick};journal[id]=rec
      local ok,res=pcall(fn)
      if not ok then rec.status='refused';rec.error=tostring(res);error(res,0) end
      rec.status='committed';rec.result=copy(res);return res
    end
    local function add_order(t,side,a)
      local name=item(side=='offer' and type(a.give)=='table' and a.give.item or a.item)
      local other=counter(t,side=='buy' and a.from or a.to)
      local n=side=='offer' and 1 or integer(a.count,1,100000,'count')
      local price,keep,give,get
      if side=='offer' then
        give={item=name,count=integer(a.give.count,1,10000,'give.count')}
        if type(a.get)~='table' then fail('get: {item,count}') end
        get={item=item(a.get.item),count=integer(a.get.count,1,10000,'get.count')}
        if get.item==name then fail('swap needs different items') end
        if give.count/prototypes.item[give.item].stack_size+get.count/prototypes.item[get.item].stack_size>config('pair_stacks') then
          fail('swap exceeds pair capacity; use smaller give/get counts')
        end
        for k in pairs(a.give) do if k~='item' and k~='count' then fail('give: only item,count') end end
        for k in pairs(a.get) do if k~='item' and k~='count' then fail('get: only item,count') end end
      else
        price=integer(a.price,math.ceil(PRICES[name]*.5),PRICES[name]*3,'price')
        if side=='sell' then keep=integer(a.keep,0,100000,'keep') end
      end
      local s=team(t);local key=order_key(side,name,other);local old=s.orders[key]
      if old and old.status=='open' then
        fail('a shared order already exists',string.format('cancel {"item":"%s","side":"%s","revision":%d%s}',name,side,old.revision,
          other~='*' and (',"team":"'..other..'"') or ''))
      end
      if side=='buy' and n*price>s.wallet-s.reserved then fail('insufficient available coin; lower count or sell surplus') end
      local o={id=s.next,team=t,side=side,item=name,other=other,count=n,price=price,keep=keep,give=give,get=get,
        matched=0,status='open',revision=old and old.revision+1 or 1,tick=game.tick}
      s.next=s.next+1;s.orders[key]=o
      if side=='buy' then s.reserved=s.reserved+n*price end
      return {order=order_view(o),next={action='status',args={}}}
    end
    local function cancel(t,a)
      local name=item(a.item)
      if K.rung(t)==1 and a.side~='offer' then fail('side: offer') end
      if a.side~='buy' and a.side~='sell' and a.side~='offer' then fail('side: buy, sell or offer') end
      local other=counter(t,a.team);local o=team(t).orders[order_key(a.side,name,other)]
      if not o or o.status~='open' then fail('no unmatched live order') end
      if a.revision~=nil and a.revision~=o.revision then fail('order changed; read its current revision') end
      cancel_order(t,o,'cancel');return {order=order_view(o),note='Matched cargo still arrives; its payment remains committed.'}
    end
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
      return {action=action,args=a}
    end
    function K.status(t)
      if K.rung(t)==0 then return nil end
      local s=team(t);local p=s.post
      local out={fault=state().fault and {state='quarantined',next={action='status',args={}}} or nil,
        rung=K.rung(t)==2 and 'coinage' or 'swap',post=p and p.valid and {position=copy(p.position),surface=p.surface.name} or false,
        stock={},orders={},offers={},inbound={},fills={},embargoed={},transit_seconds=config('transit_ticks')/60,pair_stacks_per_minute=config('pair_stacks')}
      if K.rung(t)==2 then out.wallet=s.wallet;out.reserved=s.reserved;out.available=s.wallet-s.reserved;out.reference_prices=copy(PRICES) end
      for _,n in ipairs(keys(PRICES)) do local nstock=amount(t,n);if nstock>0 then out.stock[n]=nstock end end
      for _,key in ipairs(keys(s.orders)) do
        local o=s.orders[key];local row=order_view(o)
        if #contacts(t)>1 and o.other~='*' then row[o.side=='buy' and 'from' or 'to']=o.other end
        out.orders[#out.orders+1]=row
      end
      for _,u in ipairs(contacts(t)) do
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
          if o.status~='cancelled' and (o.other=='*' or o.other==t) and remaining>0 and (o.side=='offer' or K.rung(t)==2) then
            -- No peer wallet, stock, global order id, rival coordinates, or unrelated fill count.
            local row={id=book_id(pairdata,o),side=o.side,item=o.item,price=o.price,give=copy(o.give),get=copy(o.get),accept=accepting(t,o,remaining)}
            if row.accept==false then row.blocked='no available coin; sell surplus first';row.next={action='status',args={}} end
            if blocked then row.accept=false;row.blocked='new matches stopped by embargo';row.next={action='status',args={}} end
            if #contacts(t)>1 then row.team=u end
            out.offers[#out.offers+1]=row
          end
        end
        for _,tx in ipairs(pairdata.transactions) do
          local row={id=tx.id,state=tx.status,matched_tick=tx.tick,arrival_tick=tx.eta,price=tx.price,item=tx.item,count=tx.count}
          if #contacts(t)>1 then row.team=u end
          if tx.status~='delivered' then
            for _,leg in ipairs(tx.legs) do if leg.to==t then
              local r=copy(row);r.item=leg.item;r.count=leg.count-leg.delivered;r.delivered=leg.delivered
              if r.count>0 then
                r.next=tx.status=='waiting' and out.post and {action='collect',args={position=out.post.position,count=100}} or {action='status',args={}}
                out.inbound[#out.inbound+1]=r
              end
            end end
          end
          out.fills[#out.fills+1]=row
        end
      end
      while #out.fills>20 do table.remove(out.fills,1) end
      if K.rung(t)==1 then out.next={action='research',args={technology=TECH}} end
      return out
    end
    local BASE_SCHEMA={
      offer={give='{item,count}: normal stateless goods from your Post',get='{item,count}: goods wanted; one standing lot',returns='shared order; opposite offer accepts; status shows exact calls'},
      market={returns='wallet, reserved, Post stock, own orders, pair book with accepting calls, inbound cargo and pair-local fills'},
      sell={item='reference item',price='integer coin per item, 0.5..3 times reference',keep='required stock reserve, >=0',count='required lifetime item cap',returns='shared standing order; matched items cannot be cancelled'},
      buy={item='reference item',price='integer maximum coin per item, 0.5..3 times reference',count='required lifetime item cap including cargo already in transit',returns='shared order; count*price reserved'},
      cancel={item='item of the order (give.item for a swap)',side='offer, buy or sell',revision='optional expected shared order revision',returns='unmatched quantity cancelled; cargo already matched still arrives'},
      embargo={team='contacted team to stop new matches with',returns='new matches stopped; existing cargo arrives'},
    }
    function K.open_action(t,name)
      local rung=K.rung(t)
      return BASE_SCHEMA[name] and (rung==2 or rung==1 and (name=='offer' or name=='cancel')) or false
    end
    function K.schema(t)
      local schemas={}
      for n,schema in pairs(BASE_SCHEMA) do if K.open_action(t,n) then schemas[n]=copy(schema) end end
      if K.rung(t)==1 and schemas.cancel then schemas.cancel.side='offer' end
      if #contacts(t)>1 then
        if schemas.offer then schemas.offer.to='optional contacted team' end
        if schemas.sell then schemas.sell.to='optional contacted team' end
        if schemas.buy then schemas.buy.from='optional contacted team' end
        if schemas.cancel then schemas.cancel.team='counterparty of the order; omit for the unaddressed order' end
      end
      return schemas
    end
    function K.names() return BASE_SCHEMA end
    local function invoke(t,action,a)
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
    for name in pairs(BASE_SCHEMA) do K.handlers[name]=function(_,a) return invoke(api.team_now(),name,a or {}) end end
    -- All economic mutations keep a transaction first. Catch only to mark quarantine, then rethrow.
    local function transact(tx,fn)
      local ok,err=pcall(fn)
      if not ok then
        tx.status='quarantined';tx.error=tostring(err);tx.failed_tick=game.tick
        state().fault={tick=game.tick,error=tostring(err),transaction=tx.id}
        error(err,0)
      end
    end
    local function unitcost(name) return 1/prototypes.item[name].stack_size end
    local function capacity(p)
      local used=0;local keep={}
      for _,v in ipairs(p.usage) do if game.tick-v.tick<3600 then keep[#keep+1]=v;used=used+v.stacks end end
      p.usage=keep;return math.max(0,config('pair_stacks')-used)
    end
    local function matched(o,n)
      o.matched=o.matched+n;o.revision=o.revision+1
      if o.matched==o.count then o.status='filled';o.ended_tick=game.tick end
    end
    local function same_surface(a,b)
      local x,y=team(a).post,team(b).post
      return x and x.valid and y and y.valid and x.surface.index==y.surface.index
    end
    local function newtx(p,legs,price)
      local tx={id=p.next,status='preparing',tick=game.tick,eta=game.tick+config('transit_ticks'),legs=legs,price=price,escrow=0,
        item=legs[1].item,count=legs[1].count}
      p.next=p.next+1;p.transactions[#p.transactions+1]=tx;p.pending[#p.pending+1]=tx.id;return tx
    end
    local function remove_goods(leg)
      local i=assert(inv(leg.from),'source Post unavailable')
      leg.removed=i.remove{name=leg.item,count=leg.count,quality='normal'}
      assert(leg.removed==leg.count,'short removal: transaction quarantined')
    end
    local function emit_fill(p,tx)
      local l=tx.legs[1]
      local line=tx.price and string.format('%s sells %d %s to %s at %d; arrival in %d seconds',l.from,l.count,l.item,l.to,tx.price,config('transit_ticks')/60)
        or string.format('%s swaps %d %s with %s; arrival in %d seconds',l.from,l.count,l.item,l.to,config('transit_ticks')/60)
      fact(p.a,line,true);fact(p.b,line,true)
      news(p.a,p.b,'fill',line,tx.id)
    end
    local function fill(p,ask,bid)
      local price=(ask.tick<bid.tick or ask.tick==bid.tick and game.forces[ask.team].index<game.forces[bid.team].index) and ask.price or bid.price
      local n=math.min(ask.count-ask.matched,bid.count-bid.matched,math.max(0,amount(ask.team,ask.item)-ask.keep),
        math.floor((capacity(p)+1e-9)/unitcost(ask.item)))
      if n<1 then return end
      local tx=newtx(p,{{from=ask.team,to=bid.team,item=ask.item,count=n,delivered=0}},price)
      transact(tx,function()
        remove_goods(tx.legs[1])
        local b=team(bid.team);local cost=n*price
        assert(b.reserved>=n*bid.price and b.wallet>=cost,'coin reservation invariant')
        b.reserved=b.reserved-n*bid.price;b.wallet=b.wallet-cost;tx.escrow=cost
        matched(ask,n);matched(bid,n)
        for _,o in ipairs({ask,bid}) do local k=o.team..'/'..o.id;p.filled_by_order[k]=(p.filled_by_order[k] or 0)+n end
        p.usage[#p.usage+1]={tick=game.tick,stacks=n*unitcost(ask.item)};tx.status='in_transit'
      end)
      emit_fill(p,tx)
    end
    local function swap(p,a,b)
      if a.give.item~=b.get.item or a.get.item~=b.give.item or a.give.count~=b.get.count or a.get.count~=b.give.count then return end
      local stacks=a.give.count*unitcost(a.give.item)+b.give.count*unitcost(b.give.item)
      if stacks>capacity(p)+1e-9 or amount(a.team,a.give.item)<a.give.count or amount(b.team,b.give.item)<b.give.count then return end
      local tx=newtx(p,{{from=a.team,to=b.team,item=a.give.item,count=a.give.count,delivered=0},
        {from=b.team,to=a.team,item=b.give.item,count=b.give.count,delivered=0}})
      transact(tx,function()
        for _,leg in ipairs(tx.legs) do remove_goods(leg) end
        matched(a,1);matched(b,1)
        for _,o in ipairs({a,b}) do local k=o.team..'/'..o.id;p.filled_by_order[k]=(p.filled_by_order[k] or 0)+1 end
        p.usage[#p.usage+1]={tick=game.tick,stacks=stacks};tx.status='in_transit'
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
      if frozen(p.a) or frozen(p.b) or (p.embargo and next(p.embargo)) or not same_surface(p.a,p.b) then return end
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
      if game.tick<tx.eta then return end
      transact(tx,function()
        local complete=true
        for _,leg in ipairs(tx.legs) do
          local remaining=leg.count-leg.delivered;local i=inv(leg.to)
          if remaining>0 and i then
            local n=i.insert{name=leg.item,count=remaining,quality='normal'}
            assert(n>=0 and n<=remaining and n==math.floor(n),'invalid inserted count')
            leg.delivered=leg.delivered+n
            if tx.price then
              local pay=n*tx.price;assert(tx.escrow>=pay,'payment escrow invariant')
              tx.escrow=tx.escrow-pay;team(leg.from).wallet=team(leg.from).wallet+pay
            end
            if n>0 and K.on_delivery then K.on_delivery(leg.from,leg.to,leg.item,n) end
          end
          if leg.delivered<leg.count then complete=false end
        end
        tx.status=complete and 'delivered' or 'waiting'
        if complete then tx.ended_tick=game.tick end
      end)
    end
    -- The wallet includes unmatched buy reserves. A raid cancels bids if needed to free the stolen amount;
    -- matched purchases have already left that wallet into payment escrow and are irrevocable.
    local deposit
    function K.on_died(event)
      local e=event.entity
      if not (mt() and e and e.valid and e.name==POST) then return end
      local t=e.force.name;local s=state().teams[t]
      if not s or not s.post or s.post.unit_number~=e.unit_number or s.spills[tostring(e.unit_number)] then return end
      if state().fault then return end
      -- Coins just inserted since the last one-second pass already belong to this team.
      -- Credit them before chest destruction can erase their physical stack.
      deposit(t)
      local n=math.floor(s.wallet*.25)
      local rec={unit=e.unit_number,count=n,status='preparing',tick=game.tick};s.spills[tostring(e.unit_number)]=rec
      transact(rec,function()
        if s.wallet-s.reserved<n then for _,o in pairs(s.orders) do if o.side=='buy' then cancel_order(t,o,'home Post raided') end end end
        s.wallet=s.wallet-n;rec.debited=n
        local dropped=n>0 and e.surface.spill_item_stack{position=e.position,stack={name=COIN,count=n},enable_looted=true,
          allow_belts=false,use_start_position_on_failure=true,drop_full_stack=true} or {}
        local actual=0
        for _,v in pairs(dropped or {}) do if v.valid and v.stack and v.stack.valid_for_read then actual=actual+v.stack.count end end
        rec.dropped=actual;state().physical=state().physical+actual
        assert(actual==n,'coin spill incomplete: quarantined');rec.status='spilled'
      end)
      fact(t,'Home Trading Post destroyed: '..n..' coin spilled in the wreck.',true)
      news(t,nil,'raid',t..' home Trading Post destroyed: '..n..' coin spilled in the wreck.')
    end
    deposit=function(t)
      local i=inv(t);if not i then return end
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
    function K.tick(tick)
      if not mt() or not next(teams()) or not config('enabled') or tick%60~=0 then return end
      if mt().market and mt().market.fault then return end
      for _,t in ipairs(mt().order) do if K.rung(t)>0 then K.sync(t);deposit(t) end end
      -- A single deterministic pass shares the actual Post stock and reserved balance across pairs.
      local list={}
      for i,a in ipairs(mt().order) do for j=i+1,#mt().order do
        local b=mt().order[j];if M.contacted(a,b) then list[#list+1]=pair(a,b) end
      end end
      if #list==0 or state().fault then return end
      for _,p in ipairs(list) do
        local pending={}
        for _,id in ipairs(p.pending) do
          local tx=p.transactions[id];deliver(p,tx)
          if tx.status=='in_transit' or tx.status=='waiting' then pending[#pending+1]=id end
        end
        p.pending=pending
      end
      if tick%config('batch_ticks')==0 and state().last_batch~=tick then
        state().last_batch=tick
        for _,p in ipairs(list) do match_pair(p) end
      end
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
      local total=wallets+escrow+s.physical
      if total~=s.issuance then faults[#faults+1]='coin conservation' end
      return {issuance=s.issuance,wallets=wallets,reserved=reserved,escrow=escrow,physical=s.physical,total=total,faults=faults}
    end
    function K.operator.mt_market(a)
      local s=state()
      if a.config then
        for k,v in pairs(a.config) do
          assert(CFG[k]~=nil,'unknown market setting')
          if type(CFG[k])=='boolean' then assert(type(v)=='boolean','boolean setting')
          else
            integer(v,1,216000,k)
            if k=='batch_ticks' or k=='transit_ticks' then assert(v%60==0,'timings must be whole seconds') end
          end
        end
        if a.config.enabled==false then
          for _,p in pairs(s.pairs) do for _,tx in ipairs(p.transactions) do assert(tx.status=='delivered','cannot disable with unsettled cargo') end end
          for t,v in pairs(s.teams) do for _,o in pairs(v.orders) do cancel_order(t,o,'market disabled') end end
        end
        s.config=s.config or {};for k,v in pairs(a.config) do s.config[k]=v end
      end
      for _,t in ipairs(mt().order or {}) do K.sync(t) end
      local out={audit=K.audit(),teams={},pairs=s.pairs,markers={},last_prices={}}
      for _,p in pairs(s.pairs) do
        local prices={}
        for _,tx in ipairs(p.transactions) do
          if tx.price then
            local prior=prices[tx.item]
            prices[tx.item]={a=p.a,b=p.b,item=tx.item,price=tx.price,count=tx.count,tick=tx.tick,prints=(prior and prior.prints or 0)+1}
          end
        end
        for _,v in pairs(prices) do v.thin=v.prints==1;out.last_prices[#out.last_prices+1]=v end
        for _,id in ipairs(p.pending) do
          local tx=p.transactions[id]
          for _,leg in ipairs(tx.legs) do
            local from,to=team(leg.from).post,team(leg.to).post
            if from and from.valid and to and to.valid then
              local fraction=math.min(1,math.max(0,(game.tick-tx.tick)/(tx.eta-tx.tick)))
              out.markers[#out.markers+1]={id=tx.id,from=leg.from,to=leg.to,item=leg.item,count=leg.count-leg.delivered,
                x=from.position.x+(to.position.x-from.position.x)*fraction,y=from.position.y+(to.position.y-from.position.y)*fraction,
                surface=to.surface.name,state=tx.status,arrival_tick=tx.eta}
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
        return api.as_team(h.team,function() return invoke(h.team,action,a) end)
      end)
      K.human_request_id=nil
      pl.force.print('[market] '..(ok and helpers.table_to_json(res) or ('refused: '..tostring(res))))
    end
    K.PRICES=PRICES
    return K
  end)()
  return M
end
