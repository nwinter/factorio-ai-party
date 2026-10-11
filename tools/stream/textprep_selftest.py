#!/usr/bin/env python3
"""Checks for textprep.py (TTS text prep: spaces back, spoken forms) on real lines. No network:
python3 tools/stream/textprep_selftest.py [path/to/runs/shake2/chat.jsonl]

The lines below are Sol's chat from runs/shake2 (seq in the comment), copied verbatim; each goes through
voices.speakable() first, as caster.py does, then textprep.normalize()."""
import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
os.environ["POG_KEY_DIR"] = tempfile.mkdtemp(prefix="textprep-keys-")  # no keys: no model unless a test adds one
os.environ["POG_VOICE_STATE"] = tempfile.mkdtemp(prefix="textprep-state-")

import textprep, voices  # noqa: E402

fails = 0


def check(name, ok, detail=""):
    global fails
    fails += not ok
    print(("PASS " if ok else "FAIL ") + name + (f"\n     got: {detail}" if detail and not ok else ""))


def prep(line):
    return textprep.normalize(voices.speakable(line, 400))


# ---- the brief's examples ----
check("deadline17:59", textprep.normalize("deadline17:59") == "deadline 17:59", textprep.normalize("deadline17:59"))
check("fixingall12", textprep.normalize("fixingall12") == "fixing all 12", textprep.normalize("fixingall12"))
check("Coalchestisfull", textprep.normalize("Coalchestisfull") == "Coal chest is full",
      textprep.normalize("Coalchestisfull"))

# ---- real lines, whole output ----
REAL = [
    (237, "@sonnet Delivered2assemblers5electricinserters3poles sciencechest6.5,6.5. @opus Unjammed ore lane by removing "
          "oldcoal; full12furnace throughput shouldresume. My parts buffer(-58.5,-7.5) now availablefortakingplates. "
          "Returningsteelcell.",
     "sonnet Delivered 2 assemblers 5 electric inserters 3 poles science chest. opus Unjammed ore lane by removing old "
     "coal; full 12 furnace throughput should resume. My parts buffer now available for taking plates. Returning steel "
     "cell."),
    (269, "@sonnet I will deliver2assemblers5inserters1lab now; fetchingcopperandironfirst. @everyone Steeltechdone, "
          "checkingfirststeel. Minerrelocationtunnelunpaired despite4tilesdistance, inspectingbeforefix.",
     "sonnet I will deliver 2 assemblers 5 inserters 1 lab now; fetching copper and iron first. everyone Steel tech done, "
     "checking first steel. Miner relocation tunnel unpaired despite 4 tiles distance, inspecting before fix."),
    (259, "@sonnet @muse Trunkfixedgood! Please expand toatleast4red+4green assemblers immediately; "
          "onegreenat6/min makes100greenresearchtake17min, leavingnooiltime. I will supply4moreassemblersaftersteelstarts. "
          "Delivered2asms28m51 arestillavailableforredexpansion?",
     "sonnet muse Trunk fixed good! Please expand to at least 4 red plus 4 green assemblers immediately; one green at 6 "
     "per minute makes 100 green research take 17 minutes, leaving no oil time. I will supply 4 more assemblers after "
     "steel starts. Delivered 2 assemblers 28 minutes 51 are still available for red expansion?"),
    (343, "@astra All threeiron poles restored42m40; power42m56 reported1.56MW production+consumption on network2,0unpowered. "
          "Coal miner losses nowmaystarveboilers; @luna bring100emergencycoal toboilers(31.5,19),(35.5,19) ifpossible. "
          "I'm ongreen4power.",
     "astra All three iron poles restored 42 minutes 40; power 42 minutes 56 reported 1.56 megawatts production and "
     "consumption on network unpowered. Coal miner losses now may starve boilers; luna bring 100 emergency coal to "
     "boilers, if possible. I'm on green 4 power."),
    (385, "@astra Thanks NWscout, I willholdsciencefornow: all9labs greenempty50m07 despitefourgreenAMs, diagnosing. "
          "BothmyredAMs gotcopper60each50m07, enough10min. @everyone Engine96%thenfluidhandling/oilgathering; "
          "needfinalgreenpush.",
     "astra Thanks north-west scout, I will hold science for now: all 9 labs green empty 50 minutes 07 despite four green "
     "assemblers, diagnosing. Both my red assemblers got copper 60 each 50 minutes 07, enough 10 minutes. everyone "
     "Engine 96% then fluid handling / oil gathering; need final green push."),
    (394, "@luna Yes please courier20inserters each togreen3/4 aftermyAM2upgrade(~52m35). At9packs/min each "
          "they'lldraininsertersquickly. Stock30.5,-12.5, nowiron+circuitbeltlive; thanksGemini! "
          "EngineAMpairrunningafterresearch51m25.",
     "luna Yes please courier 20 inserters each to green 3/4 after my assembler 2 upgrade (about 52 minutes 35). At 9 "
     "packs per minute each they'll drain inserters quickly. Stock, now iron and circuit belt live; thanks Gemini! Engine "
     "assembler pair running after research 51 minutes 25."),
    (92, "@luna Coal demand now ~150/min across iron/copper furnaces+miners; each self-fueling drill nets~21/min. Need at "
         "least8 coal drills until electric. I can provide iron for expansion. Please own coal scaling; let Haiku deliver.",
     "luna Coal demand now about 150 per minute across iron / copper furnaces and miners; each self-fueling drill nets "
     "about 21 per minute. Need at least 8 coal drills until electric. I can provide iron for expansion. Please own coal "
     "scaling; let Haiku deliver."),
    (408, "@gemini Thankyou70ironkeepsthose2redscienceAMsrunning3min. @everyone SEscout300,300 safe, nooilwithin64tiles. "
          "Continuingtoward(500,450) whileoil-gatheringruns.",
     "gemini Thank you 70 iron keeps those 2 red science assemblers running 3 minutes. everyone south-east scout 300,300 "
     "safe, no oil within 64 tiles. Continuing toward while oil-gathering runs."),
]
for seq, line, want in REAL:
    got = prep(line)
    check(f"shake2 #{seq}", got == want, got)

# ---- real lines, key phrases (seq 345, 364, 412, 424) ----
PARTS = [
    ("@muse Green4 nowpowered by pole(20.5,16.5), AMworking; added2inserters. Output(17.5,15.5) currentlyfacesN,"
     "picksN/dropS backintoAM; rotate180 required",
     ["Green 4 now powered by pole, assembler working; added 2 inserters", "faces north, picks north / drop south",
      "back into assembler; rotate 180"]),
    ("@luna Gearinputfullthanks, rawinputcoverage~6min. Myred belt nowlive via y14.5→14.5,12.5→inserter15.5,12.5→"
     "green3lab17.5,12.5; manual4redsseeded.",
     ["Gear input full thanks, raw input coverage about 6 minutes", "My red belt now live", "manual 4 reds seeded"]),
    ("@luna Thanks184ironcombinedwithSonnet replenishedgearcoverage. I respawnedempty; "
     "willcouriergreen fromAM2bufferedoutputs towesternlabs.",
     ["Thanks 184 iron combined with Sonnet replenished gear coverage", "respawned empty",
      "will courier green from assembler 2 buffered outputs to western labs"]),
    ("@everyone Finalhandoff: Solrepeatcourier active, keeps1green inAM2outputs andfeedswesternlabsupto2each. "
     "Oilgather32%57m00.",
     ["Final handoff: Sol repeat courier active, keeps 1 green in assembler 2 outputs and feeds western labs up to 2 each",
      "Oil gather 32% 57 minutes."]),
]
for line, wants in PARTS:
    got = prep(line)
    miss = [w for w in wants if w not in got]
    check(f"shake2 phrases: {wants[0][:40]}", not miss, f"{got}  (missing {miss})")

# ---- clean lines stay as written (other agents in shake2, plus caster-style lines) ----
CLEAN = [
    "Astra taking copper mining and smelting. Will supply plates and expand electric copper when power arrives.",
    "Labs are hungry and I'm the only one feeding them!",
    "Swapping to piercing ammo when we have steel to spare.",
    "Big push on the west wall, and Grok is holding the line!",
    "Red science is flowing, and Gemini just kicked off oil processing.",
    "That is 1,000 plates by the 2nd hour.",
]
for line in CLEAN:
    check(f"unchanged: {line[:40]}", textprep.normalize(line) == line, textprep.normalize(line))

# ---- pieces ----
n = textprep.normalize
check("units and rates", n("540kW soon, 1.5MW total, 189/min") == "540 kilowatts soon, 1.5 megawatts total, 189 per minute",
      n("540kW soon, 1.5MW total, 189/min"))
check("plural acronym glued to the next word", n("feed all green AMsto8input") == "feed all green assemblers to 8 input",
      n("feed all green AMsto8input"))
check("contractions", n("you'dneed to move") == "you'd need to move", n("you'dneed to move"))
check("ordinals stay", n("the 2nd and 3rd lab") == "the 2nd and 3rd lab")
check("report number", n("report #13 filed") == "report number 13 filed", n("report #13 filed"))
check("unknown short names are left alone", n("Kovarex and Nauvis") == "Kovarex and Nauvis")
check("glued() finds glue", textprep.glued("availablefortakingplates") >= 1 and textprep.glued("plates for taking") == 0)
check("speakable keeps a space where a coordinate was",
      voices.speakable("30 more iron in chest -58.5,-23.5 for you") == "30 more iron in chest for you",
      voices.speakable("30 more iron in chest -58.5,-23.5 for you"))
check("speakable keeps ~ before a number (captions show the original)", voices.speakable("~90 belts") == "~90 belts")

# ---- the model fallback may only add spaces ----
calls = []


def spacer(prompt, text):
    calls.append(text)
    return "Factory may get occasional copper on iron trunk."


def liar(prompt, text):
    return "The factory never gets copper on the iron trunk."


def broken(prompt, text):
    raise TimeoutError("slow")


r = textprep.Respacer(ask=spacer)
r("factorymaygetoccasionalcopperonirontrunk.")  # the heuristics split this one: no model call
check("no model call when the heuristics manage", calls == [], str(calls))
r("Zzqxwvglorpfactorymaygetoccasionalcopperonirontrunk.")  # a non-word piece stays glued: the model is asked
check("model asked when a long glued token is left", len(calls) == 1 and r.stats["model_rejected"] == 1, str(r.stats))
r2 = textprep.Respacer(ask=liar)
w = "Ironratenowxqzzyafterunjam"
got = r2(w)
check("a model answer that changes letters is rejected", got == textprep.normalize(w) and r2.stats["model_rejected"] <= 1,
      got)
r3 = textprep.Respacer(ask=broken)
check("a failing model falls back to the heuristic text", r3("Ironratenowxqzzyafterunjam") == textprep.normalize(w))
r4 = textprep.Respacer(ask=lambda p, t: "Iron rate now xqzzy after unjam")
check("a spaces-only answer is used and then normalized", r4(w) == "Iron rate now xqzzy after unjam"
      and r4.stats["model"] == 1, r4(w))
r4.ask = None
check("model answers are cached per line", r4(w) == "Iron rate now xqzzy after unjam")
check("same_but_spaces", textprep.same_but_spaces("abc def", "a b c d e f") and
      not textprep.same_but_spaces("abc", "abd"))
check("no model without keys or Workers AI", voices.respace_model(None) is None)
os.environ["POG_RESPACE"] = "0"
check("POG_RESPACE=0 turns the model off", voices.respace_model(None) is None)
del os.environ["POG_RESPACE"]

# ---- through TTS.speak: TTS gets the prepared text, the caller keeps its own ----
said = []
orig_tone = voices._tone
voices._tone = lambda text, voice: (said.append(text), orig_tone(text, voice))[1]
tts = voices.TTS("tone")
caption = voices.speakable("@grok Coalchestisfull, Delivered2assemblers at -58.5,-23.5 now")
tts.speak(caption, "orion")
check("speak() reads the prepared text (then the lexicon)",
      said[-1] == "Grock Coal chest is full, Delivered 2 assemblers now", said[-1])
check("the caption is untouched", caption == "grok Coalchestisfull, Delivered2assemblers now", caption)
voices._tone = orig_tone

# ---- the whole shake2 chat, when available ----
path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "..", "..", "player-of-games", "runs", "shake2",
                                                          "chat.jsonl")
if os.path.exists(path):
    rows = [json.loads(x) for x in open(path) if x.strip()]
    sol = [r for r in rows if r.get("from") == "sol"]
    before = [textprep.glued(voices.speakable(r["text"], 400)) for r in sol]
    after = [textprep.glued(prep(r["text"])) for r in sol]
    gl = sum(1 for b in before if b)
    still = sum(1 for b, a in zip(before, after) if b and a)
    print(f"     shake2: {len(sol)} Sol lines, {gl} glued; still glued after prep: {still}")
    check("shake2: at least 95% of Sol's glued lines come out unglued", gl and still <= 0.05 * gl, f"{still}/{gl}")
else:
    print(f"     (skipped the whole-chat check: {path} not found)")

print(f"\n{'all passed' if not fails else f'{fails} failed'}")
sys.exit(1 if fails else 0)
