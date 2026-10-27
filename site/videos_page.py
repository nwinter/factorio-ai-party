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

The page (build.py calls build_page): the three public videos first (shift 1, shift 63's Space Age victory, the
latest), moments to watch (the run's firsts with a link to the moment on YouTube), then every shift in order: title,
date, length, YouTube (in the playlist), the archive player on R2 when it has the shift, its chapters as links into
the video. YouTube's video data comes from site/content/videos.json (tools/yt_archive.py writes the videos YouTube
shows: unlisted or public). Text labels only; the thumbnails are the project's own title cards.
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

SITE = Path(__file__).resolve().parent
R2_JSON = SITE / "content" / "r2.json"
THUMBS = SITE / "og" / "thumbs"
RECEIPTS = Path.home() / "code" / "pog-operator" / "r2-receipts"
PUBLIC = "https://pub-107dd9c2d81e4ef687f434b9c598414b.r2.dev"
UA = "pog-archive-check/1 (site/videos_page.py)"  # r2.dev refuses urllib's default agent
FEATURED = {1: "The first shift", 63: "The Space Age victory"}
MOMENT_KINDS = ("space", "science")


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


def build_page(lr, videos, r2, thumbs, h):
    """The page body and its extra head. h: build.py's helpers (esc, clean, keep_line, pt, hours, shift_href,
    video_offset, game_time, live_banner)."""
    esc = h["esc"]
    done = [s for s in lr["shifts"] if not s.get("empty")]
    by_n = {s["n"]: s for s in done}
    vid_of = {v["shift"]: v for v in videos.values()}
    r2_of = {x["shift"]: x for x in r2.values()}
    playlist = next((v["playlist"] for v in videos.values() if v.get("playlist")), None)
    pub = public_shifts(videos)
    latest = max(vid_of) if vid_of else None

    def title_of(n):
        v = vid_of.get(n)
        t = headline(h["clean"](v.get("title", "")), n) if v else ""
        if not h["keep_line"](t):  # a title naming the stream owner: the shift's firsts instead
            t = ""
        if not t:
            firsts = [f["label"] for f in lr["firsts"] if f["shift"] == n and f["kind"] in MOMENT_KINDS]
            t = "; ".join(firsts[:2])
        return t

    def length_of(n):
        s = by_n.get(n)
        secs = video_seconds(vid_of.get(n)) or (r2_of.get(n) or {}).get("duration_s")
        if not secs and s:
            secs = h["hours"](s["started"], s["ended"]) * 3600
        return hm(secs)

    def thumb(n, cls="thumb"):
        if n not in thumbs:
            return f'<span class="{cls} thumb-text" aria-hidden="true">Shift {n}</span>'
        return (f'<img class="{cls}" src="/static/thumbs/shift-{n}.jpg" width="480" height="270" loading="lazy" '
                f'alt="Shift {n} title card">')

    def links(n):
        out = []
        v = vid_of.get(n)
        if v:
            out.append(f'<a class="fx-btn small" href="{esc(watch_url(v))}">YouTube</a>')
        x = r2_of.get(n)
        if x:
            out.append(f'<a class="fx-btn small ghost" href="{esc(x["player"])}" title="The shift with its timeline of '
                       f'events, captions and chat">Archive player</a>')
        if not v and not x:
            out.append('<span class="muted small">Video after the shift is uploaded</span>')
        return " ".join(out)

    def chapters(n):
        v = vid_of.get(n)
        rows = [c for c in (v or {}).get("chapters") or [] if h["keep_line"](c.get("title", ""))]
        if not rows:
            return ""
        items = "".join(f'<li><a href="{esc(watch_url(v, c["at"]))}">{esc(c["time"])}</a> {esc(h["clean"](c["title"]))}</li>'
                        for c in rows)
        return f'<details class="v-chapters"><summary>{len(rows)} chapters</summary><ol>{items}</ol></details>'

    # the three public ones
    cards = []
    for n in pub:
        s = by_n.get(n)
        label = FEATURED.get(n, "The latest shift" if n == latest else "")
        cards.append(f'<article class="v-feature"><a class="v-thumb" href="{esc(watch_url(vid_of[n]))}">{thumb(n)}</a>'
                     f'<p class="eyebrow">{esc(label)}</p><h3><a href="{h["shift_href"](s) if s else "#"}">Shift {n}</a></h3>'
                     f'<p>{esc(title_of(n))}</p><p class="muted small">{esc(h["pt"](s["started"]) if s else "")} Pacific · '
                     f'{esc(length_of(n))}</p><p class="v-links">{links(n)}</p></article>')
    featured = f'<h2 id="start">Start here</h2><div class="v-features">{"".join(cards)}</div>' if cards else ""

    # moments: the run's big firsts, each with a link to its moment in the shift's video
    moments = []
    for f in lr["firsts"]:
        if f["kind"] not in MOMENT_KINDS:
            continue
        v = vid_of.get(f["shift"])
        off = h["video_offset"](v, f["t"]) if v else None
        if off is None:
            continue
        moments.append(f'<li><a href="{esc(watch_url(v, max(0, off - 60)))}">{esc(f["label"])}</a>'
                       f'<span class="muted small"> · shift {f["shift"]} · game time {esc(h["game_time"](f["tick"]))}</span></li>')
    moments_html = (f'<h2 id="moments">Moments to watch</h2><p class="muted small">The run\'s firsts: planets, platforms, '
                    f'science and the edge. Each link starts the shift\'s video a minute before.</p>'
                    f'<ol class="v-moments">{"".join(moments)}</ol>') if moments else ""

    rows = []
    for s in done:
        n = s["n"]
        rows.append(f'<li class="v-row" id="shift-{n}" data-n="{n}">'
                    f'<a class="v-thumb" href="{esc(watch_url(vid_of[n])) if n in vid_of else h["shift_href"](s)}" '
                    f'tabindex="-1">{thumb(n)}</a><div class="v-body"><h3><a href="{h["shift_href"](s)}">Shift {n}</a>'
                    f'{" <span class=fx-chip>public</span>" if n in pub else ""}</h3><p class="v-title">{esc(title_of(n))}</p>'
                    f'<p class="muted small">{esc(h["pt"](s["started"]))} Pacific · {esc(length_of(n))} · game time '
                    f'{esc(s["game0"])} to {esc(s["game1"])}</p><p class="v-links">{links(n)}</p>{chapters(n)}</div></li>')
    on_yt, on_r2 = sum(1 for s in done if s["n"] in vid_of), sum(1 for s in done if s["n"] in r2_of)
    pl = (f' <a href="https://www.youtube.com/playlist?list={esc(playlist)}">The playlist on YouTube</a> has them '
          f'in order.') if playlist else ""
    body = f"""
{h["live_banner"]()}
<h1>Every shift on video</h1>
<p class="lede">The whole run, shift by shift: {len(done)} shifts of about four hours each, {on_yt} on YouTube.{pl}
The archive player plays a shift beside its timeline of events, the hosts' captions and the chat ({on_r2} shifts so far;
more as they are encoded).</p>
<nav class="jump" aria-label="On this page"><a href="#start">Start here</a>{'<a href="#moments">Moments to watch</a>' if moments else ""}<a href="#all">All shifts</a></nav>
{featured}
{moments_html}
<h2 id="all">All shifts</h2>
<div class="v-tools"><label>Find <input type="search" id="v-find" placeholder="a planet, a platform, a shift number"></label>
<button type="button" class="fx-btn small" id="v-order" aria-pressed="false">Newest first</button></div>
<ol class="v-list" id="v-list">{"".join(rows)}</ol>
<p class="muted small">Times are Pacific. Length: the video's, else the shift's time on stream. Chapters come from the
shift's own record: milestones, losses, deaths and viewers' questions.</p>
<script>
(function () {{
  var list = document.getElementById('v-list'), find = document.getElementById('v-find'), order = document.getElementById('v-order');
  if (!list) return;
  find.addEventListener('input', function () {{
    var q = find.value.trim().toLowerCase();
    Array.prototype.forEach.call(list.children, function (li) {{
      li.hidden = !!q && li.textContent.toLowerCase().indexOf(q) < 0 && li.dataset.n !== q;
    }});
  }});
  order.addEventListener('click', function () {{
    var rows = Array.prototype.slice.call(list.children).reverse();
    rows.forEach(function (li) {{ list.appendChild(li); }});
    var newest = order.getAttribute('aria-pressed') !== 'true';
    order.setAttribute('aria-pressed', newest ? 'true' : 'false');
    order.textContent = newest ? 'Oldest first' : 'Newest first';
  }});
}})();
</script>
"""
    return body


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
