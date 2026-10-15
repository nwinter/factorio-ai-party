-- Run with lua tests/entryset.lua: settings on the entries of place_ghosts and build (entryset.lua; Sol, shift13 19:50:
-- a bio cell took about 10 configure and wire round trips). Sol's 00:23 UTC run replayed as one entry: a decider
-- combinator with its condition, wired to a requester chest that gets set_requests and a cleared request.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local known={configure={recipe=true,filters=true,filter_mode=true,modules=true},requests={set=true,clear=true},
  circuit_set={enable=true,read=true,settings=true,decider=true},wire={from=true,to=true,color=true,from_side=true,to_side=true,disconnect=true}}
local calls={}
local refuse={}
local api={
  check=function(action,args)
    for k in pairs(args) do if not known[action][k] then error('unknown argument '..k..' for '..action,0) end end
  end,
  call=function(action,p,args)
    calls[#calls+1]={action=action,args=args}
    local why=refuse[action..'@'..(args.position or args.from).x]
    if why then error('runtime.lua:1: '..why,0) end
    if action=='configure' then return {line='recipe set'} end
    if action=='wire' then return {connected=true} end
    return {}
  end,
  position=function(v) return {x=v.x,y=v.y} end,
  reason=function(e) return (tostring(e):gsub('^[^:]*:%d+: ','')) end}
local E=dofile('mod/agent-harness_0.1.0/entryset.lua')(api)
local decider={name='decider-combinator',position={x=47.5,y=43},
  circuit={decider={first='pentapod-egg',comparator='>',constant=20,output='pentapod-egg',copy_input=false}},
  wires={{to={x=42.5,y=38.5},color='green',to_side='output'},{to={x=43.5,y=48.5},color='green',from_side='output'}}}
local chest={name='requester-chest',position={x=43.5,y=48.5},circuit={settings={circuit_exclusive_mode_of_operation='set_requests'}},
  requests={clear={'pentapod-egg'}}}
local plain={name='assembling-machine-2',position={x=10.5,y=10.5}}
local entries={decider,plain,chest}
assert(E.any(entries)); assert(not E.any({plain})); assert(not E.any(nil))
-- Checked before anything is placed: argument names, shapes, no position of their own, requests on a platform.
E.check(entries,{})
fails(function() E.check({{position={x=1,y=1},circuit={bogus=1}}},{}) end,'unknown argument bogus for circuit_set')
fails(function() E.check({{position={x=1,y=1},configure={position={x=2,y=2},recipe='x'}}},{}) end,'entry 1: configure takes the entry\'s position')
fails(function() E.check({{position={x=1,y=1},configure={'iron-gear-wheel'}}},{}) end,'entry 1: configure is an object of configure arguments')
fails(function() E.check({{position={x=1,y=1},requests={set={}}}},{platform='Sunward'}) end,'entry 1: requests on a platform entry')
fails(function() E.check({{position={x=1,y=1},wires={{color='red'}}}},{}) end,'entry 1 wire 1: {to {x,y}')
fails(function() E.check({{position={x=1,y=1},wires={{to={x=2,y=2},colour='red'}}}},{}) end,'wire 1: {to {x,y}')
-- A dry run: what each would set.
local plan=E.plan(entries)
eq(#plan,2); eq(plan[1].index,1); eq(plan[1].would_set,'circuit (decider); 2 wires'); eq(plan[2].index,3)
eq(plan[2].would_set,'requests (clear); circuit (settings)')
-- Applied: in entry order (configure, requests, circuit), then the wires, with the call's platform or surface.
local rows,line=E.apply({},entries,{surface='gleba'},{})
eq(#rows,2); eq(rows[1].circuit,'set'); eq(rows[2].requests,'set'); eq(rows[2].circuit,'set')
eq(rows[1].wires[1],'green to (42.5,38.5): connected'); eq(rows[1].wires[2],'green to (43.5,48.5): connected')
eq(line,'settings: 5 set')
local order={}
for _,c in ipairs(calls) do order[#order+1]=c.action..'@'..(c.args.position or c.args.from).x end
eq(table.concat(order,' '),'circuit_set@47.5 requests@43.5 circuit_set@43.5 wire@47.5 wire@47.5')
eq(calls[1].args.surface,'gleba'); eq(calls[1].args.decider.constant,20); eq(calls[4].args.to_side,'output'); eq(calls[5].args.from_side,'output')
eq(calls[4].args.from.y,43,'from the entry')
-- A refused setting is that row's; the placement stays; the others go on. Skipped entries (failed, still to build): none.
calls={}
refuse['circuit_set@43.5']='circuit_mode_of_operation is not a setting of requester-chest'
rows,line=E.apply({},entries,{},{[1]=true})
eq(#rows,1); eq(rows[1].index,3); eq(rows[1].requests,'set'); eq(rows[1].circuit,'circuit_mode_of_operation is not a setting of requester-chest')
eq(line,'settings: 1 set, 1 refused: entry 3 circuit: circuit_mode_of_operation is not a setting of requester-chest')
for _,c in ipairs(calls) do assert(c.args.position.x~=47.5,'entry 1 skipped') end
-- configure's readback line in the row
rows=E.apply({},{{name='assembling-machine-2',position={x=10.5,y=10.5},configure={recipe='iron-gear-wheel'}}},{},{})
eq(rows[1].configure,'set: recipe set')
print('entryset ok')
