"""Agents' (and the Operator's) game-chat lines that answer a viewer, or speak to the viewers (d15 08:07: "put
explicit model replies to viewers ... on site chat feed ... most messages there should still be from human viewers").
Pure; shared by model.py (the live page's `viewer_replies`) and site/longrun.py (the archived shift pages' Viewers).

A line is a reply when it names a viewer who wrote in the last WINDOW_S seconds of game time:
  - `@name` anywhere ("@Foobator Yes. Sonnet is ...", the Operator's "@joonazan Operator: ...");
  - the name (or its short form, 4+ letters: "Craig" for craigNZ830) as a vocative: at the start or after a sentence
    end, a comma, or a greeting or reply word, and followed by `,` `:` `.` `!` `?` or the end ("Foobator, the steel line
    ...", "Yes, Enginerd.", "Understood, Foobator.", "Thanks Foobator, a belt ...", "Foobator, Enginerd: ...").
A line speaks to the viewers when it starts with "Viewers," / "Chat," / "Everyone watching," and the like.
Not counted (shifts 15-16, chat.jsonl): a viewer named in the third person ("Foobator is right that a belt ...", 2 lines),
and an agent's next line after a viewer's @mention of it that names nobody (33 and 67 lines, nearly all team status).
The viewer line a reply answers: the named viewer's latest line before it within the window, one addressed to the
replying agent ("@sol ...") first; with several viewers named, the latest of their lines.
The Operator's replies (Nick, d16 18:32: one threaded under the wrong line): a viewer line to the Operator ("Operator,
..." / "@operator ...") goes to RUN/operator-inbox.jsonl and never into the game chat, so for the Operator the viewer
lines include the run's inbox rows from viewers (`inbox_lines`), and a line addressed to the Operator ("Operator," /
"Operator:" / "@operator" at the start, any case) is the one it answers first.
"""
import datetime, json, re

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
        return frm[7:] if frm.lower().startswith("viewer ") else frm
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


def bare(text):
    """A relayed viewer line without the relay's "@astra " address in front."""
    return re.sub(r"^@\S+\s+", "", str(text or "")).strip()


STOP = set(("that this with your have what will from they them their there when where which would could should about "
             "just also than then into only some more most very well were been being does doing over here").split())


def words(text, skip=()):
    """Words for matching an answer with its question (chatfeed.js words): 4+ letters, not common, first 5 letters."""
    return {w[:5] for w in re.findall(r"[a-z0-9']{4,}", str(text or "").lower()) if w not in STOP and w not in skip}


def classify(line, viewer_lines, inbox=()):
    """For an agent's or the Operator's line and the viewer lines before it (oldest first): None, or {kind: "reply"
    | "to_viewers", to: [viewer names], answers: the viewer line it answers or None}. inbox: the run's inbox_lines,
    for the Operator's lines only."""
    who = speaker(line)
    if not who:
        return None
    lines = list(viewer_lines)
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
        to_me = [v for v in pool if re.match(r"^\s*@" + re.escape(who) + r"\b", str(v.get("text") or "").lower())
                 or (who == "operator" and TO_OPERATOR.match(str(v.get("text") or "")))]
        pick = None
        if pool:
            # the latest, unless an earlier one shares at least two more words with the answer (chatfeed.js questionFor)
            rows = to_me or pool
            skip = {k for n in named for k in short_names(n)}
            aw = words(line.get("text"), skip)
            pick = rows[-1]
            score = len(aw & words(bare(pick.get("text")), skip))
            for v in rows:
                sc = len(aw & words(bare(v.get("text")), skip))
                if sc >= score + 2:
                    pick, score = v, sc
        return {"kind": "reply", "to": named, "answers": pick}
    if ADDRESSED.match(str(line.get("text") or "")):
        return {"kind": "to_viewers", "to": [], "answers": None}
    return None


def replies(lines, window_s=WINDOW_S, inbox=()):
    """Every reply and viewer-addressed line in a chat log (oldest first) -> [(line, result)]. inbox: the run's
    inbox_lines (viewers' lines to the Operator), for the Operator's replies."""
    out, viewers = [], []
    for line in lines:
        if viewer_name(line):
            viewers.append(line)
            # only the window matters; keep the list short on a long log
            while viewers and _age_s(line, viewers[0]) > window_s:
                viewers.pop(0)
            continue
        r = classify(line, viewers, inbox)
        if r:
            out.append((line, r))
    return out


def row(line, result):
    """The public row for the live page: {seq, t, tick, by, text, kind, to, answers: {name, text, t, tick, source}}."""
    a = result.get("answers")
    out = {"seq": line.get("seq"), "t": line.get("t"), "tick": line.get("tick"), "by": speaker(line),
           "text": str(line.get("text") or ""), "kind": result["kind"], "to": result["to"]}
    if a:
        out["answers"] = {"name": viewer_name(a), "text": bare(a.get("text")), "t": a.get("t"), "tick": a.get("tick"),
                          "source": a.get("source")}
    return out
