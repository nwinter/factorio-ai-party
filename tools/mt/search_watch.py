#!/usr/bin/env python3
"""Web searches and fetched URLs of a team run's playing agents, read from each CLI's own session logs (read only).

Nick d44: Grok keeps web search in the full team run; the operator watches whether agents search for the project. Per
agent kind (the files are found as tools/stream/tokens.py finds them; Muse's under the workspace's .native-root):

  grok  .grok-home/sessions/<quoted workspace>/*/updates.jsonl: a `tool_call_update` whose rawOutput.action is
        {type: search, query, sources[]}, {type: open_page, url} or {type: find_in_page, url, pattern}; shell commands
        are `tool_call` rawInput.command
  muse  data/muse/sessions/Y/M/D/*/session.jsonl: `assistant_tool_calls_committed` tool_calls[] named web_search
        (args.query), web_fetch (args.url) or bash (args.command)
  agy   brain/*/.system_generated/logs/transcript.jsonl: `PLANNER_RESPONSE` tool_calls[] named search_web,
        read_url_content, browser_subagent or run_command (args are JSON-encoded strings)

A query, URL or shell URL that matches tools/mt/search-terms.json is a hit. Each hit is written once, to
/Users/owner/code/pog-operator/search-wake.jsonl ({"t","from","text"}: the operator's watcher reads *-wake.jsonl),
the run's op log (runs/RUN/op/alerts.jsonl, event search-hit) and runs/RUN/op/search-hits.jsonl (the whole record).
Every web call is counted per agent per local hour in runs/RUN/op/search-watch.json, with the read offsets, so a
restarted watcher neither alerts nor counts twice.

  search_watch.py scan RUN        one pass over a registered full run (tools/mt/full_run.py runs it once a minute)
  search_watch.py hours RUN       a run's web calls per agent per local hour, from runs/RUN/op/search-watch.json
  search_watch.py report DIR...   past team folders (runs/RUN of each play tree): counts and hits, writes nothing
"""
import argparse
import datetime
import glob
import json
import os
from pathlib import Path
import re
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent/'stream'))
import tokens  # noqa: E402

TERMS = HERE/'search-terms.json'
WAKE = Path(os.environ.get('POG_SEARCH_WAKE', '/Users/owner/code/pog-operator/search-wake.jsonl'))
URL = re.compile(r'''https?://[^\s'"\\<>`)\]}]+''')
WEB = ('search', 'open', 'find', 'fetch')  # counted as web calls; 'shell' URLs are counted apart


# ---- terms ---------------------------------------------------------------------------------------------------------

class Terms:
    """The compiled config for one agent's team: own team colors and names are not flagged."""

    def __init__(self, config, teams, own=None, names=()):
        """teams: {team: [agent names]}; names: (team, name) extra display names."""
        f = re.I
        self.always = [(label, re.compile(p, f)) for label, ps in config['always'].items() for p in ps]
        self.combined = [(c['label'], [re.compile(p, f) for p in c['all']]) for c in config['combined']]
        ctx, nctx = config['team_context'], config['name_context']
        colors = [t for t in (teams or {t: [] for t in config['default_teams']}) if t != own]
        self.colors = [(c, re.compile(rf'\b{re.escape(c)}[\s_-]+{ctx}\b|\b{ctx}[\s_-]+{re.escape(c)}\b', f))
                       for c in colors]
        rival = {n for t, ns in (teams or {}).items() if t != own for n in ns}
        rival |= {n for t, n in names if t != own}
        rival |= set(config.get('extra_names') or ())
        own_names = {n for n in (teams or {}).get(own, [])} | {n for t, n in names if t == own}
        self.names = [(n, re.compile(rf'\b{re.escape(n)}\b', f)) for n in sorted(rival - own_names) if len(n) >= 3]
        self.name_ctx = re.compile(rf'\b{nctx}\b', f)
        self.ignore = set(config.get('ignore_url_hosts') or ())

    def match(self, text, strong_only=False):
        """Labels the text matches, in config order, once each."""
        out = []
        for label, rx in self.always:
            if label not in out and rx.search(text):
                out.append(label)
        if strong_only:
            return out
        for label, rxs in self.combined:
            if label not in out and all(rx.search(text) for rx in rxs):
                out.append(label)
        for color, rx in self.colors:
            if rx.search(text):
                out.append('team-color:' + color)
        if self.names and self.name_ctx.search(text):
            for name, rx in self.names:
                if rx.search(text):
                    out.append('team-name:' + name)
        return out

    def keep_url(self, url):
        host = re.sub(r'^https?://', '', url).split('/')[0].split(':')[0].lower()
        return host not in self.ignore


def config(path=TERMS):
    return json.loads(Path(path).read_text())


# ---- the transcripts -----------------------------------------------------------------------------------------------

def args_of(raw):
    """A tool call's args: a JSON string (Muse), a dict whose values are JSON-encoded strings (agy), or a dict."""
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except ValueError:
            return {'text': raw}
    if not isinstance(raw, dict):
        return {}
    out = {}
    for k, v in raw.items():
        if isinstance(v, str) and len(v) >= 2 and v[0] == '"' and v[-1] == '"':
            try:
                v = json.loads(v)
            except ValueError:
                pass
        out[k] = v
    return out


def pick(args, *keys):
    low = {k.lower(): v for k, v in args.items()}
    for k in keys:
        v = low.get(k)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return ' '.join(v for v in args.values() if isinstance(v, str)).strip()


def shell_urls(text):
    return [u.rstrip('.,;:') for u in URL.findall(text or '')]


def grok_events(line):
    if b'"rawOutput"' not in line and b'"command"' not in line:
        return []
    r = json.loads(line)
    u = (r.get('params') or {}).get('update') or {}
    t = float(r.get('timestamp') or 0)
    cid = u.get('toolCallId') or ''
    ro = u.get('rawOutput')
    if u.get('sessionUpdate') == 'tool_call_update' and isinstance(ro, dict) and isinstance(ro.get('action'), dict):
        a = ro['action']
        kind = {'search': 'search', 'open_page': 'open', 'find_in_page': 'find'}.get(a.get('type'), 'search')
        text = a.get('query') if kind == 'search' else a.get('url')
        if kind == 'find' and a.get('pattern'):
            text = f"{a.get('url')} find {a['pattern']}"
        sources = [s.get('url') for s in a.get('sources') or [] if isinstance(s, dict) and s.get('url')]
        return [dict(id=cid + ':' + kind, t=t, kind=kind, text=text or '', sources=sources)]
    ri = u.get('rawInput')
    if u.get('sessionUpdate') == 'tool_call' and isinstance(ri, dict) and isinstance(ri.get('command'), str):
        return [dict(id=f'{cid}:shell:{i}', t=t, kind='shell', text=x) for i, x in enumerate(shell_urls(ri['command']))]
    return []


def muse_events(line):
    if b'assistant_tool_calls_committed' not in line:
        return []
    r = json.loads(line)
    ev = (r.get('payload') or {}).get('event') or {}
    if ev.get('kind') != 'assistant_tool_calls_committed':
        return []
    t = (r.get('recorded_at') or 0) / 1e6
    out = []
    for c in ev.get('tool_calls') or []:
        name, args, cid = c.get('name'), args_of(c.get('args')), c.get('call_id') or c.get('id') or ''
        if name == 'web_search':
            out.append(dict(id=cid, t=t, kind='search', text=pick(args, 'query', 'q')))
        elif name == 'web_fetch':
            out.append(dict(id=cid, t=t, kind='fetch', text=pick(args, 'url')))
        elif name in ('bash', 'bash_input'):
            out += [dict(id=f'{cid}:{i}', t=t, kind='shell', text=x)
                    for i, x in enumerate(shell_urls(pick(args, 'command', 'input')))]
    return out


def agy_events(line, conv=''):
    if b'PLANNER_RESPONSE' not in line:
        return []
    r = json.loads(line)
    if r.get('type') != 'PLANNER_RESPONSE':
        return []
    try:
        t = datetime.datetime.strptime(r.get('created_at', ''), '%Y-%m-%dT%H:%M:%SZ').replace(
            tzinfo=datetime.timezone.utc).timestamp()
    except ValueError:
        t = 0.0
    out = []
    for i, c in enumerate(r.get('tool_calls') or []):
        name, args = c.get('name') or '', args_of(c.get('args'))
        cid = f"{conv}:{r.get('step_index')}:{i}"
        if name == 'search_web':
            out.append(dict(id=cid, t=t, kind='search', text=pick(args, 'query', 'q', 'searchquery')))
        elif name in ('read_url_content', 'read_url', 'execute_url'):
            out.append(dict(id=cid, t=t, kind='fetch', text=pick(args, 'url')))
        elif name == 'browser_subagent':
            out.append(dict(id=cid, t=t, kind='fetch', text=pick(args, 'task', 'url')))
        elif name == 'run_command':
            out += [dict(id=f'{cid}:{j}', t=t, kind='shell', text=x)
                    for j, x in enumerate(shell_urls(pick(args, 'commandline', 'command')))]
    return out


PARSERS = {'grok': grok_events, 'muse': muse_events, 'agy': agy_events}


def files(folder, agents, start=None):
    """{path: (agent, kind)}: one team folder's session logs for {agent: kind}."""
    out = {}
    # A CLI names a session by the workspace path it was started in; a moved run folder (a link to the SSD image)
    # resolves elsewhere, so look under both spellings.
    for spelling in {os.path.abspath(folder), os.path.realpath(folder)}:
        finder = tokens.Finder(folder, agents, start=start)
        finder.run_dir = spelling
        out.update({p: (a, agents[a]) for p, (a, _) in finder.files().items() if not p.endswith('unified.jsonl')})
    folder = os.path.realpath(folder)
    for agent, kind in agents.items():
        if kind != 'muse':
            continue
        try:
            native = Path(folder, agent, '.native-root').read_text().strip()
        except OSError:
            continue
        for p in glob.glob(os.path.join(native, 'data', 'muse', 'sessions', '*', '*', '*', '*', 'session.jsonl')):
            out[p] = (agent, kind)
            for s in glob.glob(os.path.join(os.path.dirname(p), 'subagent', '*', 'session.jsonl')):
                out[s] = (agent, kind)
    return out


def read_new(path, kind, mark):
    """Events appended to path since mark [inode, offset] (complete lines only) -> (events, new mark)."""
    try:
        st = os.stat(path)
    except OSError:
        return [], mark
    ino, offset = mark if mark else (st.st_ino, 0)
    if ino != st.st_ino or st.st_size < offset:
        offset = 0  # replaced: read again; event ids keep counts and hits single
    events = []
    parse = PARSERS[kind]
    conv = os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(path)))) if kind == 'agy' else ''
    with open(path, 'rb') as f:
        f.seek(offset)
        data = f.read(st.st_size - offset)
    end = data.rfind(b'\n') + 1
    for line in data[:end].split(b'\n'):
        if not line:
            continue
        try:
            events += parse(line, conv) if kind == 'agy' else parse(line)
        except (ValueError, TypeError, AttributeError, KeyError):
            pass
    return events, [st.st_ino, offset + end]


# ---- a run ---------------------------------------------------------------------------------------------------------

def hour(t):
    return time.strftime('%Y-%m-%d %H:00', time.localtime(t or time.time()))


class Watch:
    """One run's search state: read offsets, counted ids, hit keys and per-hour counts."""

    def __init__(self, state=None):
        s = state or {}
        self.marks = s.get('marks', {})
        self.counted = set(s.get('counted', []))
        self.seen = set(s.get('seen', []))
        self.hours = s.get('hours', {})
        self.log = None  # a list: report() keeps every web call's text

    def dump(self):
        return dict(marks=self.marks, counted=sorted(self.counted), seen=sorted(self.seen), hours=self.hours)

    def take(self, agent, team, ev, terms):
        """Counts one event once; returns the hit record when it is new."""
        if ev['id'] and (agent + '|' + ev['id']) in self.counted:
            return None
        if ev['id']:
            self.counted.add(agent + '|' + ev['id'])
        row = self.hours.setdefault(agent, {}).setdefault(hour(ev['t']), {})
        row[ev['kind']] = row.get(ev['kind'], 0) + 1
        text = ev['text']
        if self.log is not None and ev['kind'] in WEB:
            self.log.append(dict(at=ev['t'], agent=agent, kind=ev['kind'], text=text))
        if ev['kind'] in ('shell', 'open', 'fetch', 'find') and not terms.keep_url(text):
            return None
        labels = terms.match(text)
        where = ev['kind']
        if not labels:
            for src in ev.get('sources') or []:
                labels = terms.match(src, strong_only=True)
                if labels:
                    where, text = 'result', f"{ev['text']} -> {src}"
                    break
        if not labels:
            return None
        key = f"{agent}|{where}|{' '.join(text.lower().split())}"
        if key in self.seen:
            return None
        self.seen.add(key)
        return dict(at=ev['t'], agent=agent, team=team, kind=where, text=text, labels=labels)

    def scan(self, groups, terms_for):
        """groups: [(folder, {agent: (team, kind)}, start)] -> new hits."""
        hits = []
        for folder, agents, start in groups:
            for path, (agent, kind) in sorted(files(folder, {a: k for a, (_, k) in agents.items()}, start).items()):
                if kind not in PARSERS:
                    continue
                events, self.marks[path] = read_new(path, kind, self.marks.get(path))
                team = agents[agent][0]
                for ev in events:
                    hit = self.take(agent, team, ev, terms_for(team))
                    if hit:
                        hits.append(hit)
        return hits


def wake_text(run, h):
    when = time.strftime('%H:%M', time.localtime(h['at'])) if h['at'] else '?'
    what = {'search': 'searched', 'open': 'opened', 'find': 'searched in', 'fetch': 'fetched',
            'shell': 'ran a shell URL', 'result': 'got a result'}[h['kind']]
    return f"search-watch {run}: {h['agent']} ({h['team']}) {what} at {when}: {h['text'][:300]} [{', '.join(h['labels'])}]"


def append(path, row):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as out:
        try:
            import fcntl
            fcntl.flock(out, fcntl.LOCK_EX)
        except (ImportError, OSError):
            pass
        out.write(json.dumps(row) + '\n')
        out.flush()


def run_groups(op, state):
    """The registered full run's team folders: [(folder, {agent: (team, kind)}, start)] and {team: [agents]}."""
    by_folder, teams = {}, {}
    for name, a in state['agents'].items():
        by_folder.setdefault(a['folder'], {})[name] = (a['team'], a['kind'])
        teams.setdefault(a['team'], []).append(name)
    start = float(state.get('started') or time.time()) - 3600
    return [(f, ag, start) for f, ag in sorted(by_folder.items())], teams


def extra_names(op):
    """runs/RUN/op/search-names.txt: 'team<TAB>name' lines (chosen display names), if the operator keeps one."""
    out = []
    try:
        for line in Path(op, 'search-names.txt').read_text().splitlines():
            parts = line.strip().split('\t')
            if len(parts) == 2 and not line.startswith('#'):
                out.append((parts[0], parts[1]))
    except OSError:
        pass
    return out


def scan_run(op, state=None, wake=None, cfg=None):
    """One pass over a registered run (runs/RUN/op/full-run.json); writes new hits and the state. -> new hits."""
    op = Path(op)
    state = state or json.loads((op/'full-run.json').read_text())
    run = op.parent.name
    cfg = cfg or config()
    groups, teams = run_groups(op, state)
    names = extra_names(op)
    cache = {}
    terms_for = lambda team: cache.setdefault(team, Terms(cfg, teams, team, names))
    path = op/'search-watch.json'
    try:
        watch = Watch(json.loads(path.read_text()))
    except (OSError, ValueError):
        watch = Watch()
    hits = watch.scan(groups, terms_for)
    for h in hits:
        now = time.time()
        text = wake_text(run, h)
        append(op/'search-hits.jsonl', dict(h, run=run, logged=now))
        append(op/'alerts.jsonl', {'at': now, 't': now, 'run': run, 'event': 'search-hit', 'detail': text,
                                   'from': 'search-watch', 'text': text})
        append(wake or WAKE, {'t': now, 'from': 'search-watch', 'text': text})
    tmp = path.with_name(path.name + f'.{os.getpid()}.tmp')
    tmp.write_text(json.dumps(dict(watch.dump(), run=run, scanned=time.time()), indent=1) + '\n')
    tmp.replace(path)
    return hits


# ---- past runs -----------------------------------------------------------------------------------------------------

def folder_team(folder):
    """A past team folder's team: its op/workspaces.json (rehearsals) names it, else None."""
    folder = os.path.realpath(folder)
    for ws in glob.glob(os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(folder))), '*', 'runs',
                                     os.path.basename(folder), 'op', 'workspaces.json')):
        try:
            for team, row in json.load(open(ws)).items():
                if os.path.realpath(row.get('dir', '')) == folder:
                    return team
        except (OSError, ValueError):
            pass
    return None


def report(folders, cfg=None):
    cfg = cfg or config()
    out = []
    for folder in folders:
        agents = tokens.team(folder)
        team = folder_team(folder) or '?'
        terms = Terms(cfg, None, None)
        watch = Watch()
        watch.log = []
        kinds = {a: k for a, k in agents.items() if k in PARSERS}
        hits = watch.scan([(folder, {a: (team, k) for a, k in kinds.items()}, None)], lambda _t: terms)
        counts = {a: {} for a in kinds}
        for a, hours in watch.hours.items():
            for row in hours.values():
                for k, n in row.items():
                    counts[a][k] = counts[a].get(k, 0) + n
        out.append(dict(folder=folder, run=os.path.basename(os.path.realpath(folder)), team=team, agents=kinds,
                        counts=counts, hours=watch.hours, hits=hits, files=len(watch.marks),
                        calls=sorted(watch.log, key=lambda e: e['at'])))
    return out


def hours_table(run, hours):
    lines = [f'{run}: web calls per agent per hour (search/open/find/fetch; shell URLs apart)']
    for agent in sorted(hours):
        for h in sorted(hours[agent]):
            row = hours[agent][h]
            lines.append(f"  {agent:10} {h}  " + ', '.join(f'{k} {row[k]}' for k in sorted(row)))
    return '\n'.join(lines)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('action', choices=['scan', 'hours', 'report'])
    p.add_argument('target', nargs='+')
    p.add_argument('--json', action='store_true')
    a = p.parse_args()
    if a.action == 'scan':
        root = HERE.parents[1]
        for run in a.target:
            assert re.fullmatch(r'[A-Za-z0-9_-]{1,16}', run), 'plain run ID'
            for h in scan_run(root/'runs'/run/'op'):
                print(wake_text(run, h))
        return
    if a.action == 'hours':
        for run in a.target:
            assert re.fullmatch(r'[A-Za-z0-9_-]{1,16}', run), 'plain run ID'
            state = json.loads((HERE.parents[1]/'runs'/run/'op'/'search-watch.json').read_text())
            print(json.dumps(state['hours'], indent=1, sort_keys=True) if a.json else hours_table(run, state['hours']))
        return
    rows = report(a.target)
    if a.json:
        print(json.dumps(rows, indent=1))
        return
    for r in rows:
        print(f"{r['run']} {r['team']} {r['folder']} ({r['files']} logs)")
        for agent, c in r['counts'].items():
            print(f"  {agent} ({r['agents'][agent]}): " + (', '.join(f'{k} {n}' for k, n in sorted(c.items())) or 'none'))
        for e in r['calls']:
            print(f"    {time.strftime('%m-%d %H:%M', time.localtime(e['at']))} {e['agent']} {e['kind']}: {e['text'][:200]}")
        for h in r['hits']:
            print('  HIT ' + wake_text(r['run'], h))


if __name__ == '__main__':
    main()
