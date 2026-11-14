-- Actual transport callback: mod-owned storage, rotation, reload and quarantine.
package.loaded.runtime={tick=function() end,stop_all=function() end}
local events,interface={},nil
storage={}
defines={events={on_tick=1,on_player_created=2,on_console_command=3},input_action={}}
script={on_event=function(k,f) events[k]=f end,on_init=function() end,on_load=function(f) script.load=f end,
  on_configuration_changed=function() end}
remote={add_interface=function(_,i) interface=i end}
helpers={table_to_json=function(x) return x end}
local names={}
game={tick=0,server_save=function(name) names[#names+1]=name end}
log=function() end
dofile('mod/agent-harness_0.1.0/control.lua')
assert(storage.pog_autosave==nil)
local a=interface.autosave_arm('trial',3600,2)
assert(storage.pog_autosave==a and a.next_tick==60)
assert(interface.autosave_arm('trial',54000,12)==a)
game.tick=59;events[1]{tick=59};assert(#names==0)
game.tick=60;events[1]{tick=60};assert(names[1]=='trial-auto-01' and a.sequence==1)
assert(a.error==nil and a.records['1'].tick==60)
game.tick=3660;events[1]{tick=3660};assert(names[2]=='trial-auto-02')
local before_next=a.next_tick
script.load();assert(a.next_tick==before_next and a.sequence==2)
storage.agent_harness.runtime_fault={message='fixture'}
game.tick=7260;events[1]{tick=7260};assert(names[3]=='trial-auto-01' and a.sequence==3)
local scenario={pog_autosave={prefix='wrong'}}
assert(interface.autosave_status().prefix~=scenario.pog_autosave.prefix)
assert(not pcall(interface.autosave_arm,'../escape',3600,2))
assert(not pcall(interface.autosave_arm,'trial',1,2))
assert(not pcall(interface.autosave_save,'wrong'))
game.server_save=function() error('disk full') end
game.tick=10860;events[1]{tick=10860};assert(a.error:find('disk full'))
game.server_save=function(name) names[#names+1]=name end
local point=interface.autosave_save('trial');assert(point.tick==10860 and a.error==nil)
print('mt300 server clock: ok')
