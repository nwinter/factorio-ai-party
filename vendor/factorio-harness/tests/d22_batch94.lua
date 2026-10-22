-- d22 batch94 contracts (BD1, viewer Aurora site:4267-4268 on #114, Astra's equipment reminder). lua tests/d22_batch94.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,t) assert(type(s)=='string' and s:find(t,1,true),'missing "'..t..'" in: '..tostring(s)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A team of three, its reminders, the lines each gets.
local function team(extra)
  game={tick=600}
  local st,boxes={},{}
  local api={state=function() return st end,who=function(p) return p.name end,resolve=function(n) return n end,
    agents=function() return {{name='astra',index=1},{name='haiku',index=2},{name='sol',index=3}} end,
    deliver=function(index,t) boxes[index]=boxes[index] or {}; table.insert(boxes[index],t) end,
    item_known=function(n) return n~='no-such-item' end,technology_known=function(n) return n~='no-such-tech' end,
    is_gear=function(n) return n:find('equipment',1,true)~=nil or n=='mech-armor' end,
    check_items=function(l) if type(l)=='string' then l={l} end; for _,n in ipairs(l) do assert(n~='no-such-item','gap_items: no item '..n) end; return l end}
  for k,v in pairs(extra or {}) do api[k]=v end
  local R=dofile('mod/agent-harness_0.1.0/reminders.lua')(api)
  return R,st,boxes
end
local astra,haiku,sol={name='astra'},{name='haiku'},{name='sol'}
local function by_name(r) local t={}; for _,x in ipairs(r.latest) do t[x.name]=x end; return t end

-- BD1.4: an ack's state: done with a result; open without one or with gap items; deferred.
do
  local R=team({gap_facts=function(name,items)
    local rows={}
    for i,n in ipairs(items) do rows[i]={item=n,line=n..': recipe '..n..' enabled; technology energy-shield-mk2-equipment researched; in nauvis\'s logistic networks: 14, 2 rare (3 networks); held: 0'} end
    return rows
  end,gear=function(name) return 'mech-armor 10x12: energy-shield-equipment*2 battery-equipment*1; 13 free cells; shield 100/100; battery 20/20 MJ' end})
  local id=R.handlers.reminder_add(astra,{name='personal-equipment-standard',message='compare grid to stock',every_ticks=216000,recipients='team'}).added
  game.tick=216600; R.tick()
  local a=R.handlers.reminder_ack(sol,{id=id,result='6 shields 300/300, no gap'})
  eq(a.state,'done')
  R.handlers.reminder_ack(astra,{id=id})
  local h=R.handlers.reminder_ack(haiku,{id=id,result='shield mk2 missing',gap_items={'energy-shield-mk2-equipment'},gear=true})
  eq(h.state,'open (gap: energy-shield-mk2-equipment)')
  has(h.gap_facts[1].line,'technology energy-shield-mk2-equipment researched; in nauvis\'s logistic networks: 14, 2 rare')
  has(h.gear,'mech-armor 10x12: energy-shield-equipment*2')
  local r=R.handlers.reminders(astra,{all=true}).reminders[1]
  has(r.states,'astra open (acknowledged without a result)'); has(r.states,'haiku open (gap: energy-shield-mk2-equipment)'); has(r.states,'sol done')
  local l=by_name(r)
  eq(l.sol.state,'done'); eq(l.haiku.gap[1],'energy-shield-mk2-equipment')
  has(l.haiku.line,'haiku: open (gap: energy-shield-mk2-equipment); last acknowledged 0s ago: shield mk2 missing; gap energy-shield-mk2-equipment: recipe')
  has(l.haiku.line,'; their armor at the ack (tick 216600): mech-armor 10x12'); eq(l.haiku.gear_tick,216600)
  -- deferred, with the reason; the gap stays named
  R.handlers.reminder_ack(haiku,{id=id,result='no shield mk2 on Nauvis',gap_items={'energy-shield-mk2-equipment'},deferred='until Sol\'s next Nauvis delivery'})
  eq(by_name(R.handlers.reminders(haiku,{}).reminders[1]).haiku.state,'deferred (open, gap: energy-shield-mk2-equipment): until Sol\'s next Nauvis delivery')
  eq(R.handlers.reminder_ack(astra,{id=id,deferred=true}).state,'deferred (open)')
  -- the recipient's pending read lists what stays open
  local pr=R.handlers.reminders(haiku,{pending=true})
  eq(pr.count,0); has(pr.open[1],'#1 personal-equipment-standard: deferred (open, gap: energy-shield-mk2-equipment): until Sol\'s next Nauvis delivery, acknowledged 0s ago')
  eq(R.handlers.reminders(sol,{pending=true}).open,nil,'done: nothing open')
  -- fixed: an ack with a result and no gap closes it
  eq(R.handlers.reminder_ack(haiku,{id=id,result='shield mk2 fitted, 200/200'}).state,'done')
  -- refusals: an unknown item, gear for someone else, on a checklist
  fails(function() R.handlers.reminder_ack(haiku,{id=id,gap_items={'no-such-item'}}) end,'gap_items: no item no-such-item')
  R.handlers.reminder_edit(astra,{id=id,backup='sol'})
  fails(function() R.handlers.reminder_ack(sol,{id=id,['for']='haiku',result='x',gear=true}) end,'gear: your own armor only')
  local ck=R.handlers.reminder_add(astra,{message='steps',every_ticks=216000,steps={'a','b'}}).added
  fails(function() R.handlers.reminder_ack(astra,{id=ck,step=1,deferred=true}) end,'deferred, gap_items and gear are for a reminder without steps')
  print('BD1.4 done, open, deferred, gap facts and gear with the ack: ok')
end

-- BD1.3: on {research, delivered, respawn}, set by the owner; runs besides the cadence; no missed run while a line waits.
do
  local R,st,boxes=team()
  fails(function() R.handlers.reminder_add(astra,{message='x',every_ticks=216000,on={rain=true}}) end,'on takes research, delivered and respawn, not rain')
  fails(function() R.handlers.reminder_add(astra,{message='x',every_ticks=216000,on={research={'no-such-tech'}}}) end,'on.research: no technology no-such-tech')
  fails(function() R.handlers.reminder_add(astra,{message='x',every_ticks=216000,on={delivered={items={'no-such-item'}}}}) end,'on.delivered: no item no-such-item')
  fails(function() R.handlers.reminder_add(astra,{message='x',every_ticks=216000,on={}}) end,'on: research, delivered or respawn')
  local id=R.handlers.reminder_add(astra,{name='gear',message='compare grid to stock',every_ticks=1296000,recipients='team',wake=false,
    on={research='equipment',delivered={items='equipment',surface='nauvis'},respawn=true}}).added
  local r=R.handlers.reminders(astra,{id=id}).reminders[1]
  eq(r.on,'a technology unlocking equipment or armor researched; equipment or armor delivered to a landing pad or a platform\'s hub on nauvis; a recipient\'s respawn (their run only)')
  has(r.line,'#1 gear, by astra (every 6h00m, and on a technology unlocking equipment or armor researched;')
  -- a technology that unlocks no gear: no run
  eq(R.trigger('research',{name='steel-processing'}),0); eq(boxes[1],nil)
  -- one that does: a run for each recipient, its line says why
  eq(R.trigger('research',{name='energy-shield-mk2-equipment',gear='energy-shield-mk2-equipment'}),3)
  has(boxes[2][1].text,'; this run on energy-shield-mk2-equipment researched (it unlocks energy-shield-mk2-equipment)')
  eq(boxes[2][1].fyi,true,'wake false holds for trigger runs too')
  -- while the lines wait: counted beside the wait, no second line, no missed run
  eq(R.trigger('delivered',{surface='nauvis',cargo={['energy-shield-mk2-equipment']=10,['iron-plate']=200},where='landing-pad (3,4) on nauvis'}),0)
  eq(#boxes[2],1)
  local l=by_name(R.handlers.reminders(astra,{id=id}).reminders[1])
  eq(l.haiku.missed,nil); eq(l.haiku.triggers_while_waiting,1); eq(l.haiku.run_on,'energy-shield-mk2-equipment researched (it unlocks energy-shield-mk2-equipment)')
  has(l.haiku.line,', this run on energy-shield-mk2-equipment researched (it unlocks energy-shield-mk2-equipment), 1 trigger since (the last: energy-shield-mk2-equipment*10 delivered to landing-pad (3,4) on nauvis)')
  -- acknowledged: a delivery elsewhere or of other items starts nothing; one on nauvis with gear does
  for _,p in ipairs({astra,haiku,sol}) do R.handlers.reminder_ack(p,{id=id,result='checked'}) end
  eq(R.trigger('delivered',{surface='vulcanus',cargo={['energy-shield-mk2-equipment']=10},where='landing-pad on vulcanus'}),0)
  eq(R.trigger('delivered',{surface='nauvis',cargo={['iron-plate']=200},where='landing-pad on nauvis'}),0)
  eq(R.trigger('delivered',{surface='platform-3',platform='Spindle',cargo={['battery-mk2-equipment']=4},where='Spindle\'s hub'}),0,'not nauvis')
  eq(R.trigger('delivered',{surface='nauvis',cargo={['battery-mk2-equipment']=4},where='landing-pad (3,4) on nauvis'}),3)
  has(boxes[3][2].text,'this run on battery-mk2-equipment*4 delivered to landing-pad (3,4) on nauvis')
  for _,p in ipairs({astra,haiku,sol}) do R.handlers.reminder_ack(p,{id=id,result='checked'}) end
  -- a respawn: that recipient's run only
  eq(R.trigger('respawn',{name='haiku'}),1)
  eq(#boxes[2],3); eq(#boxes[1],2); eq(#boxes[3],2)
  has(boxes[2][3].text,'this run on haiku respawned')
  -- named technologies match a leveled one; a platform by name; the cadence goes on as before
  local id2=R.handlers.reminder_add(sol,{message='after shields',every_ticks=216000,on={research={'energy-shield-equipment'},delivered={items={'mech-armor'},surface='Spindle'}}}).added
  eq(R.trigger('research',{name='energy-shield-equipment-2'}),1)
  R.handlers.reminder_ack(sol,{id=id2,result='ok'})
  eq(R.trigger('delivered',{surface='platform-3',platform='Spindle',cargo={['mech-armor']=1},where='Spindle\'s hub (a rocket from nauvis)'}),1)
  eq(st.reminders.jobs[id2].next_due,600+216000,'a trigger leaves the cadence where it is')
  -- false clears them; a disabled job takes none
  R.handlers.reminder_edit(sol,{id=id2,on=false}); eq(st.reminders.jobs[id2].on,nil)
  R.handlers.reminder_edit(astra,{id=id,enabled=false}); R.handlers.reminder_ack(haiku,{id=id,result='ok'})
  eq(R.trigger('respawn',{name='haiku'}),0)
  game=nil
  print('BD1.3 reminder triggers: research, delivered, respawn: ok')
end

-- BD1.5: gapfacts.lua: recipes and technologies for an item, its count in the surface's networks by quality, held.
do
  local function counter(t) return function(x) return t[x.name..'@'..x.quality] or 0 end end
  prototypes={item={['energy-shield-mk2-equipment']={place_as_equipment_result={}},['iron-plate']={type='item'},['mech-armor']={type='armor'}},
    quality={normal={},uncommon={},rare={},['quality-unknown']={}},
    technology={['energy-shield-mk2-equipment']={effects={{type='unlock-recipe',recipe='energy-shield-mk2-equipment'}}},
      ['steel-processing']={effects={{type='unlock-recipe',recipe='steel-plate'}}}},
    recipe={['energy-shield-mk2-equipment']={products={{type='item',name='energy-shield-mk2-equipment'}}},['steel-plate']={products={{type='item',name='steel-plate'}}}},
    get_recipe_filtered=function(f) local n=f[1].elem_filters[1].name; if n=='energy-shield-mk2-equipment' then return {[n]={},['energy-shield-mk2-equipment-recycling']={hidden=true}} end; return {} end}
  defines={inventory={character_armor=5,hub_main=1}}
  local G=dofile('mod/agent-harness_0.1.0/gapfacts.lua'){}
  eq(G.is_gear('energy-shield-mk2-equipment'),true); eq(G.is_gear('mech-armor'),true); eq(G.is_gear('iron-plate'),false)
  eq(G.unlocks_gear({prototype=prototypes.technology['energy-shield-mk2-equipment']}),'energy-shield-mk2-equipment')
  eq(G.unlocks_gear({prototype=prototypes.technology['steel-processing']}),nil)
  fails(function() G.check_items({'nope'}) end,'gap_items: no item nope')
  eq(#G.check_items({'iron-plate','iron-plate'}),1)
  local nets={{get_item_count=counter({['energy-shield-mk2-equipment@normal']=12,['energy-shield-mk2-equipment@rare']=2})},{get_item_count=counter({['energy-shield-mk2-equipment@normal']=2})}}
  local force={logistic_networks={nauvis=nets},recipes={['energy-shield-mk2-equipment']={enabled=true}},technologies={['energy-shield-mk2-equipment']={researched=true}}}
  local p={force=force,character={valid=true,surface={name='nauvis'}},get_main_inventory=function() return {get_item_count=counter({})} end}
  local rows=G.facts(p,{'energy-shield-mk2-equipment','iron-plate'})
  eq(rows[1].line,'energy-shield-mk2-equipment: recipe energy-shield-mk2-equipment enabled; technology energy-shield-mk2-equipment researched; in nauvis\'s logistic networks: 14, 2 rare (2 networks); held: 0')
  eq(rows[1].in_networks.normal,14); eq(rows[1].in_networks.rare,2); eq(rows[1].technologies[1].researched,true)
  eq(rows[2].line,'iron-plate: no recipe makes it; in nauvis\'s logistic networks: 0 (2 networks); held: 0')
  -- on a platform: its hub too
  local hub={get_inventory=function() return {get_item_count=counter({['energy-shield-mk2-equipment@uncommon']=3})} end}
  force.technologies['energy-shield-mk2-equipment'].researched=false
  p.character.surface={name='platform-3',platform={hub=hub}}
  has(G.facts(p,{'energy-shield-mk2-equipment'})[1].line,'technology energy-shield-mk2-equipment not researched; in platform-3\'s logistic networks: 0 (0 networks); in its hub: 3 uncommon; held: 0')
  -- the recipient's own armor (grids.lua view), quality above normal named
  local grids=dofile('mod/agent-harness_0.1.0/grids.lua'){}
  local suit={valid_for_read=true,name='mech-armor',quality={name='rare'}}
  p.character={valid=true,grid={width=10,height=12,shield=100,max_shield=100,available_in_batteries=20e6,battery_capacity=20e6,
    equipment={{name='energy-shield-equipment',shape={width=2,height=2},quality={name='normal'}},{name='energy-shield-equipment',shape={width=2,height=2},quality={name='uncommon'}}}},
    get_inventory=function() return {suit} end}
  eq(G.gear_line(p,grids),'mech-armor@rare 10x12: energy-shield-equipment*1 energy-shield-equipment@uncommon*1; 112 free cells; shield 100/100; battery 20/20 MJ')
  p.character={valid=false}; eq(G.gear_line(p,grids),'no character (dead or not spawned)')
  prototypes=nil; defines=nil
  print('BD1.5 gap facts (research, recipes, network stock by quality) and the armor line: ok')
end
