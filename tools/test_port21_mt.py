#!/usr/bin/env python3
"""Private mt engine/config pins, version refusals and public opt-out; no network."""
import os,pathlib,subprocess,sys,tempfile
from test_imac_copy import stub
import testsafe
ROOT=pathlib.Path(__file__).resolve().parent.parent

def main():
    with tempfile.TemporaryDirectory() as d:
        log=pathlib.Path(d)/'calls'
        stub(d,'ssh',f'''case "$*" in
*"kill -0"*) exit 1;;
*launch.lock*mkdir*) exit 0;;
*"mkdir "*launch.lock*) exit "${{LOCK_EXIT:-0}}";;
*codesign*) echo verify >> '{log}'; exit "${{SIGN_EXIT:-0}}";;
*base/info.json*) echo '{{"version":"'"${{ENGINE_VERSION:-2.1.24}}"'"}}';;
*lsof*) [ "${{OCCUPIED:-0}}" = 1 ] && echo 123; exit 0;;
*nohup*) echo launch >> '{log}'; echo 5151;;
*"cat > "*) cat >/dev/null;;
esac''')
        stub(d,'scp','exit 0');stub(d,'rsync','exit 0');stub(d,'sleep','exit 0')
        stub(d,'python3',f'''case "$*" in *"from pog import Rcon"*) echo 'tick 0'; exit 0;; esac
exec '{sys.executable}' "$@"''')
        def run(**env):
            return subprocess.run([str(ROOT/'tools/mt/port21.sh'),'server','start','imac:/immutable/mt275-final.zip'],
                env=testsafe.env(PATH=d+os.pathsep+os.environ['PATH'],MT_PASSWORD_FILE=d+'/pw',**env),capture_output=True,text=True)
        for env in ({'ENGINE_VERSION':'2.0.77'},{'SIGN_EXIT':'1'},{'LOCK_EXIT':'1'},{'OCCUPIED':'1'},{'POG_MT_PUBLIC':'1'}):
            log.write_text('');r=run(**env);assert r.returncode and 'launch' not in log.read_text(),(env,r)
        log.write_text('');r=run();assert r.returncode==0,(r.stdout,r.stderr);assert 'launch' in log.read_text()
    print('port21 mt: signature/version/lock/ports checked before start; public camera opt-out passed')
if __name__=='__main__':main()
