#!/usr/bin/env python3
"""The live page's map as a standalone SVG, from a stream state (serve.py's /state.json, or the live API's state):
static/live.js runs under node with a stub page, and the map's CSS from static/style.css is inlined.

    curl -s http://127.0.0.1:8787/state.json > state.json
    python3 site/map_snapshot.py state.json docs/site-map.svg

Needs node. For a PNG, open the SVG in a browser or tools/stream/overlay_shot.sh against a built site with
?demo=1 and the state as live/state.example.json.
"""
import argparse, json, os, re, subprocess, sys, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SITE)
from test_live import MAP_JS  # noqa: E402  (live.js in a stub DOM, sample mode)

VARS = {"--fx-text": "#e3e3e3", "--fx-orange": "#ffa200", "--fx-red": "#e04e3a", "--fx-r-1": "2px", "--fx-inset-shadow": "none"}


def css():
    """The map's rules from style.css (minimap, b-, o-), with the kit's variables filled in."""
    src = open(os.path.join(SITE, "static", "style.css")).read()
    rules = re.findall(r"(?m)^[^{}@/\n]*(?:\.minimap|\.b-|\.o-)[^{}]*\{[^}]*\}", src)
    out = "\n".join(r.strip() for r in rules)
    for k, v in VARS.items():
        out = out.replace(f"var({k})", v)
    return re.sub(r"var\(--[\w-]+\)", "#888", out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("state")
    ap.add_argument("out")
    a = ap.parse_args()
    s = json.load(open(a.state))
    s = s.get("state", s) if "state" in s and isinstance(s.get("state"), dict) else s
    with tempfile.TemporaryDirectory() as d:
        js, path = os.path.join(d, "map.js"), os.path.join(d, "state.json")
        open(js, "w").write(MAP_JS)
        json.dump(s, open(path, "w"))
        r = subprocess.run(["node", js, os.path.join(SITE, "static", "live.js"), path], capture_output=True, text=True, timeout=60)
    if r.returncode:
        sys.exit(r.stderr)
    m = re.search(r'<svg class="minimap".*?</svg>', r.stdout, re.S)
    if not m:
        sys.exit("no map in the page")
    svg = m.group(0).replace('<svg class="minimap"', '<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1000" class="minimap" '
                             'font-family="Titillium Web, Segoe UI, sans-serif"', 1)
    svg = svg.replace(">", "><style>" + css() + "</style>", 1)
    open(a.out, "w").write(svg)
    legend = re.findall(r'</i>([^<]+)</li>', r.stdout)
    note = re.search(r"About \d+ tiles across[^<]*", r.stdout)
    print(f"{a.out}: {len(svg):,} bytes; legend {', '.join(legend)}\n{note.group(0) if note else ''}")


if __name__ == "__main__":
    main()
