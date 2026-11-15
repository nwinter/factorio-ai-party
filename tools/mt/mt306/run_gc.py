"""Keep the same twelve stand-ins active throughout the bounded GC sweep."""
import subprocess
from pathlib import Path
from config import TREE, HERE, CODE, PYTHON, CLAIM, PASSWORD_FILE, LABEL
with open(HERE/(LABEL+'-gc-standins.log'),'w') as log:
    load=subprocess.Popen([PYTHON,'-u',str(TREE/'tools/mt/standin_load.py'),'--port','27475',
        '--password-file',str(PASSWORD_FILE),
        '--bots','rb1,rb2,rb3,bb1,bb2,bb3,gb1,gb2,gb3,yb1,yb2,yb3',
        '--minutes','10','--rate','0.9','--give','--out',str(HERE/(LABEL+'-gc-load.jsonl'))],stdout=log,stderr=subprocess.STDOUT)
    try:
        subprocess.run([PYTHON,'-u',str(CODE/'gc_sweep.py'),'--seconds','120','--allocation-seconds','5','--out',str(HERE/(LABEL+'-gc.json'))],check=True)
        assert load.poll() in (None,0),'stand-ins failed during GC sweep'
    finally:
        if load.poll() is None:load.terminate()
        try:load.wait(timeout=10)
        except subprocess.TimeoutExpired:load.kill();load.wait()
