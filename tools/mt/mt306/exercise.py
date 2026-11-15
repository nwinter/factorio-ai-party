"""(mt306, private) Late-game forces on 2.1, all at once, on mt301's split fixture (claimed imac2): per-team platforms
travelling, per-team pods to each team's own pad (Nauvis and, on arrival, Vulcanus), red and blue turrets firing at
each other's bases, and a red->blue market fill with delivery. Run beside tools/mt/standin_load.py + load_bench.py."""
from padlib import *
import sys, time
H = '__agent-harness__'
TEAMS = ['red', 'blue', 'green', 'yellow']

def setup():
    return lua(r'''
local g={pads={},vpads={},plats={},travel={},turrets={}} storage.mt306x=g
local s=game.surfaces.nauvis local v=game.get_surface('vulcanus')
for _,t in ipairs({'red','blue','green','yellow'}) do
 local f=game.forces[t] local sp=f.get_spawn_position(s)
 local pos=s.find_non_colliding_position('cargo-landing-pad',sp,80,1)
 local pad=s.create_entity{name='cargo-landing-pad',position=pos,force=f}
 local sec=pad.get_logistic_sections().add_section() sec.set_slot(1,{value='copper-plate',min=2000})
 g.pads[t]=pad
 if v then local vs=f.get_spawn_position(v) local vp=v.find_non_colliding_position('cargo-landing-pad',vs,80,1)
  if vp then g.vpads[t]=v.create_entity{name='cargo-landing-pad',position=vp,force=f} end end
 local p=f.create_space_platform{name=t..'-drop',planet='nauvis',starter_pack='space-platform-starter-pack'} p.apply_starter_pack()
 p.hub.insert{name='iron-plate',count=4000} p.hub.insert{name='copper-plate',count=2000}
 g.plats[t]=p
 local q=f.create_space_platform{name=t..'-travel',planet='nauvis',starter_pack='space-platform-starter-pack'} q.apply_starter_pack()
 q.hub.insert{name='iron-plate',count=2000}
 g.travel[t]=q
end
local o={tick=game.tick,vulcanus=v~=nil,pads={},vpads={}}
for t,p in pairs(g.pads) do o.pads[t]=p.position end for t,p in pairs(g.vpads) do o.vpads[t]=p.position end
rcon.print(helpers.table_to_json(o))''')

def war():
    """red and blue at war; four gun turrets each at the border between their quadrants, aimed by the engine"""
    return lua(r'''
local g=storage.mt306x local s=game.surfaces.nauvis local red,blue=game.forces.red,game.forces.blue
red.set_cease_fire(blue,false) blue.set_cease_fire(red,false) red.set_friend(blue,false) blue.set_friend(red,false)
local rs,bs=red.get_spawn_position(s),blue.get_spawn_position(s) local mx,my=(rs.x+bs.x)/2,(rs.y+bs.y)/2
local placed={}
local function near(force,ex)
 local es=s.find_entities_filtered{position={mx,my},radius=200,force=ex,type={'assembling-machine','furnace','inserter','transport-belt','electric-pole','container','pipe','wall','mining-drill'},limit=200}
 local best,bd for _,e in ipairs(es) do local d=math.abs(e.position.x-mx) if not bd or d<bd then best,bd=e,d end end
 return best end
for _,pair in ipairs({{red,blue},{blue,red}}) do
 local f,ex=pair[1],pair[2] local target=near(f,ex)
 if target then
  for i=1,4 do
   local at=s.find_non_colliding_position('gun-turret',{target.position.x+(f==red and -12 or 12),target.position.y+(i-2.5)*4},20,1)
   if at then local t=s.create_entity{name='gun-turret',position=at,force=f}
    t.insert{name='uranium-rounds-magazine',count=200} g.turrets[#g.turrets+1]=t placed[#placed+1]=f.name..'@'..math.floor(at.x)..','..math.floor(at.y)..'->'..target.name end
  end
 end
end
rcon.print(helpers.table_to_json{tick=game.tick,border={mx,my},placed=placed})''')

def duel():
    """turrets in range of each other: red ones 14 tiles west of each blue turret alive, blue ones 14 east of each red one"""
    return lua(r'''local g=storage.mt306x local s=game.surfaces.nauvis local alive={red={},blue={}}
for _,t in ipairs(g.turrets) do if t.valid then local a=alive[t.force.name] if a then a[#a+1]=t end end end
if #alive.blue==0 and #alive.red==0 then alive.blue[1]={position={x=34,y=-245}} end
local placed={}
local function put(f,x,y) local at=s.find_non_colliding_position('gun-turret',{x,y},6,1)
 if at then local t=s.create_entity{name='gun-turret',position=at,force=f} t.insert{name='uranium-rounds-magazine',count=20} g.turrets[#g.turrets+1]=t placed[#placed+1]=f..'@'..math.floor(at.x)..','..math.floor(at.y) end end
for i,b in ipairs(alive.blue) do if i<=3 then put('red',b.position.x-14,b.position.y) end end
for i,r in ipairs(alive.red) do if i<=3 then put('blue',r.position.x+14,r.position.y) end end
rcon.print(helpers.table_to_json{tick=game.tick,alive_red=#alive.red,alive_blue=#alive.blue,placed=placed})''')

def drop():
    """each team's drop platform sends one pod of iron to its own Nauvis pad"""
    return lua(r'''local g=storage.mt306x local n=0
for t,p in pairs(g.plats) do if p.valid and g.pads[t].valid and p.space_location and p.space_location.name=='nauvis' then
 local pod=p.hub.create_cargo_pod() if pod then pod.get_inventory(defines.inventory.cargo_unit).insert{name='iron-plate',count=50}
 pod.cargo_pod_destination={type=defines.cargo_destination.station,station=g.pads[t]} n=n+1 end end end
for t,q in pairs(g.travel) do if q.valid and q.space_location and q.space_location.name=='vulcanus' and g.vpads[t] and g.vpads[t].valid then
 local pod=q.hub.create_cargo_pod() if pod then pod.get_inventory(defines.inventory.cargo_unit).insert{name='iron-plate',count=50}
 pod.cargo_pod_destination={type=defines.cargo_destination.station,station=g.vpads[t]} n=n+1 end end end
rcon.print(helpers.table_to_json{tick=game.tick,sent=n})''')

def hop(where):
    setter = f"q.space_location=prototypes.space_location['{where}']" if where in ('nauvis', 'vulcanus') else f"q.space_connection=prototypes.space_connection['{where}']"
    return lua(f'''local g=storage.mt306x local o={{}} for t,q in pairs(g.travel) do if q.valid then {setter}
 o[t]=(q.space_location and q.space_location.name or (q.space_connection and q.space_connection.name or '?'))..':'..q.state end end
rcon.print(helpers.table_to_json{{tick=game.tick,at=o}})''')

def counts():
    return lua(r'''local g=storage.mt306x local o={tick=game.tick,pads={},vpads={},pods=0,turrets=0,ammo=0}
for t,p in pairs(g.pads) do o.pads[t]=p.valid and (p.get_item_count('iron-plate')..'/'..p.get_item_count('copper-plate')) or 'gone' end
for t,p in pairs(g.vpads) do o.vpads[t]=p.valid and p.get_item_count('iron-plate') or 'gone' end
for _,sf in pairs(game.surfaces) do o.pods=o.pods+sf.count_entities_filtered{type='cargo-pod'} end
for _,t in ipairs(g.turrets) do if t.valid then o.turrets=o.turrets+1 o.ammo=o.ammo+t.get_item_count('uranium-rounds-magazine') end end
o.turret_hp=0 for _,t in ipairs(g.turrets) do if t.valid then o.turret_hp=o.turret_hp+t.health end end o.containers=game.surfaces.nauvis.count_entities_filtered{name='cargo-pod-container'}
o.red_n=game.surfaces.nauvis.count_entities_filtered{force='red'} o.blue_n=game.surfaces.nauvis.count_entities_filtered{force='blue'}
rcon.print(helpers.table_to_json(o))''') | {'heap_mb': lua("rcon.print(helpers.table_to_json{h=math.floor(collectgarbage('count')/1024)})", ctx=H)['h']}

def market_start():
    out = {}
    out['stock'] = lua(r'''local m=storage.agent_harness.mt local P=m.pacts or m.market or {} 
local s=storage.agent_harness local post
for _,e in pairs(game.surfaces.nauvis.find_entities_filtered{name='mt-trading-post',force='red'}) do post=e end
local n=post and post.insert{name='iron-plate',count=400} or -1
local bp for _,e in pairs(game.surfaces.nauvis.find_entities_filtered{name='mt-trading-post',force='blue'}) do bp=e end
rcon.print(helpers.table_to_json{tick=game.tick,red_post=post and post.position,inserted=n,blue_post=bp and bp.position,blue_iron=bp and bp.get_item_count('iron-plate')})''', ctx=H)
    def bot(name, action, args):
        q = {'id': 'mt306-' + uuid.uuid4().hex, 'action': action, 'args': args, 'bot': name}
        lv = 0
        t = json.dumps(q)
        while f"]{'=' * lv}]" in t: lv += 1
        return json.loads(raw('/silent-command rcon.print(remote.call("agent_harness","dispatch",' + f"[{'=' * lv}[{t}]{'=' * lv}]" + '))'))
    out['sell'] = bot('rb1', 'sell', {'item': 'iron-plate', 'count': 300, 'price': 20, 'keep': 0, 'to': 'blue'})
    out['buy'] = bot('bb1', 'buy', {'item': 'iron-plate', 'count': 300, 'price': 20, 'from': 'red'})
    return out

def market_read():
    r = call('mt_market', {})
    keep = {k: r.get(k) for k in ('audit', 'records')}
    tx = []
    for pair, rows in (r.get('transactions') or r.get('pairs') or {}).items() if isinstance(r.get('transactions') or r.get('pairs'), dict) else []:
        if 'red' in pair and 'blue' in pair: tx.append({pair: rows if len(json.dumps(rows)) < 3000 else str(rows)[:3000]})
    keep['red_blue'] = tx
    keep['blue_post'] = lua(r'''local bp for _,e in pairs(game.surfaces.nauvis.find_entities_filtered{name='mt-trading-post',force='blue'}) do bp=e end
rcon.print(helpers.table_to_json{tick=game.tick,blue_iron=bp and bp.get_item_count('iron-plate')})''')
    return keep

if __name__ == '__main__':
    phase = sys.argv[1]
    if phase == 'setup':
        r = {'setup': setup(), 'war': war(), 'market': market_start(), 'counts': counts()}
        record('exercise-setup', r); print(json.dumps(r)[:4000])
    elif phase == 'run':
        minutes = float(sys.argv[2]); t0 = time.time(); last_hop = t0; hops = ['nauvis-vulcanus', 'vulcanus', 'nauvis-vulcanus', 'nauvis']; hi = 0
        rows = []
        while time.time() - t0 < minutes * 60:
            a = alive()
            if a.startswith('DEAD'): rows.append({'dead': a}); break
            row = {'t': round(time.time() - t0), 'drop': drop()}
            if time.time() - last_hop > 45:
                row['hop'] = hop(hops[hi % 4]); hi += 1; last_hop = time.time()
            if len(rows) % 6 == 0: row['counts'] = counts()
            if len(rows) % 6 == 3: row['duel'] = duel()
            rows.append(row); print(json.dumps(row)[:600], flush=True)
            time.sleep(5)
        r = {'rows': rows, 'end': counts(), 'market': market_read()}
        record('exercise-run', r); print(json.dumps({k: r[k] for k in ('end', 'market')})[:4000])
