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
