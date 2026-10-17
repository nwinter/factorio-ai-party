-- Out-of-reach calls walk into reach first (Haiku 22:53: a transfer to a boiler more than 10 tiles away failed unless
-- walk: true was set, a retry each time; friction1300: 16 refusals in one hour where a walk would do). Shifts 12 to 14
-- held 134 out-of-reach refusals in 100 bot-hours (transfer 49, build 39, mine 19, rotate 14, load_silo 6, collect 3,
-- rearm 2, feed 1, refuel 1). Every target lay within 31.3 tiles of the character (to its edge), and 90% ended with
-- the same call made again after a move_to or with walk: true, a median 8 to 14 s later. A target beyond 32 tiles was
-- refused before that, as outside the character's sight (53 such, a median 73 tiles off).
-- So a call whose target is out of reach and within RANGE tiles walks into reach first, and its reply says so
-- (walking); farther, the call is refused, naming the same call with walk: true; walk: false refuses as before.
-- Every such walk keeps the enemy checks of move_to and the tours: a goal inside a weapon's reach the map shows is
-- refused unless unsafe_goal, and the legs go round the nests (avoid_enemies).
-- transfer, collect, feed, rearm and refuel walk as their tours do (stock.lua); mine, build, configure and rotate walk
-- as move_to {target, reach} does (M.approach) and make the call on arrival (M.resume).
return function(api)
  local M={}
  M.RANGE=32
  -- The calls that walk as their tours do go farther by default (C5, Luna 18:20: transfers at 39 tiles refused, twice,
  -- for cross-base hauling); mine, build, configure and rotate keep 32.
  M.TOUR_RANGE=64
  local TOUR={transfer=true,collect=true,feed=true,rearm=true,refuel=true}
  function M.range(action) return TOUR[action] and M.TOUR_RANGE or M.RANGE end
  -- Fields a call carries between its own reruns (build: awaited, stepped, ...); never part of the call it names.
  local INTERNAL={awaited=true,stepped=true,built_before=true,index_before=true,failed_before=true,built_ents=true,own_before=true,walked=true,
    walked_entry=true}
  local function copy(t) local o={} for k,v in pairs(t) do o[k]=v end return o end
  local function r1(x) return math.floor(x*10+0.5)/10 end
  -- walk: nil (by default), true or false.
  function M.mode(a)
    assert(a.walk==nil or type(a.walk)=='boolean','walk must be true or false')
    return a.walk
  end
  -- The call with walk: true, as JSON: transfer {"item":"coal","position":{"x":7.5,"y":70.5},"walk":true}.
  function M.call_text(action,a)
    local args={}
    for k,v in pairs(a) do if not INTERNAL[k] then args[k]=v end end
    args.walk=true
    return action..' '..api.encode(args)
  end
  -- A target out of reach: an entity {entity, d (tiles to its edge), reach, kind} or a point {point, d, reach}.
  function M.entity_far(p,e)
    local d=api.box_distance(p.position,e)
    local reach,kind=api.reach_for(p,e,d)
    return {entity=e,d=d,reach=reach,kind=kind,text=api.out_of_reach(p,e)}
  end
  function M.point_far(p,pos,reach,text)
    return {point={x=pos.x,y=pos.y},d=api.distance(p.position,pos),reach=reach,text=text}
  end
  -- 'iron-chest (59.5,19.5) is 17.9 tiles away (to its edge), reach 10' or '(53.5,35.5) is 10.2 tiles from you, build reach 10'.
  function M.far_text(f)
    if f.entity then
      local e=f.entity
      return string.format('%s (%g,%g) is %.1f tiles away (to its edge), reach %g%s',e.name,e.position.x,e.position.y,f.d,f.reach,f.kind or '')
    end
    return string.format('(%g,%g) is %.1f tiles from you, build reach %g',f.point.x,f.point.y,f.d,f.reach)
  end
  -- Whether the call walks to these targets out of reach: nil when it does not (none, walk: false, or the call made
  -- again after its walk), else the farthest. Past RANGE without walk: true: refused, naming the call that walks.
  function M.wanted(action,a,far)
    if #far==0 or M.mode(a)==false or a.walked then return nil end
    local worst
    for _,f in ipairs(far) do if not worst or f.d>worst.d then worst=f end end
    if a.walk~=true and worst.d>M.range(action) then
      error(string.format('%s; %.1f tiles is past the %d a call walks by default: %s walks there first (any distance; via: [{x,y}, ...] walks those points first)',
        worst.text,worst.d,M.range(action),M.call_text(action,a)),0)
    end
    return worst
  end
  -- The reply's walking line.
  function M.line(far,n,worst)
    if #far==1 and n<=1 then return M.far_text(far[1])..': walking into reach first (walk: false refuses instead)' end
    return string.format('%d of %d places are out of reach (the farthest: %s): walking to them first, nearest first (walk: false refuses instead)',
      #far,n,M.far_text(worst))
  end
  -- Walk into reach of target t ({entity} or {point}), as move_to {target | position, reach} walks, then make the call
  -- (M.resume): with rerun's args when given (build: the entries left), else a's, marked walked so it walks no more.
  -- The walk's own checks refuse a goal inside a weapon's reach (unsafe_goal) and go round the nests.
  function M.approach(p,action,a,t,line,rerun)
    local margs={avoid_enemies=a.avoid_enemies,unsafe_goal=a.unsafe_goal}
    if t.entity then
      local e=t.entity
      margs.target={position={x=e.position.x,y=e.position.y},name=e.name,unit_number=e.unit_number}
      margs.reach='transfer'
    else
      margs.position={x=t.point.x,y=t.point.y}; margs.reach='build'
    end
    local out=api.handlers.move_to(p,margs)
    local walk=api.state().active[p.index]
    local args=rerun
    if not args then args=copy(a); args.walked=true end
    walk.then_call={action=action,args=args,line=line,from=p.position and {x=p.position.x,y=p.position.y} or nil,
      target=t.entity and string.format('%s (%g,%g)',t.entity.name,t.entity.position.x,t.entity.position.y) or string.format('(%g,%g)',t.point.x,t.point.y)}
    return {walking=line,walking_for=action,until_tick=out.until_tick,limit=out.limit,reach=out.reach,avoid_enemies=out.avoid_enemies,unsafe_goal=out.unsafe_goal,
      retreat=out.retreat}
  end
  -- The walk's end (finish): the call it walked for, and when it was not made, why.
  function M.ended(walk,last,outcome)
    local tc=walk.then_call
    last.walking_for=tc.action
    if outcome~='arrived' and outcome~='arrived_near' then
      last.not_made=string.format('%s was not made: the walk into reach of %s ended %s',tc.action,tc.target,outcome)
    end
  end
  -- After the walk arrived: the call, made where the character now stands. A call that starts a timed action of its own
  -- (mine; a build waiting for a craft or stepping aside) goes on as that action; any other ends here, its reply in
  -- last.result (outcome done, or failed with last.error).
  function M.resume(index,p,walk)
    local tc=walk.then_call
    local s=api.state()
    local last=s.last and s.last[index]
    if not last or last.walking_for~=tc.action or last.not_made then return end
    local from=tc.from
    local walked=from and string.format('walked from (%g,%g) to (%g,%g) first, into reach of %s',r1(from.x),r1(from.y),r1(p.position.x),r1(p.position.y),tc.target)
      or 'walked into reach of '..tc.target..' first'
    local ok,result=pcall(api.handlers[tc.action],p,tc.args)
    local now=s.active[index]
    if ok and now then
      now.queued=walk.queued; now.call=now.call or walk.call
      now.report=now.report or {}; now.report.walked=walked
      return
    end
    s.last[index]={kind=tc.action,handler=tc.action,outcome=ok and 'done' or 'failed',tick=game.tick,walked=walked,
      result=ok and result or nil,error=not ok and api.reason(result) or nil}
  end
  return M
end
