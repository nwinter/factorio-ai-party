#!/usr/bin/env python3
"""Viewers' blueprints from the site into the shift's team-tools (viewer LimeLight, d16 16:17: "other ways" to share;
until now only a public GitHub repo worked, since site chat takes 200 characters and no links).

  python3 site/viewer_blueprints.py runs/shift24 --world n          # every 60 s (start-team.sh runs it)
  python3 site/viewer_blueprints.py runs/shift24 --world n --once

A viewer pastes a blueprint string with a title on the live page; the Worker checks it decodes to a blueprint or book
and stores it (POST /v1/blueprints, docs/LIVE-API.md). This pulls the new ones (GET /v1/blueprints, publish token)
into RUN/team-tools/viewer-blueprints/: ID-SLUG.txt (the string) and ID-SLUG.json ({id, name, title, time, kind,
label, blueprints, entities, string_file, blueprint: the decoded JSON}), decoded again here with the same caps. Then
one fact line to the team in game chat (`server: viewer blueprint #12 from LimeLight: "Aethera" (blueprint book, 4
blueprints, 1356 entities): team-tools/viewer-blueprints/12-aethera.json, string in 12-aethera.txt`), only while the
viewer relay is on (RUN/viewers-relay.on, as for chat lines); a line not posted yet goes out when it is on again.
The title passes the chat relay's checks (viewers.py: injection, orders, personal data, spam); one that fails is
left out of the line ("title withheld"), and the name gets " (viewer)" if it poses as an agent or staff. Nothing is
imported into the game. The cursor (the last id pulled) is RUN/../viewer-blueprints.json, so a new shift pulls only
new ones.
"""
import argparse, base64, json, os, re, sys, time, unicodedata, urllib.error, urllib.request, zlib
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE.parent / "tools" / "stream"))
MAX_STRING = 1024 * 1024
MAX_JSON = 16 * 1024 * 1024
DIR = "viewer-blueprints"
SWITCH = "viewers-relay.on"


def api_url():
    return json.loads((SITE / "config.json").read_text())["live_api_url"].rstrip("/")


def token():
    if os.environ.get("POG_LIVE_TOKEN"):
        return os.environ["POG_LIVE_TOKEN"]
    return json.loads((SITE / "worker" / ".secrets.json").read_text())["PUBLISH_TOKEN"]


def decode(string):
    """A blueprint string -> its JSON (dict); ValueError when it is not one (the Worker's checks, the same caps)."""
    s = re.sub(r"\s+", "", str(string or ""))
    if not s or len(s) > MAX_STRING or s[0] != "0":
        raise ValueError("not a blueprint string")
    try:
        raw = base64.b64decode(s[1:], validate=True)
        z = zlib.decompressobj()
        out = z.decompress(raw, MAX_JSON + 1)
    except (ValueError, zlib.error) as e:
        raise ValueError(f"not a blueprint string ({e})")
    if len(out) > MAX_JSON or z.unconsumed_tail:
        raise ValueError("too large once decoded")
    j = json.loads(out.decode("utf-8"))
    if not isinstance(j, dict) or not (isinstance(j.get("blueprint"), dict) or isinstance(j.get("blueprint_book"), dict)):
        raise ValueError("not a blueprint or blueprint book")
    return j


def slug(title, n=40):
    t = unicodedata.normalize("NFKD", str(title or "")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "-", t).strip("-")[:n].strip("-") or "blueprint"


def clean_line(text, n=300):
    t = re.sub(r"[\x00-\x1f\x7f]+", " ", str(text or ""))
    return re.sub(r"\s+", " ", t).strip()[:n]


def title_ok(title, agent_names=()):
    """The chat relay's checks on a title the agents will read: -> list of reasons it fails (empty: fine)."""
    import viewers
    reasons = []
    for f in (viewers.spam, viewers.personal, viewers.injection):
        r = f(title)
        reasons += r if isinstance(r, list) else ([r] if r else [])
    if viewers.directive(title, agent_names):
        reasons.append("order")
    if viewers.grief(title, agent_names):
        reasons.append("grief")
    if viewers.impersonation(title, agent_names):
        reasons.append("impersonation")
    return reasons


def fact_line(meta, rel_json, rel_txt, agent_names=()):
    """The one line the team reads (facts only)."""
    import viewers
    name = viewers.Filter(agent_names).name(meta.get("name") or "viewer")
    title = clean_line(meta.get("title"), 80)
    shown = f'"{title}"' if title and not title_ok(title, agent_names) else "(title withheld)"
    what = "blueprint book" if meta.get("kind") == "blueprint_book" else "blueprint"
    count = (f"{meta.get('blueprints', 0)} blueprints, " if meta.get("kind") == "blueprint_book" else "") + \
        f"{meta.get('entities', 0)} entities"
    return clean_line(f"viewer blueprint #{meta['id']} from {name}: {shown} ({what}, {count}): {rel_json}, "
                      f"string in {os.path.basename(rel_txt)}")


class Puller:
    def __init__(self, rundir, api=None, tok=None, fetch=None, say=None, cursor=None, agent_names=(), log=print):
        """fetch(url, token) -> parsed JSON; say(line) posts it in game chat."""
        self.rundir = Path(rundir)
        self.out = self.rundir / "team-tools" / DIR
        self.api, self.tok, self.log = (api or "").rstrip("/"), tok, log
        self.fetch = fetch or self.http
        self.say = say
        self.cursor = Path(cursor) if cursor else self.rundir.parent / "viewer-blueprints.json"
        self.agent_names = list(agent_names)

    @staticmethod
    def http(url, tok):
        req = urllib.request.Request(url, headers={"Authorization": "Bearer " + tok, "User-Agent": "pog-viewer-blueprints"})
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())

    def after(self):
        try:
            return int(json.loads(self.cursor.read_text()).get("after") or 0)
        except (OSError, ValueError, AttributeError):
            return 0

    def set_after(self, n):
        tmp = self.cursor.with_suffix(".tmp")
        tmp.write_text(json.dumps({"after": n}))
        os.replace(tmp, self.cursor)

    def pull(self):
        """New blueprints -> files; returns the metas written."""
        done = []
        after = self.after()
        while True:
            res = self.fetch(f"{self.api}/v1/blueprints?after={after}", self.tok)
            rows = res.get("blueprints") or []
            for row in rows:
                one = self.fetch(f"{self.api}/v1/blueprints/{int(row['id'])}", self.tok).get("blueprint") or {}
                meta = self.save(one) if one else None
                if meta:
                    done.append(meta)
                after = max(after, int(row["id"]))
                self.set_after(after)
            if len(rows) < 20:
                return done

    def save(self, b):
        try:
            j = decode(b.get("string"))
        except ValueError as e:
            self.log(f"[viewer-blueprints] #{b.get('id')} skipped: {e}")
            return None
        self.out.mkdir(parents=True, exist_ok=True)
        stem = f"{int(b['id'])}-{slug(b.get('title'))}"
        (self.out / f"{stem}.txt").write_text(re.sub(r"\s+", "", b["string"]) + "\n")
        meta = {"id": int(b["id"]), "name": b.get("name"), "title": b.get("title"),
                "time": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(float(b.get("t") or time.time()))),
                "t": b.get("t"), "kind": b.get("kind"), "label": b.get("label"), "blueprints": b.get("blueprints"),
                "entities": b.get("entities"), "string_file": f"{stem}.txt", "source": "site (a viewer pasted it)",
                "posted": None, "blueprint": j}
        (self.out / f"{stem}.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1))
        self.log(f"[viewer-blueprints] #{meta['id']} from {meta['name']}: {meta['title']} -> {stem}.json")
        return meta

    def post_pending(self, now=None):
        """One fact line per saved blueprint not posted yet, while the relay switch is on."""
        if not self.say or not (self.rundir / SWITCH).exists() or not self.out.is_dir():
            return []
        posted = []
        for p in sorted(self.out.glob("*.json"), key=lambda p: int(p.name.split("-", 1)[0]) if p.name[0].isdigit() else 0):
            try:
                meta = json.loads(p.read_text())
            except (OSError, ValueError):
                continue
            if meta.get("posted") or "id" not in meta:
                continue
            rel = f"team-tools/{DIR}/{p.name}"
            line = fact_line(meta, rel, meta.get("string_file") or "", self.agent_names)
            self.say(line)
            meta["posted"] = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now or time.time()))
            p.write_text(json.dumps(meta, ensure_ascii=False, indent=1))
            posted.append(line)
            self.log(f"[viewer-blueprints] posted: {line}")
        return posted


def agent_names(rundir):
    """The run's agents and their chosen names (stream.json), so a viewer name posing as one gets " (viewer)"."""
    try:
        run = json.loads((Path(rundir) / "stream.json").read_text())
        return [n for k, c in (run.get("agents") or {}).items() for n in (k, (c or {}).get("display_name")) if n]
    except (OSError, ValueError):
        return []


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("rundir")
    ap.add_argument("--world", default="n", help="the world whose game chat gets the fact line (RCON)")
    ap.add_argument("--every", type=float, default=60.0)
    ap.add_argument("--once", action="store_true")
    a = ap.parse_args()
    from harness import Harness
    h = Harness(a.world)

    def say(line):
        if line.startswith("/"):  # never a command: plain text is a server chat line
            line = " " + line
        h.command(line)
    p = Puller(a.rundir, api_url(), token(), say=say, agent_names=agent_names(a.rundir))
    while True:
        try:
            p.pull()
            p.post_pending()
        except (OSError, ValueError, urllib.error.URLError) as e:
            print(f"[viewer-blueprints] {type(e).__name__}: {e}", flush=True)
        if a.once:
            return
        time.sleep(a.every)


if __name__ == "__main__":
    main()
