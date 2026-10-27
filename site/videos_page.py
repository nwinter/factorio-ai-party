#!/usr/bin/env python3
"""/videos/: every shift with its video (batch265, Nick d27 07:05: the archive goes public).

  python3 site/videos_page.py refresh [--receipts DIR] [--runs-dir DIR]   # site-refresh.sh runs it before the build

refresh writes two things the build reads (both git-ignored, made again each time):
- site/content/r2.json: each shift whose R2 web rendition is complete (a receipt from tools/archive/r2_shifts.py in
  ~/code/pog-operator/r2-receipts/RUN.json) and whose master playlist answers HTTP 200 at the public r2.dev URL now:
  {run: {shift, player, master, duration_s, checked}}. A shift that fails the check is left out.
- site/og/thumbs/shift-N.jpg: the YouTube thumbnail (runs/RUN/video/thumb.png, tools/shift_video.py: the shift's
  title over a frame of the stream) at 480x270, made when missing or older than the PNG. Needs Pillow or macOS sips;
  without either there are no thumbnails.

The pages (build.py calls them; batch270): build_page, /videos/: the three public videos first (shift 1, shift 63's
Space Age victory, the latest), the run's firsts as moments to watch (a minute before each, in this site's player when
R2 has the shift, else on YouTube), then every shift as a card, newest day first: its picture with a play button, its
headline, its firsts and numbers with the game's icons (site/gameicons.py; Graphics copyright Wube Software), its
chapters, Watch, YouTube and the shift's page. build_watch, /videos/shift-N/: the player (static/player.js) for a shift
on R2, else its YouTube video; previous and next shift. home_strip: the homepage's latest four. YouTube's video data
comes from site/content/videos.json (tools/yt_archive.py writes the videos YouTube shows: unlisted or public).
"""
import argparse
import datetime
import json
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from zoneinfo import ZoneInfo

import gameicons

SITE = Path(__file__).resolve().parent
R2_JSON = SITE / "content" / "r2.json"
THUMBS = SITE / "og" / "thumbs"
RECEIPTS = Path.home() / "code" / "pog-operator" / "r2-receipts"
PUBLIC = "https://pub-107dd9c2d81e4ef687f434b9c598414b.r2.dev"
UA = "pog-archive-check/1 (site/videos_page.py)"  # r2.dev refuses urllib's default agent
FEATURED = {1: "The first shift", 63: "The Space Age victory"}
MOMENT_KINDS = ("space", "science")
PACIFIC = ZoneInfo("America/Los_Angeles")


# ---------------------------------------------------------------- refresh

def master_url(run):
    return f"{PUBLIC}/{run}/full/master.m3u8"


def player_url(run):
    return (f"{PUBLIC}/player/index.html?src=../{run}/full/master.m3u8&data=../{run}/full/shift.json"
            f"&vtt=../{run}/full/captions.vtt")


def http_status(url, timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            r.read(4096)
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except (urllib.error.URLError, TimeoutError, OSError):
        return None


def r2_rows(receipts, check=http_status, now=None):
    """{run: row} for each receipt whose master playlist answers 200."""
    recs = []
    for p in sorted(Path(receipts).glob("shift*.json")):
        try:
            r = json.loads(p.read_text())
        except (OSError, ValueError):
            continue
        run = r.get("run") or p.stem
        if r.get("prefix", f"{run}/full/") == f"{run}/full/":
            recs.append((run, r))
    with ThreadPoolExecutor(8) as ex:
        codes = list(ex.map(lambda x: check(master_url(x[0])), recs))
    stamp = (now or datetime.datetime.now()).isoformat(timespec="seconds")
    out = {}
    for (run, r), code in zip(recs, codes):
        if code == 200:
            out[run] = {"shift": int(run[5:]), "player": player_url(run), "master": master_url(run),
                        "duration_s": r.get("duration_s"), "checked": stamp}
    return out, {run: code for (run, _), code in zip(recs, codes) if code != 200}


def make_thumbs(runs_dir, out_dir=THUMBS):
    """runs/RUN/video/thumb.png -> out_dir/shift-N.jpg (480x270); returns how many were made."""
    out_dir = Path(out_dir)
    made = 0
    for png in sorted(Path(runs_dir).glob("shift[0-9]*/video/thumb.png")):
        n = int(png.parent.parent.name[5:])
        jpg = out_dir / f"shift-{n}.jpg"
        if jpg.exists() and jpg.stat().st_mtime >= png.stat().st_mtime:
            continue
        out_dir.mkdir(parents=True, exist_ok=True)
        if to_jpeg(png, jpg):
            made += 1
    return made


def to_jpeg(src, dst, size=(480, 270)):
    try:
        from PIL import Image
        Image.open(src).convert("RGB").resize(size, Image.LANCZOS).save(dst, "JPEG", quality=80, optimize=True)
        return True
    except ImportError:
        pass
    except OSError:
        return False
    if shutil.which("sips"):
        r = subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "80", "-z", str(size[1]), str(size[0]),
                            str(src), "--out", str(dst)], capture_output=True)
        return r.returncode == 0
    return False


# ---------------------------------------------------------------- the page

def hm(seconds):
    if not seconds:
        return "–"
    m = int(round(seconds / 60))
    return f"{m // 60}h{m % 60:02d}"


def video_seconds(v):
    """The YouTube video's length: its recordings' wall-clock spans (videos.json `timeline`)."""
    total = 0.0
    for a, b in (v or {}).get("timeline") or []:
        try:
            total += (datetime.datetime.fromisoformat(b) - datetime.datetime.fromisoformat(a)).total_seconds()
        except (TypeError, ValueError):
            return None
    return total or None


def headline(title, n):
    """The video title's part after "Shift N: "."""
    head = f"Shift {n}: "
    i = (title or "").find(head)
    return title[i + len(head):] if i >= 0 else ""


def public_shifts(videos):
    """The shifts the YouTube rule makes public (tools/yt_archive.py): 1, 63 and the latest with a video."""
    have = {v["shift"] for v in videos.values()}
    return sorted(({1, 63} & have) | ({max(have)} if have else set()))


def watch_url(v, t=None):
    url = f"https://www.youtube.com/watch?v={v['id']}"
    if v.get("playlist"):
        url += f"&list={v['playlist']}"
    return url + (f"&t={int(t)}s" if t else "")


def epoch(t):
    """A local (Pacific) ISO time from the score logs as Unix seconds, or None."""
    try:
        x = datetime.datetime.fromisoformat(t)
    except (TypeError, ValueError):
        return None
    if x.tzinfo is None:
        x = x.replace(tzinfo=PACIFIC)
    return x.timestamp()


def chapter_wall(v, at):
    """The wall time (Unix seconds) of a moment `at` seconds into the YouTube video, through its recordings' spans
    (videos.json `timeline`, in video order), or None."""
    done = 0.0
    for a, b in (v or {}).get("timeline") or []:
        ea, eb = epoch(a), epoch(b)
        if ea is None or eb is None:
            return None
        if at <= done + (eb - ea):
            return ea + (at - done)
        done += eb - ea
    return None


first_icon = gameicons.first_icon


def watch_href(n):
    return f"/videos/shift-{n}/"


class Shelf:
    """What /videos/ and the player pages know about each shift: the long run, YouTube, R2, thumbnails."""

    def __init__(self, lr, videos, r2, thumbs, h):
        self.lr, self.h, self.thumbs = lr, h, thumbs
        self.done = [s for s in lr["shifts"] if not s.get("empty")]
        self.by_n = {s["n"]: s for s in self.done}
        self.vid = {int(v["shift"]): v for v in videos.values()}
        self.r2 = {x["shift"]: dict(x, master=x.get("master") or master_url(run)) for run, x in r2.items()}
        self.playlist = next((v["playlist"] for v in videos.values() if v.get("playlist")), None)
        self.pub = public_shifts({k: dict(v, shift=int(v["shift"])) for k, v in videos.items()})
        self.latest = max(self.vid) if self.vid else None
        self.firsts = {}
        for f in lr["firsts"]:
            self.firsts.setdefault(f["shift"], []).append(f)
        # the shifts with a page of their own here (a video to play: R2 or YouTube), in order
        self.watchable = [s["n"] for s in self.done if s["n"] in self.r2 or s["n"] in self.vid]

    def title(self, n):
        v = self.vid.get(n)
        t = headline(self.h["clean"](v.get("title", "")), n) if v else ""
        if not self.h["keep_line"](t):  # a title naming an account or tool: the shift's firsts instead
            t = ""
        if not t:
            t = "; ".join([f["label"] for f in self.firsts.get(n, []) if f["kind"] in MOMENT_KINDS][:2])
        if not t:
            s = self.by_n.get(n) or {}
            t = "; ".join(str(m) for m in (s.get("moments") or [])[:1])
        return t

    def seconds(self, n):
        s = self.by_n.get(n)
        secs = video_seconds(self.vid.get(n)) or (self.r2.get(n) or {}).get("duration_s")
        if not secs and s:
            secs = self.h["hours"](s["started"], s["ended"]) * 3600
        return secs

    def thumb(self, n, cls="v-img", eager=False):
        if n not in self.thumbs:
            return f'<span class="{cls} thumb-text" aria-hidden="true">Shift {n}</span>'
        return (f'<img class="{cls}" src="/static/thumbs/shift-{n}.jpg" width="480" height="270" '
                f'{"" if eager else "loading=lazy "}alt="">')

    def href(self, n):
        """Where a shift's play button goes: its player page, else its page in the run."""
        return watch_href(n) if n in self.watchable else self.h["shift_href"](self.by_n[n])

    def chapters(self, n):
        v = self.vid.get(n)
        return [c for c in (v or {}).get("chapters") or [] if self.h["keep_line"](c.get("title", ""))]

    def neighbours(self, n):
        i = self.watchable.index(n)
        return (self.watchable[i - 1] if i else None,
                self.watchable[i + 1] if i + 1 < len(self.watchable) else None)


def firsts_html(fs, esc, limit=4, cls="v-firsts"):
    if not fs:
        return ""
    keep = [f for f in fs if f["kind"] in ("space", "science")] + [f for f in fs if f["kind"] not in ("space", "science")]
    items = "".join(f'<li title="{esc(f["label"])}">{first_icon(f, 22)}<span>{esc(f["label"])}</span></li>' for f in keep[:limit])
    more = f'<li class="v-more muted">+{len(keep) - limit} more</li>' if len(keep) > limit else ""
    return f'<ul class="{cls}">{items}{more}</ul>'


def nums_html(s, esc):
    """A shift's numbers with the game's icons: technologies, rockets, science per minute, platforms, deaths."""
    bits = []
    if s.get("research_new"):
        bits.append(f'{gameicons.item("lab", 18)}<b>+{s["research_new"]}</b> tech')
    if s.get("rockets_new"):
        bits.append(f'{gameicons.item("rocket-part", 18)}<b>+{s["rockets_new"]:,}</b> rockets')
    if s.get("spm"):
        bits.append(f'{gameicons.item("automation-science-pack", 18)}<b>{s["spm"]:,.0f}</b> SPM')
    for p in (s.get("platforms_built") or [])[:2]:
        bits.append(f'{gameicons.item("space-platform-hub", 18)}{esc(p)} built')
    if s.get("platforms_lost"):
        bits.append(f'<span class="v-bad">{len(s["platforms_lost"])} platform{"s" if len(s["platforms_lost"]) > 1 else ""} lost</span>')
    if s.get("deaths"):
        bits.append(f'<span class="v-bad">{s["deaths"]} death{"s" if s["deaths"] > 1 else ""}</span>')
    return f'<p class="v-nums">{"".join(f"<span>{b}</span>" for b in bits)}</p>' if bits else ""


def build_page(lr, videos, r2, thumbs, h):
    """/videos/: the body. h: build.py's helpers (esc, clean, keep_line, pt, hours, shift_href, video_offset,
    game_time, live_banner)."""
    esc = h["esc"]
    sh = Shelf(lr, videos, r2, thumbs, h)

    def play(n, size=""):
        secs = sh.seconds(n)
        if n not in sh.watchable:  # no video yet: the picture goes to the shift's page, without a play button
            return f'<a class="v-thumb{size}" href="{sh.href(n)}" tabindex="-1" aria-hidden="true">{sh.thumb(n)}</a>'
        return (f'<a class="v-thumb{size}" href="{sh.href(n)}" aria-label="Play shift {n}">{sh.thumb(n)}'
                f'<span class="v-play" aria-hidden="true"></span>'
                f'{f"""<span class="v-len">{esc(hm(secs))}</span>""" if secs else ""}</a>')

    def actions(n):
        out = []
        if n in sh.watchable:
            out.append(f'<a class="fx-btn small v-watch" href="{watch_href(n)}">▶ Watch</a>')
        v = sh.vid.get(n)
        if v:
            out.append(f'<a class="fx-btn small ghost" href="{esc(watch_url(v))}" rel="noopener">YouTube</a>')
        out.append(f'<a class="small" href="{h["shift_href"](sh.by_n[n])}">Shift page</a>')
        if n not in sh.watchable:
            out.insert(0, '<span class="muted small">The video comes after the shift is uploaded.</span>')
        return " ".join(out)

    # the three public ones
    cards = []
    for n in sh.pub:
        s = sh.by_n.get(n)
        if not s:
            continue
        label = FEATURED.get(n, "The latest shift" if n == sh.latest else "")
        cards.append(f'<article class="v-feature">{play(n, " v-thumb-lg")}<div class="v-fbody"><p class="eyebrow">{esc(label)}</p>'
                     f'<h3><a href="{sh.href(n)}">Shift {n}</a></h3><p class="v-title">{esc(sh.title(n))}</p>'
                     f'<p class="muted small">{esc(h["pt"](s["started"]))} Pacific · {esc(hm(sh.seconds(n)))}</p>'
                     f'{firsts_html(sh.firsts.get(n), esc, 3)}<p class="v-links">{actions(n)}</p></div></article>')
    featured = f'<section aria-labelledby="start"><h2 id="start">Start here</h2><div class="v-features">{"".join(cards)}</div></section>' if cards else ""

    # moments: the run's big firsts, each a minute before the moment in the shift's player (R2), else on YouTube
    moments = []
    for f in lr["firsts"]:
        if f["kind"] not in MOMENT_KINDS:
            continue
        n = f["shift"]
        at = epoch(f["t"])
        if n in sh.r2 and at:
            url = f'{watch_href(n)}?at={int(at - 60)}'
        else:
            v = sh.vid.get(n)
            off = h["video_offset"](v, f["t"]) if v else None
            if off is None:
                continue
            url = watch_url(v, max(0, off - 60))
        moments.append(f'<li><a href="{esc(url)}">{first_icon(f, 32)}<span class="v-m-label">{esc(f["label"])}</span>'
                       f'<span class="muted small">Shift {n} · game time {esc(h["game_time"](f["tick"]))}</span></a></li>')
    moments_html = (f'<section aria-labelledby="moments"><h2 id="moments">Moments to watch</h2><p class="muted small">The run\'s '
                    f'firsts: planets, platforms, science and the edge. Each starts a minute before the moment.</p>'
                    f'<ol class="v-moments{" v-clip" if len(moments) > 12 else ""}" id="v-moments">{"".join(moments)}</ol>'
                    + (f'<p><button type="button" class="fx-btn small ghost" id="v-more" aria-controls="v-moments" '
                       f'aria-expanded="false">Show all {len(moments)} moments</button></p>' if len(moments) > 12 else "")
                    + '</section>') if moments else ""

    # every shift, newest day first, as cards
    days = {}
    for s in sh.done:
        days.setdefault(s["started"][:10], []).append(s)
    groups = []
    for day in sorted(days, reverse=True):
        rows = []
        for s in sorted(days[day], key=lambda x: -x["n"]):
            n = s["n"]
            ch = sh.chapters(n)
            chapters = ""
            if ch:
                v = sh.vid[n]
                items = "".join(f'<li><a href="{esc(watch_href(n) + "?at=" + str(int(w)) if n in sh.r2 and (w := chapter_wall(v, c["at"])) else watch_url(v, c["at"]))}">'
                                f'{esc(c["time"])}</a> {esc(h["clean"](c["title"]))}</li>' for c in ch)
                chapters = f'<details class="v-chapters"><summary>{len(ch)} chapters</summary><ol>{items}</ol></details>'
            text = " ".join([f"shift {n}", sh.title(n)] + [f["label"] for f in sh.firsts.get(n, [])]
                            + (s.get("platforms_built") or []) + (s.get("planets") or [])[-1:]).lower()
            rows.append(f'<li class="v-card" id="shift-{n}" data-n="{n}" data-text="{esc(text)}">{play(n)}<div class="v-body">'
                        f'<h3><a href="{sh.href(n)}">Shift {n}</a>{" <span class=fx-chip>public</span>" if n in sh.pub else ""}'
                        f'<span class="v-when muted small">{esc(h["pt"](s["started"], day=False))} Pacific</span></h3>'
                        f'<p class="v-title">{esc(sh.title(n))}</p>{firsts_html(sh.firsts.get(n), esc)}{nums_html(s, esc)}'
                        f'<p class="muted small">Game time {esc(s["game0"])} to {esc(s["game1"])}</p>{chapters}'
                        f'<p class="v-links">{actions(n)}</p></div></li>')
        label = datetime.date.fromisoformat(day).strftime("%A, %B %-d")
        groups.append(f'<section class="v-day" data-day="{day}"><h3 class="v-dayh">{label} <span class="muted small">'
                      f'{len(rows)} shift{"s" if len(rows) > 1 else ""}</span></h3><ol class="v-grid">{"".join(rows)}</ol></section>')
    on_yt = sum(1 for s in sh.done if s["n"] in sh.vid)
    on_r2 = sum(1 for s in sh.done if s["n"] in sh.r2)
    pl = (f' <a href="https://www.youtube.com/playlist?list={esc(sh.playlist)}">The playlist on YouTube</a> has them '
          f'in order.') if sh.playlist else ""
    hours = sum(h["hours"](s["started"], s["ended"]) for s in sh.done)
    jump = "".join(x for x in ('<a href="#start">Start here</a>' if cards else "",
                               '<a href="#moments">Moments to watch</a>' if moments else "", '<a href="#all">All shifts</a>'))
    body = f"""
{h["live_banner"]()}
<h1>Every shift on video</h1>
<p class="lede">The whole run, shift by shift: {len(sh.done)} shifts, {hours:.0f} hours on stream. {on_r2} play here with their
timeline of events, the factory's numbers and the chat beside the video; {on_yt} are on YouTube.{pl}</p>
<nav class="jump" aria-label="On this page">{jump}</nav>
{featured}
{moments_html}
<section aria-labelledby="all"><h2 id="all">All shifts</h2>
<div class="v-tools"><label class="v-find">Find <input type="search" id="v-find" placeholder="a planet, a platform, a pack, a shift number"></label>
<button type="button" class="fx-btn small" id="v-order" aria-pressed="false">Oldest first</button>
<span class="muted small" id="v-count" aria-live="polite"></span></div>
<div id="v-all">{"".join(groups)}</div>
<p class="muted small">Times are Pacific. Length: the video's, else the shift's time on stream. Chapters come from the
shift's own record: milestones, losses, deaths and viewers' questions.</p></section>
<script>
(function () {{
  var all = document.getElementById('v-all'), find = document.getElementById('v-find'), order = document.getElementById('v-order'), count = document.getElementById('v-count');
  if (!all) return;
  var cards = Array.prototype.slice.call(all.querySelectorAll('.v-card'));
  function apply() {{
    var q = find.value.trim().toLowerCase(), shown = 0;
    cards.forEach(function (li) {{
      li.hidden = !!q && li.dataset.text.indexOf(q) < 0 && li.dataset.n !== q;
      if (!li.hidden) shown++;
    }});
    all.querySelectorAll('.v-day').forEach(function (d) {{ d.hidden = !d.querySelector('.v-card:not([hidden])'); }});
    count.textContent = q ? shown + ' of ' + cards.length + ' shifts' : '';
  }}
  find.addEventListener('input', apply);
  var more = document.getElementById('v-more');
  if (more) more.addEventListener('click', function () {{
    var m = document.getElementById('v-moments'), open = m.classList.toggle('v-clip');
    more.setAttribute('aria-expanded', open ? 'false' : 'true');
    more.textContent = open ? more.textContent.replace('Show fewer', 'Show all') : 'Show fewer moments';
  }});
  order.addEventListener('click', function () {{
    Array.prototype.slice.call(all.children).reverse().forEach(function (d) {{
      all.appendChild(d);
      var ol = d.querySelector('.v-grid');
      Array.prototype.slice.call(ol.children).reverse().forEach(function (li) {{ ol.appendChild(li); }});
    }});
    var oldest = order.getAttribute('aria-pressed') !== 'true';
    order.setAttribute('aria-pressed', oldest ? 'true' : 'false');
    order.textContent = oldest ? 'Newest first' : 'Oldest first';
  }});
}})();
</script>
"""
    return body


def home_strip(lr, videos, r2, thumbs, h, k=4):
    """The homepage's way into /videos/ (Nick d27 10:10: easy to find again): the latest k shifts with a video, each
    a picture with a play button, and a link to every shift. "" without any."""
    esc = h["esc"]
    sh = Shelf(lr, videos, r2, thumbs, h)
    latest = sh.watchable[-k:][::-1]
    if not latest:
        return ""
    cards = "".join(f'<li><a class="v-thumb" href="{watch_href(n)}" aria-label="Play shift {n}">{sh.thumb(n)}'
                    f'<span class="v-play" aria-hidden="true"></span><span class="v-len">{esc(hm(sh.seconds(n)))}</span></a>'
                    f'<a class="hv-title" href="{watch_href(n)}"><b>Shift {n}</b> {esc(sh.title(n))}</a></li>' for n in latest)
    return (f'<section class="home-videos" aria-labelledby="hv-h"><div class="hv-head"><h2 id="hv-h">Watch the shifts</h2>'
            f'<a class="fx-btn small" href="/videos/">All {len(sh.watchable)} shifts on video →</a></div>'
            f'<ol class="hv-list">{cards}</ol></section>\n')


def build_watch(n, lr, videos, r2, thumbs, h, timeline=(), embed=None):
    """/videos/shift-N/: the shift's video with the site's header. With R2: the player (static/player.js) with its
    timeline lanes, the factory's numbers and the chat beside it; else the YouTube video. Previous and next shift, back
    to the list. timeline: the shift's rows of the run's /timeline/ [(tick, kind, text, anchor index, agent)].
    embed: build.py's video_embed. Returns (body, extra head)."""
    esc = h["esc"]
    sh = Shelf(lr, videos, r2, thumbs, h)
    s = sh.by_n[n]
    prev, nxt = sh.neighbours(n)
    v, x = sh.vid.get(n), sh.r2.get(n)
    secs = sh.seconds(n)
    pn = "".join([f'<a class="fx-btn small ghost" rel="prev" href="{watch_href(prev)}">‹ Shift {prev}</a>' if prev else "",
                  f'<a class="fx-btn small ghost" rel="next" href="{watch_href(nxt)}">Shift {nxt} ›</a>' if nxt else ""])
    meta = " · ".join(b for b in (f'{esc(h["pt"](s["started"]))} Pacific', esc(hm(secs)),
                                  f'game time {esc(s["game0"])} to {esc(s["game1"])}',
                                  f'<a href="{h["shift_href"](s)}">The shift\'s page</a>',
                                  f'<a href="{esc(watch_url(v))}" rel="noopener">On YouTube</a>' if v else "") if b)
    top = (f'<div class="pl-top"><a class="pl-back" href="/videos/#shift-{n}">← All videos</a><nav class="pl-pn" '
           f'aria-label="Other shifts">{pn}</nav></div>'
           f'<h1 class="pl-h1">Shift {n}<span class="pl-sub">{esc(sh.title(n))}</span></h1><p class="pl-meta muted">{meta}</p>')
    rows = [[t, kind, text, a, who] for t, kind, text, a, who in timeline]
    fhtml = firsts_html(sh.firsts.get(n), esc, 12, "v-firsts pl-firsts")
    ch = sh.chapters(n)
    if x:
        planets = [["nauvis", 0]] + [[f["key"].split(":", 1)[1], f["tick"]] for f in lr["firsts"] if f["key"].startswith("planet:")]
        cfg = {"shift": n, "src": x["master"], "data": x["master"].replace("master.m3u8", "shift.json"),
               "vtt": x["master"].replace("master.m3u8", "captions.vtt"), "timeline": rows, "planets": planets}
        chapters = ""
        if ch:
            items = "".join(f'<li><a href="{esc(watch_href(n))}?at={int(w)}" data-at="{int(w)}">{esc(c["time"])}</a> '
                            f'{esc(h["clean"](c["title"]))}</li>' for c in ch if (w := chapter_wall(v, c["at"])))
            chapters = (f'<section class="pl-chapters"><h2>Chapters</h2><p class="muted small">From the shift\'s record: '
                        f'milestones, losses, deaths and viewers\' questions.</p><ol>{items}</ol></section>')
        nxt_btn = f'<a class="pl-endnext fx-btn" href="{watch_href(nxt)}">Next: Shift {nxt} ›</a>' if nxt else ""
        body = f"""{top}
<div class="pl-layout">
  <section class="pl-stage" aria-label="Video">
    <div class="pl-box">
      <video id="pl-video" controls playsinline preload="metadata" crossorigin="anonymous"{f' poster="/static/thumbs/shift-{n}.jpg"' if n in thumbs else ""}></video>
      <button id="pl-big" class="pl-big" type="button"><span class="pl-big-tri" aria-hidden="true"></span><span class="pl-big-txt">Play shift {n}<small>{esc(hm(secs))}</small></span></button>
      {nxt_btn}
    </div>
    <div class="pl-bar">
      <span class="pl-btns"><button type="button" class="fx-btn small" id="pl-prev" title="Previous event (k)">◀ Previous event</button><button type="button" class="fx-btn small" id="pl-next" title="Next event (j)">Next event ▶</button><button type="button" class="fx-btn small ghost" id="pl-cc" aria-pressed="false" title="Captions (the hosts' lines are in the picture too)">CC</button></span>
      <span class="pl-clock muted small" id="pl-clock">–</span>
    </div>
    <p class="muted small" id="pl-status" role="status"></p>
    <div class="pl-scrub">
      <p class="muted small" id="pl-span"></p>
      <div class="pl-lanes" id="pl-lanes"></div>
      <p class="pl-legend muted small"><span style="--c: var(--bad)">danger</span><span style="--c: var(--good)">progress</span><span style="--c: var(--s1)">viewer chat</span><span style="--c: var(--muted)">camera shots</span> · click a lane to jump there</p>
    </div>
  </section>
  <aside class="pl-side" aria-label="Beside the video">
    <div class="pl-card"><h2>On air</h2><div class="pl-onair" id="pl-onair">–</div><div class="muted small" id="pl-onair-why"></div></div>
    <div class="pl-card"><h2>Speaking</h2><div class="pl-speak" id="pl-speak">–</div></div>
    <div class="pl-card"><h2>The factory</h2><div class="pl-stats" id="pl-stats"></div><p class="muted small" id="pl-asof"></p></div>
    <div class="pl-card" id="pl-events-card"><h2>This shift on the timeline <span class="muted" id="pl-events-n"></span></h2><ol class="pl-events" id="pl-events"></ol><p class="small"><a href="/timeline/">The whole run's timeline →</a></p></div>
    <div class="pl-card"><h2>Chat</h2><ul class="pl-chat" id="pl-chat"></ul></div>
  </aside>
</div>
{f'<section class="pl-below"><h2>The shift\'s firsts</h2>{fhtml}</section>' if fhtml else ""}
{chapters}
<div class="pl-tip" id="pl-tip" hidden></div>
<script type="application/json" id="pl-data">{json.dumps(cfg, separators=(",", ":")).replace("</", "<\\/")}</script>
"""
        head = ('<script src="https://cdnjs.cloudflare.com/ajax/libs/hls.js/1.5.13/hls.min.js" defer></script>\n'
                '<script src="/static/player.js" defer></script>')
        return body, head
    # YouTube only: its video, chapters and the shift's events
    items = "".join(f'<li><a href="{esc(watch_url(v, c["at"]))}" rel="noopener">{esc(c["time"])}</a> {esc(h["clean"](c["title"]))}</li>'
                    for c in ch)
    evs = "".join(f'<li>{gameicons.item("rocket-part", 20) if kind == "rocket" else gameicons.tech(text, 20) if kind == "research" else gameicons.item("space-platform-hub", 20) if kind == "platform" else gameicons.place(text.split(" ")[-1], 20) if kind == "planet" else ""}'
                  f'<a href="/timeline/#e{a}">{esc(text)}</a> <span class="muted small">{esc(h["game_time"](t))}</span></li>'
                  for t, kind, text, a, _ in timeline[:60])
    body = f"""{top}
<div class="pl-layout">
  <section class="pl-stage" aria-label="Video">{embed(v) if embed else ""}
    <p class="muted small">This shift plays on YouTube; the player with its timeline beside the video comes when the
    shift is encoded for this site.</p>
    {fhtml}
    {f'<section class="pl-chapters"><h2>Chapters</h2><ol>{items}</ol></section>' if items else ""}
  </section>
  <aside class="pl-side" aria-label="Beside the video">
    <div class="pl-card"><h2>The factory</h2>{nums_html(s, esc)}</div>
    {f'<div class="pl-card"><h2>This shift on the timeline <span class="muted">{len(timeline)}</span></h2><ol class="pl-events pl-events-static">{evs}</ol><p class="small"><a href="/timeline/">The whole run&#x27;s timeline →</a></p></div>' if evs else ""}
  </aside>
</div>
"""
    return body, ""


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["refresh"])
    ap.add_argument("--receipts", default=str(RECEIPTS))
    ap.add_argument("--runs-dir", default=str(SITE.parent / "runs"))
    ap.add_argument("--out", default=str(R2_JSON))
    ap.add_argument("--thumbs", default=str(THUMBS))
    a = ap.parse_args(argv)
    rows, bad = r2_rows(a.receipts)
    Path(a.out).write_text(json.dumps(rows, indent=1) + "\n")
    made = make_thumbs(a.runs_dir, a.thumbs)
    print(f"r2.json: {len(rows)} shifts play on R2" + (f"; left out (HTTP status): {bad}" if bad else "")
          + f"; {made} thumbnails made")
    return 0


if __name__ == "__main__":
    sys.exit(main())
