"""Keep the same twelve stand-ins active throughout the bounded GC sweep."""
import argparse, subprocess
from pathlib import Path
from config import TREE, HERE, CODE, PYTHON, CLAIM, PASSWORD_FILE, LABEL
from gc_sweep import setting
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--settings',nargs='+',type=setting)
parser.add_argument('--seconds',type=int,default=120,choices=range(30,181))
args=parser.parse_args()
extra=['--settings',*(f'{p}/{s}' for p,s in args.settings)] if args.settings else []
minutes=max(2, (args.seconds/60+.2)*len(args.settings or [None]*4)+1)
with open(HERE/(LABEL+'-gc-standins.log'),'w') as log:
    load=subprocess.Popen([PYTHON,'-u',str(TREE/'tools/mt/standin_load.py'),'--port','27475',
        '--password-file',str(PASSWORD_FILE),
        '--bots','rb1,rb2,rb3,bb1,bb2,bb3,gb1,gb2,gb3,yb1,yb2,yb3',
        '--minutes',str(minutes),'--rate','0.9','--give','--out',str(HERE/(LABEL+'-gc-load.jsonl'))],stdout=log,stderr=subprocess.STDOUT)
    try:
        subprocess.run([PYTHON,'-u',str(CODE/'gc_sweep.py'),'--seconds',str(args.seconds),'--allocation-seconds','5','--out',str(HERE/(LABEL+'-gc.json')),*extra],check=True)
        assert load.poll() in (None,0),'stand-ins failed during GC sweep'
    finally:
        if load.poll() is None:load.terminate()
        try:load.wait(timeout=10)
        except subprocess.TimeoutExpired:load.kill();load.wait()
