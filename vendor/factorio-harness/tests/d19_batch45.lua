-- d19 batch45. Run from the harness root: lua tests/d19_batch45.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- batch40 C1 (Muse: second flares on a guarded spawner while shells flew): what is already coming at a flare's spot
do
  game={tick=7200}
  defines={inventory={artillery_turret_ammo=1}}
  local shells=10
  local piece={valid=true,unit_number=5,name='artillery-turret',position={x=-48.5,y=104.5},type='artillery-turret',
    get_inventory=function() return {get_item_count=function() return shells end,get_contents=function() return {{name='artillery-shell',count=shells}} end} end}
  local flare={valid=true}
  local st={artillery_checks={{index=1,by='muse',flare=flare,target={x=29.5,y=-56.5},surface=1,tick=7000,pieces={{e=piece,n=11}},m10=0},
    {index=1,by='muse',flare={valid=false},target={x=29.5,y=-56.5},surface=1,tick=3000,pieces={{e=piece,n=12}}}}}
  local surface={index=1,find_entities_filtered=function(f) if f.type=='artillery-projectile' then return {{},{}} end return {flare} end}
  local A=dofile('mod/agent-harness_0.1.0/artillery.lua'){state=function() return st end,position=function(v) return v end}
  local r=A.incoming(surface,{name='player'},{x=30,y=-56})
  eq(r.flares_waiting,1); eq(r.in_the_air,2)
  has(r.line,'1 flare of ours still waiting within 32 tiles; 2 artillery projectiles in the air within 64 tiles; team flares there in the last 60s: (29.5,-56.5) 3s ago by muse, still waiting')
  has(r.line,'pieces holding fewer shells since: artillery-turret (-48.5,104.5) 11 -> 10 shells')
  assert(not r.line:find('12 ->',1,true),'the flare over a minute old is left out')
  game,defines=nil,nil
end
print('d19_batch45 C1 artillery already coming: ok')

-- batch40 B2 (Grok: a stale provider pile looked like the load that launched): a silo inventory's spoilable items with
-- their spread, as the silo row, load_silo and the launch record give them; nil when none spoils
do
  game={tick=100}
  local spoil={inventory=function(inv,acc) for _,r in ipairs(inv.rows) do acc[#acc+1]=r end return acc end,spread_text=function(r) return r.key..'*'..r.count..': spoiled '..r.pct..'%' end}
  local S=dofile('mod/agent-harness_0.1.0/silo.lua'){spoil=function() return spoil end,state=function() return {} end}
  local lines=S.spoil_lines({rows={{key='bioflux',count=40,pct=31},{key='agricultural-science-pack',count=500,pct=12}}})
  eq(lines[1],'agricultural-science-pack*500: spoiled 12%'); eq(lines[2],'bioflux*40: spoiled 31%')
  eq(S.spoil_lines({rows={}}),nil)
  eq(S.spoil_lines(nil),nil)
  game=nil
end
print('d19_batch45 B2 silo spoil lines: ok')

-- batch40 B1 (Luna: stock 66 just after a pod, supply 194 in circulation): where_is {census}: the count by holder, the
-- spoil spread and research units of the places read, counted-only rows, made and used a minute
do
  game={tick=600}
  defines={flow_precision_index={ten_minutes=2}}
  local function inv(n) return {get_item_count=function() return n end,n=n} end
  local spoil={spoils=function() return true end,
    inventory=function(i,acc) local r=acc['agricultural-science-pack'] or {key='agricultural-science-pack',count=0}; acc['agricultural-science-pack']=r; acc[1]=r; r.count=r.count+i.n; return acc end,
    spread=function(r) return {count=r.count,min=10,max=30,mean=20,within={['10min']=0}} end,
    research_value=function(r) return {now=r.count*0.8} end}
  local function ent(t,name,mode,n) return {type=t,name=name,prototype={logistic_mode=mode},get_max_inventory_index=function() return 1 end,get_inventory=function() return inv(n) end} end
  local pad,prov,lab=ent('cargo-landing-pad','cargo-landing-pad',nil,66),ent('logistic-container','passive-provider-chest','passive-provider',100),ent('lab','lab',nil,28)
  local places={{kind='pad',count=66},{kind='chest',count=100},{kind='lab',count=28}}
  local ent_of={[places[1]]=pad,[places[2]]=prov,[places[3]]=lab}
  local S=dofile('mod/agent-harness_0.1.0/stores.lua'){spoil=function() return spoil end,agents=function() return {} end}
  local force={get_item_production_statistics=function() return {get_flow_count=function(f) return f.category=='input' and 600 or 300 end} end}
  local c=S.census_of({force=force},{name='nauvis'},'agricultural-science-pack',places,ent_of,{inserter_hands=3})
  eq(c.rows[1].holder,'provider chests'); eq(c.rows[1].count,100); eq(c.rows[1].research_units,80)
  eq(c.rows[2].holder,'landing pads'); eq(c.rows[3].holder,'labs')
  eq(c.made_per_min,60); eq(c.used_per_min,30); eq(c.research_units,155.2)
  has(table.concat(c.lines,' | '),'inserter hands 3, spoil not read (counted only)')
  has(c.spoil_read,'the largest 3 of 3 places read for spoil')
  game,defines=nil,nil
end
print('d19_batch45 B1 where_is census: ok')

-- batch40 D1 (Sol: Wayfarer fuel and ammo starvation): a platform's belt line ends, lane by lane: a stopped lane no
-- inserter takes from, a lane whose front item no inserter there takes (its lane choice or filter), what is past the end
do
  defines={}
  prototypes={item={['iron-ore']={type='item'},['firearm-magazine']={type='ammo'}},get_item_filtered=function() return {} end}
  local function line(items,n) return {get_item_count=function() return n end,get_detailed_contents=function() local out={} for k,name in ipairs(items) do out[k]={stack={valid_for_read=true,name=name},position=k} end return out end} end
  local unit=0
  local function belt(x,y,dir,left,right,typ)
    unit=unit+1
    local b={valid=true,unit_number=unit,name=typ or 'transport-belt',type=typ or 'transport-belt',position={x=x,y=y},direction=dir,belt_neighbours={inputs={},outputs={}}}
    b.get_max_transport_line_index=function() return 2 end
    b.get_transport_line=function(k) return k==1 and left or right end
    return b
  end
  -- line A: two belts east, its end at the hull edge, ore stopped on the right lane, nothing picks
  local a1=belt(0.5,0.5,4,line({},0),line({'iron-ore'},1))
  local a2=belt(1.5,0.5,4,line({},0),line({'iron-ore','iron-ore','iron-ore','iron-ore'},4))
  a2.belt_neighbours.inputs={a1}; a1.belt_neighbours.outputs={a2}
  -- line B: magazines on the left lane; an inserter picks from the right lane only
  local b1=belt(0.5,5.5,4,line({'firearm-magazine','firearm-magazine'},2),line({},0))
  local ins={valid=true,name='inserter',position={x=0.5,y=6.5},pickup_target=b1,pickup_from_left_lane=false,pickup_from_right_lane=true,filter_slot_count=0}
  local surface={find_entities_filtered=function(f)
      if f.type=='inserter' then return {ins} end
      if f.type and type(f.type)=='table' and f.type[1]=='transport-belt' then return {a1,a2,b1} end
      return {} end,
    get_tile=function(x,y) return {name=x>=2 and 'empty-space' or 'space-platform-foundation'} end}
  local L=dofile('mod/agent-harness_0.1.0/lanecheck.lua'){platform=function() return {name='Wren',surface=surface} end}
  local r=L.read({force={}},{platform='Wren',all=true})
  eq(r.ends,2); eq(r.flagged,2)
  local t=table.concat(r.lines,' | ')
  has(t,'transport-belt (1.5,0.5) right lane: 4 on the end tile (stopped), front iron-ore; past it the hull edge (empty space past it); 0 inserters on the 2 tiles back: stopped: no inserter on the run takes from it')
  has(t,'transport-belt (0.5,5.5) left lane: 2 on the end tile, front firearm-magazine')
  has(t,'no inserter on the run takes firearm-magazine from this lane (inserter (0.5,6.5) picks from the other lane)')
  defines,prototypes=nil,nil
end
print('d19_batch45 D1 platform_lanes: ok')

-- Operator 16:12 (ingredient_gap {all, area} 258 ms on n after the 16:00 load; 240 ms with 21 short items on the private
-- copy's Vulcanus, 1.9 s on a dense 128x128 of Nauvis): each short item's donor search found every holder within 64
-- tiles again and read the surface's whole ground. Now the holders are found once a call in the donor machines' box
-- (stock.near), each one's contents read once; the ground from the ground watch's last pass, once an item; donors for
-- the first 8 short items; 16 machines a call (skip; positions past 16 come back as left); with all, a machine short of
-- nothing has its line only.
do
  game={tick=100}
  defines={inventory={assembling_machine_input=2,furnace_source=3,chest=1,cargo_landing_pad_main=1}}
  prototypes={recipe={gear={ingredients={{type='item',name='iron-plate',amount=2}}},plate={ingredients={{type='item',name='iron-ore',amount=1}}}}}
  local function distance(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^.5 end
  local empty={get_contents=function() return {} end,get_item_count=function() return 0 end}
  local function asm(x,y,recipe,held)
    return {valid=true,name='assembling-machine-2',type='assembling-machine',position={x=x,y=y},get_recipe=function() return {name=recipe} end,
      get_inventory=function() return {get_item_count=function() return held or 0 end,
        get_contents=function() return {{name=prototypes.recipe[recipe].ingredients[1].name,count=held or 0,quality='normal'}} end} end,get_output_inventory=function() return empty end,fluidbox={}}
  end
  local plates={get_contents=function() return {{name='iron-plate',count=50,quality='normal'}} end,get_item_count=function() return 50 end}
  local chest={valid=true,name='iron-chest',type='container',position={x=10.5,y=0.5},get_inventory=function() return plates end}
  local machines={}
  local finds={near=0,radius=0,pods=0}
  local surface={name='nauvis',find_entities_filtered=function(f)
    if f.name=='cargo-pod-container' then finds.pods=finds.pods+1; return {} end
    if f.radius then finds.radius=finds.radius+1; return {} end
    if f.type[3]=='rocket-silo' then return machines end
    finds.near=finds.near+1
    if f.type[1]=='assembling-machine' then return machines end
    if f.type[1]=='container' then return {chest} end
    return {}
  end}
  local p={surface=surface,force={name='player'},position={x=0,y=0}}
  local S=dofile('mod/agent-harness_0.1.0/stock.lua'){distance=distance}
  local grounds=0
  local G=dofile('mod/agent-harness_0.1.0/gap.lua'){position=function(v) return v end,seen=function() return true end,
    entity=function(_,a) for _,m in ipairs(machines) do if m.position.x==a.position.x and m.position.y==a.position.y then return m end end end,
    scan=function(pp,item,opts) return S.scan(pp,item,opts) end,near=function(pp,box,ground) return S.near(pp,box,ground) end,
    ground_index=function() grounds=grounds+1; return nil end,
    where_kept=function(_,item,need,scan) local x=scan.places[1]; return x and string.format('%s (%g,%g) %d tiles, %d free',x.name,x.position.x,x.position.y,math.floor(x.distance+0.5),x.count) or 'none' end}
  for i=1,10 do machines[i]=asm(i*3+0.5,4.5,'gear',0) end
  local area={left_top={x=-10,y=-10},right_bottom={x=60,y=60}}
  local r=G.read(p,{area=area})
  eq(r.read,10); eq(r.short,10)
  eq(finds.near,3,'the holders found once: crafters, chests, pads'); eq(finds.pods,1); eq(finds.radius,0,'no search of its own per item')
  eq(grounds,1,'the ground index once an item')
  eq(r.machines[1].ingredients[1].donors,'iron-chest (10.5,0.5) 8 tiles, 50 free')
  has(r.lines[1],'iron-plate 0/2: 2 short; iron-chest (10.5,0.5) 8 tiles, 50 free')
  eq(r.machines[9].ingredients[1].donors,'donors not read: the call searched those of its first 8 short items')
  eq(r.donors_skipped,'2 short items past the first 8: their donors not read in this call')
  has(r.ground_note,'stacks on the ground not read: the ground watch has not binned them on nauvis yet')
  -- a holder past 64 tiles of a machine is not its donor
  chest.position={x=120.5,y=0.5}
  r=G.read(p,{area=area})
  eq(r.machines[1].ingredients[1].donors,'none')
  chest.position={x=10.5,y=0.5}
  -- 16 machines a call; skip reads on
  for i=11,20 do machines[i]=asm((i-10)*3+0.5,8.5,'gear',2) end
  r=G.read(p,{area=area,all=true})
  eq(r.read,16); eq(r.more,'20 machines there; 1-16 read (top to bottom, then left to right); skip: 16 reads the next')
  eq(r.machines[11].ingredients,nil,'a machine short of nothing: its line only'); has(r.machines[11].line,'iron-plate 2/2')
  eq(#r.machines[1].ingredients,1)
  r=G.read(p,{area=area,all=true,skip=16})
  eq(r.read,4); eq(r.more,nil); eq(r.machines[1].position.x,21.5)
  r=G.read(p,{area=area,skip=20})
  eq(r.read,0); eq(r.lines[1],'20 machines there; skip 20 passes over them all')
  fails=fails or function(fn,want) local ok,err=pcall(fn); assert(not ok,'expected a failure'); has(err,want) end
  fails(function() G.read(p,{positions={{x=3.5,y=4.5}},skip=1}) end,'skip goes with area')
  -- positions past 16: left
  local ps={}
  for i=1,18 do ps[i]=machines[i].position end
  r=G.read(p,{positions=ps})
  eq(r.read,16); eq(#r.left.positions,2); eq(r.left.positions[1].x,ps[17].x)
  has(r.left.note,'2 positions not read (16 a call): pass them as positions')
  defines,prototypes,game=nil,nil,nil
end
print('d19_batch45 operator 16:12 ingredient_gap bounded: ok')

-- The first reply after a load: a platform's ammunition trace for the reply's alerts is read in the background (it was
-- traced at once for a platform of up to 400 belts, 67 ms in one first reply on the private copy).
do
  game={tick=500}
  local st={}
  local F=dofile('mod/agent-harness_0.1.0/ammofeed.lua'){state=function() return st end}
  local surface={count_entities_filtered=function() return 138 end,find_entities_filtered=function() return {} end}
  local pl={index=4,name='Swift',valid=true,surface=surface,force='player'}
  local tr,why=F.get(pl,3600,true)
  eq(tr,nil); has(why,'the ammunition trace of Swift (138 belts) is read in the background')
  assert(st.ammofeed.jobs[4],'a background read begun')
  F.step(); F.step()
  eq(st.ammofeed.jobs[4],nil); assert(st.ammofeed.done[4].tr,'the trace kept')
  assert(F.get(pl,3600,true).as_of:find('read over',1,true))
  game=nil
end
print('d19_batch45 ammofeed background for replies: ok')
