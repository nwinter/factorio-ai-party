-- Run from repository root: lua tests/d28_batch307.lua
-- d28 batch307 (Astra #2673: an item-only uptime watch gave flows from uptime {} while current, but uptime {read: true,
-- id} gave zero-machine pages without them, so Sol could not audit Astra's watch by id once it was replaced). A read by
-- id gives the watch's flows on every page, whole, with their start and end ticks: a running watch's now, a done one's
-- as it ended (kept with it when it finished, was replaced or was closed as a segment), by any agent.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..'\n  lacks: '..x) end
game={tick=1000,surfaces={nauvis={name='nauvis'}}}
defines={inventory={assembling_machine_input=2,furnace_source=2,assembling_machine_output=3,furnace_result=3},flow_precision_index={ten_minutes=1}}
prototypes={item={['iron-gear-wheel']={},['iron-plate']={},['copper-plate']={},['copper-cable']={},['steel-plate']={}},
  quality={normal={},uncommon={},rare={},epic={},legendary={},['quality-unknown']={hidden=true}}}
local counts={input={},output={}}
local function key(id) return id.name..'@'..(id.quality or 'normal') end
local stats={get_input_count=function(id) return counts.input[key(id)] or 0 end,get_output_count=function(id) return counts.output[key(id)] or 0 end,
  get_flow_count=function() return 0 end}
local force={name='player',get_item_production_statistics=function() return stats end}
game.forces={player=force}
local surface=game.surfaces.nauvis
local recipe={name='iron-gear-wheel',ingredients={{type='item',name='iron-plate',amount=2}}}
local ms={}
for k=1,20 do
  local e={valid=true,name='assembling-machine-2',type='assembling-machine',position={x=k*4+0.5,y=10.5},products_finished=0,status='working',
    surface=surface,force=force}
  e.get_recipe=function() return recipe,{name='normal'} end
  e.get_inventory=function() return {get_item_count=function() return 10 end,get_contents=function() return {} end} end
  ms[k]=e
end
local st={}
local names={'sol','astra'}
local Ms=dofile('mod/agent-harness_0.1.0/measures.lua'){state=function() return st end,who_index=function(i) return names[i] end}
local U=dofile('mod/agent-harness_0.1.0/uptime.lua'){state=function() return st end,
  remote_entity=function(_,t) for _,e in ipairs(ms) do if e.position.x==t.position.x then return e end end error('none') end,
  status_name=function(e) return e.status end,craftrate=function() return {crafts_per_min=30,productivity=0} end,
  who_index=function(i) return names[i] end,watch_id=function(kind,job,i) return Ms.id(kind,job,i) end}
local sol={index=1,valid=true,force=force,surface=surface}
local astra={index=2,valid=true,force=force,surface=surface}
local function run(to)
  while game.tick<to do
    game.tick=game.tick+1
    if game.tick%60==0 then
      counts.input['iron-gear-wheel@normal']=(counts.input['iron-gear-wheel@normal'] or 0)+3
      counts.output['iron-plate@normal']=(counts.output['iron-plate@normal'] or 0)+6
      for _,e in ipairs(ms) do e.products_finished=e.products_finished+1 end
    end
    U.tick(game.tick)
  end
end
local function row(f,name,q) for _,r in ipairs(f.rows) do if r.name==name and r.quality==(q or 'normal') then return r end end end

-- Astra's item-only watch: gears every quality, plates every quality, 60 s
counts.input['iron-gear-wheel@normal']=500; counts.output['iron-plate@normal']=900
local s=U.handler(astra,{items={'iron-gear-wheel','iron-plate'},seconds=60})
eq(s.id,'uptime@1000/astra'); eq(s.machines,0)
local id=s.id
run(1600)
-- while current, by id, by Astra and by Sol: the flows so far, its ticks 1000-1600
for _,p in ipairs({astra,sol}) do
  local r=U.handler(p,{read=true,id=id})
  eq(r.watching,true); eq(r.machines_total,0); eq(r.pages,1)
  assert(r.flows,'a running watch\'s flows by id')
  eq(r.flows.start_tick,1000); eq(r.flows.end_tick,1600); eq(r.flows.surface,'nauvis')
  eq(row(r.flows,'iron-gear-wheel').produced,30); eq(row(r.flows,'iron-plate').consumed,60); eq(#r.flows.rows,2)
  has(r.flows.line,'iron-gear-wheel produced 30 (180/min)')
  has(r.line,'; flows: 2 rows of the production statistics, ticks 1000-1600')
end
eq(U.handler(sol,{read=true,id=id}).agent,'astra')
-- uptime {} gives the same rows
eq(row(U.handler(astra,{}).flows,'iron-gear-wheel').produced,30)

-- after it finishes (tick 4600): the flows as it ended, read later by id
run(4600)
local done=st.uptime[2]
eq(done.ended_tick,4600)
run(5200)  -- the statistics move on; the read stays at the end
local r=U.handler(sol,{read=true,id=id})
eq(r.done,true); eq(r.flows.start_tick,1000); eq(r.flows.end_tick,4600); eq(r.to_tick,4600)
eq(row(r.flows,'iron-gear-wheel').produced,180); eq(row(r.flows,'iron-plate').consumed,360)
has(r.line,'ticks 1000-4600')

-- after it is replaced: kept, read by id by another agent, the same flows
local s2=U.handler(astra,{positions={{x=ms[1].position.x,y=10.5}},seconds=600})
eq(s2.kept[1].id,id)
eq(st.uptime[2].kept[1],done)
run(5800)
r=U.handler(sol,{read=true,id=id})
eq(r.done,true); assert(r.kept_watch,'a kept watch'); eq(r.flows.start_tick,1000); eq(r.flows.end_tick,4600)
eq(row(r.flows,'iron-gear-wheel').produced,180); eq(row(r.flows,'iron-plate').consumed,360); eq(r.machines_total,0)
-- the new watch has no items: no flows on its read
eq(U.handler(sol,{read=true,id=s2.id}).flows,nil)

-- a running watch replaced while still running: finished there, its flows kept to that tick
local s3=U.handler(sol,{items={'iron-gear-wheel'},seconds=600})
run(6400)
U.handler(sol,{items={'copper-plate'},seconds=60})
r=U.handler(astra,{read=true,id=s3.id})
eq(r.done,true); eq(r.flows.start_tick,5800); eq(r.flows.end_tick,6400); eq(row(r.flows,'iron-gear-wheel').produced,30)
has(r.kept_watch.closed_by,'finished 590s early')

-- a machine watch with items: every page carries the flows whole, above FLOW_ROWS rows too; uptime {} still leaves
-- the rows out above 10
local list={}
for k=1,20 do list[k]={x=ms[k].position.x,y=10.5} end
for _,q in ipairs({'normal','uncommon','rare','epic','legendary'}) do
  for _,n in ipairs({'copper-plate','copper-cable','steel-plate'}) do counts.input[n..'@'..q]=100 end
end
local s4=U.handler(astra,{positions=list,items={'copper-plate','copper-cable','steel-plate'},seconds=60})
run(game.tick+60)
for _,q in ipairs({'normal','uncommon','rare','epic','legendary'}) do
  for _,n in ipairs({'copper-plate','copper-cable','steel-plate'}) do counts.input[n..'@'..q]=105 end
end
run(game.tick+3600)
local whole=U.handler(astra,{})
eq(whole.done,true); eq(whole.flows.rows,nil,'uptime {} leaves out above 10 rows'); has(whole.flows.line,'steel-plate (legendary) produced 5')
local p1=U.handler(sol,{read=true,id=s4.id})
local p2=U.handler(sol,{read=true,id=s4.id,page=2})
eq(p1.pages,2); eq(#p1.machines,16); eq(#p2.machines,4)
eq(#p1.flows.rows,15); eq(#p2.flows.rows,15); eq(p2.flows.end_tick,p1.flows.end_tick)
eq(row(p2.flows,'steel-plate','legendary').produced,5)

-- a segment (an edit closed the window, as mixed.lua closes it): its flows to the edit
local s5=U.handler(sol,{items={'iron-gear-wheel'},seconds=600})
run(game.tick+600)
local cut=game.tick
local j5=st.uptime[1]
local nj={start=cut,until_tick=cut+600*60,next_tick=cut,seconds=600,samples=0,machines={}}
U.close(j5,nj,cut,'an edit')
st.uptime[1]=nj
run(cut+600)
r=U.handler(astra,{read=true,id=s5.id})
eq(r.segment.ended_tick,cut); eq(r.flows.start_tick,cut-600); eq(r.flows.end_tick,cut); eq(row(r.flows,'iron-gear-wheel').produced,30)

-- a watch kept before batch307 (its final's flows only, rows left out above 10): the final's line, the ticks from
-- the watch
local old=st.uptime[2]
old.flows_done=nil
old.result.flows={surface='nauvis',line='production statistics on nauvis in 61s (every machine and hand there): ...'}
r=U.handler(sol,{read=true,id=s4.id})
eq(r.flows.rows,nil); eq(r.flows.start_tick,old.start); eq(r.flows.end_tick,old.ended_tick); has(r.flows.rows_left_out,'above 10 rows')
has(r.line,'; flows: no rows of the production statistics')
defines,prototypes=nil,nil
print('d28_batch307 uptime read by id: flows on every page, kept with a done watch: ok')
