#!/usr/bin/env python3
"""The social preview images (og:image, 1200x630):

    python3 site/og_card.py [--bg site/og/bg.jpg] [--out site/static/og.png]     # the site's card
    python3 site/og_card.py --shifts [--runs-dir DIR] [--html-only]              # one per shift of the long run

The site's card: the site's title, one line on what it is, and the nine agents' pixel portraits, over a darkened game
frame (site/og/bg.jpg, a camera shot from the run). build.py copies site/static/og.png to /static/og.png; the page head
links it. A shift's card: "Shift N", its times, its numbers and biggest firsts (build.shift_card_facts), into
site/og/shifts/shift-N.png with shift-N.key; only a shift whose facts changed is drawn again (tools/site-refresh.sh runs
it before the build; build.py uses a card only when its key matches). --html-only writes the cards' HTML, no browser.
Rendered with Playwright's headless Chromium shell, like tools/stream/overlay_shot.sh.
"""
import argparse
import base64
import glob
import html
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

SITE = Path(__file__).resolve().parent
REPO = SITE.parent
sys.path.insert(0, str(REPO / "tools" / "stream"))
sys.path.insert(0, str(SITE))
import avatar as avatar_art  # noqa: E402

TEAM = ["astra", "sol", "luna", "opus", "sonnet", "haiku", "grok", "gemini", "muse"]


def card(title, line, agents, bg, extra="", kicker="Streamed live on YouTube"):
    bg_css = ""
    if bg:
        data = base64.b64encode(Path(bg).read_bytes()).decode()
        bg_css = f"background-image: url(data:image/jpeg;base64,{data});"
    faces = "".join(
        f'<figure><div class="face" style="border-color:{html.escape(a.get("color") or "#888")}">'
        f'{avatar_art.svg({"name": k, "display_name": a["name"], "color": a.get("color"), "avatar": a.get("avatar")}, 84)}'
        f'</div><figcaption>{html.escape(a["name"])}</figcaption></figure>'
        for k, a in agents)
    return f"""<!doctype html><html><head><meta charset="utf-8">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Titillium+Web:wght@400;600;700&display=swap">
<style>
html, body {{ margin: 0; width: 1200px; height: 630px; overflow: hidden; background: #141414; }}
.card {{ position: relative; width: 1200px; height: 630px; {bg_css} background-size: cover; background-position: center;
  font-family: 'Titillium Web', 'Segoe UI', sans-serif; color: #f2efe8; }}
.card::before {{ content: ""; position: absolute; inset: 0;
  background: linear-gradient(100deg, rgba(14,15,18,.97) 0%, rgba(14,15,18,.9) 48%, rgba(14,15,18,.55) 100%); }}
.inner {{ position: absolute; inset: 0; padding: 58px 64px; display: flex; flex-direction: column; }}
.live {{ display: inline-flex; align-items: center; gap: 10px; font-weight: 700; letter-spacing: .14em; font-size: 22px;
  color: #ff5a4f; text-transform: uppercase; }}
.live i {{ width: 14px; height: 14px; border-radius: 50%; background: #ff3b30; box-shadow: 0 0 12px #ff3b30; }}
h1 {{ margin: 14px 0 0; font-size: 104px; line-height: 1; font-weight: 700; color: #ffb43a; letter-spacing: -.01em;
  text-shadow: 0 3px 0 #6b3d00; }}
p {{ margin: 22px 0 0; font-size: 34px; line-height: 1.25; font-weight: 600; max-width: 900px; color: #ece7dc; }}
.team {{ margin-top: auto; display: flex; gap: 14px; }}
figure {{ margin: 0; width: 108px; text-align: center; }}
.face {{ width: 92px; height: 92px; margin: 0 auto; border: 3px solid; border-radius: 10px; background: #0e1322;
  display: flex; align-items: center; justify-content: center; overflow: hidden; }}
.face svg {{ width: 84px; height: 84px; display: block; }}
figcaption {{ margin-top: 6px; font-size: 20px; font-weight: 600; color: #d8d2c6; }}
.url {{ position: absolute; right: 64px; top: 62px; font-size: 22px; font-weight: 600; color: #b9b2a5; }}
.nums {{ display: flex; gap: 34px; margin-top: 26px; }}
.nums div {{ display: flex; flex-direction: column; }}
.nums b {{ font-size: 54px; line-height: 1; color: #fff; font-variant-numeric: tabular-nums; }}
.nums span {{ font-size: 22px; color: #c9c2b5; margin-top: 4px; }}
.firsts {{ margin: 22px 0 0; padding: 0; list-style: none; font-size: 26px; font-weight: 600; color: #ffd27a; }}
.firsts li::before {{ content: "★ "; color: #ffb43a; }}
.small .team figure {{ width: 76px; }} .small .face {{ width: 62px; height: 62px; }} .small .face svg {{ width: 56px; height: 56px; }}
.small figcaption {{ font-size: 15px; }}
.small h1 {{ font-size: 84px; }} .small p {{ margin-top: 14px; font-size: 30px; }}
</style></head><body><div class="card"><div class="inner">
<div class="live"><i></i>{html.escape(kicker)}</div>
<h1>{html.escape(title)}</h1>
<p>{html.escape(line)}</p>
{extra}
<div class="team">{faces}</div>
</div><div class="url">factorio.nickwinter.net</div></div></body></html>"""


def shell():
    shells = sorted(glob.glob(os.path.expanduser(
        "~/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell")))
    if not shells:
        sys.exit("no Playwright headless shell: npx playwright install chromium-headless-shell")
    return shells[-1]


def render(page, out):
    with tempfile.TemporaryDirectory() as d:
        src = Path(d) / "card.html"
        src.write_text(page)
        subprocess.run([shell(), "--headless", "--hide-scrollbars", "--force-device-scale-factor=1",
                        "--window-size=1200,630", "--timeout=6000", f"--screenshot={Path(out).resolve()}", src.as_uri()],
                       check=True, capture_output=True, timeout=60)


def shift_cards(runs_dir, bg, html_only=False):
    """Draw each shift's card whose facts changed since its last drawing; returns the shifts drawn."""
    import build  # the site's own data: the long run as its pages show it
    if os.environ.get("POG_SITE_CONTENT"):  # as build.py --content
        build.CONTENT = json.loads(Path(os.environ["POG_SITE_CONTENT"]).read_text())
        build.AGENTS = build.CONTENT["agents"]
    build.LONG = lr = build.load_long(runs_dir)
    if not lr:
        return []
    build.OG_SHIFTS.mkdir(parents=True, exist_ok=True)
    agents = build.AGENTS
    drawn = []
    for s in lr["shifts"]:
        if s.get("empty"):
            continue
        facts = build.shift_card_facts(s, lr)
        key = build.shift_card_key(facts)
        png, keyf = build.OG_SHIFTS / f"shift-{s['n']}.png", build.OG_SHIFTS / f"shift-{s['n']}.key"
        if not html_only and png.exists() and keyf.exists() and keyf.read_text().strip() == key:
            continue
        nums = "".join(f"<div><b>{html.escape(v)}</b><span>{html.escape(k)}</span></div>" for v, k in facts["stats"])
        firsts = "".join(f"<li>{html.escape(f)}</li>" for f in facts["firsts"])
        page = card(f"Shift {facts['n']}", facts["when"], [(k, agents[k]) for k in TEAM], bg,
                    extra=f'<div class="nums">{nums}</div>' + (f'<ul class="firsts">{firsts}</ul>' if firsts else ""),
                    kicker="The long run").replace('<div class="card">', '<div class="card small">')
        if html_only:
            (build.OG_SHIFTS / f"shift-{s['n']}.html").write_text(page)
        else:
            render(page, png)
            keyf.write_text(key + "\n")
        drawn.append(s["n"])
    return drawn


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bg", default=str(SITE / "og" / "bg.jpg"))
    ap.add_argument("--out", default=str(SITE / "static" / "og.png"))
    ap.add_argument("--html", help="also write the card's HTML here")
    ap.add_argument("--shifts", action="store_true", help="the long run's shift cards (site/og/shifts/)")
    ap.add_argument("--runs-dir", default=str(REPO / "runs"))
    ap.add_argument("--html-only", action="store_true", help="with --shifts: write the cards' HTML only, no browser")
    args = ap.parse_args()
    if args.shifts:
        drawn = shift_cards(args.runs_dir, args.bg if Path(args.bg).exists() else None, args.html_only)
        print(f"shift cards: {'drew ' + ', '.join(map(str, drawn)) if drawn else 'all current'}")
        return
    config = json.loads((SITE / "config.json").read_text())
    agents = json.loads((SITE / "content" / "site.json").read_text())["agents"]
    page = card(config.get("site_title", "Factorio AI Party"), config["og_line"],
                [(k, agents[k]) for k in TEAM], args.bg if Path(args.bg).exists() else None)
    if args.html:
        Path(args.html).write_text(page)
    render(page, args.out)
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
