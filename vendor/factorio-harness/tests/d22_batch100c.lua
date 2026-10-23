-- d22 batch100 BJ3: robot_losses and its alert groups for a lost robot whose order has no target. 2.0.77 gives a robot
-- order's target_item as {name, quality} with the item prototype (userdata) as name; the prototype was stored and
-- joined into the line, which raised. Game objects here are userdata fakes (a file handle with its own metatable).
-- Run from the harness root: lua tests/d22_batch100c.lua
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function ud(fields) local u=io.tmpfile(); debug.setmetatable(u,{__index=fields}); return u end
game={tick=1000}
defines={robot_order_type={construct=1,deconstruct=2,repair=3,deliver=4,pickup=5}}
local st={}
local R=dofile('mod/agent-harness_0.1.0/robotloss.lua'){state=function() return st end,integer=function(v,d) return v or d end,position=function(v) return v end}
local enemy,ours=ud{name='enemy'},ud{name='player'}
local worm=ud{valid=true,name='big-worm-turret',type='turret',position={x=200,y=40},force=enemy}
local plate=ud{name='iron-plate',object_name='LuaItemPrototype'}
local normal=ud{name='normal',object_name='LuaQualityPrototype'}
local function robot(order) return ud{valid=true,type='logistic-robot',name='logistic-robot',force=ours,surface=ud{name='nauvis'},position={x=205,y=40},robot_order_queue={order}} end
-- two logistic robots on a pickup with no target read (the provider gone), one on a delivery to a chest
R.note({entity=robot({type=5,target_item={name=plate,quality=normal},target_count=10}),cause=worm,tick=1000})
R.note({entity=robot({type=5,target_item={name=plate,quality=normal},target_count=4}),cause=worm,tick=1000})
local chest=ud{valid=true,type='logistic-container',name='requester-chest',position={x=230.5,y=40.5},unit_number=9}
R.note({entity=robot({type=4,target=chest,target_item={name=plate,quality=normal}}),cause=worm,tick=1000})
eq(type(st.robot_losses[1].job.item),'string','the item is kept by its name'); eq(st.robot_losses[1].job.item,'iron-plate')
-- a record noted before the fix, holding the prototype itself, reads by its name too
st.robot_losses[#st.robot_losses+1]={tick=1000,surface='nauvis',force='player',robot='logistic-robot',position={x=206,y=40},
  killer={name='big-worm-turret',position={x=200,y=40},type='turret'},job={order='pickup',item=plate}}
game.tick=1600
local r=R.read({force=ours,surface=ud{name='nauvis'}},{})
eq(#r.groups,1); eq(r.groups[1].robots,4)
has(r.lines[1],'4 logistic-robot robots lost to big-worm-turret (200,40) on nauvis, the last 10s ago, sent to: 3 pickup iron-plate; 1 deliver requester-chest at (230.5,40.5)')
local g=R.alert_groups(ours)
eq(#g,1); eq(g[1].kind,'robots_lost'); has(g[1].line,'3 pickup iron-plate')
-- an item given as a name, or as the prototype itself, reads the same
R.note({entity=robot({type=5,target_item='copper-plate'}),cause=worm,tick=1600})
R.note({entity=robot({type=5,target_item=ud{name='steel-plate'}}),cause=worm,tick=1600})
eq(st.robot_losses[#st.robot_losses-1].job.item,'copper-plate'); eq(st.robot_losses[#st.robot_losses].job.item,'steel-plate')
defines=nil
print('d22_batch100c BJ3 robot losses with no target: ok')
