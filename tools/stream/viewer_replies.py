"""Agents' (and the Operator's) game-chat lines that answer a viewer, or speak to the viewers (d15 08:07: "put
explicit model replies to viewers ... on site chat feed ... most messages there should still be from human viewers").
Pure; shared by model.py (the live page's `viewer_replies`) and site/longrun.py (the archived shift pages' Viewers).

A line is a reply when it was said with reply_to a viewer line's seq (d20 batch50 C1; chat.lua keeps it on the line), or
when it names a viewer who wrote in the last WINDOW_S seconds of game time:
  - `@name` anywhere ("@Foobator Yes. Sonnet is ...", the Operator's "@joonazan Operator: ...");
  - the name (or its short form, 4+ letters: "Craig" for craigNZ830) as a vocative: at the start or after a sentence
    end, a comma, or a greeting or reply word, and followed by `,` `:` `.` `!` `?` or the end ("Foobator, the steel line
    ...", "Yes, Enginerd.", "Understood, Foobator.", "Thanks Foobator, a belt ...", "Foobator, Enginerd: ...").
A line speaks to the viewers when it starts with "Viewers," / "Chat," / "Everyone watching," and the like.
Not counted (shifts 15-16, chat.jsonl): a viewer named in the third person ("Foobator is right that a belt ...", 2 lines),
and an agent's next line after a viewer's @mention of it that names nobody (33 and 67 lines, nearly all team status).
The viewer line a reply answers (d20 batch57 S1, viewer Aurora 15:24: "Could replies link to and close only the question
they answer?"; shift47: Muse's two replies with reply_to lines 90 and 110 minutes old threaded under Aurora's and
Enginerd's newest lines): the line its reply_to names, at any age (Threads keeps every viewer line by seq); without
reply_to, the named viewers' lines in the window: the only one; else the only one addressed to the replier (the relay's
"@sol ..."); else none, and the site shows the reply as not linked to a question. `link` says which. The Operator's replies (Nick, d16 18:32: one threaded under the wrong line): a viewer line
to the Operator ("Operator, ..." / "@operator ...") goes to RUN/operator-inbox.jsonl and never into the game chat, so for
the Operator the viewer lines are the run's inbox rows from viewers (`inbox_lines`) and the game lines addressed to the
Operator ("Operator," / "Operator:" / "@operator" at the start, any case), and "your HH:MM" in the reply names the line
written at that minute, at any age.
"""
import datetime, json, os, re

WINDOW_S = 15 * 60  # a viewer "wrote recently": within this many seconds (game ticks / 60, else wall time)
LEAD = (r"thanks|thank you|yes|no|yeah|yep|nope|sorry|hi|hey|hello|good|ok|okay|right|fair|true|understood|agreed|"
        r"noted|sure|well|ah|oh|great|correct|exactly|indeed|welcome")
ADDRESSED = re.compile(r"^\s*(?:(?:hi|hey|hello|thanks|thank you)[,!]?\s+)?(?:viewers|chat|everyone watching|everybody watching|"
                       r"folks watching|everyone in chat|to the viewers|for the viewers|to everyone watching)\s*[,:!.-]", re.I)
AGENTS = ("astra", "sol", "luna", "opus", "sonnet", "haiku", "grok", "gemini", "muse", "fable")


def short_names(name):
    """The forms a viewer is called by (chatfeed.js viewerShortNames): the name, without trailing digits or _, its
    leading word ("craigNZ830" -> craignz830, craignz, craig)."""
    name = str(name or "")
    out = [name.lower(), re.sub(r"[\d_]+$", "", name).lower()]
    m = re.match(r"[A-Za-z][a-z]+", name)
    if m:
        out.append(m.group(0).lower())
    seen = []
    for k in out:
        if k and k not in seen:
            seen.append(k)
    return seen


def names_viewer(text, name):
    """'at', 'vocative' or None: how the line names viewer `name`."""
    low = str(text or "").lower()
    full = str(name or "").lower()
    if not full:
        return None
    forms = [k for k in short_names(name) if len(k) >= 4 or (k == full and len(k) >= 3)]
    for k in forms + ([full] if full not in forms and len(full) >= 2 else []):  # "@ed": a short name only with @
        if re.search(r"(?<![\w@])@(?:viewer\s+)?" + re.escape(k) + r"(?![\w])", low):
            return "at"
    for k in forms:
        before = r"(?:^|[.!?;]\s+|,\s*|(?:^|[.!?]\s+|,\s*)(?:" + LEAD + r")[,!]?\s+|\band\s+)(?:@?viewer\s+)?@?"
        if re.search(before + re.escape(k) + r"(?![\w])\s*(?:[,:.!?]|$)", low):
            return "vocative"
    return None


def viewer_name(line):
    """The viewer's name of a relayed viewer line ({from: "viewer NAME", viewer: true}), else None."""
    frm = str(line.get("from") or "")
    if line.get("viewer") or frm.lower().startswith("viewer "):
        name = frm[7:] if frm.lower().startswith("viewer ") else frm
        # the host's " (host)" tag is not part of the name agents answer to (d17 13:40: "@NickWinter" went unmatched)
        return re.sub(r"\s*\(host\)$", "", name)
    return None


def speaker(line):
    """The agent (lower-case name) or 'operator' who said a game-chat line, else None (viewers, notices, logs)."""
    if line.get("viewer") or line.get("notice") or line.get("tell"):
        return None
    frm = str(line.get("from") or "").lower()
    agent = str(line.get("agent") or "").lower()
    if agent in AGENTS:
        return agent
    if frm in AGENTS:
        return frm
    if frm == "server":
        return "operator"
    return None


def wall_t(line):
    """A line's wall time: `t`, else chat.jsonl's `logged_at` (local time), else None."""
    if line.get("t") is not None:
        return float(line["t"])
    try:
        return datetime.datetime.fromisoformat(str(line.get("logged_at"))).timestamp()
    except (TypeError, ValueError):
        return None


def _age_s(later, earlier):
    if later.get("tick") is not None and earlier.get("tick") is not None:
        return (later["tick"] - earlier["tick"]) / 60.0
    a, b = wall_t(later), wall_t(earlier)  # an inbox row has no game tick
    return a - b if a is not None and b is not None else -1.0


TO_OPERATOR = re.compile(r"^\s*(?:@operator\b|operator\s*[,:])", re.I)


def inbox_lines(rows):
    """The viewer rows of RUN/operator-inbox.jsonl ({t, agent: "viewer NAME", text, viewer: true, source}) as viewer lines
    for classify: {from, viewer, text, t, source, inbox: true}. Agents' requests (no viewer) are left out."""
    out = []
    for r in rows or []:
        if not isinstance(r, dict) or not r.get("viewer") or not str(r.get("agent") or "").lower().startswith("viewer "):
            continue
        line = {"from": r["agent"], "viewer": True, "text": str(r.get("text") or ""), "t": r.get("t"), "inbox": True}
        if r.get("source"):
            line["source"] = r["source"]
        if r.get("id"):
            line["id"] = r["id"]
        out.append(line)
    return out


def read_inbox(path):
    """inbox_lines of an operator-inbox.jsonl file ([] when there is none)."""
    rows = []
    try:
        with open(path) as f:
            for raw in f:
                try:
                    rows.append(json.loads(raw))
                except ValueError:
                    pass
    except OSError:
        return []
    return inbox_lines(rows)


# (d20 batch65 AA2, viewer Aurora 04:28: "Could replies keep the original question ID through delivery, split parts and
# history? Some clear replies say 'not linked', and artillery answers appeared under a different question"; the
# Operator's 04:20 two-line artillery answer named no time and linked by name to her 04:06 line) tools/opreply.py
# sends the Operator's reply naming the line it answers (site:3817) and first writes RUN/operator-replies.jsonl: {t, to,
# name, question {text, t, source}, parts: [each game-chat line as sent]}. A game line from the Operator whose text is
# one of those parts answers that line, at any age and after a restart; a reply with no record is matched as before.
LINKS_NAME = "operator-replies.jsonl"


def norm(text):
    return re.sub(r"\s+", " ", str(text or "")).strip()


def read_links(path):
    """{part text: {id, name, text, t, source, part: [k, n]}} of an operator-replies.jsonl file ({} when there is none)."""
    out = {}
    try:
        with open(path) as f:
            for raw in f:
                try:
                    r = json.loads(raw)
                except ValueError:
                    continue
                q = r.get("question") if isinstance(r, dict) else None
                parts = r.get("parts") if isinstance(r, dict) else None
                if not isinstance(q, dict) or not r.get("to") or not r.get("name") or not isinstance(parts, list):
                    continue
                for k, text in enumerate(parts, 1):
                    out[norm(text)] = {"id": str(r["to"]), "name": str(r["name"]), "text": str(q.get("text") or ""), "t": q.get("t"),
                                       "source": q.get("source"), "part": [k, len(parts)]}
    except OSError:
        pass
    return out


LINKS_BACK = 2  # (d22 batch89 AY4) earlier runs whose operator-replies.jsonl the model reads too


def links_files(path, back=LINKS_BACK):
    """(d22 batch89 AY4) The operator-replies.jsonl files to read, oldest first: up to `back` runs this one resumed from
    (runs/RUN/resumed-from), then this run's. tools/opreply.py run with --run shift56 during shift57 wrote 6 records
    into shift56's file, and shift57's service read only its own: the 06:28 replies never reached the reply feed, and
    one threaded under the wrong line."""
    out, run_dir = [path], os.path.dirname(path)
    for _ in range(back):
        try:
            prev = open(os.path.join(run_dir, "resumed-from")).readline().strip()
        except OSError:
            break
        if not prev:
            break
        run_dir = os.path.join(os.path.dirname(run_dir), prev)
        p = os.path.join(run_dir, os.path.basename(path))
        if p in out:
            break
        out.append(p)
    return out[::-1]


# (d28 batch309) RUN/viewer-replies.jsonl: each reply row (row()) as model.py made it, one per game seq; read back at a
# stream service start, and from the runs before (links_files), so a restart or a new shift keeps them
ROWS_NAME = "viewer-replies.jsonl"


def read_rows(path):
    """The reply rows of a viewer-replies.jsonl file with a game seq and a time ([] when there is none)."""
    out = []
    try:
        with open(path) as f:
            for raw in f:
                try:
                    r = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(r, dict) and isinstance(r.get("seq"), int) and not isinstance(r.get("seq"), bool) \
                        and isinstance(r.get("t"), (int, float)) and r.get("text") and r.get("by"):
                    out.append(r)
    except OSError:
        pass
    return out


def link_line(line, links):
    """The Operator's game line that tools/opreply.py sent: its link (line["reply_link"]), else the line as it is."""
    if links and speaker(line) == "operator":
        rl = links.get(norm(line.get("text")))
        if rl:
            line["reply_link"] = rl
    return line


def bare(text):
    """A relayed viewer line without the relay's "@astra " address in front (every leading @name: "@Muse @Luna Could
    ..." came back "@Luna Could ...", and the site's match missed Aurora's 04:21 line, d20 batch65 AA2)."""
    return re.sub(r"^(?:@\S+\s+)+", "", str(text or "")).strip()


def to_speaker(v, who):
    """The viewer line is addressed to `who`: the relay's "@sol ..." (or "@muse @sol ..."); for the Operator, an inbox
    row or "Operator, ..."."""
    text = str(v.get("text") or "")
    if who == "operator":
        return bool(v.get("inbox") or TO_OPERATOR.match(text))
    return bool(re.match(r"^\s*(?:@\S+\s+)*@" + re.escape(who) + r"\b", text.lower()))  # "@muse @sol muse: ..."


YOUR_TIME = re.compile(r"\byour (\d{1,2}):(\d{2})\b", re.I)


def local_hm(v):
    t = wall_t(v)
    return datetime.datetime.fromtimestamp(t).strftime("%H:%M") if t is not None else None


def pick(pool, who):
    """(line, link) for a reply that names the viewers of `pool` (their lines in the window, oldest first): the only
    line, else the only one addressed to the replier. Whether a line was answered already does not count: several
    agents answer one line, and one agent answers it again with progress (shift46-47: that rule linked 6 of 10
    follow-ups to another line)."""
    if len(pool) == 1:
        return pool[0], "only_line"
    mine = [v for v in pool if to_speaker(v, who)]
    if len(mine) == 1:
        return mine[0], "only_to"
    return None, "none"


def from_replies_to(line, by_seq=None):
    """(d22 batch75 AK6, viewer Aurora site:4175: "preserve source message IDs through the harness and reply feed, then
    thread by those IDs? Allow one answer to link to several messages.") The viewer lines a say answers as chat.lua kept
    them on the line (replies_to [{seq, name, id, source, tick, text}]): each the line itself when kept here (by_seq),
    else a line made of what the say kept, so a line from an earlier shift or gone from this log still links; with its
    own id (source_id). [] without."""
    out = []
    for x in line.get("replies_to") or []:
        if not isinstance(x, dict) or not x.get("name"):
            continue
        v = (by_seq or {}).get(x.get("seq")) if isinstance(x.get("seq"), int) else None
        v = dict(v) if v and viewer_name(v) else {"from": "viewer " + str(x["name"]), "viewer": True, "text": str(x.get("text") or ""),
                                                 "seq": x.get("seq"), "tick": x.get("tick")}
        for k, f in (("source_id", "id"), ("source", "source")):
            if x.get(f) and not v.get(k):
                v[k] = x[f]
        out.append(v)
    return out


def classify(line, viewer_lines, inbox=(), by_seq=None):
    """For an agent's or the Operator's line and the viewer lines before it (oldest first): None, or {kind: "reply"
    | "to_viewers", to: [viewer names], answers: the viewer line it answers or None, also: the other lines it answers
    (AK6), link (replies): reply_to | name | only_line | only_to | time | none}. inbox: the run's inbox_lines, for the
    Operator's lines only; by_seq: every viewer line kept, by seq (for reply_to)."""
    who = speaker(line)
    if not who:
        return None
    found = from_replies_to(line, by_seq)
    if found:  # (AK6) reply_to (one or several), or linked by the harness by the name it says ("name")
        names = []
        for v in found:
            if viewer_name(v).lower() not in [n.lower() for n in names]:
                names.append(viewer_name(v))
        return {"kind": "reply", "to": names, "answers": found[0], "also": found[1:], "link": "name" if line.get("linked_by") == "name" else "reply_to"}
    rl = line.get("reply_link")
    if isinstance(rl, dict) and rl.get("name"):  # (AA2) the line the Operator named (tools/opreply.py)
        v = {"from": "viewer " + rl["name"], "viewer": True, "text": rl.get("text") or "", "t": rl.get("t"), "id": rl.get("id")}
        if rl.get("source"):
            v["source"] = rl["source"]
        return {"kind": "reply", "to": [rl["name"]], "answers": v, "link": "reply_to"}
    lines = list(viewer_lines)
    # (d20 batch50 C1) say reply_to a viewer line's seq (chat.lua keeps it on the line): that line, whatever the text
    # names; (batch57 S1) at any age
    rt = line.get("reply_to")
    linked_elsewhere = False
    if isinstance(rt, int) and not isinstance(rt, bool):
        v = (by_seq or {}).get(rt) or next((v for v in reversed(lines) if v.get("seq") == rt and viewer_name(v)), None)
        if v and viewer_name(v):
            return {"kind": "reply", "to": [viewer_name(v)], "answers": v, "link": "reply_to"}
        linked_elsewhere = True  # a line this log does not have: never another one by name
    if who == "operator" and inbox:
        lines = sorted(lines + list(inbox), key=lambda v: wall_t(v) or 0)
    recent = [v for v in lines if viewer_name(v) and 0 <= _age_s(line, v) <= WINDOW_S]
    names = []
    for v in recent:
        n = viewer_name(v)
        if n.lower() not in [x.lower() for x in names] and n.lower() not in AGENTS:
            names.append(n)
    named = [n for n in names if names_viewer(line.get("text"), n)]
    text_low = str(line.get("text") or "").lower()
    named.sort(key=lambda n: min([i for i in (text_low.find(k) for k in short_names(n)) if i >= 0] or [len(text_low)]))
    if named:
        low = [n.lower() for n in named]
        pool = [v for v in recent if viewer_name(v).lower() in low]
        if linked_elsewhere:
            return {"kind": "reply", "to": named, "answers": None, "link": "none"}
        if who == "operator":
            # the Operator answers what was asked of it (d17 16:05: "@Foobator Operator: ... every shift's end save is
            # kept" threaded under "@sol isnt spindle your space sci source?"); "your 13:59" names that line
            m = YOUR_TIME.search(str(line.get("text") or ""))
            if m:
                hm = "%02d:%s" % (int(m.group(1)), m.group(2))
                kept = list((by_seq or {}).values()) + [v for v in lines if not isinstance(v.get("seq"), int)]
                at = [v for v in kept if viewer_name(v) and viewer_name(v).lower() in low and _age_s(line, v) >= 0
                      and local_hm(v) == hm]
                if at:
                    return {"kind": "reply", "to": named, "answers": at[-1], "link": "time"}
            pool = [v for v in pool if to_speaker(v, who)]
        if not pool:
            return {"kind": "reply", "to": named, "answers": None, "link": "none"}
        v, link = pick(pool, who)
        return {"kind": "reply", "to": named, "answers": v, "link": link}
    if ADDRESSED.match(str(line.get("text") or "")):
        return {"kind": "to_viewers", "to": [], "answers": None}
    if linked_elsewhere:  # (AK6) a reply_to a viewer line from before this log (shift57: Muse's 19841 to 19660): a reply
        return {"kind": "reply", "to": [], "answers": None, "link": "none"}
    return None


# (d19 batch42 A1) fh posts a say over 500 bytes as numbered parts, "@Foobator (2/3) ...", each repeating the line's
# leading @names (host/saysplit.ts). Part k of n from the same speaker within PART_S of part k-1 answers what part 1
# answered: one thread, also when part 1 named the viewer only as a vocative and the later parts name nobody.
PART = re.compile(r"^(?:@[^\s,:]+[,:]?\s+)*\((\d{1,2})/(\d{1,2})\)\s")
PART_S = 120


def part_of(text):
    """(k, n) of a numbered part ("@Foobator (2/3) ..."), else None."""
    m = PART.match(str(text or ""))
    if not m:
        return None
    k, n = int(m.group(1)), int(m.group(2))
    return (k, n) if 1 <= k <= n and n >= 2 else None


class Threads:
    """classify() that keeps a long reply's numbered parts in part 1's thread (model.py, replies()) and every viewer
    line by seq (`see`: a reply_to finds its line at any age)."""

    KEEP = 2000  # viewer lines kept by seq (a shift has a few hundred)

    def __init__(self):
        self.last = {}  # speaker -> ((k, n), line, result) of its latest numbered part that classified
        self.by_seq = {}

    def see(self, line):
        """A viewer line (one a reply_to can name)."""
        s = line.get("seq")
        if isinstance(s, int) and not isinstance(s, bool) and viewer_name(line):
            self.by_seq[s] = line
            while len(self.by_seq) > self.KEEP:
                self.by_seq.pop(next(iter(self.by_seq)))

    def classify(self, line, viewer_lines, inbox=()):
        who = speaker(line)
        p = part_of(line.get("text"))
        prev = self.last.get(who) if who else None
        if isinstance(line.get("reply_link"), dict):  # (AA2) each part names its line
            r = classify(line, viewer_lines, inbox, self.by_seq)
        elif p and p[0] > 1 and prev and prev[0] == (p[0] - 1, p[1]) and 0 <= _age_s(line, prev[1]) <= PART_S:
            r = prev[2]
        else:
            # part 1 reads without its "(1/3) " ("(1/3) Foobator, the steel line ..." names Foobator as a vocative)
            m = PART.match(str(line.get("text") or "")) if p else None
            plain = dict(line, text=line["text"][:m.start(1) - 1] + line["text"][m.end():]) if m else line
            r = classify(plain, viewer_lines, inbox, self.by_seq)
        if who:
            if p and r and p[0] < p[1]:
                self.last[who] = (p, line, r)
            else:
                self.last.pop(who, None)
        return r


def replies(lines, window_s=WINDOW_S, inbox=(), links=None):
    """Every reply and viewer-addressed line in a chat log (oldest first) -> [(line, result)]. inbox: the run's
    inbox_lines (viewers' lines to the Operator), for the Operator's replies; links: read_links of the run's
    operator-replies.jsonl."""
    out, viewers, threads = [], [], Threads()
    for line in lines:
        if links:
            line = link_line(dict(line), links)
        if viewer_name(line):
            viewers.append(line)
            threads.see(line)
            # only the window matters for a reply without reply_to; keep the list short on a long log
            while viewers and _age_s(line, viewers[0]) > window_s:
                viewers.pop(0)
            continue
        r = threads.classify(line, viewers, inbox)
        if r:
            out.append((line, r))
    return out


def answer_row(a):
    """A viewer line a reply answers, for the page: {name, text, t, tick, source, id?}: id, the line's own id where it
    was written (site:3817: the Operator named it, AA2; AK6: kept on the game line, source_id)."""
    out = {"name": viewer_name(a), "text": bare(a.get("text")), "t": a.get("t"), "tick": a.get("tick"), "source": a.get("source")}
    if a.get("id") or a.get("source_id"):
        out["id"] = str(a.get("id") or a.get("source_id"))
    return out


def row(line, result):
    """The public row for the live page: {seq, t, tick, by, text, kind, to, history?, link?, answers: {name, text, t,
    tick, source}}. link (a reply): how its line was found (classify), "none" when it is linked to no line."""
    a = result.get("answers")
    out = {"seq": line.get("seq"), "t": line.get("t"), "tick": line.get("tick"), "by": speaker(line),
           "text": str(line.get("text") or ""), "kind": result["kind"], "to": result["to"]}
    if line.get("history"):  # read again at a stream restart (model.py chat_time): its own time, shown as history
        out["history"] = True
    if result.get("link"):
        out["link"] = result["link"]
    if a:
        out["answers"] = answer_row(a)
    also = [answer_row(v) for v in result.get("also") or []]
    if also:  # (AK6) the other lines one reply answers
        out["also"] = also
    # (AA2) one of a split reply's parts: [k, n] ("part 1 of 2" on the site)
    rl = line.get("reply_link") if isinstance(line.get("reply_link"), dict) else {}
    p = tuple(rl["part"]) if isinstance(rl.get("part"), list) and len(rl["part"]) == 2 and rl["part"][1] > 1 else part_of(line.get("text"))
    if p:
        out["part"] = [p[0], p[1]]
    return out
