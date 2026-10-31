"""Export the real overlay pages with file-only state delivery; no service, audio or world.

Replay an already reviewed script without another model call:
  python3 tools/stream/shift_recap_rehearsal.py --manifest .../manifest.json --out ...
"""
import argparse
import json
from pathlib import Path
import re
import shutil

import shift_recap_visuals as visuals

HERE = Path(__file__).resolve().parent


def js(value):
    return json.dumps(value, ensure_ascii=False).replace("<", "\\u003c")


def pages(manifest, out):
    """Keep the page markup, renderers and CSS; substitute only their transport.

    The restore snapshot is an empty Model (the service before its first world read).
    The early case omits even agents, proving recap rendering does not depend on them.
    No CSS or JavaScript presentation is duplicated in this exporter.
    """
    import model
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    manifest = visuals.bind(manifest)
    sequence = [visuals.public(manifest, line, phase, asset_prefix="assets/")
                for phase, lines in (("transition", manifest["transition"]), ("recap", manifest["lines"]))
                for line in lines]
    durations = [line.get("duration", 5) for line in manifest["transition"] + manifest["lines"]]
    still = next((n for n, beat in enumerate(sequence) if beat["media"]), 0)
    neutral = next((n for n, beat in enumerate(sequence) if beat["phase"] == "recap" and not beat["media"]), 0)
    cases = {"transition": 0, "still": still, "neutral": neutral, "early": still,
             "restore": len(sequence), "interrupted": len(sequence), "holding": len(sequence)}
    normal = model.Model({"title": "Player of Games", "subtitle": "Offline layout rehearsal", "agents": {}}).snapshot(manifest["through"], {})
    payload = {"sequence": sequence, "durations": durations, "normal": normal, "cases": cases,
               "layouts": {name: json.loads((HERE / "static" / (name + ".json")).read_text())
                           for name in ("layout", "layout-portrait", "layout-3cam")}}
    bootstrap = r"""<script>
(() => {
 const data = DATA, params = new URLSearchParams(location.search);
 const which = params.get('case'), early = which === 'early';
 let step = Math.max(0, Math.min(data.sequence.length, Number(params.get('step') ?? params.get('card') ?? data.cases[which] ?? 0))), timer;
 const transport = {addEventListener(){}, removeEventListener(){}, close(){}};
 window.pogEvents = transport;
 function snapshot() {
   let recap = data.sequence[step] || null;
   if (which === 'holding' && step === data.sequence.length) recap = {...data.sequence.at(-1), holding:true};
   return early ? {shift_recap:recap} : {...data.normal, shift_recap:recap};
 }
 window.fetch = async (url) => {
   const key = String(url).match(/\/static\/(layout[^/]*)\.json/);
   return {ok:true, json:async()=>key ? data.layouts[key[1]] : snapshot()};
 };
 function show(n) {
   clearTimeout(timer); step = Math.max(0, Math.min(data.sequence.length, n));
   const query = new URLSearchParams(location.search); query.set('step',step);
   history.replaceState(null,'','?'+query);
   transport.onmessage({data:JSON.stringify(snapshot())});
   return step;
 }
 function play() {
   show(step);
   if (step < data.sequence.length) timer = setTimeout(()=>{step++;play();},data.durations[step]*1000);
 }
 window.PogRecapReplay = {data, show, play, snapshot, get step(){return step;}, ready:false};
 addEventListener('keydown', e=>{
   if(e.key==='ArrowRight') show(step+1);
   if(e.key==='ArrowLeft') show(step-1);
   if(e.key===' ') {e.preventDefault();play();}
   if(e.key==='Escape') show(data.sequence.length);
 });
 addEventListener('DOMContentLoaded',()=>{
   show(step); window.PogRecapReplay.ready=true;
   if(params.get('play')==='1')play();
 });
})();
</script>""".replace("DATA", js(payload), 1)
    for kind, source in (("landscape", "index.html"), ("portrait", "portrait.html")):
        page = (HERE / "static" / source).read_text()
        def style(match):
            css = (HERE / "static" / match[1]).read_text()
            # Existing normal-layout font import is the only remote dependency; system
            # fallback for the empty restore. Recap uses system-ui in production too.
            css = re.sub(r"(?m)^@import.*$", "", css)
            return "<style>" + css + "</style>"
        def script(match):
            if match[1] == "audio.js":
                return ""  # no voice playback/capture receipts in a visual rehearsal
            return "<script>" + (HERE / "static" / match[1]).read_text().replace("</script", "<\\/script") + "</script>"
        page = re.sub(r'<link rel="stylesheet" href="/static/([^"]+)">', style, page)
        page = re.sub(r'<script src="/static/([^"]+)"></script>', script, page)
        page = page.replace("</head>", bootstrap + "</head>")
        (out / f"onair-{kind}.html").write_text(page)
    (out / "replay-sequence.json").write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--run-dir", type=Path, help="refresh media from this recorded run without rewriting narration")
    args = parser.parse_args()
    import shift_recap as recap
    manifest = json.loads(args.manifest.read_text())
    args.out.mkdir(parents=True, exist_ok=True)
    for row in manifest.get("stills", []):
        if visuals.media_record(row):
            src = args.manifest.parent / "assets" / row["asset"]
            dst = args.out / "assets" / row["asset"]
            dst.parent.mkdir(exist_ok=True)
            if src.is_file() and src.resolve() != dst.resolve():
                shutil.copyfile(src, dst)
    from shift_recap_media import checked, refresh
    manifest = refresh(args.run_dir, args.out, manifest, force=True) if args.run_dir else checked(manifest, args.out)
    recap.save_json(args.out / "manifest.json", manifest)
    recap.export(manifest, args.out)
    if manifest["media_review"]["no_media"]:
        print("WARNING: NO BOUND MEDIA; see review.md")
    print(args.out.resolve())


if __name__ == "__main__":
    main()
