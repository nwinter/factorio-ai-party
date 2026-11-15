"""Matched native bench phase. Owns only its stand-in/exercise/collector processes."""
import argparse,json,subprocess,time
from pathlib import Path
from padlib import raw,lua,HERE,record
from config import TREE, HERE, CODE, PYTHON, CLAIM, PASSWORD_FILE, LABEL
p=argparse.ArgumentParser()
p.add_argument('label');p.add_argument('phase',choices=['standins','all']);p.add_argument('--minutes',type=float,required=True)
a=p.parse_args()
(HERE/(a.label+'-'+a.phase+'.pid')).write_text(str(__import__('os').getpid())+'\n')
base=HERE/(a.label+'-'+a.phase)
children=[];logs=[]

def spawn(name,cmd):
    f=open(str(base)+'-'+name+'.log','w');logs.append(f)
    proc=subprocess.Popen(cmd,stdout=f,stderr=subprocess.STDOUT)
    children.append(proc)
    return proc

def sample():
    return lua("local s=storage.agent_harness; local n=s.networks or {}; rcon.print(helpers.table_to_json{tick=game.tick,paused=game.tick_paused,heap_mb=collectgarbage('count')/1024,network_errors=n.view_errors,map_errors=n.map_errors,push_errors=s.push_errors,census_errors=s.census and s.census.errors,production_error=s.production_legs_error})",ctx='__agent-harness__')

try:
    if a.phase=='all':
        subprocess.run([PYTHON,str(CODE/'exercise.py'),'setup'],stdout=open(str(base)+'-setup.log','w'),stderr=subprocess.STDOUT,check=True)
    output=str(base)+'.json'
    ready=Path(output+'.ready')
    assert not ready.exists(),'do not overwrite an existing phase'
    before=sample();print(json.dumps({'begin':before}),flush=True)
    collector=spawn('bench',[PYTHON,'-u',str(CODE/'load_bench_ready.py'),'--port','27475','--password-file',str(PASSWORD_FILE),
        '--log-cmd','ssh -o BatchMode=yes imac.local cat /Users/owner/pog-mt21/data/factorio-current.log',
        '--minutes',str(a.minutes),'--window','60','--every','5','--label',a.label+'-'+a.phase,'--out',output])
    deadline=time.monotonic()+30
    while not ready.exists():
        assert collector.poll() is None,'collector exited before profile start'
        assert time.monotonic()<deadline,'collector start timeout'
        time.sleep(.05)
    lua("game.tick_paused=false; rcon.print(helpers.table_to_json{tick=game.tick,paused=false})")
    standin=spawn('standins',[PYTHON,'-u',str(TREE/'tools/mt/standin_load.py'),'--port','27475','--password-file',str(PASSWORD_FILE),
        '--bots','rb1,rb2,rb3,bb1,bb2,bb3,gb1,gb2,gb3,yb1,yb2,yb3','--minutes',str(a.minutes),'--rate','0.9','--give','--out',str(base)+'.jsonl'])
    if a.phase=='all':spawn('exercise',[PYTHON,'-u',str(CODE/'exercise.py'),'run',str(a.minutes)])
    deadline=time.monotonic()+a.minutes*60+120
    while any(c.poll() is None for c in children):
        assert time.monotonic()<deadline,'phase time budget exceeded'
        for c in children:
            assert c.poll() in (None,0),'phase child failed; inspect logs'
        print(json.dumps({'progress':sample()}),flush=True)
        time.sleep(30)
    after=sample()
    text=subprocess.check_output(['ssh','-o','BatchMode=yes','imac.local','cat','/Users/owner/pog-mt21/data/factorio-current.log'],text=True)
    Path(str(base)+'.profile.log').write_text(text)
    record(a.label+'-'+a.phase+'-bounds',{'before':before,'after':after,'profile':json.loads(ready.read_text())})
    print(json.dumps({'done':after}),flush=True)
finally:
    for c in children:
        if c.poll() is None:c.terminate()
    for c in children:
        try:c.wait(timeout=10)
        except subprocess.TimeoutExpired:c.kill();c.wait()
    for f in logs:f.close()
