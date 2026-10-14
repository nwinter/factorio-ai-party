-- Run with lua tests/lookahead.lua: the look-ahead block's lines (lookahead.lua; Nick 12:35) and the network stock
-- samples behind its running-out line (networks.lua).
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
storage={}
defines={flow_precision_index={five_seconds=0}}
local force={name='player',players={{}}}
local nauvis={name='nauvis',index=1,find_entities_filtered=function() return {} end,count_entities_filtered=function() return 0 end}
game={tick=0,forces={player=force},surfaces={nauvis}}
-- Network 8: iron-plate falling 100 a game minute from 6000, copper-plate steady, gears falling slowly.
local stock={['iron-plate']=6000,['copper-plate']=900,['iron-gear-wheel']=5000}
local ln={network_id=8,all_logistic_robots=10,available_logistic_robots=10,all_construction_robots=0,available_construction_robots=0,cells={},
  requester_points={}}
ln.get_contents=function() local out={} for name,n in pairs(stock) do out[#out+1]={name=name,quality='normal',count=n} end return out end
force.logistic_networks={nauvis={ln}}
local N=dofile('mod/agent-harness_0.1.0/networks.lua'){state=function() return storage end}
local function run(min)
  for _=1,min*60*60 do
    game.tick=game.tick+1
    if game.tick%3600==0 then stock['iron-plate']=stock['iron-plate']-100; stock['iron-gear-wheel']=stock['iron-gear-wheel']-10 end
    N.tick(game.tick)
  end
end
-- Under 30 min of samples: said so.
run(20)
local rows,enough=N.running_out(force,5)
eq(#rows,0); eq(enough,false)
run(15)
rows,enough=N.running_out(force,5)
eq(enough,true); eq(#rows,1,'iron falls to zero within 2 h; gears in 7+ h; copper steady')
eq(rows[1].name,'iron-plate'); eq(rows[1].id,8); eq(rows[1].surface,'nauvis')
-- The last sample (30:05): 3000 left at 100 a minute: 30 min.
eq(math.floor(rows[1].ticks/3600+0.5),30)
-- The block.
force.current_research={name='automation-2'}; force.research_progress=0.52
force.research_queue={{name='automation-2'},{name='steel-processing'},{name='logistics-2'}}
local view={line='iron smelting column east',line_tick=game.tick-80*3600,items={'#12 Iron smelting east (claim claimed)','#15 Gears for science (task doing)'},
  goals='blue science by hour 40'}
local L=dofile('mod/agent-harness_0.1.0/lookahead.lua'){who=function(p) return p.name end,board_view=function(name) eq(name,'astra'); return view end,
  running_out=function(f,max) return N.running_out(f,max) end}
local r=L.read({name='astra',force=force})
eq(r.lines[1],'your plan line: "iron smelting column east" (set 1h20m ago)')
eq(r.lines[2],'your open board items: #12 Iron smelting east (claim claimed); #15 Gears for science (task doing)')
eq(r.lines[3],'team plan goals: blue science by hour 40')
eq(r.lines[4],'research: automation-2 52% running; queued next: steel-processing, logistics-2')
assert(r.lines[5]:find('^stock falling to zero within 2 h at the last 30 min rate: iron%-plate in network #8 %(nauvis%) in 30m %(3000 left%)'),r.lines[5])
eq(r.sentence,'look ahead: a moment to think past the current task: what you and the team will need in the next hour or two, and whether your plan line still says it. What you do with this is up to you.')
-- No line, no items, no goals, no research.
view={items={}}; force.current_research=nil; force.research_queue={}
r=L.read({name='astra',force=force})
eq(r.lines[1],'your plan line: none'); eq(r.lines[2],'your open board items: none'); eq(r.lines[3],'team plan goals: none')
eq(r.lines[4],'research: none running; nothing queued next')
print('lookahead: ok')
