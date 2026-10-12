#!/usr/bin/env python3
"""The social preview image (og:image, 1200x630): python3 site/og_card.py [--bg site/og/bg.jpg] [--out site/static/og.png]

A dark card with the site's title, one line on what it is, and the nine agents' pixel portraits, over a darkened game
frame (site/og/bg.jpg, a camera shot from the run). Rendered with Playwright's headless Chromium shell, like
tools/stream/overlay_shot.sh. build.py copies site/static/og.png to /static/og.png; the page head links it.
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
import avatar as avatar_art  # noqa: E402

TEAM = ["astra", "sol", "luna", "opus", "sonnet", "haiku", "grok", "gemini", "muse"]


def card(title, line, agents, bg):
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
</style></head><body><div class="card"><div class="inner">
<div class="live"><i></i>Streamed live on YouTube</div>
<h1>{html.escape(title)}</h1>
<p>{html.escape(line)}</p>
<div class="team">{faces}</div>
</div><div class="url">factorio.nickwinter.net</div></div></body></html>"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bg", default=str(SITE / "og" / "bg.jpg"))
    ap.add_argument("--out", default=str(SITE / "static" / "og.png"))
    ap.add_argument("--html", help="also write the card's HTML here")
    args = ap.parse_args()
    config = json.loads((SITE / "config.json").read_text())
    agents = json.loads((SITE / "content" / "site.json").read_text())["agents"]
    page = card(config.get("site_title", "Factorio AI Party"), config["og_line"],
                [(k, agents[k]) for k in TEAM], args.bg if Path(args.bg).exists() else None)
    if args.html:
        Path(args.html).write_text(page)
    shells = sorted(glob.glob(os.path.expanduser(
        "~/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell")))
    if not shells:
        sys.exit("no Playwright headless shell: npx playwright install chromium-headless-shell")
    with tempfile.TemporaryDirectory() as d:
        src = Path(d) / "card.html"
        src.write_text(page)
        out = Path(args.out).resolve()
        subprocess.run([shells[-1], "--headless", "--hide-scrollbars", "--force-device-scale-factor=1",
                        "--window-size=1200,630", "--timeout=6000", f"--screenshot={out}", src.as_uri()],
                       check=True, capture_output=True, timeout=60)
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
