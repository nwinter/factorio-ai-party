"""Preserve final native errors, GC settings and the server log before restoration."""
from padlib import lua, raw, record
from config import HERE, LABEL, PASSWORD_FILE
from server_guard import remote

state = lua("""
local s=storage.agent_harness
local n=s.networks or {}
local errors={}
for k,v in pairs(s) do
  if type(k)=='string' and k:find('error') then
    if type(v)=='table' then errors[k]={tick=v.tick,count=v.count,last=v.last,error=v.error}
    elseif type(v)=='string' or type(v)=='number' then errors[k]=v end
  end
end
local p=collectgarbage('setpause',200); collectgarbage('setpause',p)
local m=collectgarbage('setstepmul',200); collectgarbage('setstepmul',m)
rcon.print(helpers.table_to_json{tick=game.tick,errors=errors,
  census_errors=s.census and s.census.errors,map_errors=n.map_errors,view_errors=n.view_errors,
  gc={pause=p,stepmul=m,running=collectgarbage('isrunning')},heap_mb=collectgarbage('count')/1024})
""", ctx='__agent-harness__')
record(LABEL + '-errors-end', state)
assert state['gc']['running'] and state['gc']['pause'] == 200 and state['gc']['stepmul'] == 200, state['gc']
name = 'mt306-' + LABEL
assert all(c.isalnum() or c == '-' for c in name)
record(LABEL + '-save', {'response': raw("/silent-command game.server_save('" + name + "'); rcon.print('save requested')"), 'save': name})
text = remote('cat /Users/owner/pog-mt21/data/factorio-current.log\n')
secret = PASSWORD_FILE.read_text().strip()
if secret:
    text = text.replace(secret, '[REDACTED_RCON_PASSWORD]')
(HERE / (LABEL + '-server-complete.log')).write_text(text)
print(state)
