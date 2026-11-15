"""Freeze the joined fixture and save the exact cold start reused by the after run."""
import json
from padlib import raw,lua,record,HERE
pause=lua("game.tick_paused=true; rcon.print(helpers.table_to_json{tick=game.tick,paused=game.tick_paused})")
shift=json.loads(raw("/silent-command rcon.print(remote.call('agent_harness','shift_start',306))"))
assert shift.get('ok'),shift
out=lua("""
local s=storage.agent_harness
s.networks=nil; s.push_alerts=nil; s.push_jobs=nil; s.push_bg=nil; s.push_requested=nil
local o={tick=game.tick,paused=game.tick_paused,teams={},bots={},surfaces=0,platforms=0,base=script.active_mods.base,shift=s.shift}
for _,name in ipairs({'red','blue','green','yellow'}) do
 local f=game.forces[name]; local ps={}
 for _,p in pairs(f.players) do ps[#ps+1]={name=p.name,connected=p.connected} end
 assert(#ps>=1,'no joined player for '..name)
 o.teams[name]={players=ps,entities=game.surfaces.nauvis.count_entities_filtered{force=f}}
end
for _,sf in pairs(game.surfaces) do o.surfaces=o.surfaces+1 end
for _,f in pairs(game.forces) do for _,p in pairs(f.platforms) do o.platforms=o.platforms+1 end end
for name,b in pairs(s.bots.by_name) do o.bots[#o.bots+1]={name=name,force=b.force,alive=b.character and b.character.valid} end
rcon.print(helpers.table_to_json(o))
""",ctx='__agent-harness__')
assert out['base']=='2.1.24'
assert len(out['bots'])==12,out['bots']
record('canonical-start',{'pause':pause,'shift':shift,'fixture':out,'save':'mt306-joined-cold-cp31'})
print(json.dumps(out),flush=True)
print(raw("/silent-command game.server_save('mt306-joined-cold-cp31'); rcon.print('mt306 canonical save requested')"),flush=True)
