#!/usr/bin/env python3
"""Voice bench: the same 20 lines through every available provider and voice.

    python3 tools/stream/voice_bench.py                       # every provider with a key, plus Aura-2
    python3 tools/stream/voice_bench.py --providers eleven,openai --voices el-liam,oa-cedar
    python3 tools/stream/voice_bench.py --design              # also design the casters' voices (ROLE_DESIGN) first
    python3 tools/stream/voice_bench.py --list eleven         # the voices this key can use (to update the catalog)
    python3 tools/stream/voice_bench.py --dry-run             # plan and cost estimate only
    python3 tools/stream/voice_bench.py --resume runs/voice-bench/20261010-2353 --providers eleven,eleven-fast
                                                              # only the clips that folder lacks
    python3 tools/stream/voice_bench.py --index runs/voice-bench/20261010-2353   # rebuild the page from its files
    python3 tools/stream/voice_bench.py --account             # plan and credits per provider (keys never printed)

Writes runs/voice-bench/<stamp>/: one mp3 per line and voice (<provider>/<voice>/<nn>-<kind>.mp3), results.jsonl
(appended clip by clip, so a run that is cut off keeps its record and errors), summary.md (latency, loudness, cost per
stream hour) and index.html, a page that plays each line across voices.
Spending stops at --max-spend (default $8): the plan is estimated first and refused if it would cost more. A provider
that fails --give-up times in a row (default 4) is dropped for the rest of the run with its last error printed.
"""
import argparse, html, json, os, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import voices  # noqa: E402

# (kind, role, text). role pbp/color = a caster line (caster delivery and role voice); None = an agent line.
LINES = [
    ("pbp-open", "pbp", "And we are live! Nine agents, one factory, and Sol has already claimed the iron patch."),
    ("pbp-attack", "pbp", "Biters at the west wall! Grok is holding the line with three turrets and no ammo to spare!"),
    ("pbp-research", "pbp", "Red science is flowing, and Gemini just kicked off oil processing. This team means business!"),
    ("pbp-camera", "pbp", "Let's swing over to Luna, who has been quietly building the biggest smelter column on Nauvis."),
    ("pbp-loss", "pbp", "Oh no, the main bus is cut! Twelve inserters starving and Opus is sprinting back."),
    ("color-banter", "color", "You know, Rook, I have watched a lot of factories, and this one is held together with optimism."),
    ("color-analysis", "color", "What Haiku is doing there is smart: steel first, then the rail, and nobody argues about belts."),
    ("color-lull", "color", "A quiet moment. Muse is labelling chests, which is the most exciting thing in logistics."),
    ("color-praise", "color", "That was a beautiful handoff between Sonnet and Astra. Two hundred plates, no words wasted."),
    ("color-tease", "color", "GPT-6.1 Sol versus Claude Opus on who owns the copper. My money is on whoever has the coal."),
    ("agent-excited-1", None, "YES! Blue science is finally online! Who said we couldn't do it before dinner?"),
    ("agent-excited-2", None, "Roboports are up, the bots are flying, and I am never placing a chest by hand again!"),
    ("agent-excited-3", None, "Kovarex is running. I repeat, Kovarex is running. Somebody put that on the stream."),
    ("agent-frustrated-1", None, "Ugh, the inserters are stuck again. Who put a wooden chest in the middle of my belt?"),
    ("agent-frustrated-2", None, "Seriously, Grok, that is the third time the power has gone out. Build more steam engines!"),
    ("agent-frustrated-3", None, "Why does the furnace keep starving? I fed it coal two minutes ago. This is broken."),
    ("agent-deadpan-1", None, "Iron plates. Again. I have become the iron plate."),
    ("agent-deadpan-2", None, "The biters ate the wall. The wall was load tested. The test has concluded."),
    ("agent-deadpan-3", None, "I have sorted the chests by colour. Nobody asked. You are welcome."),
    ("agent-plan", None, "Plan for the next hour: Luna on smelting, Haiku on rails, and I take the oil field at Vulcanus."),
]
# Planning volume per stream hour: eng/audio's two-host casters now talk ~80% of the time and put Aura-2 at ~$1.4 an
# hour, i.e. ~47k characters at $0.030/1k (casters and agents together), so plan for 45k (about 50 minutes of speech).
CHARS_PER_HOUR = 45000
CHARS_PER_SECOND = 15.0  # speech rate used to convert per-minute prices before any audio is measured


def plan(providers, only=None, design=None):
    """[(backend, voice id)] to render: every catalog voice of each provider (Aura-2 included)."""
    jobs = []
    for prov in providers:
        fam = voices.FAMILY.get(prov, "aura2")  # tone, say, aura1, melotts render the Aura-2 ids
        ids = [v for v, e in voices.CATALOG.items() if voices.FAMILY.get(e[0], e[0]) == fam]
        ids += [v for v in (design or {}).get(prov, [])]
        for v in sorted(ids):
            if not only or v in only:
                jobs.append((prov, v))
    return jobs


def pitch_movement(path):
    """Spread of the voice's pitch over a clip in semitones (10th to 90th percentile; autocorrelation pitch on 40 ms
    frames): a liveliness proxy, flat voices score low (Aura-2 ~5-8, OpenAI ~7-12, Eleven v4 ~14-18 in bench run 1).
    None without numpy or with too little voiced audio."""
    try:
        import numpy as np
    except ImportError:
        return None
    sr, win, hop = 16000, 640, 160
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", path, "-ac", "1", "-ar", str(sr), "-f", "s16le", "-"],
                         capture_output=True).stdout
    x = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768
    lo, hi, f0 = sr // 400, sr // 70, []
    for s in range(0, len(x) - win, hop):
        f = x[s:s + win]
        if np.sqrt(np.mean(f * f)) < 0.02:
            continue
        f = f - f.mean()
        ac = np.correlate(f, f, "full")[win - 1:]
        lag = lo + int(np.argmax(ac[lo:hi]))
        if ac[0] > 0 and ac[lag] / ac[0] > 0.45:
            f0.append(sr / lag)
    if len(f0) < 20:
        return None
    st = 12 * np.log2(np.array(f0) / np.median(f0))
    return round(float(np.percentile(st, 90) - np.percentile(st, 10)), 1)


def clip_cost(prov, text, seconds=None):
    """What a clip costs (as TTS.speak() counts it), from its seconds when measured."""
    unit, rate = voices.PRICE[prov]
    return rate * (len(text) if unit == "chars" else (seconds or len(text) / CHARS_PER_SECOND) / 60)


def estimate(jobs, lines):
    return sum(clip_cost(prov, t) for prov, _ in jobs for _, _, t in lines)


def clip_path(prov, vid, i, kind):
    return os.path.join(prov, vid, f"{i:02d}-{kind}.mp3")


def todo(out, jobs, lines, redo=()):
    """[(prov, vid, i, kind, role, text)] the folder lacks (or that `redo` names)."""
    return [(prov, vid, i, kind, role, text) for prov, vid in jobs for i, (kind, role, text) in enumerate(lines, 1)
            if kind in redo or not os.path.exists(os.path.join(out, clip_path(prov, vid, i, kind)))]


def load_rows(out):
    """Every clip in the folder: the latest results.jsonl row per clip, else one rebuilt from the file (a run cut off
    before it wrote results: no latency, cost estimated from the text and measured length). Plus recorded errors for
    clips that never appeared."""
    latest = {}
    try:
        for line in open(os.path.join(out, "results.jsonl"), encoding="utf-8"):
            if line.strip():
                r = json.loads(line)
                latest[(r["provider"], r["voice"], r["line"])] = r
    except OSError:
        pass
    rows = []
    for prov in sorted(os.listdir(out)):
        if prov not in voices.PRICE or not os.path.isdir(os.path.join(out, prov)):
            continue
        for vid in sorted(os.listdir(os.path.join(out, prov))):
            for i, (kind, role, text) in enumerate(LINES, 1):
                rel = clip_path(prov, vid, i, kind)
                r = latest.pop((prov, vid, kind), None)
                if not os.path.exists(os.path.join(out, rel)):
                    if r and "error" in r:
                        rows.append(r)
                    continue
                if not r or "file" not in r:
                    secs = voices.duration(open(os.path.join(out, rel), "rb").read())
                    r = {"provider": prov, "voice": vid, "line": kind, "role": role or "agent", "text": text,
                         "file": rel, "seconds": round(secs, 2), "latency": None,
                         "cost": round(clip_cost(prov, text, secs), 5), "recovered": True,
                         "mtime": os.path.getmtime(os.path.join(out, rel))}
                    r.update(voices.loudness(os.path.join(out, rel)))
                if "pitch" not in r:
                    r["pitch"] = pitch_movement(os.path.join(out, rel))
                rows.append(r)
    # recovered clips: the time since the previous clip was written bounds the latency from above (it also holds
    # loudness normalisation and, with --check, the transcription)
    prev = None
    for r in sorted((r for r in rows if r.get("recovered")), key=lambda r: r["mtime"]):
        nxt = prev and (prev["voice"], int(os.path.basename(prev["file"])[:2]) + 1) == \
            (r["voice"], int(os.path.basename(r["file"])[:2]))  # the clip right after, no failures between
        if nxt and prev["provider"] == r["provider"] and r["mtime"] - prev["mtime"] < 30:
            r["interval"] = round(r["mtime"] - prev["mtime"], 1)
        prev = r
    return rows + [r for r in latest.values() if "error" in r]


def per_hour(prov, chars_per_sec=None):
    unit, rate = voices.PRICE[prov]
    if unit == "chars":
        return rate * CHARS_PER_HOUR
    return rate * CHARS_PER_HOUR / (chars_per_sec or CHARS_PER_SECOND) / 60


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--providers", help="comma-separated backends (default: every one with a key, plus aura2)")
    ap.add_argument("--voices", help="comma-separated voice ids to limit to")
    ap.add_argument("--lines", help="comma-separated line kinds to limit to (e.g. pbp-attack,agent-deadpan-1)")
    ap.add_argument("--out", default=os.path.join(HERE, "..", "..", "runs", "voice-bench", time.strftime("%Y%m%d-%H%M")))
    ap.add_argument("--max-spend", type=float, default=8.0, help="refuse a plan estimated above this many dollars")
    ap.add_argument("--design", action="store_true", help="design the casters' voices (ROLE_DESIGN) and include them")
    ap.add_argument("--check", action="store_true", help="transcribe each clip with Whisper on Workers AI (accuracy)")
    ap.add_argument("--list", metavar="PROVIDER", help="print the voices this provider's key can use and exit")
    ap.add_argument("--resume", metavar="DIR", help="render into an earlier bench folder, only the clips it lacks")
    ap.add_argument("--redo", help="with --resume: line kinds to render again even where the clip exists")
    ap.add_argument("--index", metavar="DIR", help="rebuild summary.md and index.html from DIR's clips and exit")
    ap.add_argument("--account", action="store_true", help="print each provider's plan and credits and exit")
    ap.add_argument("--give-up", type=int, default=4, help="drop a provider after this many failures in a row")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    if a.index:
        out = os.path.abspath(a.index)
        rows = load_rows(out)
        write_summary(out, rows)
        write_index(out, rows, LINES)
        print(f"{sum('file' in r for r in rows)} clips, ${sum(r.get('cost', 0) for r in rows):.2f} spent; "
              f"listen: {os.path.join(out, 'index.html')}")
        return
    if a.account:
        for prov in voices.available_providers():
            p = voices.PROVIDERS[prov]()
            print(f"{prov}: {p.account() if hasattr(p, 'account') else 'no account endpoint in voices.py'}")
        return
    if a.list:
        p = voices.PROVIDERS[a.list]()
        if not p.available():
            sys.exit(f"{a.list}: no key file {voices.PROVIDER_KEY[a.list]}.key in {voices.KEY_DIR}")
        for vid, name, desc in p.voices():
            print(f"{vid}\t{name}\t{desc}")
        return

    have = voices.available_providers()
    providers = a.providers.split(",") if a.providers else have + ["aura2"]
    skipped = [p for p in providers if p in voices.PROVIDERS and p not in have]
    providers = [p for p in providers if p not in skipped]
    for p in skipped:
        print(f"skip {p}: no key file {voices.PROVIDER_KEY[p]}.key in {voices.KEY_DIR}")
    lines = [ln for ln in LINES if not a.lines or ln[0] in a.lines.split(",")]
    only = set(a.voices.split(",")) if a.voices else None

    design = {}
    if a.design and not a.dry_run:
        for prov in providers:
            if not hasattr(voices.PROVIDERS.get(prov, lambda: None)(), "design"):
                continue
            tts = voices.TTS(prov)
            for role, desc in voices.ROLE_DESIGN.items():
                vid = tts.designed_voice(f"{role}{prov[:2]}", desc)  # my-pbpel, my-colorin...
                print(f"designed {role} on {prov}: {vid or 'failed (see ' + voices.STATE_DIR + '/designed.json)'}")
                if vid:
                    design.setdefault(prov, []).append(vid)

    jobs = plan(providers, only, design)
    out = os.path.abspath(a.resume or a.out)
    items = todo(out, jobs, lines, set((a.redo or "").split(",")) - {""})
    cost = sum(clip_cost(prov, text) for prov, _, _, _, _, text in items)
    print(f"{len(items)} clips to render ({len(jobs)} voices x {len(lines)} lines on "
          f"{', '.join(providers) or 'nothing'}{', minus those already in ' + out if a.resume else ''}): "
          f"about ${cost:.2f}")
    if not jobs:
        sys.exit("nothing to render: no provider available (keys go in ~/.config/pog/, see voices.py)")
    if cost > a.max_spend:
        sys.exit(f"estimate ${cost:.2f} is over --max-spend ${a.max_spend:.2f}; narrow --providers/--voices/--lines")
    for prov in providers:
        p = voices.PROVIDERS.get(prov)
        if p and hasattr(p(), "account") and any(it[0] == prov for it in items):
            print(f"{prov} account: {p().account()}")
    if a.dry_run:
        for prov, vid in jobs:
            n = sum(1 for it in items if it[:2] == (prov, vid))
            if n:
                print(f"  {prov:12} {vid:14} {n} clips")
        return

    os.makedirs(out, exist_ok=True)
    log = open(os.path.join(out, "results.jsonl"), "a", encoding="utf-8")
    whisper, ttss, fails, dropped = 0.0, {}, {}, {}
    for prov, vid, i, kind, role, text in items:
        if prov in dropped:
            continue
        tts = ttss.get(prov) or ttss.setdefault(prov, voices.TTS(prov))
        # a caster line is spoken by the voice under test with the caster's delivery
        before = tts.spent
        row = {"provider": prov, "voice": vid, "line": kind, "role": role or "agent", "text": text,
               "at": time.strftime("%H:%M:%S")}
        orig = dict(voices.ROLE_VOICES)
        try:
            if role:
                voices.ROLE_VOICES[role] = [vid]
            audio, ctype, dur, lat = tts.speak(text, vid, caster=role)
        except Exception as x:  # noqa: BLE001  a bench records failures and moves on
            row.update(error=f"{type(x).__name__}: {str(x)[:300]}")
            print(f"  {prov}/{vid} {kind}: {row['error']}", flush=True)
            log.write(json.dumps(row, ensure_ascii=False) + "\n")
            log.flush()
            fails[prov] = fails.get(prov, 0) + 1
            if fails[prov] >= a.give_up:
                dropped[prov] = row["error"]
                print(f"dropping {prov} for this run after {fails[prov]} failures in a row: {row['error']}")
            continue
        finally:
            voices.ROLE_VOICES.clear()
            voices.ROLE_VOICES.update(orig)
        fails[prov] = 0
        rel = clip_path(prov, vid, i, kind)
        os.makedirs(os.path.join(out, prov, vid), exist_ok=True)
        open(os.path.join(out, rel), "wb").write(audio)
        row.update(file=rel, seconds=round(dur, 2), latency=round(lat, 2), cost=round(tts.spent - before, 5),
                   mood=tts.last.get("mood"), spoken_by=tts.last.get("provider"),
                   model=getattr(tts.providers.get(prov), "model", None))
        row.update(voices.loudness(os.path.join(out, rel)))
        row["pitch"] = pitch_movement(os.path.join(out, rel))
        if a.check and tts.ai is not None:
            heard = voices.transcribe(tts.ai, audio)
            whisper += voices.WHISPER_PRICE * dur / 60
            row.update(heard=heard, accuracy=round(voices.word_accuracy(text, heard), 2))
        log.write(json.dumps(row, ensure_ascii=False) + "\n")
        log.flush()
        print(f"  {prov}/{vid} {kind}: {dur:.1f}s audio in {lat:.2f}s", flush=True)
        if sum(t.spent for t in ttss.values()) + whisper > a.max_spend:
            print(f"stopped: spent over --max-spend ${a.max_spend:.2f}")
            break
    log.close()
    spent = sum(t.spent for t in ttss.values()) + whisper
    rows = load_rows(out)
    write_summary(out, rows)
    write_index(out, rows, LINES)
    for prov, err in dropped.items():
        print(f"{prov} dropped: {err}")
    print(f"\nspent ${spent:.4f} this run, ${sum(r.get('cost', 0) for r in rows):.2f} on the folder's clips; "
          f"listen: {os.path.join(out, 'index.html')}")


def latency_text(rows, q=0.5):
    """Median (or quantile q) latency, else "≤" the median time between clips of a cut-off run, else "–"."""
    for field, pre in (("latency", ""), ("interval", "≤")):
        v = sorted(r[field] for r in rows if r.get(field) is not None)
        if v:
            return f"{pre}{v[int(q * (len(v) - 1))]:.1f} s"
    return "–"


def write_summary(out, rows):
    ok = [r for r in rows if "file" in r]
    spent = sum(r.get("cost", 0) for r in ok)
    md = [f"# Voice bench {time.strftime('%Y-%m-%d %H:%M')}", "",
          f"{len(ok)} clips, {len(rows) - len(ok)} failures, ${spent:.2f} spent on the clips. Cost per hour assumes "
          f"{CHARS_PER_HOUR} characters an hour.", "",
          "Latency is the wait for a clip; where a run was cut off before it recorded latencies, \"≤\" is the time "
          "between clips written (latency plus normalisation, and transcription with --check).", "",
          "| Provider | Voices | Median latency | p90 latency | Median LUFS | Chars/s | $/stream hour | Failures |",
          "|---|---|---|---|---|---|---|---|"]
    for prov in sorted({r["provider"] for r in rows}):
        mine = [r for r in rows if r["provider"] == prov]
        good = [r for r in mine if "file" in r]
        lufs = [r["lufs"] for r in good if r.get("lufs") is not None]
        cps = sum(len(r["text"]) for r in good) / max(0.1, sum(r["seconds"] for r in good)) if good else None
        md.append(f"| {prov} | {len({r['voice'] for r in mine})} | {latency_text(good)} | "
                  f"{latency_text(good, 0.9)} | {statistics.median(lufs) if lufs else float('nan'):.1f} | "
                  f"{cps or 0:.1f} | ${per_hour(prov, cps):.2f} | {len(mine) - len(good)} |")
    acc = [r for r in ok if "accuracy" in r]
    if acc:
        md += ["", "Whisper word accuracy by voice (lowest first):", ""]
        by = {}
        for r in acc:
            by.setdefault(f"{r['provider']}/{r['voice']}", []).append(r["accuracy"])
        for k, v in sorted(by.items(), key=lambda kv: statistics.mean(kv[1]))[:15]:
            md.append(f"- {k}: {statistics.mean(v):.2f}")
    errs = [r for r in rows if "error" in r]
    if errs:
        md += ["", "Failures (first 10):", ""] + [f"- {r['provider']}/{r['voice']} {r['line']}: {r['error']}"
                                                  for r in errs[:10]]
    open(os.path.join(out, "summary.md"), "w").write("\n".join(md) + "\n")


PAGE_CSS = """
:root{--bg:#fbfaf7;--fg:#1f1d1a;--mute:#6b665e;--line:#e4e0d8;--card:#fff;--acc:#b4531c;--star:#fff4e0}
@media (prefers-color-scheme:dark){:root{--bg:#171614;--fg:#ece8e1;--mute:#9a948a;--line:#34312c;--card:#211f1c;
--acc:#f0a46c;--star:#3a2a18}}
*{box-sizing:border-box}body{background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,sans-serif;margin:0;
padding:20px 16px 60px;max-width:1180px;margin-inline:auto}
h1{font-size:22px;margin:0 0 4px}h2{font-size:15px;margin:30px 0 2px}.mute{color:var(--mute)}
table{border-collapse:collapse;margin:12px 0;font-size:13px;display:block;overflow-x:auto}
td,th{border-bottom:1px solid var(--line);padding:5px 10px;text-align:left;white-space:nowrap}
th{font-weight:600}.num{text-align:right;font-variant-numeric:tabular-nums}
.bar{position:sticky;top:0;background:var(--bg);padding:8px 0;border-bottom:1px solid var(--line);z-index:1;
display:flex;flex-wrap:wrap;gap:6px 14px;align-items:center}
.bar label{cursor:pointer;user-select:none}.t{color:var(--mute);margin:0 0 8px;max-width:820px}
.grid{display:flex;flex-wrap:wrap;gap:8px}
.c{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:6px 8px;font-size:12px;width:250px}
.c.def{background:var(--star);border-color:var(--acc)}.c b{font-weight:600}
audio{width:100%;height:30px;margin-top:4px}.note{border-left:3px solid var(--acc);padding:4px 12px;margin:14px 0}
"""
PAGE_JS = """
document.querySelectorAll('.bar input').forEach(cb=>cb.addEventListener('change',()=>{
  document.querySelectorAll('.c.p-'+cb.value).forEach(el=>el.hidden=!cb.checked)}));
document.addEventListener('play',e=>{document.querySelectorAll('audio').forEach(a=>{if(a!==e.target)a.pause()})},true);
"""


def defaults_auto():
    """{role: catalog id} the casters get under --tts auto with the keys on this machine, and the agents' pool."""
    tts = voices.TTS.__new__(voices.TTS)
    tts.backend, tts.down = "auto", {}
    tts.providers = {p: None for p in voices.available_providers()}  # no network: keys only
    return {role: tts.caster_voice(role) for role in ("pbp", "color")}


def write_index(out, rows, lines):
    """A page with one section per line and a player per voice, so the same words compare across voices: the cost so
    far, a table per provider, provider toggles, and the voices --tts auto gives the casters marked."""
    ok = [r for r in rows if "file" in r]
    provs = sorted({r["provider"] for r in rows})
    expected = {p: len({v for v, e in voices.CATALOG.items() if voices.FAMILY.get(e[0], e[0]) ==
                        voices.FAMILY.get(p, "aura2")}) * len(lines) for p in provs}
    casters = defaults_auto()
    e = html.escape
    parts = ["<!doctype html><html lang=en><meta charset=utf-8>",
             "<meta name=viewport content='width=device-width,initial-scale=1'><title>Voice bench</title>",
             f"<style>{PAGE_CSS}</style>",
             f"<h1>Voice bench</h1><p class=mute>{os.path.basename(out)} · {len(ok)} clips · "
             f"${sum(r.get('cost', 0) for r in ok):.2f} spent on these clips · cost per stream hour at "
             f"{CHARS_PER_HOUR:,} characters an hour. Click to play; nothing autoplays, and one clip plays at a "
             f"time.</p>",
             "<table><tr><th>Provider</th><th class=num>Clips</th><th class=num>of</th><th class=num>Voices</th>"
             "<th class=num>Median latency</th><th class=num>Spent</th><th class=num>$/stream hour</th>"
             "<th>Failures</th></tr>"]
    for p in provs:
        good = [r for r in ok if r["provider"] == p]
        bad = [r for r in rows if r["provider"] == p and "error" in r]
        cps = sum(len(r["text"]) for r in good) / max(0.1, sum(r["seconds"] for r in good)) if good else None
        err = e(bad[-1]["error"][:90]) if bad else ""
        parts.append(f"<tr><td>{e(p)}</td><td class=num>{len(good)}</td><td class=num>{expected[p]}</td>"
                     f"<td class=num>{len({r['voice'] for r in good})}</td>"
                     f"<td class=num>{latency_text(good)}</td>"
                     f"<td class=num>${sum(r.get('cost', 0) for r in good):.2f}</td>"
                     f"<td class=num>${per_hour(p, cps):.2f}</td><td>{len(bad) or ''} {err}</td></tr>")
    parts.append("</table>")
    parts.append(f"<p class=note>Highlighted: the voices <code>--tts auto</code> gives the casters with the keys on "
                 f"this machine (play-by-play <b>{e(casters['pbp'])}</b>, colour <b>{e(casters['color'])}</b>). "
                 f"A caster line is read by every voice in the caster's delivery, so any voice can be judged as a "
                 f"caster. Clips without a latency came from a run that was cut off before it wrote its "
                 f"results.</p>")
    # voices by pitch movement (liveliness proxy) and pace, caster lines and agent lines apart
    per = {}
    for r in ok:
        if r.get("pitch") is not None:
            d = per.setdefault((r["provider"], r["voice"]), {"caster": [], "agent": [], "pace": []})
            d["agent" if r["role"] == "agent" else "caster"].append(r["pitch"])
            if r["role"] != "agent":
                d["pace"].append(len(r["text"]) / max(0.1, r["seconds"]))
    med = lambda v: statistics.median(v) if v else None  # noqa: E731
    ranked = sorted(per.items(), key=lambda kv: -(med(kv[1]["caster"]) or med(kv[1]["agent"]) or 0))
    if ranked:
        parts.append("<details><summary>Voices by pitch movement (a liveliness measure, not a verdict: listen) "
                     "</summary><table><tr><th>Voice</th><th class=num>Caster lines, semitones</th>"
                     "<th class=num>Agent lines</th><th class=num>Caster pace, chars/s</th><th class=num>Clips</th>"
                     "</tr>")
        for (p, v), d in ranked:
            cells = [f"{x:.1f}" if x is not None else "–" for x in (med(d["caster"]), med(d["agent"]), med(d["pace"]))]
            parts.append(f"<tr><td>{e(p)} / {e(v)}</td>" + "".join(f"<td class=num>{c}</td>" for c in cells)
                         + f"<td class=num>{len(d['caster']) + len(d['agent'])}</td></tr>")
        parts.append("</table><p class=mute>Spread of pitch over a clip, 10th to 90th percentile; flat voices score "
                     "low. Pace is characters per second on the caster lines.</p></details>")
    parts.append("<div class=bar><span class=mute>Show:</span>" + "".join(
        f"<label><input type=checkbox value={e(p)} checked> {e(p)}</label>" for p in provs) + "</div>")
    by_line = {}
    for r in ok:
        by_line.setdefault(r["line"], []).append(r)
    for kind, role, text in lines:
        parts.append(f"<h2>{e(kind)} <span class=mute>({e(role or 'agent')})</span></h2><p class=t>{e(text)}</p>"
                     "<div class=grid>")
        for r in sorted(by_line.get(kind, []), key=lambda r: (r["provider"], r["voice"])):
            star = role and casters.get(role) == r["voice"]
            wait = f"{r['latency']}s wait" if r.get("latency") is not None else \
                f"≤{r['interval']}s wait" if r.get("interval") is not None else None
            meta = [f"{r['seconds']}s"] + ([wait] if wait else []) + ([r["mood"]] if r.get("mood") else [])
            desc = (voices.CATALOG.get(r["voice"]) or ("", "", ""))[2]
            parts.append(f"<div class='c p-{e(r['provider'])}{' def' if star else ''}' title='{e(desc)}'>"
                         f"<b>{e(r['voice'])}</b> <span class=mute>{e(r['provider'])} · {e(' · '.join(meta))}"
                         f"</span><audio controls preload=none src='{e(r['file'])}'></audio></div>")
        missing = sum(1 for r in rows if r["line"] == kind and "error" in r)
        parts.append("</div>" + (f"<p class=mute>{missing} voices failed on this line.</p>" if missing else ""))
    parts.append(f"<script>{PAGE_JS}</script>")
    open(os.path.join(out, "index.html"), "w").write("\n".join(parts) + "\n")


if __name__ == "__main__":
    main()
