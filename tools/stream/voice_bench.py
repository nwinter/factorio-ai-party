#!/usr/bin/env python3
"""Voice bench: the same 20 lines through every available provider and voice.

    python3 tools/stream/voice_bench.py                       # every provider with a key, plus Aura-2
    python3 tools/stream/voice_bench.py --providers eleven,openai --voices el-liam,oa-cedar
    python3 tools/stream/voice_bench.py --design              # also design the casters' voices (ROLE_DESIGN) first
    python3 tools/stream/voice_bench.py --list eleven         # the voices this key can use (to update the catalog)
    python3 tools/stream/voice_bench.py --dry-run             # plan and cost estimate only

Writes runs/voice-bench/<stamp>/: one mp3 per line and voice (<provider>/<voice>/<nn>-<kind>.mp3), results.jsonl,
summary.md (latency, loudness, cost per stream hour) and index.html, a page that plays each line across voices.
Spending stops at --max-spend (default $8): the plan is estimated first and refused if it would cost more.
"""
import argparse, html, json, os, statistics, sys, time

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


def estimate(jobs, lines):
    chars = sum(len(t) for _, _, t in lines)
    total = 0.0
    for prov, _ in jobs:
        unit, rate = voices.PRICE[prov]
        total += rate * (chars if unit == "chars" else chars / CHARS_PER_SECOND / 60)
    return total


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
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

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
    cost = estimate(jobs, lines)
    print(f"{len(jobs)} voices x {len(lines)} lines on {', '.join(providers) or 'nothing'}: about ${cost:.2f}")
    if not jobs:
        sys.exit("nothing to render: no provider available (keys go in ~/.config/pog/, see voices.py)")
    if cost > a.max_spend:
        sys.exit(f"estimate ${cost:.2f} is over --max-spend ${a.max_spend:.2f}; narrow --providers/--voices/--lines")
    if a.dry_run:
        for prov, v in jobs:
            print(f"  {prov:12} {v}")
        return

    out = os.path.abspath(a.out)
    os.makedirs(out, exist_ok=True)
    rows, spent, whisper = [], 0.0, 0.0
    ttss = {}
    for prov, vid in jobs:
        tts = ttss.get(prov) or ttss.setdefault(prov, voices.TTS(prov))
        for i, (kind, role, text) in enumerate(lines, 1):
            # a caster line is spoken by the voice under test with the caster's delivery
            before = tts.spent
            row = {"provider": prov, "voice": vid, "line": kind, "role": role or "agent", "text": text}
            try:
                orig = dict(voices.ROLE_VOICES)
                if role:
                    voices.ROLE_VOICES[role] = [vid]
                audio, ctype, dur, lat = tts.speak(text, vid, caster=role)
            except Exception as x:  # noqa: BLE001  a bench records failures and moves on
                row.update(error=f"{type(x).__name__}: {str(x)[:200]}")
                print(f"  {prov}/{vid} {kind}: {row['error']}")
                rows.append(row)
                continue
            finally:
                voices.ROLE_VOICES.clear()
                voices.ROLE_VOICES.update(orig)
            rel = os.path.join(prov, vid, f"{i:02d}-{kind}.mp3")
            os.makedirs(os.path.join(out, prov, vid), exist_ok=True)
            open(os.path.join(out, rel), "wb").write(audio)
            row.update(file=rel, seconds=round(dur, 2), latency=round(lat, 2), cost=round(tts.spent - before, 5),
                       mood=tts.last.get("mood"), spoken_by=tts.last.get("provider"))
            row.update(voices.loudness(os.path.join(out, rel)))
            if a.check and tts.ai is not None:
                heard = voices.transcribe(tts.ai, audio)
                whisper += voices.WHISPER_PRICE * dur / 60
                row.update(heard=heard, accuracy=round(voices.word_accuracy(text, heard), 2))
            rows.append(row)
            print(f"  {prov}/{vid} {kind}: {dur:.1f}s audio in {lat:.2f}s", flush=True)
            if sum(t.spent for t in ttss.values()) + whisper > a.max_spend:
                sys.exit(f"stopped: spent over --max-spend ${a.max_spend:.2f}")
    spent = sum(t.spent for t in ttss.values()) + whisper
    with open(os.path.join(out, "results.jsonl"), "w") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    write_summary(out, rows, providers, spent)
    write_index(out, rows, lines)
    print(f"\nspent ${spent:.4f}; listen: {os.path.join(out, 'index.html')}")


def write_summary(out, rows, providers, spent):
    ok = [r for r in rows if "file" in r]
    md = [f"# Voice bench {time.strftime('%Y-%m-%d %H:%M')}", "",
          f"{len(ok)} clips, {len(rows) - len(ok)} failures, ${spent:.4f} spent. Cost per hour assumes "
          f"{CHARS_PER_HOUR} characters an hour.", "",
          "| Provider | Voices | Median latency | p90 latency | Median LUFS | Chars/s | $/stream hour | Failures |",
          "|---|---|---|---|---|---|---|---|"]
    for prov in providers:
        mine = [r for r in rows if r["provider"] == prov]
        good = [r for r in mine if "file" in r]
        if not mine:
            continue
        lat = sorted(r["latency"] for r in good) or [0]
        lufs = [r["lufs"] for r in good if r.get("lufs") is not None]
        cps = sum(len(r["text"]) for r in good) / max(0.1, sum(r["seconds"] for r in good)) if good else None
        md.append(f"| {prov} | {len({r['voice'] for r in mine})} | {statistics.median(lat):.2f} s | "
                  f"{lat[int(0.9 * (len(lat) - 1))]:.2f} s | {statistics.median(lufs) if lufs else float('nan'):.1f} | "
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


def write_index(out, rows, lines):
    """A page with one section per line and a player per voice, so the same words compare across voices."""
    by_line = {}
    for r in rows:
        if "file" in r:
            by_line.setdefault(r["line"], []).append(r)
    parts = ["<!doctype html><meta charset=utf-8><title>Voice bench</title>",
             "<style>body{font:14px system-ui;margin:24px;max-width:1100px}h2{font-size:15px;margin:28px 0 6px}"
             ".t{color:#555;margin-bottom:8px}.c{display:inline-flex;flex-direction:column;margin:4px 10px 4px 0;"
             "font-size:12px}audio{width:230px;height:32px}</style>",
             "<h1>Voice bench</h1><p>Each line through every voice. Click to play; nothing autoplays.</p>"]
    for kind, role, text in lines:
        parts.append(f"<h2>{html.escape(kind)} ({html.escape(role or 'agent')})</h2>"
                     f"<div class=t>{html.escape(text)}</div>")
        for r in sorted(by_line.get(kind, []), key=lambda r: (r["provider"], r["voice"])):
            label = f"{r['provider']} / {r['voice']} · {r['seconds']}s · {r['latency']}s"
            parts.append(f"<span class=c>{html.escape(label)}<audio controls preload=none "
                         f"src=\"{html.escape(r['file'])}\"></audio></span>")
    open(os.path.join(out, "index.html"), "w").write("\n".join(parts) + "\n")


if __name__ == "__main__":
    main()
