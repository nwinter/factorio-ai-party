#!/usr/bin/env python3
"""Persistent world: agent-only shifts, one watchdog decision per pane, scoped nudges."""
import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time

from run_state import ROOT, alert, command, lock, op_dir, pinned, read, write
from team_views import Reader
sys.path[:0]=[str(ROOT/'tools'),str(ROOT/'tools/stream')]
import quota_check
import quota_rest
import pacing
import pane_resume
import announce
import search_watch

ENV_KEYS=('PATH','HOME','USER','LOGNAME','SHELL','TMPDIR','LANG','TZ','HERDR_WORKSPACE_ID',
          'IMAC_HOST','IMAC_PYTHON',
          'MT_DIR','MT_FACTORIO_APP','MT_EXPECT_VERSION','MT_RCON_PORT','MT_GAME_PORT','MT_MODS_FILE',
          'POG_KB','POG_FACTORIO_VERSION','POG_SPACE_AGE','POG_BROKER','POG_TIME_MODE','POG_ENEMIES','POG_SEED',
          'POG_TEAM_LINE','POG_GOAL','POG_MAP_TEXT','POG_IDENTITY_BRIEF','POG_OPENING_BRIEF',
          'POG_WEB_BLOCK','POG_DENY_READ','POG_READ_SCOPE','POG_SHELL_NET','POG_FULL_TOOLS',
          'POG_ISOLATED','POG_IDLE_NUDGE','POG_PANE_WATCH','POG_WORLD_RUNNING','POG_CLAIM_OWNER',
          'POG_OPERATOR_WAKE','POG_CONTINUOUS')
NUDGE=('Operator (automatic): check your own status, tells, board and notes.md. '
       'Keep building toward the goal with your teammate. If blocked, explain the blocker once '
       'and choose another useful task. Keep your current identity and update your notes.')
# (note-mt309-x) the routes a full run admits: agy, Grok and Muse on their own, Codex on the owner's personal Codex
# (POG Codex home), Claude on the personal or account C profile; never a account B route
ROUTES={'agy':('agy','-'),'grok':('grok','-'),'muse':('muse','-'),'codex':('codex',),'claude':('claude','claude-c')}
FORBIDDEN_ROUTES=('claude-b','codex-b','gsopenrouter')
NUDGE_S=20   # (note-mt309-x) seconds after a turn ends before the idle prompt; the gap between two prompts is 1.5x
LIMIT=re.compile(r'usage limit|weekly limit|quota exceeded|resource.exhausted|exhausted.*quota|hit your .*limit',re.I)
LOGIN=re.compile(r'login expired|not logged in|authentication failed|please (?:run /login|log in)',re.I)


def event(op,kind,**fields):
    with (op/'shifts.jsonl').open('a') as out:out.write(json.dumps(dict(at=time.time(),event=kind,**fields))+'\n')

def members(op):
    work=read(op/'workspaces.json');result={}
    for line in (op/'teams.tsv').read_text().splitlines():
        if not line or line.startswith('#'):continue
        team,name,kind,route,model,effort,label,harness=line.split('\t')
        if team not in work:continue
        assert route not in FORBIDDEN_ROUTES and route in ROUTES.get(kind,()), f'unapproved route {kind}/{route}'
        folder=Path(work[team]['dir']).resolve();tree=Path(work[team]['tree']).resolve()
        assert tree.name.startswith('play-') and folder==tree/'runs'/op.parent.name
        result[name]=dict(team=team,name=name,kind=kind,route=route,model=model,effort=effort,label=label,
                          harness=harness,folder=str(folder),tree=str(tree))
    assert result
    return result

def indexes(op,state):
    (op/'panes.txt').write_text(''.join(f"{a['team']} {n} {a['pane']} {a['kind']}\n" for n,a in state['agents'].items() if a.get('pane')))
    for folder in {a['folder'] for a in state['agents'].values()}:
        Path(folder,'panes.txt').write_text(''.join(f"{n} {a['pane']} {a['kind']}\n" for n,a in state['agents'].items()
                                                 if a['folder']==folder and a.get('pane')))

def capture_env(op):
    write(op/'full-env.json',{k:os.environ[k] for k in ENV_KEYS if k in os.environ})
    (op/'full-env.json').chmod(0o600)

def set_deadline(a,at):
    a['deadline']=at
    # Shift maintenance is operator state; no end time enters an agent's workspace.
    Path(a['folder'],a['name'],'deadline.txt').unlink(missing_ok=True)

def init(run,minutes,max_shifts=0,nudge_s=NUDGE_S):
    pinned();op=op_dir(run)
    assert not (op/'full-run.json').exists(),'run already registered'
    agents=members(op);panes={p[1]:p[2] for l in (op/'panes.txt').read_text().splitlines() if len(p:=l.split())==4}
    now=time.time()
    for name,a in agents.items():
        a.update(pane=panes.get(name),shift=1,deadline=now+minutes*60,started=now,restarts=0,next_retry=0,nudge_s=nudge_s)
        set_deadline(a,math.ceil((now+minutes*60)/60)*60)
    state=dict(run=run,phase='running',started=now,minutes=minutes,max_shifts=max_shifts,agents=agents,serial=0,nudge_s=nudge_s)
    capture_env(op);write(op/'full-run.json',state)
    event(op,'registered',agents=list(agents),minutes=minutes,max_shifts=max_shifts)
    return state

CLAUDE_BIN='/Users/owner/.local/bin/claude'

def claude_client(folder):
    """(ct2, note-mt309-z2) A Claude arm starts from DIR/.claude-run.sh in its pane (tools/launch-agent.sh) and writes
    no .client-state.json: its client is the player Claude process (--permission-mode dontAsk) whose working folder
    is the agent's folder. Its pid, or None."""
    try:
        rows=command(['ps','-axo','pid=,command=']).splitlines()
    except subprocess.SubprocessError:return None
    for line in rows:
        pid,_,args=line.strip().partition(' ')
        if not args.startswith(CLAUDE_BIN+' ') or '--permission-mode dontAsk' not in args:continue
        try:
            cwd=[l[1:] for l in command(['lsof','-a','-p',pid,'-d','cwd','-Fn']).splitlines() if l.startswith('n')]
        except subprocess.SubprocessError:continue
        if cwd and Path(cwd[0])==folder:return int(pid)
    return None

def live_client(a):
    folder=Path(a['folder'])/a['name'];row=read(folder/'.client-state.json',{})
    if a.get('kind')=='claude' and not row:return claude_client(folder) is not None
    if row.get('phase')!='running':return False
    try:
        args=command(['ps','-p',row['pid'],'-o','command='])
        return 'agent-watch-run.py' in args and str(folder) in shlex.split(args)
    except (KeyError,subprocess.SubprocessError):return False

def stop_client(a):
    folder=Path(a['folder'])/a['name'];row=read(folder/'.client-state.json',{})
    if a.get('kind')=='claude' and not row:
        pid=claude_client(folder)
        if pid:
            os.kill(pid,signal.SIGTERM)
            for _ in range(20):
                if claude_client(folder) is None:break
                time.sleep(.5)
            if claude_client(folder) is not None:os.kill(pid,signal.SIGKILL);time.sleep(1)
            if claude_client(folder) is not None:raise RuntimeError('native client did not stop; refusing duplicate')
    elif live_client(a):
        # The wrapper owns its child's process group, including native shell tools.
        child=int(row['child']);parent=int(row['pid'])
        owned=command(['ps','-p',child,'-o','ppid=']).strip()==str(parent)
        os.kill(parent,signal.SIGTERM)
        for _ in range(20):
            if not live_client(a):break
            time.sleep(.5)
        if live_client(a):
            if owned and command(['ps','-p',child,'-o','ppid=']).strip()==str(parent):
                os.killpg(child,signal.SIGKILL)
            time.sleep(1)
        if live_client(a):raise RuntimeError('native client did not stop; refusing duplicate')
    if a.get('pane'):
        subprocess.run(['herdr','pane','close',a['pane']],capture_output=True,timeout=15)
    a['pane']=None

def archive_codex(op,state,a,serial):
    """(note-mt309-x) A stopped Codex client's rollouts out of the POG Codex home into op/codex-sessions/serial-N: the
    next shift's session starts in an empty home, the burn reader still finds them (it reads op/codex-sessions), and
    its rollout check reads only the new session. Not while another Codex client of the run is live (one home)."""
    if a.get('kind')!='codex':return None
    if any(b is not a and b.get('kind')=='codex' and live_client(b) for b in state['agents'].values()):
        alert(op,'codex-archive-skipped',f"{a['name']}: another Codex client is live");return None
    sys.path.insert(0,str(ROOT/'tools'));import codex_pog_home
    home=Path(os.environ.get('POG_CODEX_HOME') or Path.home()/'.pog-codex'/'home')
    out=codex_pog_home.archive(home,op/'codex-sessions'/f'serial-{serial}')
    event(op,'codex-archive',agent=a['name'],serial=serial,moved=len(out['moved']));return out

def snapshot(a,serial):
    folder=Path(a['folder']); dest=Path(a['tree'])/'runs'/f'handoff-{serial}'
    target=dest/a['name'];target.mkdir(parents=True,exist_ok=False)
    for name in ('notes.md','journal.jsonl','context.log','resting.json','resting-last.json'):
        source=folder/a['name']/name
        if source.is_file():shutil.copy2(source,target/name)
    return dest

def start_client(op,a,carry):
    left=math.ceil((a['deadline']-time.time())/60)
    if left<1:raise RuntimeError('shift deadline passed during launch')
    env=read(op/'full-env.json')
    # (note-mt309-x) a Codex player only in its scope with the POG Codex home; never on a account B route
    if a['kind']=='codex' and env.get('POG_ISOLATED')!='1':raise RuntimeError('Codex restarts only isolated (POG_ISOLATED=1)')
    if a['route'] in FORBIDDEN_ROUTES:raise RuntimeError(f"route {a['route']} refused")
    proxies={l.split()[0]:'http://127.0.0.1:'+l.split()[1] for l in (op/'netgate.tsv').read_text().splitlines() if l.strip()}
    folder=Path(a['folder']);tree=Path(a['tree'])
    rest=read(carry/a['name']/'resting.json',{})
    if rest.get('until',0)>time.time():
        write(folder/a['name']/'resting.json',rest)
        return
    env.update(POG_PROXY=proxies[a['name']],POG_TEAM=str(folder/'team.txt'),POG_NO_WAIT='1',POG_TAB='',
               POG_WS=a['name'],POG_BOT=a['name'],POG_MODEL=f"{a['label']} ({a['harness']})",POG_ROUTE=a['route'],
               POG_RESUME=carry.name,POG_RESUME_DIR=str(carry),POG_WORLD_RUNNING='1',POG_PANE_WATCH='1',POG_CONTINUOUS='1')
    # Prompt is shared only within this pair; both fresh and resumed readers get the same accurate facts.
    (folder/'prompt.md').write_text('Read AGENTS.md. Continue from your own notes.md in the same running world. '
                                   'Keep your chosen identity. Check current status and coordinate with your teammate. '
                                   'Keep notes current and keep progressing toward the goal.\n')
    out=command([tree/'tools/launch-agent.sh',op.parent.name,'imac2',a['name'],left,a['kind'],a['model'],a['effort']],
                env=env,cwd=tree,timeout=180)
    a['pane']=out.strip().splitlines()[-1].split()[0];a['started']=time.time()
    # Carry firm or unexpired rests; restart never silently cancels a provider hold.
    rest=read(carry/a['name']/'resting.json',{})
    if rest and rest.get('until',0)>time.time():write(folder/a['name']/'resting.json',rest)
    command([ROOT/'tools/clear-prompts.sh','30',a['pane'],folder/a['name']],timeout=45)

def say(op,key,text):
    session=read(op/'public-session.json',{})
    # Closed rehearsals record the exact line without posting to the production site.
    if session.get('phase')!='live':event(op,'announcement',key=key,text=text,sent=False);return
    token=announce.token()
    if not token:
        token_file=Path('/Users/owner/code/player-of-games/site/worker/.secrets.json')
        token=read(token_file,{}).get('PUBLISH_TOKEN')
    if not token:raise RuntimeError('site announcement token unavailable')
    assert not announce.PRIVATE.search(text)
    cid=hashlib.sha256(('team-shift:'+op.parent.name+':'+key).encode()).hexdigest()[:24]
    ok,detail=announce.post(announce.SITE_API,token,text,cid)
    event(op,'announcement',key=key,text=text,sent=ok,detail=detail)
    if not ok:alert(op,'announcement-failed',detail)

def change(op,state,names,minutes=None,reason='shift',hold=False):
    selected=[state['agents'][n] for n in names]
    state['serial']+=1;serial=state['serial']
    # Save intent before a mutation. The watch can recover a partial launch, never a second live copy.
    for a in selected:a['changing']=True
    write(op/'full-run.json',state)
    if reason=='shift':
        try:say(op,str(serial)+'-begin',f"Shift handoff begins for {len(selected)} agents; the world keeps running.")
        except Exception as e:alert(op,'announcement-failed',e)
    for a in selected:
        stop_client(a)
        archive_codex(op,state,a,serial)
        carry=snapshot(a,serial);a['carry']=str(carry)
        if reason=='shift':a['shift']+=1;a['restarts']=0
        if minutes is not None:a['deadline']=time.time()+minutes*60
        a['held']=hold
        a.pop('completed',None)
        try:
            if not hold:start_client(op,a,carry)
            a['changing']=False
        except Exception as e:
            a['next_retry']=time.time()+300
            alert(op,'agent-start-failed',f"{a['name']}: {e}")
        indexes(op,state);write(op/'full-run.json',state)
    event(op,reason,serial=serial,names=names,held=hold,panes={a['name']:a.get('pane') for a in selected})
    if minutes is not None and not hold:
        end=math.ceil((time.time()+minutes*60)/60)*60
        for a in selected:set_deadline(a,end)
        write(op/'full-run.json',state)
    if reason=='shift':
        count=sum(bool(a.get('pane')) for a in selected)
        try:say(op,str(serial)+'-ready',f"Shift handoff finished: {count} of {len(selected)} agents launched; the world continues.")
        except Exception as e:alert(op,'announcement-failed',e)


def quota(brief,team_file,now):
    if not brief or not 0<=now-float(brief.get('generated_at',0))<=900:return {},{}
    # A newly published brief can contain an older saved provider observation.
    # Recompute its age before either resting a client or releasing a quota hold.
    brief=dict(brief,profiles=[p for p in brief.get('profiles',[])
        if 0<=now-float(p.get('observed_at') or brief['generated_at'])<=900])
    return quota_check.at_limit(brief,str(team_file),now),quota_check.room(brief,str(team_file),now)

def retry_delay(restarts):return min(1800,60*2**min(restarts,5))

def native_idle(a,screen,now):
    """Grok can finish at an empty prompt while Herdr reports unknown.

    Require both the native successful completion receipt and the empty prompt;
    journal silence alone cannot distinguish thinking from a finished turn.
    """
    if a['kind']=='codex':return codex_idle(a,screen,now)
    if a['kind']!='grok':return False
    tail='\n'.join(screen.splitlines()[-25:])
    if pane_resume.BUSY.search(tail) or pane_resume.PURCHASE.search(screen):return False
    if not re.search(r'(?m)^\s*[│┃]\s*❯\s*[│┃]\s*$',tail):return False
    folder=Path(a['folder'])/a['name']/'.grok-home/sessions'
    try:
        path=max(folder.rglob('updates.jsonl'),key=lambda p:p.stat().st_mtime)
        if path.stat().st_mtime<a['started']:return False
        with path.open('rb') as f:
            f.seek(max(0,path.stat().st_size-65536))
            row=json.loads(f.read().splitlines()[-1])
        update=row.get('params',{}).get('update',{})
        return (row.get('method')=='_x.ai/session/update' and update.get('sessionUpdate')=='turn_completed'
                and update.get('stop_reason')=='end_turn' and a['started']<=row['timestamp']<=now-a.get('nudge_s',120))
    except (OSError,ValueError,KeyError,IndexError,TypeError):return False

def codex_idle(a,screen,now,home=None):
    """(s1cx3) A scoped Codex pane reads unknown to Herdr, so a finished turn waited for the 600 s silence rule
    (Astra: 10 min at game 9m). Idle when the arm's newest rollout in the POG Codex home ends its last turn with
    task_complete at least a['nudge_s'] (default 120) s ago and the screen shows no running turn."""
    if pane_resume.BUSY.search('\n'.join(screen.splitlines()[-25:])) or pane_resume.PURCHASE.search(screen):return False
    home=Path(home or os.environ.get('POG_CODEX_HOME') or Path.home()/'.pog-codex'/'home')
    ws=os.path.abspath(os.path.join(a['folder'],a['name'])).encode()
    try:
        mine=[]
        for path in (home/'sessions').rglob('rollout-*.jsonl'):
            if path.stat().st_mtime<a['started']:continue
            with path.open('rb') as f:
                if ws in f.read(16384):mine.append(path)
        if not mine:return False
        path=max(mine,key=lambda p:p.stat().st_mtime)
        with path.open('rb') as f:
            f.seek(max(0,path.stat().st_size-262144))
            rows=[json.loads(l) for l in f.read().splitlines()[1:] if l.strip()]
        turns=[r for r in rows if r.get('type')=='event_msg' and r.get('payload',{}).get('type') in ('task_started','task_complete')]
        if not turns or turns[-1]['payload']['type']!='task_complete':return False
        done=datetime.datetime.fromisoformat(turns[-1]['timestamp'].replace('Z','+00:00')).timestamp()
        return a['started']<=done<=now-a.get('nudge_s',120)
    except (OSError,ValueError,KeyError,IndexError,TypeError):return False

def due_agents(state,now,rooms):
    # A provider hold can span a shift boundary. Process newly available quota
    # before deadlines, or the expired held agent would never be visited again.
    for name in rooms:
        a=state['agents'].get(name)
        if a and a.get('hold_reason')=='quota':
            a['held']=False;a.pop('hold_reason',None)
    return [n for n,a in state['agents'].items() if now>=a['deadline'] and not a.get('completed')
            and (not a.get('held') or (state['max_shifts'] and a['shift']>=state['max_shifts']))]

def watch_agent(op,state,a,now,panes,hits,rooms):
    folder=Path(a['folder'])/a['name'];rest=read(folder/'resting.json',{})
    hit=hits.get(a['name'])
    if hit and (not rest or hit['reset']>rest.get('until',0)):
        stop_client(a)
        line,ok=quota_rest.mark(str(folder),hit['reset'],'quota',firm=True)
        alert(op,'quota-rest',line);rest=read(folder/'resting.json',{})
        if not ok:alert(op,'quota-rest-push-failed',line)
    if rest.get('until',0)>now:
        a['rest_until']=rest['until'];return
    if rest:
        quota_rest.done(str(folder));a.pop('rest_until',None)
    if a.get('hold_reason')=='quota' and a['name'] in rooms:
        a['held']=False;a.pop('hold_reason',None)
    if a.get('held') or now<a.get('next_retry',0):return
    alive=live_client(a)
    screen=panes.read(a['pane']) if a.get('pane') else ''
    if LOGIN.search(screen):
        a['held']=True;stop_client(a);alert(op,'login-required',a['name']);return
    if LIMIT.search(screen):
        # Unknown reset is a firm local hold, not a guessed time or endless retry.
        if a['name'] not in rooms:
            a['held']=True;a['hold_reason']='quota';stop_client(a);alert(op,'quota-reset-unknown',a['name']);return
    stopped=pane_resume.provider_stop(a['kind'],screen)
    status=panes.status(a['pane']) if a.get('pane') else None
    if stopped and status=='working':stopped=None
    if not alive or stopped:
        a['restarts']+=1
        if a['restarts']>4:
            a['held']=True;alert(op,'restart-budget-exhausted',a['name']);return
        a['next_retry']=now+retry_delay(a['restarts'])
        alert(op,'client-restart',f"{a['name']}: {stopped or 'native process exited'}; attempt {a['restarts']}")
        change(op,state,[a['name']],reason='restart');return
    # A live interactive client at an idle prompt may need a local prompt, not a game tell.
    native_ready=status=='unknown' and native_idle(a,screen,now)
    # (note-mt309-x) the run's nudge_s after the turn ends (20 s by default), the same gap rule as sprints: 1.5x
    wait=a.get('nudge_s',state.get('nudge_s',NUDGE_S))
    if (status in ('idle','done') or native_ready) and now-a.get('last_prompt',a['started'])>=wait*1.5:
        recent=folder/'journal.jsonl'
        if not recent.exists() or now-recent.stat().st_mtime>=wait:
            how,ok,detail=panes.prompt(a['pane'],NUDGE);a['last_prompt']=now
            event(op,'idle-prompt',agent=a['name'],method=how,accepted=ok,native_completion=native_ready,
                  first_failed=(lambda v:v if isinstance(v,str) else None)(getattr(panes,'last_failed',None)))
            if not ok:alert(op,'idle-prompt-failed',f"{a['name']}: {detail}")


def nudge(op,state,now):
    reader=Reader()
    for team in {a['team'] for a in state['agents'].values()}:
        report=reader.op('idle_report',team=team)
        for row in report.get('agents') or []:
            a=state['agents'].get(row.get('name'))
            if not a or a['team']!=team or a.get('held') or a.get('rest_until',0)>now:continue
            if now-a['started']<300 or now-a.get('last_nudge',0)<1200:continue
            if (row.get('standing_s') or 0)<600:continue
            if any(l.get('state')=='running' for l in row.get('lanes',[]) if isinstance(l,dict)):continue
            reader.op('tell',{'to':a['name'],'text':NUDGE},team=team)
            a['last_nudge']=now;event(op,'idle-nudge',agent=a['name'],team=team)

_search_at=0.0

def searches(op,state,force=False):
    """The playing agents' web searches and fetched URLs (tools/mt/search_watch.py), once a minute and at the end;
    a failure alerts and never stops the watch. POG_SEARCH_WATCH=0 turns it off."""
    global _search_at
    if os.environ.get('POG_SEARCH_WATCH','1')!='1' or not state or not state.get('agents'):return
    now=time.time()
    if not force and now-_search_at<60:return
    _search_at=now
    try:search_watch.scan_run(op,state)
    except Exception as e:alert(op,'search-watch-error',e)

def watch(run):
    op=op_dir(run);stop=threading.Event();panes=pane_resume.HerdrPanes()
    for sig in (signal.SIGTERM,signal.SIGINT):signal.signal(sig,lambda *_:stop.set())
    with lock(op/'full-watch.lock'):
        while not stop.is_set():
            try:
                pinned()
                with lock(op/'agents.lock'):
                    state=read(op/'full-run.json');now=time.time()
                    if state['phase']!='running':return
                    brief=read(Path.home()/'.cache/ai-usage/agent-brief.json',{})
                    hits,rooms={},{}
                    for folder in {a['folder'] for a in state['agents'].values()}:
                        h,r=quota(brief,Path(folder)/'team.tsv',now);hits.update(h);rooms.update(r)
                    due=due_agents(state,now,rooms)
                    if due:
                        finished=[n for n in due if state['max_shifts'] and state['agents'][n]['shift']>=state['max_shifts']]
                        for n in finished:
                            stop_client(state['agents'][n]);state['agents'][n]['held']=True
                            state['agents'][n]['completed']=True
                        next_names=[n for n in due if n not in finished]
                        if next_names:change(op,state,next_names,state['minutes'])
                        if all(a.get('completed') for a in state['agents'].values()):
                            state['phase']='shifts-complete';event(op,'shifts-complete')
                    if state['phase']=='running':
                        for a in state['agents'].values():
                            if now<a['deadline']:watch_agent(op,state,a,now,panes,hits,rooms)
                        if os.environ.get('POG_IDLE_NUDGE','1')=='1':nudge(op,state,now)
                    state['heartbeat']=time.time();indexes(op,state);write(op/'full-run.json',state)
                # Outside the mutation lock: reading transcripts never holds up an operator shift.
                searches(op,state,force=state['phase']=='shifts-complete')
                if state['phase']=='shifts-complete':return
            except BlockingIOError:pass # a deliberate operator shift holds the mutation lock
            except Exception as e:alert(op,'watchdog-error',e)
            stop.wait(20)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('action',choices=['env','init','watch','shift','hold','release','shutdown','status'])
    p.add_argument('run');p.add_argument('--minutes',type=int,default=90)
    p.add_argument('--max-shifts',type=int,default=0);p.add_argument('--select',default='all')
    p.add_argument('--nudge-s',type=int,default=NUDGE_S,help='init: seconds after a turn ends before the idle prompt')
    p.add_argument('--execute',action='store_true');a=p.parse_args()
    assert a.minutes>=1 and a.max_shifts>=0;op=op_dir(a.run)
    if a.action=='env':capture_env(op);return
    if a.action=='init':print(json.dumps(init(a.run,a.minutes,a.max_shifts,a.nudge_s)));return
    if a.action=='watch':watch(a.run);return
    if a.action=='status':print(json.dumps(read(op/'full-run.json'),indent=2));return
    with lock(op/'agents.lock'):
        state=read(op/'full-run.json');assert state
        names=[n for n,r in state['agents'].items() if a.select in ('all',n,r['team'])]
        assert names,'unknown selection'
        if not a.execute:print(json.dumps(dict(action=a.action,agents=names,minutes=a.minutes,world='keeps running')));return
        os.environ.update(read(op/'full-env.json'));pinned()
        if a.action=='shutdown':
            state['phase']='stopped'
            write(op/'full-run.json',state)
            for row in state['agents'].values():stop_client(row)
            indexes(op,state);write(op/'full-run.json',state)
            return
        if a.action in ('shift','release'):state['phase']='running'
        change(op,state,names,a.minutes,reason='shift' if a.action=='shift' else a.action,hold=a.action=='hold')
        indexes(op,state);write(op/'full-run.json',state)

if __name__=='__main__':main()
