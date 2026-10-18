-- circuit_gate {position, all, at?, source?} (d17 batch20 C1, Grok: an inserter gated on bioflux over 200 AND
-- agricultural science under 500, flipped by hand about six times a shift; a logistic condition holds one test). The
-- game's way: a decider combinator reading the logistic network (a roboport set to read its items) with every test in
-- its conditions joined by "and", its output wired to the entity's circuit condition. This does what a player does by
-- hand, through the same actions an agent calls (build from the character's own inventory, in build reach; circuit_set;
-- wire), in that order; a step that fails stops it and the reply says which steps were done and the calls left.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function at(q) return string.format('(%g,%g)', q.x, q.y) end
  local DECIDER = 'decider-combinator'
  -- Where a decider (facing north: 1x2) can stand within wire reach of both ends and build reach of the character:
  -- the free spot nearest the target.
  local function spot(p, target, source, reach)
    local proto = prototypes.entity[DECIDER]
    local wire = try(function() return proto.get_max_circuit_wire_distance() end) or 9
    local function wr(e) return math.min(wire, try(function() return (e.type == 'entity-ghost' and e.ghost_prototype or e.prototype).get_max_circuit_wire_distance() end) or wire) end
    local wt, ws = wr(target), wr(source)
    local best, bd
    local tx, ty = math.floor(target.position.x), math.floor(target.position.y)
    for dx = -8, 8 do
      for dy = -8, 8 do
        local q = {x=tx + dx + 0.5, y=ty + dy + 1}
        local d1 = ((q.x - target.position.x)^2 + (q.y - target.position.y)^2)^0.5
        local d2 = ((q.x - source.position.x)^2 + (q.y - source.position.y)^2)^0.5
        local d3 = ((q.x - p.position.x)^2 + (q.y - p.position.y)^2)^0.5
        if d1 <= wt - 0.5 and d2 <= ws - 0.5 and d3 <= (reach or 10) - 0.5 and (not bd or d1 < bd)
          and p.surface.can_place_entity{name=DECIDER, position=q, direction=defines.direction.north, force=p.force, build_check_type=defines.build_check_type.manual} then
          best, bd = q, d1
        end
      end
    end
    return best, wt, ws
  end
  -- The roboport of the target's logistic network nearest it.
  local function roboport(p, target)
    local net = try(function() return p.surface.find_logistic_network_by_position(target.position, p.force) end)
    local best, bd
    for _, cell in ipairs(net and try(function() return net.cells end) or {}) do
      local o = try(function() return cell.owner end)
      if o and o.valid and o.type == 'roboport' then
        local d = (o.position.x - target.position.x)^2 + (o.position.y - target.position.y)^2
        if not bd or d < bd then best, bd = o, d end
      end
    end
    return best, net
  end
  function M.handler(p, a)
    assert(type(a.all) == 'table' and #a.all >= 1 and #a.all <= 8, 'all is a list of 1..8 conditions, e.g. ["bioflux > 200", "agricultural-science-pack < 500"]')
    for i, c in ipairs(a.all) do assert(type(c) == 'string' or type(c) == 'table', 'all ' .. i .. ' is a condition: "bioflux > 200" or {signal, comparator, value}') end
    local target = api.entity(p, {position=a.position})
    assert(target and target.valid and target.force == p.force, 'position must name an entity of ours with a circuit condition (an inserter, a belt, a pump, ...)')
    local source
    if a.source ~= nil then source = api.entity(p, {position=a.source})
    else
      local net
      source, net = roboport(p, target)
      if not source then
        error(string.format('%s %s is in no logistic network with a roboport of ours (%s); source: {x,y} names the entity whose wire carries the signals',
          target.name, at(target.position), net and 'its network has none' or 'no network there'), 0)
      end
    end
    local done, left = {}, {}
    local held = p.get_main_inventory and try(function() return p.get_main_inventory().get_item_count(DECIDER) end) or 0
    local pos = a.at ~= nil and api.position(a.at) or nil
    local wt, ws
    if not pos then pos, wt, ws = spot(p, target, source, p.build_distance) end
    local conds = {}
    for i, c in ipairs(a.all) do conds[i] = i == 1 and c or (type(c) == 'string' and 'and ' .. c or (function() local t = {}; for k, v in pairs(c) do t[k] = v end; t.compare = 'and'; return t end)()) end
    local decider_args = {conditions=conds, outputs={{signal='signal-check', constant=1}}}
    -- The calls, in order (the reply lists the ones not done when a step fails).
    local function calls(dpos)
      local d = dpos and at(dpos) or '(x,y)'
      return {
        string.format('build {"item":"%s","position":%s,"direction":"north"}', DECIDER, dpos and string.format('{"x":%g,"y":%g}', dpos.x, dpos.y) or '{x,y}'),
        string.format('circuit_set {position: %s, read: {logistic_network_contents: true}} (the roboport)', at(source.position)),
        string.format('wire {from: %s, to: %s, color: red, to_side: input}', at(source.position), d),
        string.format('circuit_set {position: %s, decider: {conditions: [%s], outputs: [{signal: signal-check, constant: 1}]}}', d,
          table.concat((function() local t = {}; for i, c in ipairs(conds) do t[i] = type(c) == 'string' and '"' .. c .. '"' or '{...}' end; return t end)(), ', ')),
        string.format('wire {from: %s, to: %s, color: green, from_side: output}', d, at(target.position)),
        string.format('circuit_set {position: %s, enable: "signal-check > 0"}', at(target.position)),
      }
    end
    if not pos then
      error(string.format('no free tile for a %s within wire reach of %s %s (%g tiles) and %s %s (%g tiles) and your build reach; the calls, from a spot that reaches both: %s',
        DECIDER, target.name, at(target.position), wt or 9, source.name, at(source.position), ws or 9, table.concat(calls(nil), '; ')), 0)
    end
    if held < 1 then
      error(string.format('you hold no %s (the gate takes one from your inventory); the calls once you hold one: %s', DECIDER, table.concat(calls(pos), '; ')), 0)
    end
    local list = calls(pos)
    local decider
    local steps = {
      function()
        local r = api.build(p, {item=DECIDER, position=pos, direction='north'})
        decider = p.surface.find_entities_filtered{position=pos, radius=0.6, name=DECIDER, force=p.force, limit=1}[1]
        assert(decider, 'the build placed no ' .. DECIDER .. (r and r.walking and ' (it walks first: call again once there)' or ''))
        return string.format('built %s at %s from your inventory', DECIDER, at(decider.position))
      end,
      function()
        if source.type ~= 'roboport' then return 'source ' .. source.name .. ' ' .. at(source.position) .. ' as it is' end
        api.circuit_set(p, {position=source.position, read={logistic_network_contents=true}})
        return string.format('roboport %s reads its network\'s items', at(source.position))
      end,
      function() api.wire(p, {from=source.position, to=decider.position, color='red', to_side='input'}); return 'red wire ' .. at(source.position) .. ' -> decider input' end,
      function() api.circuit_set(p, {position=decider.position, decider=decider_args}); return 'decider: ' .. #conds .. ' conditions joined by and, output signal-check 1' end,
      function() api.wire(p, {from=decider.position, to=target.position, color='green', from_side='output'}); return 'green wire decider output -> ' .. target.name .. ' ' .. at(target.position) end,
      function()
        local set = {position=target.position, enable='signal-check > 0'}
        local cb = try(function() return target.get_control_behavior() end)
        local logistic = cb and try(function() return cb.connect_to_logistic_network end)
        if logistic then set.logistic = false end
        api.circuit_set(p, set)
        return target.name .. ' enabled when signal-check > 0' .. (logistic and ' (its logistic condition turned off: the decider holds every test)' or '')
      end,
    }
    for i, step in ipairs(steps) do
      local ok, res = pcall(step)
      if not ok then
        for j = i, #list do left[#left+1] = list[j] end
        error(string.format('step %d failed: %s; done: %s; left: %s', i, api.reason(res), #done > 0 and table.concat(done, '; ') or 'nothing', table.concat(left, '; ')), 0)
      end
      done[#done+1] = res
    end
    local read = try(function() return api.circuit_line(target) end)
    return {decider=decider.position, source={name=source.name, position=source.position}, done=done,
      line=string.format('%s %s runs only while %s (decider %s reading %s %s)', target.name, at(target.position),
        table.concat((function() local t = {}; for i, c in ipairs(a.all) do t[i] = type(c) == 'string' and c or '?' end; return t end)(), ' and '),
        at(decider.position), source.name, at(source.position)), now=read}
  end
  M.schema = {circuit_gate={position='{x,y}: the entity to gate (an inserter, belt, pump, ... of ours with a circuit condition)',
    all='1..8 conditions, all of which must hold: "bioflux > 200", "agricultural-science-pack < 500", or {signal, comparator, value | signal2}',
    at='optional {x,y}: where the decider combinator goes (default: the free tile nearest the entity within wire reach of it and the source and in your build reach)',
    source='optional {x,y}: the entity whose wire carries the signals (default: the roboport of the entity\'s logistic network nearest it, set to read its network\'s items)',
    returns='the game\'s way for two or more tests: a decider combinator from your inventory with every test joined by and, output signal-check 1, fed by the source on a red wire, its output on a green wire to the entity, the entity enabled when signal-check > 0 (a logistic condition on it turned off): decider, source, done (each step), line, now (the entity\'s circuit line); a failed step says which were done and the calls left. Refused before anything changes when you hold no decider-combinator or no tile fits, with the calls'}}
  return M
end
