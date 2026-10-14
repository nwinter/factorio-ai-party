"""Token usage per agent (operator 08:55, from Nick: "token usage stats for each agent in various places"), read from
each agent CLI's own session logs, read only. A session belongs to an agent and a shift by its working directory,
runs/RUN/AGENT:

  claude (opus, sonnet, haiku)  ROOT/projects/<the workspace path with / and . as ->/*.jsonl: each `assistant` record's
                                message.usage, once per message id (Claude Code repeats it on every content block);
                                `system` compact_boundary records are compactions
  codex (astra, sol, luna)      ROOT/sessions/YYYY/MM/DD/rollout-*.jsonl whose first record (session_meta) has the
                                workspace as cwd, subagent rollouts included: one `token_usage_record` per model
                                response (compaction requests included); `compacted` records are compactions
  grok                          runs/RUN/grok/.grok-home/logs/unified.jsonl (the workspace's own Grok home):
                                `shell.turn.inference_done` per model call; compactions from
                                ROOT/sessions/<quoted workspace>/*/updates.jsonl `auto_compact_completed`
  agy (gemini)                  ROOT/brain/<conversation>/.system_generated/logs/transcript.jsonl: `PLANNER_RESPONSE`
                                per model call. A conversation belongs to the run its first 128 KB names most
                                (runs/RUN/AGENT); the agent's loop starts a fresh conversation every ~10 minutes
                                (conversations), with no compaction
  muse                          ROOT/sessions/YYYY/MM/DD/<id>/session.jsonl whose head has the workspace as cwd, and its
                                subagent/*/session.jsonl: `model_completed` per model call; each
                                `context_compaction_installed` is a compaction, its summarizer's tokens counted too

ROOT is each home of that kind of CLI (`ai-session routes`, with defaults): opus runs on another Claude profile, and
the Codex agents moved between two homes over the run.

Numbers per agent: input (every prompt token: uncached, cache reads and cache writes), cache_read, cache_write,
output (as the CLI counts it), reasoning (where the log reports it), calls (model calls: the turns), compactions,
conversations (agy), context (the prompt size of each call: last, peak, and the peak per minute), first and last
call. Claude Code's compaction summaries and Grok's are in no record, so they are not counted.

Every file is read from the byte offset where the last read stopped; a file found shorter or replaced is read again
from the start, its own numbers replaced. TokenFeed does that once a minute in a thread of its own for the stream
(serve.py), so a slow disk never holds the stream's tick. load() counts a whole shift for the site and caches it in
runs/RUN/tokens.json (git-ignored), recounted when a file changed.
"""
import datetime, glob, json, os, re, subprocess, threading, time
from urllib.parse import quote

VERSION = 1
FILE = "tokens.json"
KINDS = {"claude code": "claude", "codex": "codex", "grok build": "grok", "antigravity": "agy", "muse code": "muse"}
DEFAULT_ROOTS = {"claude": ["~/.claude", "~/.profiles/claude/account-c", "~/.profiles/claude/account-b"],
                 "codex": ["~/.codex", "~/.codex-account-b"], "grok": ["~/.grok"],
                 "agy": ["~/.gemini/antigravity-cli"], "muse": ["~/.local/share/muse"]}
FIELDS = ("input", "cache_read", "cache_write", "output", "reasoning", "calls", "compactions")
HEAD = 16 * 1024        # bytes read to place a Codex or Muse file (its cwd is in the first 4 KB)
AGY_HEAD = 128 * 1024   # bytes of an agy conversation searched for the run it names (about 50 times in its opening)
CHUNK = 4 << 20         # bytes read from one file at a time
CONTEXT_POINTS = 480    # per-minute context peaks kept per agent and shift, the latest (a shift is 4 hours)
_roots = None


def roots():
    """{kind: [existing home dirs]}: POG_TOKEN_ROOTS (JSON, for tests), else the defaults and `ai-session routes`."""
    global _roots
    if _roots is not None:
        return _roots
    env = os.environ.get("POG_TOKEN_ROOTS")
    if env:
        found = json.loads(env)
    else:
        found = {k: list(v) for k, v in DEFAULT_ROOTS.items()}
        try:
            text = subprocess.run(["ai-session", "routes"], capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            text = ""
        for line in text.splitlines()[1:]:
            parts = line.split()
            if len(parts) >= 3 and parts[1] in found and parts[-1].startswith("/"):
                found[parts[1]].append(parts[-1])
    out = {}
    for kind, dirs in found.items():
        seen = []
        for d in dirs:
            d = os.path.realpath(os.path.expanduser(d))
            if os.path.isdir(d) and d not in seen:
                seen.append(d)
        out[kind] = seen
    _roots = out
    return out


def team(run_dir):
    """{agent: kind} from runs/RUN/team.txt ("opus|Claude Opus 5.5 (Claude Code)"), else stream.json's harnesses."""
    out = {}
    try:
        for line in open(os.path.join(run_dir, "team.txt")):
            name, _, label = line.strip().partition("|")
            m = re.search(r"\(([^)]+)\)\s*$", label)
            kind = KINDS.get(m.group(1).strip().lower()) if m else None
            if name and kind:
                out[name] = kind
    except OSError:
        pass
    if out:
        return out
    try:
        agents = json.load(open(os.path.join(run_dir, "stream.json"))).get("agents") or {}
        for name, cfg in agents.items():
            kind = KINDS.get(str((cfg or {}).get("harness") or "").lower())
            if kind:
                out[name] = kind
    except (OSError, ValueError, AttributeError):
        pass
    return out


def shift_times(run_dir):
    try:
        return json.load(open(os.path.join(run_dir, "stream.json"))).get("shift") or {}
    except (OSError, ValueError, AttributeError):
        return {}


def run_start(run_dir):
    """Unix time the shift started: stream.json's shift start, else the first score's local time, else team.txt's."""
    s = shift_times(run_dir).get("start")
    if isinstance(s, (int, float)):
        return float(s)
    try:
        with open(os.path.join(run_dir, "scores.jsonl")) as f:
            return datetime.datetime.fromisoformat(json.loads(f.readline())["t"]).timestamp()
    except (OSError, ValueError, KeyError, TypeError):
        pass
    try:
        return os.path.getmtime(os.path.join(run_dir, "team.txt"))
    except OSError:
        return time.time()


def run_end(run_dir, start):
    """Unix time the shift ends: stream.json's shift end, else six hours after its start."""
    e = shift_times(run_dir).get("end")
    return float(e) if isinstance(e, (int, float)) else start + 6 * 3600


def days(start, end):
    """Local dates YYYY/MM/DD from the day before start to end's, for the CLIs' date folders."""
    d = datetime.date.fromtimestamp(start) - datetime.timedelta(days=1)
    last = datetime.date.fromtimestamp(end)
    out = []
    while d <= last:
        out.append(d.strftime("%Y/%m/%d"))
        d += datetime.timedelta(days=1)
    return out


def when(v):
    """Unix seconds from an ISO time ("2026-10-14T10:36:04.026Z"), seconds or microseconds; None if unreadable."""
    if isinstance(v, (int, float)):
        return v / 1e6 if v > 1e14 else v / 1e3 if v > 1e11 else float(v)
    if isinstance(v, str):
        try:
            return datetime.datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp()
        except ValueError:
            return None
    return None


def blank():
    return {"input": 0, "cache_read": 0, "cache_write": 0, "output": 0, "reasoning": 0, "calls": 0, "compactions": 0,
            "compaction_at": [], "ctx": {}, "last_ctx": None, "first": None, "last": None}


def add(acc, t, prompt, cache_read, cache_write, output, reasoning, call=True):
    """One model call (call=False: a summary call counted in tokens only): prompt is every prompt token."""
    acc["input"] += prompt
    acc["cache_read"] += cache_read
    acc["cache_write"] += cache_write
    acc["output"] += output
    acc["reasoning"] += reasoning
    if not call:
        return
    acc["calls"] += 1
    if t is None:
        return
    m = int(t // 60)
    acc["ctx"][m] = max(acc["ctx"].get(m, 0), prompt)
    if acc["last_ctx"] is None or t >= acc["last_ctx"][0]:
        acc["last_ctx"] = [t, prompt]
    acc["first"] = t if acc["first"] is None else min(acc["first"], t)
    acc["last"] = t if acc["last"] is None else max(acc["last"], t)


def compaction(acc, t):
    acc["compactions"] += 1
    if t is not None:
        acc["compaction_at"].append(round(t))


def n(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else 0


# ---- one parser per CLI: (line bytes, the file's numbers, the file's own state) ------------------------------------

def claude_line(line, acc, st):
    if b'"usage"' in line:
        r = json.loads(line)
        m = r.get("message") if r.get("type") == "assistant" else None
        u = m.get("usage") if isinstance(m, dict) else None
        if not isinstance(u, dict) or m.get("model") == "<synthetic>":
            return
        mid = m.get("id")
        if mid is not None:
            if mid in st.setdefault("ids", {}):
                return
            st["ids"][mid] = True
            if len(st["ids"]) > 256:  # the repeats of one message come together
                st["ids"].pop(next(iter(st["ids"])))
        cw, cr = n(u.get("cache_creation_input_tokens")), n(u.get("cache_read_input_tokens"))
        add(acc, when(r.get("timestamp")), n(u.get("input_tokens")) + cw + cr, cr, cw, n(u.get("output_tokens")),
            n((u.get("output_tokens_details") or {}).get("thinking_tokens")))
    elif b'"compact_boundary"' in line:
        r = json.loads(line)
        if r.get("type") == "system" and r.get("subtype") == "compact_boundary":
            compaction(acc, when(r.get("timestamp")))


def codex_line(line, acc, st):
    if b'"token_usage_record"' in line:
        r = json.loads(line)
        p = r.get("payload") if r.get("type") == "token_usage_record" else None
        u = p.get("usage") if isinstance(p, dict) else None
        if not isinstance(u, dict):
            return
        rid = p.get("response_id")
        if rid is not None:
            seen = st.setdefault("ids", set())
            if rid in seen:
                return
            seen.add(rid)
        add(acc, when(r.get("timestamp")), n(u.get("input_tokens")), n(u.get("cached_input_tokens")),
            n(u.get("cache_write_input_tokens")), n(u.get("output_tokens")), n(u.get("reasoning_output_tokens")))
    elif b'"compacted"' in line:
        r = json.loads(line)
        if r.get("type") == "compacted":
            compaction(acc, when(r.get("timestamp")))


def grok_line(line, acc, st):
    if b'"shell.turn.inference_done"' in line:
        r = json.loads(line)
        c = r.get("ctx") if r.get("msg") == "shell.turn.inference_done" else None
        if isinstance(c, dict):
            add(acc, when(r.get("ts")), n(c.get("prompt_tokens")), n(c.get("cached_prompt_tokens")), 0,
                n(c.get("completion_tokens")), n(c.get("reasoning_tokens")))


def grok_updates_line(line, acc, st):
    if b'"auto_compact_completed"' in line:
        r = json.loads(line)
        u = (r.get("params") or {}).get("update") or {}
        if u.get("sessionUpdate") == "auto_compact_completed":
            compaction(acc, when(r.get("timestamp")))


def agy_line(line, acc, st):
    if b'"PLANNER_RESPONSE"' in line and b'"input_tokens"' in line:
        r = json.loads(line)
        if r.get("type") == "PLANNER_RESPONSE":
            cr = n(r.get("cache_read_tokens"))
            add(acc, when(r.get("created_at")), n(r.get("input_tokens")) + cr, cr, 0, n(r.get("output_tokens")), 0)


def muse_line(line, acc, st):
    if b'"model_completed"' in line:
        r = json.loads(line)
        ev = (r.get("payload") or {}).get("event") or {}
        u = ev.get("usage") if ev.get("kind") == "model_completed" else None
        if isinstance(u, dict):
            add(acc, when(r.get("recorded_at")), n(u.get("input_tokens")), n(u.get("cache_read_tokens") or u.get("cached_tokens")),
                n(u.get("cache_write_tokens")), n(u.get("output_tokens")), n(u.get("reasoning_tokens")))
    elif b'"context_compaction_installed"' in line:
        r = json.loads(line)
        ev = (r.get("payload") or {}).get("event") or {}
        if ev.get("kind") == "context_compaction_installed":
            t = when(r.get("recorded_at"))
            su = ev.get("summarizer_usage") or {}
            add(acc, t, n(su.get("input_tokens")), 0, 0, n(su.get("output_tokens")), 0, call=False)
            compaction(acc, t)


# ---- finding the files ---------------------------------------------------------------------------------------------

def head(path, size=HEAD):
    try:
        with open(path, "rb") as f:
            return f.read(size)
    except OSError:
        return b""


CWD = re.compile(rb'"cwd"\s*:\s*"([^"]+)"')
_placed = {}  # (path, how) -> what the file's head says: once the head is written it never changes


def placed(path, how, fn, size=HEAD):
    """fn(path), kept once the file's first `size` bytes are written (a young file may not name its place yet)."""
    key = (path, how)
    if key in _placed:
        return _placed[key]
    found = fn(path)
    try:
        if os.path.getsize(path) >= size:
            _placed[key] = found
    except OSError:
        pass
    return found


def head_cwd(path):
    m = CWD.search(head(path))
    return m.group(1).decode("utf-8", "replace") if m else None


def run_named(agent):
    """The run an agy conversation's opening names most as runs/RUN/AGENT (None if it names none)."""
    want = re.compile(rb"runs/([^/\"\\]+)/" + re.escape(agent.encode()) + rb"\b")

    def fn(path):
        names = {}
        for m in want.finditer(head(path, AGY_HEAD)):
            names[m.group(1)] = names.get(m.group(1), 0) + 1
        return max(names, key=names.get).decode("utf-8", "replace") if names else None
    return fn


class Finder:
    """The session files of one shift's agents, found again on each call (new subagent files, new agy conversations);
    a file's head is read once to place it."""

    def __init__(self, run_dir, agents, start=None, end=None):
        """end: None for the live shift (searched up to now)."""
        self.run_dir = os.path.realpath(run_dir)
        self.run = os.path.basename(self.run_dir)
        self.agents = dict(agents)  # agent -> kind
        self.start = start if start is not None else run_start(run_dir)
        self.end = end

    def workspace(self, agent):
        return os.path.join(self.run_dir, agent)

    def files(self):
        """{path: (agent, parser)} for the files there are now."""
        out = {}
        dates = days(self.start, self.end or time.time())
        by_kind = {}
        for agent, kind in self.agents.items():
            by_kind.setdefault(kind, []).append(agent)
        r = roots()
        for agent in by_kind.get("claude", []):
            name = re.sub(r"[^A-Za-z0-9]", "-", self.workspace(agent))
            for root in r.get("claude", []):
                d = os.path.join(root, "projects", name)
                for p in glob.glob(os.path.join(d, "*.jsonl")) + glob.glob(os.path.join(d, "*", "subagents", "*.jsonl")):
                    out[p] = (agent, claude_line)
        if by_kind.get("codex"):
            ws = {self.workspace(a): a for a in by_kind["codex"]}
            for root in r.get("codex", []):
                for day in dates:
                    for p in glob.glob(os.path.join(root, "sessions", day, "rollout-*.jsonl")):
                        agent = ws.get(placed(p, "cwd", head_cwd))
                        if agent:
                            out[p] = (agent, codex_line)
        for agent in by_kind.get("grok", []):
            home = os.path.join(self.workspace(agent), ".grok-home")
            p = os.path.join(home, "logs", "unified.jsonl")
            if os.path.exists(p):
                out[p] = (agent, grok_line)
            for root in r.get("grok", []) + [home]:
                for u in glob.glob(os.path.join(root, "sessions", quote(self.workspace(agent), safe=""), "*", "updates.jsonl")):
                    out.setdefault(os.path.realpath(u), (agent, grok_updates_line))
        for agent in by_kind.get("agy", []):
            for root in r.get("agy", []):
                for conv in glob.glob(os.path.join(root, "brain", "*")):
                    p = os.path.join(conv, ".system_generated", "logs", "transcript.jsonl")
                    try:
                        if os.path.getmtime(p) < self.start - 86400:
                            continue  # last written before the shift: another run's
                    except OSError:
                        continue
                    if placed(p, "agy:" + agent, run_named(agent), AGY_HEAD) == self.run:
                        out[p] = (agent, agy_line)
        if by_kind.get("muse"):
            ws = {self.workspace(a): a for a in by_kind["muse"]}
            for root in r.get("muse", []):
                for day in dates:
                    for p in glob.glob(os.path.join(root, "sessions", day, "*", "session.jsonl")):
                        agent = ws.get(placed(p, "cwd", head_cwd))
                        if agent:
                            out[p] = (agent, muse_line)
                            for s in glob.glob(os.path.join(os.path.dirname(p), "subagent", "*", "session.jsonl")):
                                out[s] = (agent, muse_line)
        return out


# ---- reading -------------------------------------------------------------------------------------------------------

class Tail:
    """One file read on from where the last read stopped."""

    def __init__(self, path, agent, parse):
        self.path, self.agent, self.parse = path, agent, parse
        self.offset, self.partial, self.ino = 0, b"", None
        self.acc, self.state = blank(), {}
        self.bad = 0

    def read(self, budget=None, pause=0.0):
        """Reads what was appended (at most budget bytes; None: all of it) -> bytes read."""
        try:
            st = os.stat(self.path)
        except OSError:
            return 0
        if self.ino is not None and (st.st_ino != self.ino or st.st_size < self.offset):
            self.offset, self.partial, self.acc, self.state = 0, b"", blank(), {}  # replaced: count it again
        self.ino = st.st_ino
        done = 0
        with open(self.path, "rb") as f:
            f.seek(self.offset)
            while self.offset < st.st_size and (budget is None or done < budget):
                data = f.read(min(CHUNK, st.st_size - self.offset))
                if not data:
                    break
                self.offset += len(data)
                done += len(data)
                lines = (self.partial + data).split(b"\n")
                self.partial = lines.pop()
                for line in lines:
                    self.line(line)
                if pause:
                    time.sleep(pause)  # the stream's other threads get the interpreter between chunks
        return done

    def line(self, line):
        try:
            self.parse(line, self.acc, self.state)
        except (ValueError, TypeError, AttributeError, KeyError):
            self.bad += 1

    def finish(self):
        """A last line with no newline (a finished file): counted if it parses."""
        if self.partial.strip():
            self.line(self.partial)
            self.partial = b""


def merge(accs, kind=None):
    """One agent's numbers from its files' numbers (kind agy: each file is a conversation)."""
    out = {f: 0 for f in FIELDS}
    ctx, at, last, first, final = {}, [], None, None, None
    conversations = 0
    for a in accs:
        for f in FIELDS:
            out[f] += a[f]
        for m, v in a["ctx"].items():
            ctx[m] = max(ctx.get(m, 0), v)
        at += a["compaction_at"]
        if a["last_ctx"] and (last is None or a["last_ctx"][0] >= last[0]):
            last = a["last_ctx"]
        if a["first"] is not None:
            first = a["first"] if first is None else min(first, a["first"])
            final = a["last"] if final is None else max(final, a["last"])
        conversations += a["calls"] > 0
    keys = sorted(ctx)[-CONTEXT_POINTS:]
    out.update({"total": out["input"] + out["output"], "context": last[1] if last else None,
                "context_at": round(last[0]) if last else None, "context_max": max(ctx.values()) if ctx else None,
                "context_minutes": [[m * 60, ctx[m]] for m in keys], "compaction_at": sorted(at),
                "conversations": conversations if kind == "agy" else None, "first": round(first) if first else None,
                "last": round(final) if final else None})
    return out


class Shift:
    """One shift's token numbers per agent, kept up to date by poll(). live: files are searched for up to now (new
    subagent files and agy conversations keep coming); else up to the shift's end."""

    def __init__(self, run_dir, agents=None, live=True):
        self.run_dir = run_dir
        self.agents = dict(agents) if agents is not None else team(run_dir)
        start = run_start(run_dir)
        self.finder = Finder(run_dir, self.agents, start, None if live else run_end(run_dir, start) + 3600)
        self.tails = {}  # path -> Tail

    def poll(self, budget=None, pause=0.0):
        """Reads what every file gained since the last poll (each at most budget bytes) -> bytes read."""
        done = 0
        found = self.finder.files()
        for path in [p for p in self.tails if p not in found and os.path.exists(p)]:
            del self.tails[path]  # placed elsewhere now (a young agy conversation named another run first)
        for path, (agent, parse) in found.items():
            t = self.tails.get(path)
            if t is None:
                t = self.tails[path] = Tail(path, agent, parse)
            done += t.read(budget, pause)
        return done

    def finish(self):
        for t in self.tails.values():
            t.finish()

    def stats(self):
        """{agent: numbers} for every agent of the shift (zeros where no file was found)."""
        by = {a: [] for a in self.agents}
        for t in self.tails.values():
            by.setdefault(t.agent, []).append(t.acc)
        return {a: merge(accs, self.agents.get(a)) for a, accs in by.items()}

    def sources(self):
        out = {}
        for p in sorted(self.tails):
            try:
                st = os.stat(p)
                out[p] = [st.st_size, int(st.st_mtime)]
            except OSError:
                pass
        return out


def compute(run_dir, final=False):
    s = Shift(run_dir, live=not final)
    s.poll()
    s.finish()
    return {"version": VERSION, "run": os.path.basename(os.path.realpath(run_dir)), "final": bool(final),
            "agents": s.stats(), "sources": s.sources()}


def unchanged(sources):
    for p, (size, mtime) in sources.items():
        try:
            st = os.stat(p)
        except OSError:
            continue  # a CLI pruned an old session: the cache keeps its numbers
        if st.st_size != size or int(st.st_mtime) != mtime:
            return False
    return True


def load(run_dir, cache_dir=None, final=False):
    """A shift's numbers, from runs/RUN/tokens.json (or cache_dir/RUN.tokens.json) while its files are unchanged.
    final: the shift has ended (a later one exists), so a cache counted after its end is not searched again for new
    files; the live shift's is. A cache whose files are gone stays (the CLIs prune old sessions)."""
    run_dir = os.path.realpath(run_dir)
    cache = os.path.join(cache_dir, os.path.basename(run_dir) + ".tokens.json") if cache_dir else os.path.join(run_dir, FILE)
    try:
        c = json.load(open(cache))
        if not isinstance(c, dict) or c.get("version") != VERSION:
            c = None
    except (OSError, ValueError):
        c = None
    if c and c.get("final") and unchanged(c.get("sources") or {}):
        return c
    fresh = compute(run_dir, final)
    if c and c.get("sources") and not fresh["sources"]:
        return c  # every session file is gone: keep what was counted
    try:
        if cache_dir:
            os.makedirs(cache_dir, exist_ok=True)
        tmp = cache + ".tmp"
        with open(tmp, "w") as f:
            json.dump(fresh, f, separators=(",", ":"))
        os.replace(tmp, cache)
    except OSError:
        pass  # a read-only runs folder: counted each build
    return fresh


# ---- the stream ----------------------------------------------------------------------------------------------------

_reads = None


def game_action(action, args):
    """agent_stats' rule (tools/agent_stats.py): a request is a game action unless it only reads or talks."""
    global _reads
    if _reads is None:
        import sys
        sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        from agent_stats import READS, TALK
        _reads = (READS, TALK)
    reads, talk = _reads
    return not (action in reads or action in talk or (action == "research" and not args))


REQUEST = re.compile(rb'"event":\s?"request"')


def journal_line(line, acc, st):
    """An agent's fh journal (runs/RUN/AGENT/journal.jsonl): its game actions, in st["actions"]."""
    if REQUEST.search(line, 0, 120):  # {"at":"...","event":"request",...}: replies are most of the bytes
        r = json.loads(line)
        q = r.get("request") if r.get("event") == "request" else None
        if isinstance(q, dict) and game_action(q.get("action"), q.get("args") or {}):
            st["actions"] = st.get("actions", 0) + 1


class TokenFeed:
    """The live shift's numbers for the stream (serve.py): a thread reads the agents' session logs and journals once a
    minute, from where it stopped (the whole shift so far on the first pass, 4 MB at a time with a pause between);
    snapshot() is the latest result and never waits on a file."""

    def __init__(self, run_dir, agents=None, every=60.0):
        self.run_dir = run_dir
        self.every = every
        self.shift = Shift(run_dir, agents)
        self.journals = {a: Tail(os.path.join(run_dir, a, "journal.jsonl"), a, journal_line) for a in self.shift.agents}
        self.latest = None
        self.error = None
        self.thread = None

    def poll(self, pause=0.002):
        self.shift.poll(pause=pause)
        stats = self.shift.stats()
        for agent, j in self.journals.items():
            j.read(pause=pause)
            if agent in stats:
                stats[agent]["actions"] = j.state.get("actions", 0)
        rows = [dict(v, name=k) for k, v in stats.items()]
        rows.sort(key=lambda r: (-r["total"], r["name"]))
        self.latest = {"t": round(time.time(), 1), "since": run_start(self.run_dir), "rows": rows}
        return self.latest

    def run(self):
        while True:
            t0 = time.time()
            try:
                self.poll()
                self.error = None
            except Exception as e:  # never let a strange file stop the feed
                self.error = str(e)
                print(f"[tokens] {type(e).__name__}: {e}", flush=True)
            time.sleep(max(5.0, self.every - (time.time() - t0)))

    def start(self):
        self.thread = threading.Thread(target=self.run, name="tokens", daemon=True)
        self.thread.start()
        return self

    def snapshot(self):
        return self.latest


ROW_KEYS = ("name", "total", "input", "cache_read", "cache_write", "output", "reasoning", "calls", "compactions",
            "conversations", "context", "context_max", "actions")


def brief(snap):
    """The feed's result without the per-minute context series: what the stream's state carries every second."""
    if not snap:
        return None
    return {"t": snap.get("t"), "since": snap.get("since"),
            "rows": [{k: r.get(k) for k in ROW_KEYS} for r in snap.get("rows") or []]}


def short(v):
    """12345678 -> '12.3M', 45600 -> '45.6K', 900 -> '900'."""
    v = v or 0
    for div, unit in ((1e9, "B"), (1e6, "M"), (1e3, "K")):
        if v >= div:
            x = v / div
            return (f"{x:.1f}" if x < 100 else f"{x:.0f}") + unit
    return str(int(v))


def card_line(rows, limit=5, label=None):
    """'Tokens this shift: 1. luna 92.1M, 2. ...' (the overlay card's text, and what the hosts read)."""
    label = label or (lambda name: name)
    parts = [f"{i}. {label(r['name'])} {short(r['total'])}" for i, r in enumerate([r for r in rows if r["total"]][:limit], 1)]
    return "Tokens this shift: " + ", ".join(parts) if parts else None
