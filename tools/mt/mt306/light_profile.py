"""Baseline tick timing with only the outer timer, plus gross allocation without profiler timers."""
import json,subprocess,time
from pathlib import Path
from padlib import raw,lua,HERE,record
from config import TREE, HERE, CODE, PYTHON, CLAIM, PASSWORD_FILE, LABEL
def heap():
    return lua("rcon.print(helpers.table_to_json{tick=game.tick,kb=collectgarbage('count')})",ctx='__agent-harness__')
with open(HERE/(LABEL+'-light-standins.log'),'w') as f:
    load=subprocess.Popen([PYTHON,'-u',str(TREE/'tools/mt/standin_load.py'),'--port','27475','--password-file',str(PASSWORD_FILE),
        '--bots','rb1,rb2,rb3,bb1,bb2,bb3,gb1,gb2,gb3,yb1,yb2,yb3','--minutes','2','--rate','0.9','--give','--out',str(HERE/(LABEL+'-light-load.jsonl'))],stdout=f,stderr=subprocess.STDOUT)
    try:
        time.sleep(30)
        start=json.loads(raw("/silent-command rcon.print(remote.call('agent_harness','profile_ticks',3600))"))
        before=heap();points=[];deadline=time.monotonic()+90
        while time.monotonic()<deadline:
            time.sleep(5);p=heap();points.append(p)
            if p['tick']>=start['until_tick']+60:break
        else:raise TimeoutError('outer timer exceeded budget')
        # A separate three-second allocation sample: no per-part profiler.
        a=lua("collectgarbage('stop'); rcon.print(helpers.table_to_json{tick=game.tick,kb=collectgarbage('count')})",ctx='__agent-harness__')
        try:
            deadline=time.monotonic()+15
            while time.monotonic()<deadline:
                time.sleep(.3);b=heap()
                if b['tick']>=a['tick']+180:break
            else:raise TimeoutError('gross allocation sample exceeded budget')
        finally:lua("collectgarbage('restart'); rcon.print('{}')",ctx='__agent-harness__')
        row={'profile':start,'before':before,'samples':points,'allocation':{'before':a,'after':b,'kb_per_game_s':(b['kb']-a['kb'])/((b['tick']-a['tick'])/60)}}
        record((LABEL+'-light'),row)
        text=subprocess.check_output(['ssh','-o','BatchMode=yes','imac.local','cat','/Users/owner/pog-mt21/data/factorio-current.log'],text=True)
        lines=[l for l in text.splitlines() if 'agent-harness tick average over 3600 ticks' in l]
        row['tick_average_lines']=lines[-1:]
        (HERE/(LABEL+'-light-result.json')).write_text(json.dumps(row,indent=1)+'\n')
        print(json.dumps({'tick_average':row['tick_average_lines'],'allocation_kb_per_game_s':row['allocation']['kb_per_game_s']}),flush=True)
    finally:
        if load.poll() is None:load.terminate()
        try:load.wait(timeout=10)
        except subprocess.TimeoutExpired:load.kill();load.wait()
