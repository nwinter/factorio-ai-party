"""Rolling stream state built from normalized observations (live or mock).

An observation is a dict:
  tick, paused, game_seconds
  agents: [{name, kind, display_name, color, glyph, motto, position{x,y}, alive, dead_until_tick,
            active (action kind or False), last {kind, outcome, tick}, combat, last_said {text, tick}}]
  chat: [{seq, tick, from, text}]                  (any window; deduplicated by seq)
  research: {current, progress, done [names], top_done [names]}
  produced: {item: total}                          (from tools/pog.py score)
  flows: {item: [per-2-minute counts, oldest first]} (optional, refreshed slowly)
  power: {machines, starved}                       (optional)
  events: [{kind: attack|loss|death|info, agent?, text, key?, ttl?, position?}] (optional)
  board_events: [{seq, tick, by, id, change, title, kind?, progress?, steps_done?, steps_total?}] (optional; docs/BOARD-API.md)
  board: {items: [...], open_unowned, plan} (optional, refreshed slowly; docs/BOARD-API.md; project items carry progress)
"""
import datetime, json, math, os, re, time
from collections import deque

import attention
import chronicle_log
import pacing
import waitcard
import workcard
import viewer_replies
import clouds as clouds_mod
import loadout as loadouts_mod
import efficiency as efficiency_mod
import tokens

FIGHT_EPISODE_GAP = 45.0  # seconds without a report: the next report at the same key is a new fight
ATTENTION_TTL = 120.0  # seconds: an attention point older than this is no longer where the agent is looking

HALF_LIFE = 75.0  # seconds; interest decays toward 0 with this half-life
ACTION_WEIGHT = {
    "build": 3.0, "place": 3.0, "construct": 3.5, "blueprint": 4.0, "build_blueprint": 4.0, "rotate": 1.0,
    "mine": 1.2, "craft": 1.0, "insert": 1.2, "take": 1.0, "feed": 1.2, "walk": 0.6, "path": 0.6,
    "attack": 6.0, "shoot": 6.0, "kite": 6.0, "research": 2.0, "wait_until": 0.2, "wait": 0.2,
    "guard": 0.3,  # a shoot with nothing in range (combat_state)
}
SCIENCE = ["automation-science-pack", "logistic-science-pack", "military-science-pack", "chemical-science-pack",
           "production-science-pack", "utility-science-pack", "space-science-pack",
           # Space Age: one pack per planet, then promethium from the edge of the system
           "metallurgic-science-pack", "electromagnetic-science-pack", "agricultural-science-pack",
           "cryogenic-science-pack", "promethium-science-pack"]
SPACE_PACKS = SCIENCE[6:]
# Science per minute as players say it (viewer joonazan, operator 15:51): research throughput, the labs' use of
# science packs in sets. Every 2.0 technology takes one of each of its packs per unit (243 of 243 with units in the
# 2.0.77 data) and one technology runs at a time, so the units are the count of the pack the labs used most. The
# agricultural pack spoils, and its count runs ahead of the others (shift12: the labs' agricultural count rose 3942
# while red rose 2149), so it is left out unless nothing else was used.
SPOILING_PACKS = {"agricultural-science-pack"}


def research_units(used):
    """Research units from the packs the labs used ({pack: count or rate}): the most-used pack that does not spoil."""
    vals = [v or 0 for k, v in used.items() if k not in SPOILING_PACKS]
    best = max(vals, default=0)
    return best if best > 0 else max((v or 0 for v in used.values()), default=0)


HISTORY_S = 60  # game seconds: a line in the first chat read (the backlog at a restart) older than this is history
CHAT_LOG_TAIL = 4 << 20  # bytes of runs/RUN/chat.jsonl read for restored lines' times (about 15000 lines)
MAIDEN_STALE_S = 120  # game seconds: a platform_left read later than this (a restart catching up) is not shown
PLANET_LABELS = {"nauvis": "Nauvis", "vulcanus": "Vulcanus", "fulgora": "Fulgora", "gleba": "Gleba", "aquilo": "Aquilo",
                 "solar-system-edge": "Solar system edge", "shattered-planet": "Shattered Planet"}
# Items the production widget can show, by game stage (0 raw .. 5 rocket). The widget leads with science per minute
# and fills the rest with what is being made now, favouring the stage the factory has reached.
STAGE_ITEMS = [
    (0, ["iron-plate", "copper-plate", "stone-brick", "iron-ore", "copper-ore", "coal", "stone"]),
    (1, ["iron-gear-wheel", "copper-cable", "electronic-circuit", "transport-belt", "inserter"]),
    (2, ["steel-plate", "firearm-magazine", "piercing-rounds-magazine", "stone-wall", "engine-unit"]),
    (3, ["plastic-bar", "sulfur", "advanced-circuit", "battery", "solid-fuel"]),
    (4, ["processing-unit", "electric-engine-unit", "flying-robot-frame", "low-density-structure", "rocket-fuel"]),
    (5, ["rocket-part", "satellite"]),
]
ITEM_STAGE = {n: s for s, names in STAGE_ITEMS for n in names}
# Stage 3 was "Oil": shake5's hosts read it as "the oil is dry" an hour after blue science started
STAGE_LABELS = ["Raw resources", "Automation", "Steel & logistics", "Oil & blue science", "Advanced", "Rocket"]
SCIENCE_STAGE = {"automation-science-pack": 1, "logistic-science-pack": 2, "military-science-pack": 2,
                 "chemical-science-pack": 3, "production-science-pack": 4, "utility-science-pack": 4,
                 "space-science-pack": 5, **{n: 5 for n in SCIENCE[7:]}}
SPARK_ITEMS = [n for _, names in STAGE_ITEMS for n in names] + SCIENCE
VERBS = {"build": "building", "place": "placing", "construct": "constructing", "build_blueprint": "placing blueprint",
         "blueprint": "placing blueprint", "mine": "mining", "craft": "crafting", "insert": "loading", "take": "taking",
         "feed": "feeding", "walk": "walking", "path": "walking", "move_to": "walking", "gather": "gathering",
         "build_path": "building", "repair": "repairing", "deconstruct": "removing", "follow": "following", "shoot": "fighting", "attack": "fighting", "kite": "fighting",
         "rotate": "rotating", "wait_until": "waiting", "wait": "waiting", "research": "researching"}
THINK_WINDOW = 90  # seconds after an action ends during which an inactive agent counts as "thinking"
CHANGELOG_RE = re.compile(r"^\s*(?:server:\s*)?harness (v[\w.]+):\s*(.+)$", re.I)  # operator chat "server: harness vN: ..."
BOARD_STATUS = {"posted": "open", "taken": "claimed", "assigned": "claimed", "started": "doing", "done": "done",
                "blocked": "blocked", "dropped": "dropped", "reopened": "open", "released": "open"}


def board_verb(change):
    """A board event's `change` -> posted | taken | started | done | blocked | dropped | reopened | note | step |
    updated. The contract leaves `change` loose, so accept "posted", "status:done", "owner:astra", {"status": "done"},
    ...; a project's step_done is a step (its other step_* changes, goal, handoff and areas are updates)."""
    if isinstance(change, dict):
        change = ("status:" + str(change["status"]) if change.get("status") else "owner" if change.get("owner")
                  else "note" if change.get("note") else "")
    c = str(change or "").lower()
    if c.startswith("step_"):
        return "step" if c == "step_done" else "updated"
    if c in ("goal", "handoff", "areas"):
        return "updated"
    for verb, words in (("posted", ("post", "creat", "new")), ("done", ("done", "complet", "finish")),
                        ("blocked", ("block",)), ("dropped", ("drop", "cancel")), ("started", ("doing", "start")),
                        ("assigned", ("assign",)), ("released", ("release",)),
                        ("taken", ("take", "took", "claim", "owner")), ("reopened", ("open",)), ("note", ("note",))):
        if any(w in c for w in words):
            return verb
    return "updated"


PROGRESS_RE = re.compile(r"^(\d+) of (\d+) steps?$")


def lost_details(ev):
    """A harness platform_lost event (chronicle.lua) as the stream's loss facts: where (a stop or the leg flown), cause
    (what killed the hub), cargo ("400 iron-plate, 20 rocket-fuel, +3 kinds"), hit_by (the asteroid kinds that hit it
    most)."""
    cargo = [c for c in ev.get("cargo") or [] if isinstance(c, dict)]
    more = (ev.get("cargo_kinds") or 0) - len(cargo)
    text = ", ".join(f"{c.get('count')} {c.get('name')}" for c in cargo) + (f", +{more} kinds" if more > 0 else "")
    hits = [h.get("name") for h in ev.get("hit_by") or [] if isinstance(h, dict) and h.get("name")]
    out = {"where": ev.get("where"), "cause": ev.get("by"), "cargo": text or "empty", "cargo_items": ev.get("cargo_items") or 0,
           "hit_by": ", ".join(hits) or None}
    return {k: v for k, v in out.items() if v is not None}


def project_next(steps):
    """A project's next step from a board row's next_steps ("[ ] build 8 furnaces"), the box left off; None if none."""
    if not isinstance(steps, list) or not steps:
        return None
    return clean_text(re.sub(r"^\[[ x]\]\s*", "", str(steps[0]))) or None


STEP_RE = re.compile(r"^\[(x| )\]\s*(?:(\d+)\.\s*)?(.*?)(?:\s+\(done by ([^,()]+), ([^()]+?) ago\))?\s*$", re.S)
STEPS_MAX, STEP_TEXT = 30, 200


STEP_TAIL_RE = re.compile(r"\s+\(([A-Za-z][\w.-]*)\)$")


def parse_steps(steps, known=None):
    """A project's steps as the board shows them ("[x] 3. Lay the belt (sol) (done by sol, 5m00s ago)", "[ ] 4. Feed
    coal (luna) (parallel)") -> [{n, text, done, by, ago, owner, parallel}], at most STEPS_MAX, each text cut to
    STEP_TEXT. A step's own owner is a trailing "(name)" that known(name) accepts (the team's names), and "(parallel)"
    marks a step with no order between it and its parallel neighbours (d15 batch5 J2, viewer Foobator). The first step
    not done is next, and so are the parallel steps right after it when it is parallel itself."""
    out = []
    for s in (steps if isinstance(steps, list) else [])[:STEPS_MAX]:
        m = STEP_RE.match(str(s))
        if not m:
            continue
        text = clean_text(m.group(3)).strip()  # (after the match: clean_text takes "[x]" for a rich-text tag)
        owner, parallel = None, False
        for _ in range(2):
            t = STEP_TAIL_RE.search(text)
            if not t:
                break
            word = t.group(1)
            if word == "parallel" and not parallel:
                parallel = True
            elif owner is None and known is not None and known(word):
                owner = word
            else:
                break
            text = text[:t.start()].rstrip()
        row = {"n": int(m.group(2)) if m.group(2) else None, "text": text[:STEP_TEXT], "done": m.group(1) == "x"}
        if owner:
            row["owner"] = owner
        if parallel:
            row["parallel"] = True
        if m.group(4):
            row["by"], row["ago"] = m.group(4).strip(), m.group(5).strip()
        out.append(row)
    for i, r in enumerate(out):
        if not r["done"]:
            r["next"] = True
            for r2 in out[i + 1:] if r.get("parallel") else []:
                if r2["done"]:
                    continue
                if not r2.get("parallel"):
                    break
                r2["next"] = True
            break
    return out


def project_steps(progress, done=None, total=None):
    """A project's steps done and in all, from an event's numbers or its progress text ("3 of 7 steps", "no steps
    yet": 0, 0); None, None when neither says."""
    if isinstance(done, int) and isinstance(total, int):
        return done, total
    m = PROGRESS_RE.match(str(progress or ""))
    if m:
        return int(m.group(1)), int(m.group(2))
    return (0, 0) if progress == "no steps yet" else (None, None)


def clean_text(s):
    return re.sub(r"\[/?[a-z-]+(=[^\]]*)?\]", "", s or "")


def evidence_lines(v):
    """(d19 batch42-43 A2; batch41 B2's evidence.lua) a board item's or reminder's evidence as the runtime gives it, one
    line each ("by sol 12m ago: metric PU 600/min (tick ...); decision ...; next check ..."), oldest first, whole; None
    without any."""
    if not isinstance(v, list):
        return None
    out = [clean_text(str(x)).strip() for x in v if isinstance(x, (str, int, float)) and str(x).strip()]
    return out or None


def with_evidence(row):
    """{"evidence": lines} for a row that has any, else {} (no key)."""
    ev = evidence_lines((row or {}).get("evidence"))
    return {"evidence": ev} if ev else {}


try:  # eng/audio's local classifier, so the overlay and the casters agree on what is conversation
    from caster import heuristic_kind
except Exception:  # caster.py missing or failing to import: everything from agents counts as talk
    heuristic_kind = None


def chat_lane(entry):
    """'talk' (banter, strategy, emotion, `aloud`, confessionals: the big chat lane), 'operator' (the operator's own
    lines, from `server`), 'notice' (harness notices: votes
    and their results, humans joining and leaving; shown in the chat feed), 'log' (coordinates, counts,
    acknowledgements, server lines: not shown), or 'viewer' (a viewer line relayed into the game chat: the feed shows it
    once, from the viewers list)."""
    frm = (entry.get("from") or "").lower()
    if entry.get("notice"):  # a harness notice ("vote: ...", "players: ..."; votes.lua, players.lua)
        return "notice"
    if entry.get("viewer") or frm.startswith("viewer") or clean_text(entry.get("text")).lower().startswith("viewer "):
        return "viewer"
    # the operator writes in game chat as `server` (shift01 16:25, thanking a viewer): shown, pinned and voiced as the
    # Operator; "harness vN: ..." changelog lines stay with the board panel
    if frm == "server" and not entry.get("agent") and not CHANGELOG_RE.match(clean_text(entry.get("text"))):
        return "operator"
    if entry.get("confess") or entry.get("aloud"):
        return "talk"
    if not entry.get("agent"):
        return "log"
    if heuristic_kind is None:
        return "talk"
    return "talk" if heuristic_kind(clean_text(entry.get("text")))[0] == "voice" else "log"


# What an agent's shoot is doing (viewer Joonazan, 13:36: "I'm pretty sure biters are not hitting anyone on Gleba";
# the stream called Sol's shoot auto guard by the egg breeders, nothing in range, "under attack"). From status combat
# (target, fired_tick, kills_10s) and hurt (the last hit by another force on the character or its vehicle):
HURT_S = 15.0   # a hit this many game seconds ago or less: "X is under attack"
FIRED_S = 10.0  # fired at something this recently (or a target in range now, or a kill): "X is fighting <enemy>"
DAMAGE_TYPES = {"physical", "acid", "fire", "explosion", "poison", "laser", "electric", "impact", "enemy"}


def combat_state(combat, hurt, tick):
    """-> (state, info). state: "hurt" (hit in the last HURT_S), "fighting" (a target, a shot or a kill lately),
    "guard" (a shoot running with nothing to shoot at) or None. info: {by, what} for hurt, {target, position} for a
    fight. `combat` True (the mock, a row with no detail) is the old meaning: hit. A runtime from before these
    fields: a shoot at a position fights, an auto shoot guards."""
    h = hurt if isinstance(hurt, dict) else (combat.get("hurt") if isinstance(combat, dict) else None)
    if isinstance(h, dict) and isinstance(h.get("tick"), (int, float)) and isinstance(tick, (int, float)) \
            and tick - h["tick"] <= HURT_S * 60:
        by = h.get("by") if h.get("by") not in DAMAGE_TYPES else None
        return "hurt", {"by": by, "what": h.get("what")}
    if combat is True:
        return "hurt", {}
    if not isinstance(combat, dict) or not combat:
        return None, {}
    t = combat.get("target") if isinstance(combat.get("target"), dict) else {}
    fired = combat.get("fired_tick")
    recent = isinstance(fired, (int, float)) and isinstance(tick, (int, float)) and tick - fired <= FIRED_S * 60
    if t.get("name") or recent or (combat.get("kills_10s") or 0) > 0:
        return "fighting", {"target": t.get("name"), "position": t.get("position")}
    if "kills_10s" not in combat:
        return ("guard" if combat.get("auto") else "fighting"), {}
    return "guard", {}


def enemy_label(name):
    """"small-biter" -> "a small biter", "gleba-spawner" -> "a gleba spawner"; None -> None."""
    if not name:
        return None
    n = str(name).replace("-", " ")
    return ("an " if n[:1].lower() in "aeiou" else "a ") + n


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def planet_label(name):
    return PLANET_LABELS.get(name) or (name or "?").replace("-", " ").capitalize()


def where_label(surface, platform=None):
    """An agent's surface for viewers: the platform's name on a platform, else the planet."""
    return platform or planet_label(surface)


def pack_label(item):
    return item.replace("-science-pack", "").replace("-", " ").capitalize() + " science"


def fmt_count(n):
    return f"{n / 1000:.1f}k".replace(".0k", "k") if n >= 1000 else str(int(n))


AT_RE = re.compile(r"^([\w-]+)->([\w-]+) (\d+)%$")


# Buildings only a space platform has, and asteroid attackers: a loss line (no surface) with one of these is on a platform
SPACE_HIT = re.compile(r"space platform hub|space-platform-hub|asteroid collector|asteroid-collector|thruster|crusher|"
                       r"asteroid", re.I)
HUB_LOST = re.compile(r"space[ -]platform[ -]hub", re.I)


def platform_place(p):
    """Where a platform is, for the hosts: "in orbit of Vulcanus", "travelling from Nauvis to Vulcanus"."""
    w = platform_where(p)
    if w["route"]:
        return f"travelling from {w['route']['from']} to {w['route']['to']}"
    return f"in orbit of {w['where']}" if w["where"] and w["where"] != "in transit" else "in transit"


# The harness's platform defence as text (space.lua platforms {platform}, platalerts.lua defense): "860/1000",
# "5 gun-turrets: 4 empty, 0 low (under 10 rounds)", "turrets hold 120 rounds, the hub firearm-magazine 920, ...";
# hub_items and repair_packs as "name*count name@quality*count ... +N more".
PLAT_HP = re.compile(r"^\s*(\d+)\s*/\s*(\d+)")
PLAT_GUNS = re.compile(r"^(\d+)\s[^:]*:\s*(\d+) empty,\s*(\d+) low")
PLAT_ROUNDS = re.compile(r"turrets hold (\d+) rounds?")
PLAT_STACK = re.compile(r"([a-z0-9][\w-]*)(?:@[\w-]+)?\*(\d+)")
NOT_CARGO = re.compile(r"magazine|ammo|rounds|repair-pack|cannon-shell|rocket$|^rocket\b|railgun-ammo", re.I)
STORY_CARGO = re.compile(r"science-pack$|egg$")


def story_cargo(hub_items):
    """Science packs and eggs in a hub's items text, the largest first: "1200 agricultural science pack, 20 biter egg";
    "" for none."""
    got = {}
    for n, c in PLAT_STACK.findall(str(hub_items or "")):
        if STORY_CARGO.search(n):
            got[n] = got.get(n, 0) + int(c)
    return ", ".join(f"{c} {n.replace('-', ' ')}" for n, c in sorted(got.items(), key=lambda x: -x[1]))
HITS_WINDOW_MIN = 5  # status alerts cover the last 5 game minutes (whole minutes): hits per minute over that


AMMO_OUT = re.compile(r"^([\w-]+):.*?runs out in (?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)? at that rate, before the arrival")
DANGER_HIT_S = 60     # a hit on the hub this recent (game seconds) is a platform under fire
DANGER_LOSS_S = 120   # buildings lost this recently (seconds) too


def ammo_runout(lines):
    """The platforms read's ammo_rates lines (space.lua; round2250b) -> (seconds, ammo) for the ammo that runs out
    first before the arrival ("firearm-magazine: made 0/min, used 35/min ...; runs out in 4m09s at that rate, before the
    arrival at gleba in 75m00s"), or None when none does."""
    best = None
    for line in lines if isinstance(lines, list) else []:
        m = AMMO_OUT.match(str(line))
        if m:
            s = int(m[2] or 0) * 3600 + int(m[3] or 0) * 60 + int(m[4] or 0)
            if best is None or s < best[0]:
                best = (s, m[1])
    return best


def minutes_text(s):
    return "under a minute" if s < 60 else f"{math.ceil(s / 60)} min"


def platform_danger(name, hits, losses, ammo_lines, tick, now, hub_pct=None):
    """What puts a platform in danger now, for onecam's danger shot (viewer joonazan, d15 10:45: "show the ship only
    when something happens, e.g. ammo running dry"); the facts urgent.lua wakes agents on, as the stream sees them:
    - fire: its hub was hit in the last DANGER_HIT_S game seconds (status alerts' platform_hits: damage by entity), or
      buildings on it were lost in the last DANGER_LOSS_S (loss events naming it) -> {kind: fire, reason: "Wayfarer under
      fire: 3 buildings lost" / "Wayfarer under fire: hub hit, hub 62%", last (wall time of the latest), level};
    - ammo: else, an ammo type that runs out before the arrival (ammo_rates) -> {kind: ammo, reason: "Wayfarer ammo for 2
      min", runs_out_s, ammo, level}.
    None otherwise."""
    lost, lost_t = 0, None
    for total, t in (losses or {}).values():
        if now - t <= DANGER_LOSS_S:
            lost += total
            lost_t = max(lost_t or t, t)
    hub_t = None
    if hits and "space-platform-hub" in str(hits.get("entities") or "") and isinstance(hits.get("last_tick"), (int, float)) and tick:
        ago = (tick - hits["last_tick"]) / 60
        if 0 <= ago <= DANGER_HIT_S:
            hub_t = now - ago
    if lost or hub_t:
        parts = [f"{lost} building{'s' if lost != 1 else ''} lost"] if lost else []
        if hub_t:
            parts.append("hub hit" + (f", hub {hub_pct}%" if isinstance(hub_pct, (int, float)) and hub_pct < 100 else ""))
        return {"kind": "fire", "reason": f"{name} under fire: " + "; ".join(parts), "last": max(t for t in (lost_t, hub_t) if t),
                "level": lost * 1000 + (100 - (hub_pct if isinstance(hub_pct, (int, float)) else 100))}
    out = ammo_runout(ammo_lines)
    if out:
        return {"kind": "ammo", "reason": f"{name} ammo for {minutes_text(out[0])}", "runs_out_s": out[0], "ammo": out[1],
                "level": -out[0]}
    return None


def platform_card(p, hits=None, aboard=(), working=()):
    """A platform row for the Space widget: platform_where plus its defence, repair packs, damaged count, cargo
    highlights, asteroid hits per minute and who is aboard or working on it from the ground. Unknown parts are left
    out (the score's rows between platform reads have only the name and where)."""
    card = platform_where(p)
    card["drifting"] = bool(p.get("paused") and card["route"])  # paused on a route: drifts back among its asteroids
    d = p.get("defense") or {}
    m = PLAT_HP.match(str(d.get("hub_health") or ""))
    if m and int(m[2]):
        card["hub"] = {"hp": int(m[1]), "max": int(m[2]), "pct": round(100 * int(m[1]) / int(m[2]))}
    elif isinstance((p.get("view") or {}).get("hub_health"), (int, float)):
        card["hub"] = {"pct": int(p["view"]["hub_health"])}
    guns = str(d.get("turrets") or "")
    m = PLAT_GUNS.match(guns)
    if m:
        total, empty, low = int(m[1]), int(m[2]), int(m[3])
        card["guns"] = {"total": total, "armed": total - empty, "empty": empty, "low": low}
    elif guns == "none":
        card["guns"] = {"total": 0, "armed": 0, "empty": 0, "low": 0}
    ammo = str(d.get("ammo") or "")
    m = PLAT_ROUNDS.search(ammo)
    if m:
        hub_part = ammo.split("the hub", 1)[1] if "the hub" in ammo else ""
        hub_n = sum(int(x) for x in re.findall(r"(?<![+\w])(\d+)\b(?! more)", hub_part)) if "no ammo" not in hub_part else 0
        card["ammo"] = {"turrets": int(m[1]), "hub": hub_n}
    if p.get("repair_packs") is not None:
        card["repair"] = sum(int(n) for _, n in PLAT_STACK.findall(str(p["repair_packs"])))
    dmg = p.get("damaged_count") or len(p.get("damaged") or [])
    if p.get("defense") is not None or dmg:
        card["damaged"] = dmg
    cargo = [{"item": n, "count": int(c)} for n, c in PLAT_STACK.findall(str(p.get("hub_items") or ""))
             if not NOT_CARGO.search(n)]
    if cargo:
        card["cargo"] = cargo[:3]
    if hits and hits.get("hits"):
        card["hits_per_min"] = round(hits["hits"] / HITS_WINDOW_MIN, 1)
        if hits.get("by"):
            card["hit_by"] = str(hits["by"]).split(",")[0].strip()
    if aboard:
        card["aboard"] = list(aboard)
    if working:
        card["working"] = list(working)
    return card


def platform_where(p):
    """A platform row (score + `platforms` detail) for the page: where it is or its route with progress, speed.
    `at` is a location name or "from->to N%" (space.lua); speed is LuaSpacePlatform.speed, shown x60 as km/s.
    "from->to" are the space connection's ends and N its distance from `from`, whichever way the platform flies:
    `toward` (Model._orient_platforms) is where it is headed; toward `from`, the route and progress turn round."""
    at = p.get("at") or ""
    m = AT_RE.match(at)
    route = None
    if m:
        a, b, pct = m[1], m[2], int(m[3])
        if p.get("toward") == a:  # Sunward 14:09, Vulcanus to Nauvis on nauvis->vulcanus: not "leaving Nauvis"
            a, b, pct = b, a, 100 - pct
        route = {"from": planet_label(a), "to": planet_label(b), "pct": pct}
    where = f"{route['from']} → {route['to']}" if route else planet_label(at) if at and at != "in transit" else "in transit"
    speed = p.get("speed")
    out = {"name": p.get("name"), "where": where, "route": route, "state": p.get("state"), "paused": bool(p.get("paused")),
            "speed_kms": round(speed * 60) if isinstance(speed, (int, float)) and speed else None, "view": p.get("view")}
    if route:  # (d20 batch57 S3) the route's location names, origin first (edgedense.py: the edge legs' dense part)
        out["route_ids"] = [a, b]
    return out


# notes.md "## Now" (the agents' own state for their next turn) opens with the clock more often than the job: shift05
# Astra "Game16h40, deadline2026-10-13 10:56PDT (~2h57 remaining). Nauvis position69.86,64.58,8deaths, ... Main job
# Peregrine ferry aboveVulcanus plus east/south defense.", Haiku "Deadline 10:56 PDT (2h58m left ...). Goal: keep
# burners, furnaces and boilers fuelled; ..."
CLOCKISH = re.compile(r"deadline|remaining|\bleft at\b|\bgame ?\d+h|\b\d+h\d+m?\b|\bP[DS]T\b|\bUTC\b|position ?-?\d|"
                      r"\d+ ?deaths|^deaths?\b|^shift ?\d|^tick\b|^(game )?time\b|^next( concrete)? steps?\b|`|^\d+\.$|"
                      r"^(do not|don'?t|never)\b|^sleep \d",
                      re.I)
JOBISH = re.compile(r"^((main|current|my)\s+)?(job|goal|task|focus|role)s?\b[\s:,-]*|^(doing|working on|now|currently)\b"
                    r"[\s:,-]*", re.I)


def notes_job(md, limit=90):
    """The agent's job from its notes.md: the first sentence of "## Now" that names a job ("Main job ...", "Goal: ..."),
    else its first sentence that is not the clock, deadline or position; trimmed. None without a usable line."""
    m = re.search(r"^##\s*Now\b[^\n]*\n(.*?)(?=^##\s|\Z)", md or "", re.M | re.S)
    if not m:
        return None
    sents = [s.strip(" -*•\t") for line in m.group(1).splitlines() for s in re.split(r"(?<=[.;!?])\s+", line)]
    sents = [s for s in sents if len(s) >= 6 and not CLOCKISH.search(s)]
    if not sents:
        return None
    pick = next((s for s in sents[:4] if JOBISH.match(s)), sents[0])  # (further down: older shifts' lines)
    pick = JOBISH.sub("", pick, count=1).strip().rstrip(".;")
    pick = pick[:1].upper() + pick[1:]
    return pick if len(pick) <= limit else pick[:limit - 1].rsplit(" ", 1)[0] + "…"


DETAIL_ZOOM = (0.55, 1.0)  # (d20 batch50 A2) a detail pan's zoom: at least 0.55 (gun turrets ~35 px, small asteroids
#                            ~18 px at 1080p), at most 1.0
DETAIL_CROSS_S = 15.0       # a detail pan moves one view height in this long (~70 px/s at 1080p)
DETAIL_BOW_S = 8.0          # a detail pan rests this long on the bow first, where asteroids come from in flight
# (d22 batch99 BI4, viewer Foobator site:4332: "the camera up and down on ships does not show enough north and south
# for large ships like asterion") a detail pan longer than this many view heights is not used: Asterion in flight
# (60 x 275 tiles of hull, guns reaching 37 ahead) was a 0.55 view 62 tiles high panning 254 tiles at 4.1 tiles/s,
# 70 s from bow to stern, so a 20 s visit showed its bow and a quarter of the hull. Such a ship gets the whole-frame
# shot instead: the zoom that fits it (at least 0.3, cameras.lua's least: 113 tiles high) and the pan over the shot
# (OneCam pan_y, and a visit held long enough for one view height in PAN_VIEW_S).
LONG_VIEWS = 2.5


def gun_reach(view):
    """(d20 batch50 A1) The box the platform's guns reach: each turret's position +- its range (view guns, from the
    prototypes with quality), with the ship's bounds; None when the view has no guns read (an older read: the shot
    frames as before) or no turrets."""
    guns = view.get("guns")
    if not guns:
        return None
    left = min(g["x"] - g["range"] for g in guns)
    top = min(g["y"] - g["range"] for g in guns)
    right = max(g["x"] + g["range"] for g in guns)
    bottom = max(g["y"] + g["range"] for g in guns)
    return left, top, right, bottom


def platform_shot(view, margin=10.0, *, travelling=False, frac=1.0):
    """A camera shot of a whole platform from its view (live.py PLATFORM_LUA): the centre of its entities' bounds on
    its surface, at the zoom that fits them. A director client at zoom 1 shows ~60x34 tiles (1920x1080 at 32 px per
    tile), so the zoom is what fits the bounds plus a margin, clamped to cameras.lua's 0.3..4. exact_zoom: the
    director sends it as is (no main/side scaling, which would crop the platform). In flight, include 32 extra
    tiles ahead and 8 aft and on each side for approaching asteroids. Forward on the platform surface is north
    on either leg of a space connection; reversing the route does not turn the build around. frac is the width
    the on-air crop actually shows.
    (d20 batch50 A1, Nick: "we only need to be zoomed out far enough to see asteroids get destroyed, so no more than
    max gun range") With the view's guns read: in flight the frame is the ship and the box its turrets reach (each
    one's range; at most the ship plus its longest range all round) with a 2-tile margin; a ship without turrets is
    its bounds plus that margin. `fit_zoom` is that whole-ship zoom.
    (A2, "shots that slowly pan over their targets ... a better detail view at more zoom") In flight with turrets,
    when the whole frame is wider than a detail view: the shot is the detail view, `zoom` the one that fits the guns'
    reach across (DETAIL_ZOOM), starting at the bow (the top of the reach) and panning to the stern at DETAIL_CROSS_S
    per view height after DETAIL_BOW_S on the bow (`pan` with speed and bow_s; OneCam's pan_step). Docked: a still
    shot."""
    b = view.get("bounds") or {}
    hub = view.get("hub") or {"x": 0, "y": 0}
    left, top = b.get("left", hub["x"] - 6), b.get("top", hub["y"] - 6)
    right, bottom = b.get("right", hub["x"] + 6), b.get("bottom", hub["y"] + 6)
    hull = (left, top, right, bottom)
    reach = gun_reach(view)
    if travelling and "guns" in view:
        margin = 4.0
        if reach:
            left, top, right, bottom = min(left, reach[0]), min(top, reach[1]), max(right, reach[2]), max(bottom, reach[3])
    elif travelling:
        left, top, right, bottom = left - 8, top - 32, right + 8, bottom + 8
    w, h = right - left + margin, bottom - top + margin
    zoom = max(0.3, min(2.0, 60.0 * frac / w, 34.0 / h))
    out = {"position": {"x": round((left + right) / 2, 1), "y": round((top + bottom) / 2, 1)}, "surface": view["surface"],
           "zoom": round(zoom, 2), "exact_zoom": True}
    if "guns" in view:
        out["fit_zoom"] = out["zoom"]
    if travelling and reach:
        detail = max(DETAIL_ZOOM[0], min(DETAIL_ZOOM[1], 60.0 * frac / w))
        dh = 34.0 / round(detail, 2)
        y0, y1 = top - margin / 2 + dh / 2, max(top - margin / 2 + dh / 2, hull[3] + margin / 2 - dh / 2)
        if detail > zoom + 0.05 and (y1 - y0) <= LONG_VIEWS * dh:
            out.update(zoom=round(detail, 2), position={"x": out["position"]["x"], "y": round(y0, 1)},
                       pan={"y0": round(y0, 1), "y1": round(y1, 1), "speed": round(dh / DETAIL_CROSS_S, 2),
                            "bow_s": DETAIL_BOW_S, "detail": True})
            return out
    # (d19 batch42 C2, viewer Foobator: "see all of Bastion when it flies") taller than the view at the zoom that fits
    # (the least zoom 0.3 shows ~113 tiles; Bastion in flight needs ~174): `pan`, the view's centre from the bow (north,
    # forward) to the stern; OneCam starts the shot at the bow and moves it (pan_step), a camera without that keeps the
    # centre
    vh = 34.0 / round(zoom, 2)
    if h > vh + margin:  # (a few tiles of the margin cut is no pan: Cinder in flight is 111 high at 0.31, ~110)
        y0, y1 = top - margin / 2 + vh / 2, bottom + margin / 2 - vh / 2
        out["pan"] = {"y0": round(y0, 1), "y1": round(y1, 1)}
    return out


def fmt_age(sec):
    """An age for a card: 40 s, 12 min, 2 h, 2 h 15 min."""
    sec = int(sec)
    if sec < 90:
        return f"{sec} s"
    if sec < 90 * 60:
        return f"{round(sec / 60)} min"
    h, m = sec // 3600, sec // 60 % 60
    return f"{h} h" + (f" {m} min" if m else "")


def fmt_game_time(sec):
    sec = int(sec)
    return f"{sec // 3600}h{sec // 60 % 60:02d}m"


# Technologies and the buildings they unlock, for the hosts' commentary on what the team has not built yet
# (HOSTS4 item 2: "logistic robotics researched 3 h ago, no roboport built"). Buildings are counted by tools/pog.py's
# score; a technology whose building is not counted there is left out. One table with the harness: its unlocks.lua
# (the agents' shift block, "researched, none built") is read here.
UNLOCKS_LUA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "vendor", "factorio-harness", "mod",
                           "agent-harness_0.1.0", "unlocks.lua")


def load_unlocks(path=UNLOCKS_LUA):
    """unlocks.lua rows `{'tech', {'building', ...}, 'label'},` -> {tech: ((buildings), label)}, in file order."""
    out = {}
    row = re.compile(r"^\s*\{\s*'([^']+)'\s*,\s*\{([^}]*)\}\s*,\s*'([^']+)'\s*\},?\s*$")
    for line in open(path):
        m = row.match(line)
        if m:
            out[m.group(1)] = (tuple(re.findall(r"'([^']+)'", m.group(2))), m.group(3))
    return out


UNLOCKS = load_unlocks()


def tech_label(name):
    if not name:
        return None
    label = name.replace("-", " ").capitalize()
    # shake11's template aired "Planet discovery fulgora": planets keep their capitals
    return re.sub(r"\b(nauvis|vulcanus|fulgora|gleba|aquilo)\b", lambda m: m.group(1).capitalize(), label)


REPEATING_MAX = 24  # infinite technologies on the research card (Space Age has about 30)


def repeating_levels(rows, current=None, progress=None):
    """(d20 batch57 S4, viewer Foobator, shift48 18:25: "the current level of ever increasing recurring research") The
    extras read's infinite technologies [{name, level, next, researching}] -> [{name, label ("Mining productivity",
    the prototype name without its starting number), level (the last level researched), next (the level the tech tree
    shows to research), researching?, progress?}], the highest level first, then by label; levels as the game counts
    them (mining-productivity-3 starts at 3: levels 1 and 2 are the two finite technologies before it)."""
    out = []
    for r in rows or []:
        if not isinstance(r, dict) or not r.get("name") or not isinstance(r.get("level"), int):
            continue
        row = {"name": r["name"], "label": tech_label(re.sub(r"-\d+$", "", r["name"])), "level": r["level"],
               "next": r.get("next") if isinstance(r.get("next"), int) else r["level"] + 1}
        if r.get("researching") or r["name"] == current:
            row["researching"] = True
            if isinstance(progress, (int, float)):
                row["progress"] = round(progress, 3)
        out.append(row)
    out.sort(key=lambda x: (-x["level"], x["label"]))
    return out[:REPEATING_MAX]


def research_label(name, rows):
    """(d23 batch119 CB1, viewer Aurora site:4386: "The research header says Mining productivity 3, but the detailed
    panel says level 16 reached and researching 17") The running technology for viewers: an infinite one by the level
    it is researching ("Mining productivity 17": the prototype's "-3" is the level it starts at), from the extras
    read's rows (repeating_levels); any other by its name."""
    for r in rows or []:
        if r.get("name") == name and isinstance(r.get("next"), int):
            return f"{r['label']} {r['next']}"
    return tech_label(name)


def level_done_label(row, tick, read_tick):
    """A finished level of an infinite technology (research.lua's board event, titled by the prototype name only) by
    the level done, from its row in the extras read at read_tick (repeating_levels): the row's level when the read came
    after the event, one more when the event is newer (the read runs every 3 s). None when the level cannot be told
    (the event has no tick): the caller names the technology without a level. A technology with no row yet is on its
    first level, the prototype's own (tech_label: "Mining productivity 3"; names have no number from level 1)."""
    if read_tick is None or not isinstance(tick, int):
        return None
    return f"{row['label']} {row['level'] if tick <= read_tick else row['level'] + 1}"


def human_name(name):
    """A prototype name for viewers: 'assembling-machine-2' -> 'Assembling machine 2', 'travel to vulcanus' ->
    'Travel to vulcanus'."""
    return tech_label(str(name)) or ""


def describe_action(kind):
    """'craft:lab' -> 'crafting lab', 'build_blueprint' -> 'placing blueprint'."""
    kind, _, what = str(kind).partition(":")
    verb = VERBS.get(kind, kind.replace("_", " "))
    return f"{verb} {what.replace('-', ' ')}".strip()


class Agent:
    def __init__(self, name, cfg):
        self.name = name
        self.cfg = cfg or {}
        self.kind = self.cfg.get("kind", "bot")
        self.display_name = self.cfg.get("display_name") or name.capitalize()
        self.color = self.cfg.get("color")
        self.glyph = self.cfg.get("glyph")
        self.motto = ""
        self.profile_set = None  # None: unknown (no `profiles`); False: the agent has not called `profile` yet
        self.position = None
        self.where = None  # profiles' text while in a cargo pod ("cargo pod to X")
        self.travel = None  # a bot's ride: ascending | aboard | descending
        self.alive = True
        self.dead_until_tick = None
        self.active = False
        self.action_since = None
        self.last = None
        self.last_activity_t = None  # wall time of the last observed action or speech
        self.combat = False  # in a fight now: hit lately or fighting (combat_state)
        self.resting = None  # a rest between turns (pacing.py: {since, until, reason}), or None
        self.combat_state = None  # "hurt" | "fighting" | "guard" | None
        self.vehicle_fire = None  # (d22 batch93 BC2) driving a spidertron: {range, ammo, targets, farthest, box, ...}
        self.combat_info = {}
        self.plan = None  # the action running now with its bounds (live.py `plan`; onecam.py looks ahead with it)
        self.auto = None  # a standing order running for it (live.py `auto`, orders.lua): {name, reason, step, steps}
        self.last_said = None
        self.interest = 0.0
        self.interest_t = time.time()
        self.seen = False
        self.died_at = None
        self.connected = True
        self.voice = None  # profile.voice: a voice id from tools/stream/voices.py
        self.voice_description = None  # profile.voice_description: words for a designed voice (voices.py)
        self.pronouns = None  # profile.pronouns, e.g. "he/him": the casters use them (else "they")
        self.avatar = None  # profile.avatar: parts for avatar.js (docs/ART-NOTES.md); None draws the name default
        self.surface = None   # Space Age (status): the surface the body is on, and the platform's name when on one
        self.platform = None
        self.wait = None  # latest measured sleep/body/queue wait from existing status and journal reads
        self.notes_job = None  # its notes.md "## Now" job line (live.py, notes_job), for the card
        self.notes_job_t = None  # when that notes.md was saved (wall clock), for the card's age
        self.attention = None  # its latest request with a place (attention.py), with t: when it came in
        # (d20 batch70 AF3) its current work for the card (workcard.py): bounded watches, queue lanes, repeating requests
        self.watches = None
        self.queues = None
        self.repeats = None

    def bump(self, amount, now):
        self.decay(now)
        self.interest = min(self.interest + amount, 30.0)

    def decay(self, now):
        dt = max(0.0, now - self.interest_t)
        self.interest *= 0.5 ** (dt / HALF_LIFE)
        self.interest_t = now


PROJECTS_SHOWN_MAX = 8  # (d22 batch75 AK11) projects worked on or blocked the board card shows before "show all"

class Model:
    def set_inbox(self, path):
        """runs/RUN/operator-inbox.jsonl: its viewer rows count as viewer lines for the Operator's replies."""
        self.inbox_path, self.inbox_mtime, self.inbox_rows = path, None, []

    def inbox_lines(self):
        if not self.inbox_path:
            return []
        try:
            m = os.stat(self.inbox_path).st_mtime_ns
        except OSError:
            return []
        if m != self.inbox_mtime:
            self.inbox_mtime, self.inbox_rows = m, viewer_replies.read_inbox(self.inbox_path)[-200:]
        return self.inbox_rows

    def set_reply_links(self, path):
        """(d20 batch65 AA2) runs/RUN/operator-replies.jsonl (tools/opreply.py): the line each Operator reply names."""
        self.links_path, self.links_mtime, self.links = path, None, {}

    def reply_links(self):
        """(d22 batch89 AY4) this run's file and the two runs' before it (viewer_replies.links_files), a newer record over an older one."""
        if not self.links_path:
            return {}
        files = viewer_replies.links_files(self.links_path)
        m = []
        for p in files:
            try:
                m.append(os.stat(p).st_mtime_ns)
            except OSError:
                m.append(None)
        if not any(m):
            return {}
        if m != self.links_mtime:
            links = {}
            for p in files:
                links.update(viewer_replies.read_links(p))
            self.links_mtime, self.links = m, links
        return self.links

    def __init__(self, run):
        self.run = run
        self.agents = {}
        for name, cfg in (run.get("agents") or {}).items():
            self.agents[name] = Agent(name, cfg)
        self.chat = deque(maxlen=200)  # chat_window() picks each lane's latest from here
        # agents' and the Operator's lines that answer a viewer or speak to the viewers (viewer_replies.py; Nick, d15
        # 08:07): the live page's site chat shows them among the viewers' lines, so they outlive the chat window
        self.viewer_replies = deque(maxlen=40)
        self.reply_threads = viewer_replies.Threads()  # a long reply's numbered parts stay in part 1's thread
        # viewers' lines to the Operator, which go to the run's operator inbox, not the game chat (viewer_replies.py):
        # set_inbox; read again when the file changes
        self.inbox_path, self.inbox_mtime, self.inbox_rows = None, None, []
        self.links_path, self.links_mtime, self.links = None, None, {}  # set_reply_links
        self.chat_seen = set()
        self.chat_read = False  # the first chat read (the backlog) is done
        # (d22 batch111 BU1) the operator-read feeds whose backlog is read (an empty read since the start): until then a
        # line older than HISTORY_S by game tick is history (backlog_old)
        self.feeds_live = set()
        self.chat_log_path, self.chat_log_times = None, None  # set_chat_log
        self.operator_requests = deque(maxlen=5)  # the last few agents' requests to the operator, for the snapshot
        self.alerts = deque(maxlen=30)
        self.alert_keys = {}
        self.tick = 0
        self.tick_t = None  # when self.tick was read (ingest)
        self.paused = False
        self.research = {"current": None, "progress": None, "done": set(), "recent": deque(maxlen=6)}
        self.done_at = {}    # technology -> when this stream saw it finish (unused_unlocks)
        self.research_news = {}  # technology -> {name, label, t}: finished while this stream ran (the research card)
        self.unlocks = {}        # technology -> {unlocks, more} from research.lua's board event
        self.entities = {}   # building counts from the score (unused_unlocks)
        self.entities_counted = set()  # the buildings the score counts (absent from entities means none)
        self.research_started = False
        self.prod_samples = deque(maxlen=400)  # (wall time, game seconds, {item: total})
        self.flows = {}
        self.used_samples = deque(maxlen=400)  # (wall time, game seconds, {pack: total the labs used}): score's consumed
        self.used_flows = {}  # pack -> 30 two-minute counts the labs used, oldest first (harness.USED_FLOW_LUA)
        self.power = None
        self.darkness = None  # LuaSurface.darkness: 0 day .. ~0.85 midnight (nightlift.py)
        self.connected_players = None  # the game's connected player names, as last read (hostview.py)
        self.basemap = None  # the base as a coarse grid (harness.BASEMAP_LUA), for the site's live map only
        self.turret_state = None  # (d20 batch50 G1) turretstate.py public(): counts, the turrets not armed, as_of
        self.planet_maps = {}  # the other planets' coarse maps by surface (census.lua via harness.planet_map), one read a minute
        self.clouds = {}  # surface -> pollution or spores per charted chunk (clouds.normalise; live.py observe_clouds)
        self.clouds_t = None
        self.library_areas = None  # (d21 batch68 AD2) the library's placed areas, the last read (live.py observe_library_areas)
        self.library_areas_t = None
        self.net_maps = {}  # (d21 batch68 AD3) surface -> (its networks map, when read) (live.py observe_net_map)
        self.terrain_grid = None  # (d22 batch75 AK9) the charted ground's tiles (terrain_grid.py via live.py)
        self.map_memory = None  # (d22 batch75 AK1) runs/RUN/map-memory.json (set_map_memory): both maps across restarts
        self.map_memory_t = 0.0
        self.planet_unlisted = {}  # (AK1) surface -> when the census's planet list first left it out
        self.board = {"events": deque(maxlen=40), "seen": set(), "items": {}, "open_unowned": None,
                      "changelog": deque(maxlen=5), "available": False}
        # Space Age: score's rockets/planets/platforms plus platform detail (live.py); moments fire once each
        self.space = {"rockets": 0, "planets": [], "platforms": []}
        self.space_seen = None  # moment keys already true; None until the first observation seeds it silently
        self.moments = deque(maxlen=8)
        # platforms by name as last seen (to name one that is destroyed), reads each has been missing, hub losses
        self.platform_last, self.platform_missing, self.hub_losses = {}, {}, deque(maxlen=20)
        self.platform_course = {}  # name -> {conn, pct, toward, orbit, moving}: which way it flies, the last planet
        self.arrivals = []  # (name, planet, came from, its first there, the run's first there) this read
        self.planets_reached = set()  # planets any platform has been at (or our entities stand on)
        self.space_memory = None  # runs/RUN/space-memory.json (set_space_memory): visited and reached across restarts
        # (d22 batch83 AS1) name -> {"from>to": [game ticks of its latest departures on that route]}: kept in
        # space-memory.json, seeded from the chronicle along the run chain; the camera tells news from routine by it
        self.platform_routes = {}
        self.orbit_known = set()  # (platform, planet) visited before this service saw it: no orbit moment for those
        self.rockets_at_start = None  # the shift's first rocket is a headline (seeded with the count at start)
        # Space widget: status alerts' platform_hits rows by platform (live.py), and platforms lost lately
        self.platform_hits, self.platforms_lost = {}, deque(maxlen=6)
        self.platform_losses = {}  # platform name -> {loss key: (total, wall time it last grew)}: onecam's danger shot
        # the run's chronicle (live.py, the harness's chronicle read; viewers Alex and syndesis 22:24): the agents'
        # entries and the events the harness saw, the newest kept for the state; a platform's loss as the harness read
        # it at its hub's death (where, what killed it, its cargo), by name, for the stream's own loss line
        self.chronicle_entries, self.chronicle_events, self.harness_lost = deque(maxlen=12), deque(maxlen=20), {}
        self.chronicle_earlier = set()  # set_platform_history
        # each platform's newest creation and its departures since (chronicle_log.platform_history, then the live
        # events): its first departure is a maiden flight (viewer Foobator, d17 14:24)
        self.platform_history = {}
        self.work = deque(maxlen=20)  # work away from the body (live.py observe_work), for the director
        self.incoming = {}  # id -> an enemy group on its way (attack_groups_live), as last read
        self.big = {}  # id -> a demolisher near our buildings (big_enemies_live), as last read
        self.hauling = None  # hand hauling this shift (live.py observe_hauling): {rows, since, t}
        self.reminders = None  # the team's reminder jobs (reminders.lua via live.py): {jobs, tick}
        # production credited to who built the machine (live.py observe_efficiency): the last read, and the reads of the
        # last hour for a notable change (efficiency.notable)
        self.efficiency = None
        self.efficiency_hist = deque(maxlen=24)
        self.loadouts = loadouts_mod.Loadouts()  # what each agent carries, wears and builds (live.py observe_loadout)
        self.tokens, self.tokens_from = None, None  # token use this shift (tokens.py TokenFeed, brief): {t, since, rows}
        self.fights = {}  # key -> fight still reported (attacked chunk, loss, agent in combat), for replays.py
        self.space_age = bool(run.get("space_age")) or "Space Age" in (run.get("subtitle") or "")
        self.last_obs_t = None
        self.errors = {}

    # ---- ingestion -------------------------------------------------------------------------------------------
    def agent(self, name):
        if name not in self.agents:
            self.agents[name] = Agent(name, (self.run.get("agents") or {}).get(name))
        return self.agents[name]

    def ingest(self, obs, now=None):
        now = now or time.time()
        self.last_obs_t = now
        if obs.get("tick") is not None:  # replays.py maps a loss's game tick to wall time with (tick_t, tick)
            self.tick, self.tick_t = obs["tick"], now
        self.paused = bool(obs.get("paused"))
        game_sec = obs.get("game_seconds", self.tick / 60)
        team = self.run.get("agents") or {}
        for a in obs.get("agents", []):
            # cards are the run's team only (stream.json agents, from team.txt); shake8 showed Nick, a human player,
            # as a tenth card ("model ? · profile not set · dead"). Without a team in the run, everyone counts.
            if team and a.get("name") not in team:
                continue
            self._ingest_agent(a, now)
        chat = obs.get("chat") or []
        for m in chat:
            # the first read after a (re)start is the game's chat backlog: restored lines keep their time (chat_time)
            self._ingest_chat(m, now, restored=not self.chat_read)
        self.chat_read = self.chat_read or bool(chat)
        for e in (obs.get("chronicle") or {}).get("entries") or []:
            self._ingest_chronicle_entry(e, now)
        for e in (obs.get("chronicle") or {}).get("events") or []:
            self._ingest_chronicle_event(e, now)
        for c in obs.get("confessions") or []:
            self._ingest_confession(c, now)
        for t in obs.get("tells") or []:
            self._ingest_tell(t, now)
        for r in obs.get("operator_requests") or []:
            self._ingest_operator_request(r, now)
        self._feeds_read(obs, ("confessions", "tells", "operator_requests"))
        if obs.get("research"):
            self._ingest_research(obs["research"], now)
        if obs.get("produced") is not None:
            self.prod_samples.append((now, game_sec, dict(obs["produced"])))
        if obs.get("consumed") is not None:
            self.used_samples.append((now, game_sec, dict(obs["consumed"])))
        if obs.get("used_flows"):
            self.used_flows = obs["used_flows"]
        if obs.get("entities") is not None:  # the score's building counts (tools/pog.py), for unused_unlocks
            self.entities = dict(obs["entities"])
            # zeros are left out of the counts, so only a building the score says it counts can be "none built"
            self.entities_counted = set(obs.get("entities_counted") or [])
        if obs.get("flows"):
            self.flows = obs["flows"]
        if obs.get("darkness") is not None:
            self.darkness = obs["darkness"]
        if obs.get("connected_players") is not None:
            self.connected_players = list(obs["connected_players"])
        if isinstance(obs.get("turret_state"), dict):  # (d20 batch50 G1) each turret's readiness (turretstate.py)
            self.turret_state = obs["turret_state"]
        if obs.get("basemap"):
            ore = obs["basemap"].get("ore") or (self.basemap or {}).get("ore")  # ore is read less often: keep the last
            self.basemap = dict(obs["basemap"], ore=ore) if ore else obs["basemap"]
        # (d20 batch50 D1, viewer Aurora: "Could partial map updates retain the last map with its age?") a planet the
        # census read leaves out keeps its last map (its tick says how old; the site labels it), so a page loaded later
        # still has its tab
        if isinstance(obs.get("planet_map"), dict) and obs["planet_map"].get("surface"):
            self.planet_maps[obs["planet_map"]["surface"]] = obs["planet_map"]
        if isinstance(obs.get("planet_names"), list) and obs["planet_names"]:
            # (AK1) a planet the census has not listed for PLANET_GONE_S goes (one pass may list fewer)
            for k in list(self.planet_maps):
                if k in obs["planet_names"]:
                    self.planet_unlisted.pop(k, None)
                elif now - self.planet_unlisted.setdefault(k, now) >= self.PLANET_GONE_S:
                    del self.planet_maps[k]
                    self.planet_unlisted.pop(k, None)
        if isinstance(obs.get("library_areas"), dict):
            self.library_areas, self.library_areas_t = obs["library_areas"], now
        if isinstance(obs.get("terrain_grid"), dict) and isinstance(obs["terrain_grid"].get("rows"), list):
            self.terrain_grid = obs["terrain_grid"]
        if isinstance(obs.get("net_map"), dict) and isinstance(obs["net_map"].get("surface"), str):
            self.net_maps[obs["net_map"]["surface"]] = (obs["net_map"], now)
        if isinstance(obs.get("net_map_listed"), list):  # (a surface gone has no map in the runtime's listing)
            self.net_maps = {k: v for k, v in self.net_maps.items() if k in obs["net_map_listed"]}
        if any(k in obs for k in ("planet_map", "planet_names", "net_map", "net_map_listed")):
            self._save_map_memory(now)
        if obs.get("clouds") is not None:  # a read happened: a surface missing from it has no cloud now
            self.clouds, self.clouds_t = clouds_mod.normalise(obs["clouds"]), now
        if obs.get("power"):
            self._ingest_power(obs["power"], now)
        for e in obs.get("board_events") or []:
            self._ingest_board_event(e, now)
        self._feeds_read(obs, ("board_events",))
        if obs.get("board") is not None:  # after the events: a `board` read is the authoritative item state
            self._ingest_board(obs["board"])
        for e in obs.get("events", []):
            self._ingest_event(e, now)
        if obs.get("space") is not None:
            # a platform counts once its hub exists: shake7's "First space platform: Solstice" fired on the record the
            # New platform button makes (waiting_for_starter_pack), before any rocket. Rows without the field (older
            # score reads) count as before.
            sp = dict(obs["space"])
            sp["platforms"] = [p for p in sp.get("platforms") or []
                               if p.get("hub", True) and p.get("state") != "waiting_for_starter_pack"]
            self.planets_reached.update(sp.get("planets") or [])  # surfaces with our entities: reached before
            sp["platforms"] = self._orient_platforms(sp["platforms"])
            self._save_space_memory()
            self.space = sp
            self._platforms_lost(now)
        if obs.get("platform_hits") is not None:  # one status round's rows: a platform not in them took no hits lately
            self.platform_hits = {r.get("platform"): r for r in obs["platform_hits"] if r.get("platform")}
        if obs.get("space") is not None or any(a.get("surface") for a in obs.get("agents", [])):
            self._space_moments(now)
        for w in obs.get("work") or []:
            self._ingest_work(w, now)
        for x in obs.get("attention") or []:
            self._ingest_attention(x, now)
        if obs.get("attack_groups") is not None:  # a read happened (an empty list: none on the way)
            self._ingest_groups(obs["attack_groups"], now)
        if obs.get("big_enemies") is not None:
            self._ingest_big(obs["big_enemies"], now)
        if obs.get("reminders") is not None:  # the team's reminder jobs, for the site's panel
            self.reminders = obs["reminders"]
        if obs.get("hauling") is not None:  # hand hauling this shift (live.py observe_hauling), for the segment card
            self.hauling = obs["hauling"]
        if obs.get("efficiency") is not None:  # machines' output by builder (live.py observe_efficiency)
            self.efficiency = obs["efficiency"]
            self.efficiency_hist.append((now, obs["efficiency"]))
        if obs.get("loadout") is not None:  # guns, armor, items, crafting, building per agent (live.py observe_loadout)
            team = self.run.get("agents") or {}
            self.loadouts.ingest([r for r in obs["loadout"] if not team or r.get("name") in team], now)
        self.errors = obs.get("errors", {})

    def set_tokens(self, snap):
        """The token feed's latest result (serve.py's poller hands it over): kept without its per-minute series."""
        if snap is not self.tokens_from:
            self.tokens_from, self.tokens = snap, tokens.brief(snap)

    def platform_view(self, name):
        """A platform's camera view (live.py PLATFORM_LUA: surface, hub, bounds), or None before it is read."""
        return next((p.get("view") for p in self.space.get("platforms") or [] if p.get("name") == name and p.get("view")), None)

    def _ingest_work(self, w, now):
        """Work away from an agent's body (live.py observe_work) -> a labelled item the director can cut to."""
        if w.get("agent") not in self.agents:
            return
        ag = self.agents[w["agent"]]
        who = ag.display_name or w["agent"]
        item = {"id": f"work-{w['agent']}-{w.get('at') or now}", "agent": w["agent"], "action": w.get("action"),
                "t": now, "platform": w.get("platform"), "position": w.get("position"), "surface": w.get("surface")}
        if w.get("platform"):
            view = self.platform_view(w["platform"])
            if not view:
                return  # its surface is not known yet (the platform read runs every 15 s): nothing to cut to
            verb = w.get("verb") or "building"
            on = "" if verb.endswith((" to", " from", " on")) else " on"  # "launching a rocket to Starling"
            item.update(surface=view["surface"], view=view, label=f"{who} {verb}{on} {w['platform']} (from the ground)")
        else:
            if not w.get("position"):
                return
            p = w["position"]
            item["label"] = f"{who} {w.get('verb') or 'building'} at ({round(p['x'])}, {round(p['y'])}) (from afar)"
        if any(x["agent"] == item["agent"] and x.get("platform") == item["platform"] and now - x["t"] < 20
               for x in self.work):
            return  # one request after another on the same job: one item
        self.work.append(item)
        ag.bump(1.0, now)

    def _ingest_groups(self, groups, now):
        """Enemy groups on their way (harness attack_groups_live): each with a label for the page and the hosts, "38
        biters and spitters heading for the oil field", and when it was first seen."""
        seen = {}
        for g in groups:
            if not g.get("id") or not g.get("position"):
                continue
            old = self.incoming.get(g["id"]) or {}
            row = dict(g, first_seen=old.get("first_seen", now), t=now)
            row["label"] = self.group_label(row)
            seen[g["id"]] = row
        self.incoming = seen

    def group_label(self, g):
        kinds = str(g.get("kinds") or "")
        words = [w for w, rx in (("biters", "biter"), ("spitters", "spitter"), ("demolishers", "demolisher"),
                                 ("worms", "worm"), ("strafers", "strafer"), ("stompers", "stomper")) if rx in kinds]
        what = " and ".join(words[:2]) or "enemies"
        t = g.get("target")
        if t and (g.get("surface") or "nauvis") == "nauvis":
            where = self.spot_name(t)  # a landmark ("the oil field"), "spawn", or "120 m NE" (of spawn)
            if where[0].isdigit():
                where = f"the base, {where} of spawn"
        elif t:
            where = f"({round(t['x'])}, {round(t['y'])}) on {planet_label(g['surface'])}"
        else:
            where = "the base"
        return f"{g.get('size') or '?'} {what} heading for {where}"

    def _ingest_big(self, rows, now):
        """Demolishers near our buildings or agents, labelled "Small demolisher · 300 tiles from Sol's gun turrets"."""
        seen = {}
        for e in rows:
            if e.get("id") is None or not e.get("position"):
                continue
            seen[e["id"]] = dict(e, t=now, label=self.big_label(e))
        self.big = seen

    def big_label(self, e):
        what = human_name(e.get("name") or "enemy").capitalize()
        # whose: the agent whose character is nearest the building (bots have no player: matched by position)
        ch = e.get("character") or {}
        owner = self.agents.get(ch.get("player")) if ch.get("player") else None
        if not owner and ch:
            owner = next((ag for ag in self.agents.values() if ag.position and
                          (ag.surface or "nauvis") == (e.get("surface") or "nauvis") and
                          math.hypot(ag.position["x"] - ch["x"], ag.position["y"] - ch["y"]) <= 3), None)
        b = e.get("nearest")
        near_owner = owner and b and math.hypot(ch["x"] - b["x"], ch["y"] - b["y"]) <= 80
        who = owner.display_name if owner else None
        if b and e.get("nearest_distance") is not None:
            things = human_name(b.get("name") or "building").lower() + "s"
            target = f"{who}'s {things}" if near_owner else f"our {things} at ({b['x']}, {b['y']})"
            return f"{what} · {e['nearest_distance']} tiles from {target}"
        if who and e.get("character_distance") is not None:
            return f"{what} · {e['character_distance']} tiles from {who}"
        return what

    def big_snapshot(self, now):
        return [e for e in self.big.values() if now - e["t"] < 20]

    def incoming_snapshot(self, now):
        return [dict(g, age_s=round(now - g["first_seen"], 1)) for g in self.incoming.values() if now - g["t"] < 20]

    def _ingest_attention(self, x, now):
        """An agent's latest request with a position, area or list (live.py, attention.py): where it is looking or
        working now. A platform's point is on the platform's surface (when its view is known)."""
        ag = self.agents.get(x.get("agent"))
        if not ag or not x.get("kind"):
            return
        surface = ((self.platform_view(x["platform"]) or {}).get("surface") if x.get("platform")
                   else ag.surface or "nauvis")
        ag.attention = {k: x.get(k) for k in ("kind", "action", "verb", "what", "position", "extent", "platform", "count")}
        ag.attention.update(t=now, surface=surface)

    def attention_row(self, ag, now):
        """snapshot agents[].attention: {kind, verb, text ("placing ghosts 40 m north"), position, extent, surface,
        platform, age_s, dist (tiles from the character on its surface), far} while under ATTENTION_TTL old."""
        a = ag.attention
        if not a or now - a["t"] > ATTENTION_TTL:
            return None
        here = ag.position if not a.get("platform") and (ag.surface or "nauvis") == a.get("surface") else None
        d = math.hypot(a["position"]["x"] - here["x"], a["position"]["y"] - here["y"]) \
            if here and a.get("position") else None
        far = (d is not None and d >= attention.FAR) or bool(a.get("platform") and ag.platform != a["platform"])
        landmarks = self.run.get("landmarks", []) if (a.get("surface") or "nauvis") == "nauvis" else ()
        return dict({k: v for k, v in a.items() if k != "t"}, text=attention.text(a, here, landmarks),
                    age_s=round(now - a["t"], 1), dist=None if d is None else round(d, 1), far=far)

    def _fight(self, key, kind, position, now, text, agent=None, loss=False, tick=None):
        """A fight still being reported (live.py re-reports an attacked chunk every poll while its last hit is under 30
        game seconds old, a loss for ~2 minutes, an agent's combat flag while it lasts): `last` is when it was last
        seen, so replays.py can wait until it has been quiet before airing anything about it."""
        f = self.fights.get(key)
        if f and now - f["last"] > FIGHT_EPISODE_GAP:
            # a new fight at the same place (or the same agent attacked again): its own first sign and losses
            # (shift06 13:2x: "Astra is under attack" kept its first from minutes before, so every new attack on
            # Astra counted as a fight over 30 s long, and the replay judged 0 s of 474 s as shown)
            f = None
        if not f:
            f = self.fights[key] = {"key": key, "kind": kind, "first": now, "losses": [], "text": text, "agent": agent}
        f.update(last=now, position={k: position[k] for k in ("x", "y", "surface", "extent") if k in position})
        if loss:
            f["losses"].append(now)  # when a loss alert first came in: the moment something was destroyed (+ poll lag)
            # the incident's last_tick (live.py), or None: the game tick of that moment, beside each entry of losses
            f.setdefault("loss_ticks", []).append(tick)
            f["text"] = text
        for k in [k for k, v in self.fights.items() if now - v["last"] > 300]:
            del self.fights[k]

    def fights_snapshot(self, now):
        return [dict(f, losses=list(f["losses"]), loss_ticks=list(f.get("loss_ticks") or []))
                for f in self.fights.values() if now - f["last"] < 240]

    def work_snapshot(self, now):
        return [dict(w, age_s=round(now - w["t"], 1)) for w in self.work if now - w["t"] < 60]

    def _ingest_agent(self, a, now):
        ag = self.agent(a["name"])
        for key in ("kind", "display_name", "color", "glyph", "motto", "voice", "voice_description", "pronouns"):
            if a.get(key):
                setattr(ag, key, a[key])
        if "avatar" in a:
            ag.avatar = a["avatar"] if isinstance(a["avatar"], dict) else None
        if "wait" in a:
            ag.wait = a["wait"]
        if "notes_job" in a:
            ag.notes_job = a["notes_job"]
        if "notes_job_t" in a:
            ag.notes_job_t = a["notes_job_t"]
        for key in ("watches", "queues", "repeats"):
            if key in a:
                setattr(ag, key, a[key] or None)
        if "resting" in a:  # the agy loop sleeps between turns (pacing.py); said once to the hosts as a fact
            rest = a["resting"] if isinstance(a["resting"], dict) else None
            if rest and (not ag.resting or ag.resting.get("until") != rest.get("until")):
                self.alert("rest", f"{ag.display_name} is {pacing.label(rest)}", key=f"rest:{ag.name}:{rest.get('until')}",
                           agent=ag.name, ttl=60)
            ag.resting = rest
        if "profile_set" in a:
            ag.profile_set = a["profile_set"]
        if a.get("position"):
            ag.position = a["position"]
        if a.get("surface"):
            ag.surface, ag.platform = a["surface"], a.get("platform")
        # Bot travel (harness): ascending | aboard | descending, and the pod's text ("cargo pod to X"); None once landed.
        for key in ("travel", "where"):
            if key in a:
                setattr(ag, key, a[key])
        # A bot riding a cargo pod or aboard a platform has no body; it is not dead.
        alive = a.get("alive", True) or bool(a.get("travel"))
        connected = a.get("connected", True)
        if ag.seen and ag.alive and not alive and connected and ag.connected:
            ag.died_at = now
            ag.bump(5, now)
            where = where_label(ag.surface, ag.platform) if ag.surface else None
            # (the casters' facts name no planet while Nauvis is the only one in play: Nick 12:35, item 4)
            self.alert("death", f"{ag.display_name} died" + (f" on {where}" if where and where != "Nauvis" else ""),
                       surface=ag.surface or "nauvis",
                       key=f"death:{ag.name}:{int(now // 30)}", agent=ag.name,
                       facts={"headline": "agent_death", "agent": ag.display_name,
                              "where": where if where != "Nauvis" or self.space_in_play() else None})
        ag.alive = alive
        ag.connected = connected
        ag.dead_until_tick = a.get("dead_until_tick")
        active = a.get("active") or False
        # Under attack only when hit lately; fighting while it shoots at something; a guard with nothing in range is
        # neither, and its action is "guard", not "shoot" (the director's fight kinds and the hosts' "fighting" are for
        # fights; viewer Joonazan, 13:36)
        state, info = combat_state(a.get("combat"), a.get("hurt"), self.tick)
        ag.vehicle_fire = a.get("vehicle_fire") if isinstance(a.get("vehicle_fire"), dict) else None
        if state == "guard" and str(active).split(":")[0] == "shoot":
            active = "guard"
        if active and active != ag.active:
            ag.action_since = now
            ag.bump(ACTION_WEIGHT.get(str(active).split(":")[0], 1.0), now)
        if active:
            ag.last_activity_t = now
            # sustained work keeps a little interest alive
            ag.bump(0.04 * ACTION_WEIGHT.get(str(active).split(":")[0], 1.0), now)
        elif ag.active and not active:
            ag.last_activity_t = now
        ag.active = active
        if a.get("last"):
            ag.last = a["last"]
        was = ag.combat_state
        if state == "hurt":
            by = enemy_label(info.get("by"))
            text = f"{ag.display_name} is under attack" + (f" by {by}" if by else "") + \
                (f" in the {info['what'].replace('-', ' ')}" if info.get("what") else "")
            if ag.position:  # an agent's own fight, seen on every poll while it lasts (replays.py)
                self._fight(f"attack:{ag.name}", "attack", ag.position, now, text, agent=ag.name)
            if was != "hurt":
                ag.bump(6, now)
                self.alert("attack", text, key=f"attack:{ag.name}", agent=ag.name, ttl=60, position=ag.position,
                           surface=ag.surface or "nauvis")
        elif state == "fighting":
            foe = enemy_label(info.get("target"))
            text = f"{ag.display_name} is fighting {foe}" if foe else f"{ag.display_name} is firing"
            if ag.position:  # a fight of its own, lower weight: no urgent cut (the hosts and the toasts have it)
                self._fight(f"fight:{ag.name}", "fight", ag.position, now, text, agent=ag.name)
            if was not in ("hurt", "fighting"):
                ag.bump(3, now)
                self.alert("fight", text, key=f"fight:{ag.name}", agent=ag.name, ttl=60, position=ag.position,
                           surface=ag.surface or "nauvis")
        ag.combat_state, ag.combat_info = state, info
        ag.combat = state in ("hurt", "fighting")
        if "plan" in a:
            ag.plan = a["plan"] if active and active != "guard" else None
        if "auto" in a:
            ag.auto = a["auto"] or None
        said = a.get("last_said")
        if said and said.get("text") and (not ag.last_said or said.get("tick") != ag.last_said.get("tick")):
            if ag.seen:
                ag.bump(2, now)
                ag.last_activity_t = now
            ag.last_said = dict(said, t=now)
        ag.seen = True

    def notice(self, text, now=None):
        """A notice line of the stream's own in the chat feed (lane 'notice', as the harness's: hostview.py)."""
        now = now or time.time()
        self._ingest_chat({"seq": f"stream-notice-{int(now * 1000)}", "tick": None, "from": "stream", "text": text, "t": now, "notice": True}, now)

    def set_chat_log(self, path):
        """runs/RUN/chat.jsonl (tools/chat-log.py: {seq, tick, ..., logged_at}): the wall time of lines read again at a
        restart."""
        self.chat_log_path, self.chat_log_times = path, None

    def chat_time(self, m):
        """(d19 batch42 A5, viewer Aurora: "old chat restored after a restart ... earlier defense replies now look new")
        A backlog line's wall time: chat.jsonl's logged_at for its seq and tick, else the game ticks since it (at 60 a
        second) before the tick read now."""
        if self.chat_log_times is None:
            self.chat_log_times = {}
            try:
                with open(self.chat_log_path, "rb") as f:
                    f.seek(0, 2)
                    f.seek(max(0, f.tell() - CHAT_LOG_TAIL))
                    for raw in f.read().decode("utf-8", "replace").splitlines():
                        try:
                            r = json.loads(raw)
                            self.chat_log_times[(r["seq"], r["tick"])] = datetime.datetime.fromisoformat(r["logged_at"]).timestamp()
                        except (ValueError, KeyError, TypeError):
                            pass
            except (OSError, TypeError):
                pass
        t = self.chat_log_times.get((m.get("seq"), m.get("tick")))
        if t is not None:
            return t
        return self.tick_time(m["tick"])

    def tick_time(self, tick):
        """A line's wall time from its game tick: the game ticks since it (at 60 a second) before the tick read now. A
        lower bound on its age across a shift break (the server stood still between shifts)."""
        return (self.tick_t or time.time()) - max(0, self.tick - tick) / 60.0

    # (d22 batch111 BU1, Nick: a Sol line "keeps coming back onto the stream at weird random times throughout the past
    # few days") live.py reads confessions, tells and board_events from 0 after a restart, and operator_requests from
    # the inbox file's last seq: the first reads return the runtime's kept lines (Sol's confessional seq 67, tick
    # 10291268, was voiced 11 times in shift52-60, each about 20 s after a caster start, with Astra's seq 65). As for
    # restored chat (_ingest_chat): a line from a feed's backlog older than HISTORY_S by game tick keeps its own time
    # and is marked history (the site, the overlay; never voiced, no interest for the director).
    def backlog_old(self, m, feed):
        """True for a line of `feed` read before its backlog is done whose tick is more than HISTORY_S behind now."""
        return feed not in self.feeds_live and isinstance(m.get("tick"), (int, float)) and bool(self.tick) \
            and (self.tick - m["tick"]) / 60.0 > HISTORY_S

    def _feeds_read(self, obs, feeds):
        """A feed's backlog is done at its first empty read (live.py puts each feed it read in obs, [] when nothing is
        new; the confessions and tells reads return the newest kept at once, board_events 100 at a time)."""
        for feed in feeds:
            if isinstance(obs.get(feed), list) and not obs[feed]:
                self.feeds_live.add(feed)

    def _restore(self, entry, m, feed):
        """Mark a backlog line history with its own time (backlog_old); True when it did."""
        if not self.backlog_old(m, feed):
            return False
        entry["t"], entry["history"] = self.tick_time(m["tick"]), True
        return True

    def _ingest_chat(self, m, now, restored=False):
        key = m.get("seq") or (m.get("tick"), m.get("from"), m.get("text"))
        if key in self.chat_seen:
            return
        self.chat_seen.add(key)
        sender = self._match_sender(m.get("from", ""))
        entry = {"seq": m.get("seq"), "tick": m.get("tick"), "from": m.get("from"), "agent": sender,
                 "text": m.get("text", ""), "t": m.get("t", now)}
        if restored and m.get("t") is None and isinstance(m.get("tick"), (int, float)) and self.tick \
                and (self.tick - m["tick"]) / 60.0 > HISTORY_S:
            # said before this restart: its own time, and marked history (the site, the overlay; never voiced again)
            entry["t"], entry["history"] = self.chat_time(m), True
        if m.get("aloud"):  # the agent asked for this line to be voiced on stream (tools/stream/caster.py)
            entry["aloud"] = True
        if m.get("source"):  # a relayed viewer line: where the viewer wrote, YouTube or site (chat.lua)
            entry["source"] = m["source"]
        if isinstance(m.get("look"), dict):  # say look=: what the camera might show while it is read out (onecam cue)
            entry["look"] = m["look"]
        if isinstance(m.get("reply_to"), int):  # say reply_to a viewer line (chat.lua; viewer_replies.py threads it)
            entry["reply_to"] = m["reply_to"]
        # (d22 batch75 AK6) each viewer line a say answers as chat.lua kept it {seq, name, id, source, tick, text}, linked_by
        # "name" when the harness linked it by the name it says, and a viewer line's own id where it was written
        if isinstance(m.get("replies_to"), list):
            entry["replies_to"] = [r for r in m["replies_to"] if isinstance(r, dict) and r.get("name")][:8]
        if m.get("linked_by") == "name":
            entry["linked_by"] = "name"
        if isinstance(m.get("source_id"), str):
            entry["source_id"] = m["source_id"]
        if m.get("viewer"):  # a viewer's line the operator relayed into the game chat (audience.lua)
            entry["viewer"] = m["viewer"]
        if m.get("notice"):  # a harness notice: the agents' mute votes and their results (audience.lua)
            entry["notice"] = True
        entry["lane"] = chat_lane(entry)
        self.chat.append(entry)
        if viewer_replies.viewer_name(entry):  # (d20 batch57 S1) a say's reply_to finds it after it left self.chat
            self.reply_threads.see(entry)
        if entry["lane"] not in ("viewer", "notice"):
            viewer_replies.link_line(entry, self.reply_links())  # (AA2) the line tools/opreply.py named
            r = self.reply_threads.classify(entry, [c for c in self.chat if viewer_replies.viewer_name(c)],
                                            self.inbox_lines() if viewer_replies.speaker(entry) == "operator" else ())
            if r:
                self.viewer_replies.append(viewer_replies.row(entry, r))
        cl = None if sender else CHANGELOG_RE.match(clean_text(entry["text"]))
        if cl:
            self._changelog(cl.group(2).strip(), m.get("tick"), entry["t"], version=cl.group(1))
        if sender and entry["t"] > now - 30:
            ag = self.agents[sender]
            ag.bump(2, now)
            ag.last_activity_t = now

    def chat_window(self, talk=12, other=8, tells=24, heard=12):
        """The last `talk` conversation lines, the last `tells` tells (enough for the page to fold a burst), the last
        `heard` viewer and operator lines (the page pairs agents' answers with the viewer lines they saw in game,
        chatfeed.js viewerPins) and the last `other` log / notice lines, in arrival order: one kind must not push
        another off the page."""
        msgs = list(self.chat)
        keep = {id(m) for m in [m for m in msgs if m.get("lane") == "talk"][-talk:]}
        keep |= {id(m) for m in [m for m in msgs if m.get("lane") == "tell"][-tells:]}
        keep |= {id(m) for m in [m for m in msgs if m.get("lane") in ("viewer", "operator")][-heard:]}
        keep |= {id(m) for m in [m for m in msgs if m.get("lane") not in ("talk", "tell", "viewer", "operator")][-other:]}
        return [m for m in msgs if id(m) in keep]

    def _ingest_confession(self, c, now):
        """audience.lua `confessions` (operator read): {seq, tick, from, text}, an agent talking to the viewers only."""
        key = ("confess", c.get("seq"))
        if key in self.chat_seen:
            return
        self.chat_seen.add(key)
        sender = self._match_sender(c.get("from", ""))
        entry = {"seq": f"c{c.get('seq')}", "tick": c.get("tick"), "from": c.get("from"), "agent": sender,
                 "text": c.get("text", ""), "t": c.get("t", now), "confess": True, "lane": "talk"}
        old = self._restore(entry, c, "confessions")
        self.chat.append(entry)
        if sender and not old:
            self.agents[sender].bump(2.5, now)

    def _ingest_tell(self, t, now):
        """tells.lua `tells` (operator read): {seq, tick, from, to (names or "team"), text}, what an agent sent to
        teammates outside the game chat: the team's main channel (shake7: ~540 tells to ~100 chat lines). Lane "tell":
        the page shows them in the chat feed as direct lines ("Sol → Astra", `to_shown` and `body`); `text` stays
        "-> Astra: ..." for the site's live feed and the logs. Never voiced."""
        key = ("tell", t.get("seq"))
        if key in self.chat_seen:
            return
        self.chat_seen.add(key)
        sender = self._match_sender(t.get("from", ""))
        to = t.get("to")
        names = ["team"] if to == "team" else [n for n in (to or []) if isinstance(n, str)]
        shown = ", ".join("team" if n == "team" else (self.agents[m].display_name or n) if (m := self._match_sender(n))
                          else n for n in names)
        entry = {"seq": f"t{t.get('seq')}", "tick": t.get("tick"), "from": t.get("from"), "agent": sender,
                 "text": f"\u2192 {shown}: {t.get('text', '')}", "t": t.get("t", now), "tell": True, "lane": "tell",
                 "to_shown": shown, "to": names, "body": t.get("text", "")}
        old = self._restore(entry, t, "tells")
        self.chat.append(entry)
        if sender and not old:
            self.agents[sender].bump(1, now)

    def _ingest_operator_request(self, r, now):
        """An agent's request to the operator (tells.lua `operator`; live.py's rows {t, seq, agent, text}): shown on
        the ticker like a tell ("Astra → operator: ..."), kept among the snapshot's last few. Never voiced."""
        key = ("operator", r.get("seq"))
        if key in self.chat_seen:
            return
        self.chat_seen.add(key)
        sender = self._match_sender(r.get("agent", ""))
        text = r.get("text", "")
        entry = {"seq": f"o{r.get('seq')}", "tick": r.get("tick"), "from": r.get("agent"), "agent": sender,
                 "text": f"→ operator: {text}", "t": r.get("t", now), "tell": True, "operator": True, "lane": "tell",
                 "to_shown": "operator", "to": ["operator"], "body": text}
        # (live.py's t is when the inbox row was written, the read's time: a backlog row's own time is its tick's)
        old = self._restore(entry, r, "operator_requests")
        self.chat.append(entry)
        self.operator_requests.append({"seq": r.get("seq"), "t": entry["t"], "agent": sender or r.get("agent"),
                                       "display_name": self.agents[sender].display_name if sender else None, "text": text,
                                       **({"history": True} if old else {})})
        if sender and not old:
            self.agents[sender].bump(1, now)

    def _match_sender(self, frm):
        frm = (frm or "").lower()
        for name, ag in self.agents.items():
            aliases = {name, (ag.display_name or "").lower(), f"pog-{name}"}
            aliases |= {s.lower() for s in ag.cfg.get("aliases", [])}
            if frm in aliases:
                return name
        return None

    def _ingest_research(self, r, now):
        done = set(r.get("done") or [])
        res = self.research
        if not self.research_started:
            # seed "recent" with the most advanced technologies already finished (no timestamps known)
            for name in reversed(r.get("top_done") or []):
                res["recent"].appendleft({"name": name, "label": tech_label(name), "t": None})
            self.research_started = True
        else:
            for name in sorted(done - res["done"]):
                self.done_at[name] = now
                res["recent"].appendleft({"name": name, "label": tech_label(name), "t": now})
                self.alert("research", f"Research complete: {tech_label(name)}", key=f"research:{name}", ttl=40)
                self.research_news[name] = {"name": name, "label": tech_label(name), "t": now}
                # credit whoever has been busiest lately (labs are fed by the team; this keeps cameras lively)
                live = [a for a in self.agents.values() if a.alive and a.last_activity_t]
                for a in sorted(live, key=lambda a: -a.last_activity_t)[:2]:
                    a.bump(2.5, now)
        res["done"] = done
        res["current"] = r.get("current")
        res["progress"] = r.get("progress")
        res["packs"] = list(r.get("packs") or [])  # the running technology's packs (score's current_packs)
        if "repeating" in r:
            res["repeating"] = repeating_levels(r.get("repeating"), r.get("current"), r.get("progress"))
            res["repeating_tick"] = self.tick  # the game tick of this read (level_done_label)

    def unused_unlocks(self, now=None):
        """Researched technologies whose building the team has none of, oldest first: [{tech, unlocks, built,
        researched}], researched being "N minutes ago" or "before this stream" (already done when the stream
        started). For the hosts' commentary to viewers only; nothing here goes to the agents."""
        if not self.entities_counted:
            return []
        now = now or time.time()
        out = []
        for tech, (names, label) in UNLOCKS.items():
            if tech not in self.research["done"] or any(self.entities.get(n) for n in names) or \
                    not all(n in self.entities_counted for n in names):
                continue
            t = self.done_at.get(tech)
            out.append((t or 0, {"tech": tech_label(tech), "unlocks": label, "built": 0,
                                 "researched": f"{round((now - t) / 60)} minutes ago" if t else "before this stream"}))
        out.sort(key=lambda x: x[0])
        return [x for _, x in out][:4]

    def _ingest_board(self, b):
        """`board` read: current items (newest first) and the open unowned request count."""
        board = self.board
        board["available"] = True
        items = (b.get("items") or []) if isinstance(b, dict) else (b or [])
        if isinstance(b, dict) and b.get("open_unowned") is not None:
            board["open_unowned"] = b["open_unowned"]
        if isinstance(b, dict) and "plan" in b:  # the team plan (board_plan): goals and who is on what
            board["plan"] = b["plan"] or None
        if isinstance(b, dict) and "focus" in b:  # each agent's board_focus row by name; None: the runtime gave none
            rows = b["focus"]
            board["focus"] = {r["agent"]: r for r in rows if isinstance(r, dict) and r.get("agent")} if isinstance(rows, list) else None
        if isinstance(b, dict) and isinstance(b.get("progress"), list):  # (AK11) board_progress rows by id (None: kept)
            board["progress"] = {r["id"]: r for r in b["progress"] if isinstance(r, dict) and r.get("id") is not None}
        if isinstance(b, dict) and "active_ids" in b:  # the ids an active read listed (live.py): the open and doing lists
            board["active_ids"] = set(b["active_ids"]) if b["active_ids"] is not None else None
        if isinstance(b, dict) and "finished_ids" in b:  # (BI3) the finished tasks and requests a read listed
            board["finished_ids"] = set(b["finished_ids"]) if b["finished_ids"] is not None else None
        for it in items:
            if it.get("id") is not None:
                board["items"][it["id"]] = it
        if len(board["items"]) > 400:
            for key in sorted(board["items"], key=lambda k: board["items"][k].get("updated_tick") or 0)[:-300]:
                del board["items"][key]

    def _who(self, name):
        if not name:
            return None
        return name if name in self.agents else self._match_sender(name)

    def _ingest_board_event(self, e, now):
        board = self.board
        board["available"] = True
        key = e.get("seq") if e.get("seq") is not None else (e.get("tick"), e.get("id"), str(e.get("change")))
        if key in board["seen"]:
            return
        board["seen"].add(key)
        verb = board_verb(e.get("change"))
        it = board["items"].get(e.get("id")) or {}
        kind = e.get("kind") or it.get("kind")
        # keep the item cache moving between (slower) `board` reads, so claims and the request count stay current
        if e.get("id") is not None:
            it = board["items"].setdefault(e["id"], {"id": e["id"]})
            it["title"] = e.get("title") or it.get("title")
            it["kind"] = kind
            if "status" in e:  # eng/board events carry the item's status, owner and requester after the change
                for k in ("status", "owner", "requested_by"):
                    it[k] = e.get(k)
            else:
                status = "claimed" if verb == "posted" and kind == "claim" else BOARD_STATUS.get(verb)
                if status:
                    it["status"] = status
                if verb == "posted":
                    it.setdefault("requested_by", e.get("by"))
                    if kind == "claim":
                        it["owner"] = e.get("by")
                elif verb == "taken":
                    it["owner"] = e.get("by")
                elif verb in ("reopened", "released"):
                    it["owner"] = None
            it["updated_tick"] = e.get("tick")
            if e.get("progress") is not None:  # a project's events carry its progress after the change
                it["progress"] = e.get("progress")
            if board["open_unowned"] is not None and kind == "request":
                board["open_unowned"] = None  # recount from items until the next `board` read
        if verb in ("note", "updated") or (kind == "harness" and verb not in ("posted", "done")):
            return  # notes and operator bookkeeping are noise on stream
        if kind == "plan":
            return  # plan edits show as the plan line itself (board_snapshot)
        agent = self._who(e.get("by"))
        restored = self.backlog_old(e, "board_events")  # (BU1) a restart's replay of the kept events
        t = self.tick_time(e["tick"]) if restored else e.get("t", now)
        recent = t > now - 30
        title = e.get("title") or it.get("title") or ""
        if kind == "research":  # a finished technology (research.lua): no item, by "research"
            self._tech_unlocks(title, e.get("text"), now)
            row = next((r for r in self.research.get("repeating") or [] if r.get("name") == title), None)
            if row:  # an infinite technology: the level done (CB1); a restart's replay names it without one
                title = (None if restored else level_done_label(row, e.get("tick"), self.research.get("repeating_tick"))) \
                    or row["label"]
            else:
                title = tech_label(title)
        entry = {"seq": e.get("seq"), "tick": e.get("tick"), "by": e.get("by"), "agent": agent, "id": e.get("id"),
                 "verb": verb, "title": clean_text(title), "kind": kind,
                 "owner": it.get("owner"), "owner_agent": self._who(it.get("owner")), "t": t,
                 **({"history": True} if restored else {})}
        if kind == "project":  # its progress after this change ("3 of 7 steps"), and the step a step event did
            done, total = project_steps(e.get("progress"), e.get("steps_done"), e.get("steps_total"))
            entry.update(progress=e.get("progress"), steps_done=done, steps_total=total)
            if verb == "step":
                entry["step"] = clean_text(str(e.get("text") or ""))
        board["events"].append(entry)
        if agent and recent:
            self.agents[agent].bump({"done": 1.5, "posted": 1.0, "taken": 1.0, "step": 1.0}.get(verb, 0.5), now)
            self.agents[agent].last_activity_t = now
        if kind == "harness" and verb == "done":
            self._changelog(entry["title"], e.get("tick"), entry["t"])

    UNLOCKS_RE = re.compile(r"^unlocks: (.*?)(?:, \+(\d+) more)?$")

    def _tech_unlocks(self, name, text, now):
        """research.lua's board event for a finished technology carries "unlocks: a, b, +N more" (recipe names,
        "travel to vulcanus", "rare quality"). Kept per technology: the event can come before or after the score
        shows the technology done, and a replayed old event must not make a card (research_news comes from the
        score)."""
        m = self.UNLOCKS_RE.match(str(text or ""))
        if not name or not m:
            return
        names = [n.strip() for n in m.group(1).split(",") if n.strip()]
        self.unlocks[name] = {"unlocks": [human_name(n) for n in names], "more": int(m.group(2) or 0)}

    def research_news_snapshot(self, now):
        """Technologies finished in the last 30 s (seen in the score), with what they unlock when the board said:
        the stream's "Research complete" card (overlay.js renderResearchCard)."""
        for k in [k for k, v in self.research_news.items() if now - v["t"] > 120]:
            del self.research_news[k]
        out = []
        for name, n in sorted(self.research_news.items(), key=lambda kv: kv[1]["t"]):
            if now - n["t"] <= 30:
                u = self.unlocks.get(name) or {}
                out.append(dict(n, unlocks=u.get("unlocks") or [], more=u.get("more") or 0, age_s=round(now - n["t"], 1)))
        return out

    def _changelog(self, text, tick, t, version=None):
        """A harness request marked done (title, no version) and the operator's chat line "harness vN: what"
        usually arrive together: merge them into one changelog line."""
        cl = self.board["changelog"]
        if any(c["text"] == text and c["version"] == version for c in cl):
            return
        if cl and abs((t or 0) - (cl[-1]["t"] or 0)) < 180 and bool(version) != bool(cl[-1]["version"]):
            last = cl[-1]
            if version:
                last.update(version=version, text=text, request=last["text"])
            else:
                last["request"] = text
            return
        cl.append({"text": text, "version": version, "request": None if version else text, "tick": tick, "t": t})

    # (d20 batch65 AA4) every job for the site's "Show all" (push_live.public_reminders keeps them within its budget);
    # a cap against a runaway list
    REMINDERS_MAX = 100

    def reminders_snapshot(self):
        """The team's reminder jobs for the site's panel (d15 batch5 group I): owner, message, next due, the last result
        and its age, and each recipient's state (pending, acknowledged, overdue); None before the first read."""
        r = self.reminders
        if not isinstance(r, dict):
            return None
        rows = []
        for j in (r.get("jobs") or [])[:self.REMINDERS_MAX]:
            if not isinstance(j, dict):
                continue
            rows.append({"id": j.get("id"), "name": clean_text(j.get("name") or ""), "owner": j.get("owner"),
                         "agent": self._who(j.get("owner")), "recipients": j.get("recipients"),
                         "message": clean_text(j.get("message") or ""), "cadence": j.get("cadence"),
                         "enabled": bool(j.get("enabled")), "done": bool(j.get("done")),
                         "next_due_in_s": j.get("next_due_in_s"), "last_result": clean_text(j.get("last_result") or "") or None,
                         "result_age_s": j.get("result_age_s"), "result_by": j.get("result_by"), "states": j.get("states"),
                         # (d17 batch35 D3) runs each recipient missed ({name: runs}); states says when the owner was told
                         "missed": {str(k): v for k, v in (j.get("missed") or {}).items() if isinstance(v, int)} or None,
                         # (d20 batch70 AF2, viewer Aurora) its backup, and each recipient's latest result or wait
                         "backup": j.get("backup") or None, "latest": self._reminder_latest(j.get("latest")),
                         # (d19 batch43 A2) the evidence given with its acknowledgments (batch41 B2), whole
                         **with_evidence(j)})
        return {"jobs": rows, "total": len(r.get("jobs") or [])}

    LATEST_RESULT = 240  # a recipient's latest result on the panel (the job's last result stays whole)

    def _reminder_latest(self, rows):
        """(d20 batch70 AF2) each recipient's latest as the runtime gives it (reminders.lua latest): acknowledged when,
        with what and by whom (a backup's for them), or waiting how long with the runs missed; None from an older runtime."""
        if not isinstance(rows, list):
            return None
        out = []
        for x in rows[:12]:
            if not isinstance(x, dict) or not x.get("name"):
                continue
            res = clean_text(x.get("result") or "") or None
            if res and len(res) > self.LATEST_RESULT:
                res = res[:self.LATEST_RESULT - 3].rstrip() + "..."
            num = lambda k: x.get(k) if isinstance(x.get(k), (int, float)) and not isinstance(x.get(k), bool) else None  # noqa: E731
            out.append({"name": x["name"], "agent": self._who(x["name"]), "state": x.get("state"),
                        "acked_ago_s": num("acked_ago_s"), "result": res, "by": x.get("by") or None,
                        "waiting_s": num("waiting_s"), "missed": num("missed"),
                        "backup_told": bool(x.get("backup_told_tick"))})
        return out or None

    def board_snapshot(self):
        b = self.board
        items = list(b["items"].values())
        claims = [it for it in items if it.get("kind") == "claim" and it.get("status") in ("open", "claimed", "doing")]
        claims.sort(key=lambda it: -(it.get("updated_tick") or 0))
        unowned = b["open_unowned"]
        if unowned is None:
            unowned = sum(1 for it in items if it.get("kind") == "request" and it.get("status") == "open"
                          and not it.get("owner"))
        doing = sum(1 for it in items if it.get("kind") in ("task", "request") and it.get("status") in ("claimed", "doing"))
        projects = self.projects_snapshot()
        # (AK11) the card shows every project worked on or blocked (up to PROJECTS_SHOWN_MAX), at least 4
        shown = max(4, min(PROJECTS_SHOWN_MAX, sum(1 for r in projects if r.get("state"))))
        open_items, doing_items = self.jobs_snapshot()
        return {
            "available": b["available"],
            "events": list(b["events"])[-8:],
            "open_unowned": unowned,
            "in_progress": doing,
            "claims": [{"id": it.get("id"), "title": clean_text(it.get("title") or ""), "owner": it.get("owner"),
                        "agent": self._who(it.get("owner")), **with_evidence(it)} for it in claims[:6]],
            "claims_total": len(claims),
            "changelog": list(b["changelog"])[-2:],
            "plan": self.plan_snapshot(),
            "projects": projects[:shown],
            "projects_total": len(projects),
            # the projects the card hides, and the last finished ones (Foobator 08:31: "no way to browse hidden projects")
            "projects_more": projects[shown:30],
            "projects_done": self.done_projects_snapshot(),
            # the jobs behind the two counts (viewer joonazan, d15 08:19): open tasks and requests nobody owns, and those
            # claimed or being done, the latest changed first, JOBS_MAX each; absent until an active read listed them
            **({"open_items": open_items[:self.JOBS_MAX], "open_items_total": len(open_items),
                "doing_items": doing_items[:self.JOBS_MAX], "doing_items_total": len(doing_items)}
               if open_items is not None else {}),
        }

    JOBS_MAX = 20
    ALL_MAX = 400  # (BI3) board_all_snapshot's tasks and requests at most

    def board_all_snapshot(self):
        """(d22 batch99 BI3, viewer Aurora site:4316: "Could the board show all tasks and reminders, with paging if
        needed?") Every task and request the last board reads listed (open, claimed, doing, blocked, done, dropped),
        every claim, every project read (open and finished) and every reminder job, for the site's full lists (serve.py
        /board.json; push_live sends it apart from the state). Rows as the board snapshot's, with status and when each
        last changed (updated_tick); the latest changed first. None before an active read."""
        ids = self.board.get("active_ids")
        if ids is None:
            return None
        fin = self.board.get("finished_ids") or set()
        items = [it for i, it in self.board["items"].items()
                 if it.get("kind") in ("task", "request") and (i in ids or i in fin or it.get("status") in ("done", "dropped"))]
        items.sort(key=lambda it: -(it.get("updated_tick") or 0))
        claims = [it for it in self.board["items"].values() if it.get("kind") == "claim"
                  and it.get("status") in ("open", "claimed", "doing")]
        claims.sort(key=lambda it: -(it.get("updated_tick") or 0))

        def row(it):
            return {"id": it.get("id"), "title": clean_text(it.get("title") or ""), "kind": it.get("kind"),
                    "owner": it.get("owner"), "agent": self._who(it.get("owner")), "status": it.get("status"),
                    "requested_by": it.get("requested_by"), "updated_tick": it.get("updated_tick"), **with_evidence(it)}
        projects = [self.project_row(it) for it in self._projects(("open", "claimed", "doing", "blocked", "done", "dropped"))]
        rem = self.reminders_snapshot() or {}
        return {"tick": self.tick, "items": [row(it) for it in items[:self.ALL_MAX]], "items_total": len(items),
                "claims": [row(it) for it in claims], "projects": projects,
                "reminders": rem.get("jobs") or [], "reminders_total": rem.get("total") or 0}

    def jobs_snapshot(self):
        """(open, doing): tasks and requests from the last active board read (board.active_ids), open with no owner, and
        claimed or doing; each {id, title, kind, owner, agent, status, requested_by, updated_tick (the site's "changed
        N ago", d23 batch119 CB2)}, the latest changed first. (None,
        None) before an active read (an older service, or the read failed)."""
        ids = self.board.get("active_ids")
        if ids is None:
            return None, None
        rows = [it for i, it in self.board["items"].items() if i in ids and it.get("kind") in ("task", "request")]
        rows.sort(key=lambda it: -(it.get("updated_tick") or 0))
        def row(it):
            return {"id": it.get("id"), "title": clean_text(it.get("title") or ""), "kind": it.get("kind"),
                    "owner": it.get("owner"), "agent": self._who(it.get("owner")), "status": it.get("status"),
                    "requested_by": it.get("requested_by"), "updated_tick": it.get("updated_tick"), **with_evidence(it)}
        open_ = [row(it) for it in rows if it.get("status") == "open" and not it.get("owner")]
        doing = [row(it) for it in rows if it.get("status") in ("claimed", "doing")]
        return open_, doing

    def projects_snapshot(self):
        """Open projects (board kind project) for the board widget and the site: title, owner, progress ("3 of 7 steps")
        and its numbers for a bar. (d22 batch75 AK11, viewer Foobator site:4284: "can projects that are actively being
        worked on and blocked projects be easier to see on site?") Those being worked on first (status doing, or an
        agent's board focus on it), then the blocked ones (status blocked, or an open item in blocked_by), then the rest;
        the latest changed first within each."""
        rows = [self.project_row(it) for it in self._projects(("open", "claimed", "doing", "blocked"))]
        rank = {"active": 0, "blocked": 1}
        return sorted(rows, key=lambda r: rank.get(r.get("state"), 2))  # stable: the latest changed first within each

    def done_projects_snapshot(self):
        """Finished projects (status done) the last board read listed, the latest first: the live page's "show all"."""
        return [self.project_row(it) for it in self._projects(("done",))][:10]

    def _projects(self, statuses):
        rows = [it for it in self.board["items"].values() if it.get("kind") == "project" and it.get("status") in statuses]
        rows.sort(key=lambda it: -(it.get("updated_tick") or 0))
        return rows

    def project_row(self, it):
        """One project for the board widget and the site: title, owner, status, progress and its numbers, next step, goal;
        and when present its steps (all of them once live.py read the project in full; else the next open ones, with
        steps_partial), what it needs, its handoff and who asked for it when not its owner (viewer Foobator, d15 08:31:
        "we cant see the individual steps")."""
        done, total = project_steps(it.get("progress"))
        full = isinstance(it.get("steps"), list)
        steps = parse_steps(it.get("steps") if full else it.get("next_steps"), known=lambda n: self._who(n) is not None)
        nxt = [f"[ ] {s['text']}" for s in steps if s.get("next")]
        row = {"id": it.get("id"), "title": clean_text(it.get("title") or ""), "owner": it.get("owner"),
               "agent": self._who(it.get("owner")), "status": it.get("status"),
               "progress": it.get("progress") or "", "done": done, "total": total,
               # its next step and goal for the site's Team plan (viewer Alex 22:12; a list row's next_steps)
               "next": project_next(nxt or it.get("next_steps")), "goal": clean_text(it.get("goal") or "") or None}
        if steps:
            row["steps"] = steps
            if not full:
                row["steps_partial"] = True
        needs = it.get("needs")
        if isinstance(needs, dict) and needs:
            row["needs"] = {str(k): v for k, v in needs.items() if isinstance(v, (int, float))}
        if it.get("handoff"):  # (d19 batch43 A3) whole: up to 1000 characters (it was cut at 300 here, mid-word)
            row["handoff"] = clean_text(str(it["handoff"]))
        ev = evidence_lines(it.get("evidence"))
        if ev:
            row["evidence"] = ev
        if it.get("requested_by") and it.get("requested_by") != it.get("owner"):
            row["requested_by"] = it["requested_by"]
        row.update(self.project_state(it))
        return row

    def project_state(self, it):
        """(d22 batch75 AK11) What the board holds on whether a project is worked on or blocked, and why: state "active"
        (status doing, or an agent's board focus on it), "blocked" (status blocked, or an open item in its blocked_by) or
        None; focus [{agent, step, blocker}] (the board_focus rows on it); blocked_by [{id, title, status, owner}] (the
        open ones the board read has; an id alone otherwise); note {by, text, tick} (its newest note, when blocked);
        check {state, stalled, unchanged_checks, checked_s, last_change_s, error} (progress.lua's last check, board_progress).
        Facts as the board holds them; nothing judged."""
        out = {}
        items = self.board.get("items") or {}
        focus = [f for f in (self.board.get("focus") or {}).values() if isinstance(f, dict) and f.get("id") == it.get("id")]
        if focus:
            out["focus"] = [{k: f.get(k) for k in ("agent", "step", "blocker", "stale") if f.get(k)} for f in focus]
        live = ("open", "claimed", "doing", "blocked")
        by = []
        for bid in it.get("blocked_by") or []:
            o = items.get(bid)
            if o is None:
                by.append({"id": bid})
            elif o.get("status") in live:
                by.append({"id": bid, "title": clean_text(o.get("title") or ""), "status": o.get("status"), "owner": o.get("owner")})
        if by:
            out["blocked_by"] = by
        blocked = it.get("status") == "blocked" or any(b.get("status") in live for b in by)
        state = "active" if (it.get("status") == "doing" or focus) else "blocked" if blocked else None
        if state:
            out["state"] = state
        notes = [n for n in it.get("notes") or [] if isinstance(n, dict) and n.get("text")]
        if blocked and notes:
            n = notes[-1]
            out["note"] = {"by": n.get("by"), "text": clean_text(str(n["text"])), "tick": n.get("tick")}
        pr = (self.board.get("progress") or {}).get(it.get("id"))
        if isinstance(pr, dict):
            chk = {"state": pr.get("state"), "stalled": pr.get("stalled") or None, "unchanged_checks": pr.get("unchanged_checks"),
                   "checked_s": pr.get("checked_s"), "last_change_s": pr.get("last_change_s"), "error": pr.get("check_error")}
            out["check"] = {k: v for k, v in chk.items() if v is not None}
        work = self.owner_work(it)
        if work:
            out["owner_work"] = work
        return out

    def owner_work(self, it, now=None):
        """(d22 batch99 BI5, viewer Aurora site:4333: "Asterion still shows stalled while Astra's timed flight watch is
        running. Could the board show the active test and its deadline alongside the last progress check?") The
        project owner's running bounded watches (status work: uptime, turret_tally, belt_flow, collector_tally,
        asteroid_watch, and the flight watches it set) and its current wait, as its card reads them: [{kind, line,
        end_tick, names}], names the board items a watch names (an item's #id in its scope or reason); this: true when it
        names this item: its #id, or this item's title naming, as a word, the watch's scope or a platform its scope
        names (Astra's asteroid_watch "asteroids and 97 turrets on Asterion" and project #1807 "Asterion: finish
        coldstart ...", world n 17:05). Facts only:
        the progress check's state stays as it is."""
        ag = self.agents.get(it.get("owner")) if it.get("owner") else None
        if not ag:
            return None
        now = (getattr(self, "snap_now", None) or time.time()) if now is None else now
        title = (it.get("title") or "").lower()
        items = self.board.get("items") or {}
        plats = [p["name"] for p in (self.space.get("platforms") or []) if isinstance(p, dict) and p.get("name")]
        rows = []
        for w in ag.watches or []:
            if not isinstance(w, dict) or w.get("state") not in ("running", "armed"):
                continue
            line = workcard.rows([w], None, None, None, self.tick)[0]["line"]
            text = " ".join(str(w.get(k) or "") for k in ("scope", "reason", "line"))
            named = []
            for m in re.finditer(r"#(\d+)", text):
                i = int(m.group(1))
                if i in items and i not in [n["id"] for n in named]:
                    named.append({"id": i, "title": clean_text(items[i].get("title") or "")})
            # the places it watches: its scope as a whole (a flight watch's platform), and each platform it names
            # ("asteroids and 97 turrets on Asterion"); this item when its title names one of them as a word
            scope = str(w.get("scope") or "").strip()
            places = [scope] + [p for p in plats if re.search(r"\b" + re.escape(p.lower()) + r"\b", scope.lower())]
            this = any(n["id"] == it.get("id") for n in named) or any(
                len(x) >= 4 and re.search(r"\b" + re.escape(x.lower()) + r"\b", title) for x in places)
            row = {"kind": w.get("kind") or "watch", "line": line, "end_tick": w.get("end_tick"),
                   "names": named or None, "this": this or None}
            rows.append({k: v for k, v in row.items() if v is not None})
        wl = waitcard.line(ag.wait, self.tick, now) if ag.wait else None
        if wl:
            rows.append({"kind": "wait", "line": wl, "end_tick": (ag.wait or {}).get("until_tick")})
        return rows or None

    def plan_snapshot(self):
        """The team plan for the board widget and the site's Team plan: goals, each agent's line (agent name matched to
        its card), last edit; with a runtime that gives the plan's ticks (board plan_ticks), the tick each line was set
        and who set it when not the agent itself (`by`), the goals' tick and the last edit's."""
        p = self.board.get("plan")
        if not isinstance(p, dict) or not (p.get("goals") or p.get("doing")):
            return None
        ticks = {str(l.get("agent")): l for l in p.get("lines") or [] if isinstance(l, dict)}
        doing = []
        for line in p.get("doing") or []:
            name, _, text = str(line).partition(": ")
            # (d23 batch123 CF1) the runtime's stale mark rides at the end of the line; the rows carry it apart
            text = re.sub(r" \[marked stale .*\]$", "", text)
            row = {"agent": self._who(name), "name": name, "text": clean_text(re.sub(r" \(set by [^)]*\)$", "", text))}
            t = ticks.get(name)
            if t:
                row["tick"] = t.get("tick")
                if t.get("by") and t.get("by") != name:
                    row["by"] = t.get("by")
                if t.get("stale"):
                    row["stale"] = clean_text(t["stale"])
            doing.append(row)
        out = {"goals": clean_text(p.get("goals") or ""), "doing": doing, "edited": p.get("edited")}
        if p.get("goals_tick") is not None:
            out["goals_tick"] = p["goals_tick"]
        if p.get("updated_tick") is not None:
            out["updated_tick"] = p["updated_tick"]
        return out

    def _ingest_power(self, p, now):
        self.power = p
        machines, starved = p.get("machines") or 0, p.get("starved") or 0
        if machines >= 10 and starved / machines > 0.25 and not self.paused:
            self.alert("power", f"Low power: {starved} of {machines} machines starved", key="power", ttl=90)

    def _ingest_event(self, e, now):
        e = self._on_platform(e)
        if e["kind"] == "loss" and e.get("platform"):
            m = re.match(r"(\d+) lost", e["text"])
            seen = self.platform_losses.setdefault(e["platform"], {})
            key = e.get("key") or e["text"]
            total = int(m[1]) if m else 1
            if key not in seen or total > seen[key][0]:  # re-reported every poll: the time only moves when it grows
                seen[key] = (total, now)
            for k in [k for k, v in seen.items() if now - v[1] > 600]:
                del seen[k]
        if e["kind"] == "loss" and HUB_LOST.search(e["text"]):
            self.hub_losses.append((now, e.get("platform"), e["text"]))
        ag = self.agents.get(e.get("agent")) if e.get("agent") else None
        if e["kind"] == "attack" and ag:
            ag.bump(6, now)
        p = e.get("position")
        fresh = e.get("key") not in self.alert_keys or now - self.alert_keys[e["key"]] >= e.get("ttl", 60)
        if p and e["kind"] in ("attack", "loss"):
            self._fight(e.get("key") or f"{e['kind']}:{p['x']},{p['y']}", e["kind"], p, now, e["text"],
                        loss=e["kind"] == "loss" and fresh, tick=e.get("tick"))
        if p and fresh:  # a fight somewhere: pull cameras toward agents near it
            for other in self.agents.values():
                if other.position and math.hypot(other.position["x"] - p["x"], other.position["y"] - p["y"]) <= 60:
                    other.bump(4, now)
        self.alert(e["kind"], e["text"], key=e.get("key") or f"{e['kind']}:{e['text']}", agent=e.get("agent"),
                   ttl=e.get("ttl", 60), position=p, surface=(p or {}).get("surface") or (
                       ag.surface if ag and ag.surface else "nauvis" if e["kind"] in ("attack", "loss") else None),
                   platform=e.get("platform"))

    def alert(self, kind, text, key=None, agent=None, ttl=45, position=None, facts=None, surface=None, platform=None):
        """surface: where it happened (a planet or a platform's surface; None for research, power, space news), for the
        hosts (caster.py: each battle fact says its planet; viewer Joonazan, 13:38: lines that mix planets)."""
        now = time.time()
        key = key or f"{kind}:{text}"
        if key in self.alert_keys and now - self.alert_keys[key] < ttl:
            return
        self.alert_keys[key] = now
        row = {"id": f"{key}:{int(now)}", "key": key, "kind": kind, "text": text, "agent": agent,
               "t": now, "until": now + min(ttl, 40), "position": position}
        if facts:  # a headline's facts for the hosts (caster.py facts_for): names, place, cause
            row["facts"] = facts
        if surface:
            row["surface"] = surface
        if platform:
            row["platform"] = platform
        self.alerts.append(row)

    # ---- which platform a fight is on -------------------------------------------------------------------------
    def platform_of(self, e):
        """The platform row an attack or loss is on, or None. The attack's surface names it (live.py: the platform
        views give each platform's surface); a loss line has no surface, so space-only buildings (a hub, an asteroid
        collector, a thruster, a crusher) or asteroid attackers place it on a platform: the only one, else unknown.
        shift04 05:15: "A space platform hub is gone" was Skylark, never named."""
        plats = self.space.get("platforms") or []
        surf = ((e.get("position") or {}).get("surface") or "").lower()
        if surf and surf != "nauvis":
            for p in plats:
                if surf == str((p.get("view") or {}).get("surface") or "").lower() or surf == str(p.get("name")).lower():
                    return p
        if not SPACE_HIT.search(e.get("text") or ""):
            return None
        return plats[0] if len(plats) == 1 else {"name": None}

    def _on_platform(self, e):
        p = self.platform_of(e) if e["kind"] in ("attack", "loss") else None
        if not p:
            return e
        where = platform_place(p) if p.get("name") else None
        label = f"platform {p['name']}" + (f" ({where})" if where else "") if p.get("name") else "a space platform"
        text = e["text"]
        text = re.sub(r"^(\d+ lost)(?: near \([^)]*\))?", rf"\1 on {label}", text)
        text = re.sub(r"^Base under attack(?: near \([^)]*\))?", f"{label[0].upper() + label[1:]} under attack", text)
        if HUB_LOST.search(text) and e["kind"] == "loss":
            text += f"; the hub is gone, so {p['name'] or 'the platform'} is destroyed"
        return dict(e, text=text, platform=p.get("name"))

    # ---- derived ---------------------------------------------------------------------------------------------
    def is_resting(self, ag, now=None):
        r = ag.resting
        return bool(r and r.get("until", 0) > (now or time.time()))

    def activity(self, ag, now):
        if not ag.connected:
            return "offline"
        if not ag.alive:
            return "dead"
        if self.is_resting(ag, now):  # between turns, pacing its quota: neither idle nor offline
            return "resting"
        if ag.active:
            return "acting"
        if ag.last_activity_t and now - ag.last_activity_t < THINK_WINDOW and not self.paused:
            return "thinking"
        return "idle"

    def action_text(self, ag):
        if not ag.connected:
            return "client offline"
        if self.is_resting(ag):
            return pacing.label(ag.resting)
        if not ag.alive:
            if ag.dead_until_tick and ag.dead_until_tick > self.tick:
                return f"respawning in {math.ceil((ag.dead_until_tick - self.tick) / 60)} s"
            return "dead"
        if ag.combat_state == "guard":  # a shoot running with nothing in range (combat_state)
            return "on guard"
        if ag.combat_state == "fighting":  # shooting at something (a standing order's name would hide it)
            return "fighting"
        if ag.auto and ag.auto.get("name"):  # a standing order runs the character: "auto: restock ammo"
            return "auto: " + str(ag.auto["name"]).replace("-", " ").replace("_", " ")
        if ag.active:
            return describe_action(ag.active)
        if ag.last and ag.last.get("kind"):
            outcome = ag.last.get("outcome")
            return f"last: {ag.last['kind'].replace('_', ' ')}" + (f" ({outcome.replace('_', ' ')})" if outcome else "")
        return ""

    def location(self, ag):
        # Space Age: a bot in a cargo pod says so (bot travel); a platform or another planet is named
        if ag.travel in ("ascending", "descending"):
            return ag.where or "cargo pod"
        if ag.platform:
            return where_label(ag.surface, ag.platform)
        p = ag.position
        if not p:
            return None
        if ag.surface and ag.surface != "nauvis":  # landmarks and "m from spawn" are Nauvis coordinates
            return where_label(ag.surface, ag.platform)
        return self.spot_name(p)

    def spot_name(self, p):
        """A Nauvis point: its run landmark, "spawn", or "120 m NE" (from spawn)."""
        best = None
        for lm in self.run.get("landmarks", []):
            d = math.hypot(p["x"] - lm["x"], p["y"] - lm["y"])
            if d <= lm.get("r", 30) and (best is None or d < best[0]):
                best = (d, lm["name"])
        if best:
            return best[1]
        d = math.hypot(p["x"], p["y"])
        if d < 25:
            return "spawn"
        ang = math.degrees(math.atan2(-p["y"], p["x"])) % 360  # Factorio y grows southward
        dirs = ["E", "NE", "N", "NW", "W", "SW", "S", "SE"]
        return f"{int(round(d / 10) * 10)} m {dirs[int((ang + 22.5) // 45) % 8]}"

    # ---- Space Age -------------------------------------------------------------------------------------------
    def _space_moments(self, now):
        """First rocket, first platform, a platform's first arrival at a planet other than Nauvis, the first landing
        on such a planet (an agent's body there, or our entities). Each fires once as a moment (segments.py turns it
        into a space_moment segment) and an alert; whatever is already true when the service starts is seeded."""
        sp = self.space
        found = []
        if sp.get("rockets"):
            found.append(("rocket", {"kind": "first_rocket", "title": "First rocket launched",
                                     "facts": {"rockets": sp["rockets"]}}))
        if self.rockets_at_start is None:
            # (d22 batch89 AY3) seeded once a shift, at its first service start, and kept in space-memory.json: a
            # mid-shift restart re-seeded it from the live count, and the next rocket read as "the first this shift"
            # (shift57 09:02, rocket 20001, with the shift's first at 06:21)
            self.rockets_at_start = sp.get("rockets") or 0
            self._save_space_memory()
        elif (sp.get("rockets") or 0) > self.rockets_at_start:  # the shift's first rocket (a headline)
            found.append(("shift_rocket", {"kind": "shift_rocket",
                                           "title": f"Rocket {sp['rockets']} launched, the first this shift",
                                           "facts": {"rockets": sp["rockets"]}}))
        plats = sp.get("platforms") or []
        if plats:
            p = plats[0]
            found.append(("platform", {"kind": "first_platform", "title": f"First space platform: {p['name']}",
                                       "facts": {"platform": p["name"], "where": platform_place(p)}}))
        for p in plats[1:]:  # every later platform launched is a headline too
            found.append((f"platform:{p['name']}", {"kind": "new_platform", "title": f"New space platform: {p['name']}",
                                                    "facts": {"platform": p["name"], "where": platform_place(p)}}))
        for p in plats:  # each platform's first arrival at each planet other than Nauvis
            loc = p.get("at") if p.get("at") in PLANET_LABELS else None
            if loc and loc != "nauvis":
                found.append((f"orbit:{p['name']}:{loc}", {
                    "kind": "orbit", "title": f"{p['name']} reaches {planet_label(loc)}",
                    "facts": {"platform": p["name"], "planet": planet_label(loc)}, "planet": loc}))
        landed = {s: None for s in sp.get("planets") or [] if s != "nauvis"}
        for ag in self.agents.values():
            if ag.surface and ag.surface != "nauvis" and not ag.platform and ag.alive:
                landed[ag.surface] = landed.get(ag.surface) or ag
        for planet, ag in landed.items():
            who = ag.display_name if ag else None
            found.append((f"landing:{planet}", {
                "kind": "landing", "planet": planet, "agent": ag.name if ag else None,
                "title": f"{who} lands on {planet_label(planet)}" if who else f"First foothold on {planet_label(planet)}",
                "facts": {"planet": planet_label(planet), "agent": who,
                          "planets_reached": len({"nauvis", *landed})}}))
        arrivals, self.arrivals = self.arrivals, []
        if self.space_seen is None:
            self.space_seen = {k for k, _ in found}
            return
        fired = set()
        for key, m in found:
            if key in self.space_seen:
                continue
            if m["kind"] == "orbit" and (m["facts"]["platform"], m["planet"]) in self.orbit_known:
                self.space_seen.add(key)  # been there before this service saw it (space-memory.json, a mid-trip start)
                continue
            self.space_seen.add(key)
            fired.add(key)
            m.update(id=f"m-{key}", key=key, t=now, game_time=fmt_game_time(self.tick / 60))
            m["facts"]["game_time"] = m["game_time"]
            self.moments.append(m)
            self.alert("space", m["title"], key=f"space:{key}", agent=m.get("agent"), ttl=40,
                       facts=dict(m["facts"], headline=m["kind"]))
        # every other arrival after a trip, home included (shift06 14:14:32 Sunward back at Nauvis: Astra called it,
        # the hosts had nothing; only a first arrival at a planet other than Nauvis was a moment). Firsts are
        # headlines: a platform's first arrival at a planet, the run's first there. Later ones (a ferry's round
        # trips) are an ordinary "arrival" below battles: a headline every trip pulled the hosts off fights.
        for name, planet, came, first, team_first in arrivals:
            if f"orbit:{name}:{planet}" in fired:
                continue
            aboard = [a.display_name or a.name for a in self.agents.values() if a.platform == name and a.alive]
            title = f"{name} is back at Nauvis" if planet == "nauvis" else f"{name} arrives at {planet_label(planet)}"
            facts = {"platform": name, "planet": planet_label(planet), "came_from": planet_label(came) if came else None,
                     "aboard": aboard or None, "game_time": fmt_game_time(self.tick / 60)}
            # (d23 batch130 CM1) what hoststory.ArrivalGate weighs: the leg's game minutes from its departure in the
            # route memory, and science or eggs in the hub
            left = self.route_last(name, came, planet, self.tick + 1) if came and self.tick else None
            if left is not None:
                facts["leg_minutes"] = round((self.tick - left) / 3600)
            row = next((p for p in sp.get("platforms") or [] if p.get("name") == name), None) or {}
            facts["carrying"] = story_cargo(row.get("hub_items")) or None
            trips = self.platform_course.get(name, {})
            trips["arrivals"] = trips.get("arrivals", 0) + 1  # one alert per arrival (keys dedupe within a ttl)
            key = f"arrive:{name}:{planet}:{trips['arrivals']}"
            if first or team_first:
                self.alert("space", title, key=key, ttl=120, facts=dict(
                    facts, headline="platform_arrival", first_visit=True, team_first=team_first or None))
            else:
                self.alert("arrival", title, key=key, ttl=120, facts=facts)

    def set_space_memory(self, path, earlier=()):
        """Keep where each platform has been, and the planets reached, in the run folder (serve.py), so a restart
        does not take a ferry's next arrival for a first: an arrival headline, or the one-time "X reaches Vulcanus"
        moment with its segment. (d22 batch75 AK2) Also where each platform stopped and the game tick it got there
        (`stops`); a run without its own file takes those from the newest of earlier (the runs it resumed from)."""
        self.space_memory = path
        for p in (path, *earlier):  # (AS1) the routes flown, from this run and the runs before it
            try:
                with open(p) as f:
                    got = json.load(f)
                # (d23 batch130 CM1) and where each platform has been: a new shift's file started empty, and every
                # platform's next arrival at each planet aired as a first ("Kestrel II reaches Fulgora", 20 in each
                # shift's first hour on d23; "Asterion reaches Solar system edge" again at 13:48)
                for name, planets in (got.get("visited") or {}).items():
                    self.platform_course.setdefault(name, {"visited": set()})["visited"].update(planets)
                    self.orbit_known.update((name, pl) for pl in planets)
                self.planets_reached.update(got.get("reached") or [])
                for name, routes in (got.get("routes") or {}).items():
                    for key, ticks in (routes or {}).items():
                        frm, _, to = str(key).partition(">")
                        for tick in ticks if isinstance(ticks, list) else ():
                            if isinstance(tick, int) and frm and to:
                                self.add_route(name, frm, to, tick, save=False)
            except (OSError, ValueError, AttributeError):
                continue
        try:
            with open(path) as f:
                mem = json.load(f)
        except (OSError, ValueError):
            mem = None
            for p in earlier:
                try:
                    with open(p) as f:
                        mem = {"stops": json.load(f).get("stops") or {}}
                    break
                except (OSError, ValueError, AttributeError):
                    continue
            if not mem:
                return
        for name, planets in (mem.get("visited") or {}).items():
            self.platform_course.setdefault(name, {"visited": set()})["visited"].update(planets)
            self.orbit_known.update((name, pl) for pl in planets)
        for name, stop in (mem.get("stops") or {}).items():  # (AK2) where each stopped and since when, across restarts
            if isinstance(stop, dict) and isinstance(stop.get("at"), str) and isinstance(stop.get("tick"), int):
                self.platform_course.setdefault(name, {"visited": set()})["stop"] = {"at": stop["at"], "tick": stop["tick"], "seen": bool(stop.get("seen"))}
        self.planets_reached.update(mem.get("reached") or [])
        if isinstance(mem.get("rockets_at_start"), int):  # (AY3) this run's own file only: earlier runs give stops
            self.rockets_at_start = mem["rockets_at_start"]

    ROUTE_KEEP = 4         # departure ticks kept per platform and route
    ROUTE_SAME = 2 * 3600  # two records of one departure (the score's read and the chronicle's event) this close: one

    def add_route(self, name, frm, to, tick, save=True):
        """(d22 batch83 AS1) A platform's departure from frm to to (location ids) at a game tick."""
        ticks = self.platform_routes.setdefault(name, {}).setdefault(f"{frm}>{to}", [])
        if any(abs(t - tick) < self.ROUTE_SAME for t in ticks):
            return
        ticks.append(int(tick))
        ticks.sort()
        del ticks[:-self.ROUTE_KEEP]
        if save:
            self._save_space_memory()

    def route_last(self, name, frm, to, before):
        """The game tick of the platform's latest departure from frm to to before tick `before`, or None."""
        ticks = [t for t in (self.platform_routes.get(name) or {}).get(f"{frm}>{to}") or () if t < before]
        return max(ticks) if ticks else None

    def platform_visited(self, name):
        """The locations the platform has been at (space-memory.json visited, and both ends of every route in its route
        memory: a new shift's file starts without visited), or None when nothing is known of it."""
        c, routes = self.platform_course.get(name), self.platform_routes.get(name)
        if not c and not routes:
            return None
        out = set((c or {}).get("visited") or ())
        for key in routes or ():
            out.update(key.split(">", 1))
        return out

    MAP_MEMORY_EVERY = 60.0
    PLANET_GONE_S = 1800.0

    def set_map_memory(self, path, earlier=()):
        """(d22 batch75 AK1, viewer Aurora: "Planet buttons and network layers disappear between refreshes") keep each
        planet's last coarse map and networks map in the run folder (serve.py), so a restart or a shift change starts
        with them instead of rereading one planet a minute: read from path, else the newest of earlier (the runs this
        one resumed from). Their ticks say how old they are; a newer read replaces each."""
        self.map_memory = path
        for p in (path, *earlier):
            try:
                with open(p) as f:
                    mem = json.load(f)
            except (OSError, ValueError):
                continue
            if not isinstance(mem, dict):
                continue
            for k, m in (mem.get("planet_maps") or {}).items():
                if isinstance(m, dict) and isinstance(m.get("rows"), list):
                    self.planet_maps.setdefault(k, m)
            for k, row in (mem.get("net_maps") or {}).items():
                if isinstance(row, dict) and isinstance(row.get("map"), dict) and isinstance(row.get("t"), (int, float)):
                    self.net_maps.setdefault(k, (row["map"], row["t"]))
            return p
        return None

    def _save_map_memory(self, now, force=False):
        if not self.map_memory or (not force and now - self.map_memory_t < self.MAP_MEMORY_EVERY):
            return
        self.map_memory_t = now
        mem = {"planet_maps": self.planet_maps, "net_maps": {k: {"map": m, "t": t} for k, (m, t) in self.net_maps.items()}}
        try:
            tmp = self.map_memory + ".tmp"
            with open(tmp, "w") as f:
                json.dump(mem, f, separators=(",", ":"))
            os.replace(tmp, self.map_memory)
        except (OSError, TypeError, ValueError):
            pass

    def _save_space_memory(self):
        if not self.space_memory:
            return
        mem = {"visited": {n: sorted(c.get("visited") or ()) for n, c in sorted(self.platform_course.items())},
               "reached": sorted(self.planets_reached),
               "stops": {n: c["stop"] for n, c in sorted(self.platform_course.items()) if c.get("stop")},
               "routes": {n: dict(sorted(r.items())) for n, r in sorted(self.platform_routes.items())}}
        if self.rockets_at_start is not None:
            mem["rockets_at_start"] = self.rockets_at_start
        if mem == getattr(self, "_space_memory_saved", None):
            return
        try:
            tmp = self.space_memory + ".tmp"
            with open(tmp, "w") as f:
                json.dump(mem, f)
            os.replace(tmp, self.space_memory)
            self._space_memory_saved = mem
        except OSError:
            pass

    def _orient_platforms(self, plats):
        """Which way each travelling platform flies (`toward`, for platform_where): space.lua's "a->b N%" is the
        space connection, fixed whichever way it is flown (shift06 14:09, Sunward from Vulcanus to Nauvis on
        nauvis->vulcanus showed as "leaving Nauvis for Vulcanus", then "travelling to Vulcanus (5%)" a minute from
        Nauvis). In order: the schedule's current stop (pog.py score `to`), the distance moving (not while paused: a
        paused platform drifts back), the way it was going, the planet it last orbited; else a->b. A platform at a
        planet after travelling is an arrival (self.arrivals)."""
        out = []
        for p in plats:
            p = dict(p)
            name, at = p.get("name"), p.get("at") or ""
            new = name not in self.platform_course
            c = self.platform_course.setdefault(name, {"visited": set()})
            m = AT_RE.match(at)
            if not m:
                if at and at != "in transit":
                    # (d22 batch75 AK2, viewer Foobator: "the rest have their planetary waiting time displayed") the
                    # game tick of the first read at this planet; seen: the read before had it elsewhere (else it was
                    # there when the service started: at least that long)
                    if (c.get("stop") or {}).get("at") != at and self.tick:
                        c["stop"] = {"at": at, "tick": self.tick, "seen": bool(c.get("moving") or c.get("orbit"))}
                    if c.get("moving"):
                        came = c.get("orbit") if c.get("orbit") != at else None
                        if not came and c.get("conn"):
                            came = next((x for x in c["conn"] if x != at), None)
                        self.arrivals.append((name, at, came, at not in c["visited"], at not in self.planets_reached))
                    c.update(orbit=at, moving=False, conn=None, pct=None, toward=None)
                    c["visited"].add(at)  # where it is when first seen counts as visited (a service restart)
                    self.planets_reached.add(at)
                elif at == "in transit":
                    c["moving"] = True
                    c.pop("stop", None)
                out.append(p)
                continue
            a, b, pct = m[1], m[2], int(m[3])
            same = c.get("conn") == (a, b)
            if p.get("to") in (a, b):
                toward = p["to"]
            elif same and c.get("pct") is not None and pct != c["pct"] and not p.get("paused"):
                toward = b if pct > c["pct"] else a
            elif same and c.get("toward"):
                toward = c["toward"]
            elif c.get("orbit") in (a, b):
                toward = b if c["orbit"] == a else a
            else:
                toward = b
            if c.get("moving") is False and c.get("orbit") in (a, b) and self.tick:  # (AS1) seen leaving a stop
                self.add_route(name, c["orbit"], b if c["orbit"] == a else a, self.tick)
            c.update(conn=(a, b), pct=pct, toward=toward, moving=True)
            c.pop("stop", None)
            if new and p.get("to") in (a, b):  # first seen mid-trip (a restart): it has been where it left
                c["visited"].add(a if toward == b else b)
                if toward in self.planets_reached:
                    # headed for a planet the team has reached, with nothing remembered of it (no space-memory.json
                    # yet, or made while the service was down): a ferry more likely than a first trip, so its arrival
                    # is an ordinary one, not a false first
                    c["visited"].add(toward)
                for planet in c["visited"]:
                    self.orbit_known.add((name, planet))
            p["toward"] = toward
            out.append(p)
        return out

    def _platforms_lost(self, now):
        """A platform gone from two space reads in a row is destroyed (its hub was lost: Factorio deletes the
        platform): a headline with its name, where it was and what did it (shift04 05:15 and shift05 07:48: "a space
        platform hub is gone", never which). A rename (one gone, one new, same read) is not a loss."""
        names = {p["name"]: p for p in self.space.get("platforms") or [] if p.get("name")}
        missing = [n for n in self.platform_last if n not in names]
        new = [n for n in names if n not in self.platform_last]
        if missing and len(new) == len(missing):
            for n in missing:
                self.platform_last.pop(n, None)
                self.platform_missing.pop(n, None)
            missing = []
        for n in list(self.platform_missing):
            if n in names:
                self.platform_missing.pop(n)
        for n in missing:
            self.platform_missing[n] = self.platform_missing.get(n, 0) + 1
            if self.platform_missing[n] >= 2:
                p = self.platform_last.pop(n)
                self.platform_missing.pop(n)
                self._platform_destroyed(p, now)
        self.platform_last.update(names)

    def _ingest_chronicle_entry(self, e, now):
        """An agent's chronicle entry: its words, where it stood and the events it is filed beside."""
        if chronicle_log.entry_key(e) in self.chronicle_earlier:
            return
        agent = self._who(e.get("agent"))
        self.chronicle_entries.append({"seq": e.get("seq"), "tick": e.get("tick"), "game_time": e.get("game_time"),
                                       "agent": agent, "name": e.get("agent"), "title": clean_text(e.get("title") or "") or None,
                                       "text": clean_text(e.get("text") or ""), "where": e.get("platform") or e.get("planet"),
                                       "about": [str(r.get("line")) for r in e.get("refs") or [] if isinstance(r, dict)][:3],
                                       "t": now})
        if agent:
            self.agents[agent].bump(2.0, now)

    def _ingest_chronicle_event(self, ev, now):
        """An event the harness saw. A platform's loss carries where it was, what killed it and its hub's items: the
        stream's own loss line (_platform_destroyed) takes them."""
        if chronicle_log.event_key(ev) in self.chronicle_earlier:
            return
        row = {k: ev.get(k) for k in ("id", "kind", "tick", "game_time", "line", "platform", "agent", "where", "by",
                                      "cargo", "cargo_items", "hit_by") if ev.get(k) is not None}
        row["t"] = now
        self.chronicle_events.append(row)
        if ev.get("kind") == "platform_left" and ev.get("platform") and ev.get("at") and ev.get("to") and \
                isinstance(ev.get("tick"), (int, float)):
            self.add_route(ev["platform"], ev["at"], ev["to"], int(ev["tick"]))
        if ev.get("kind") in chronicle_log.PLATFORM_KINDS and ev.get("platform"):
            before = chronicle_log.follow_platform(self.platform_history, ev)
            if before is not None and not before["left"]:
                self._maiden_flight(ev, before, now)
        if ev.get("kind") == "platform_lost" and ev.get("platform"):
            self.harness_lost[ev["platform"]] = (now, ev)
            for x in self.platforms_lost:  # the stream saw it go first: the harness's facts fill in
                if x["name"] == ev["platform"] and now - x["t"] < 600:
                    x.update(lost_details(ev))

    def set_platform_history(self, chronicle_path):
        """Each platform's creation and departures from the chronicle files along the run chain (serve.py), so a
        restart or a new shift knows which platforms have flown since they were built."""
        self.platform_history = chronicle_log.platform_history(chronicle_path)
        for name, frm, to, tick in chronicle_log.departures(chronicle_path) if chronicle_path else ():
            self.add_route(name, frm, to, tick, save=False)  # (AS1) the routes flown before this service ran
        # the rows earlier shifts wrote: a file carrying them again (before d20 batch65 AA3) does not show them as new
        self.chronicle_earlier = chronicle_log.earlier_keys(chronicle_path) if chronicle_path else set()

    def _maiden_flight(self, ev, h, now):
        """A platform's first departure since its creation (the history knows when it was built and by whom): a
        maiden flight moment, which segments.py turns into a space_moment card and onecam.py into a held shot of the
        ship. A departure read MAIDEN_STALE_S of game time late (a restart catching up) is history only."""
        name, tick = ev["platform"], ev["tick"]
        if self.tick and self.tick - tick > MAIDEN_STALE_S * 60:
            return
        ag = self.agents.get(h.get("by") or "")
        built_by = ag.display_name if ag else (h["by"].capitalize() if h.get("by") else None)
        frm = planet_label(ev["at"]) if ev.get("at") else None
        to = planet_label(ev["to"]) if ev.get("to") else None
        key = f"maiden:{name}:{h['created']}"
        facts = {"platform": name, "from": frm, "to": to, "built_by": built_by, "game_time": fmt_game_time(tick / 60)}
        m = {"kind": "maiden_flight", "title": f"Maiden flight of {name}" + (f" to {to}" if to else ""), "facts": facts,
             "id": f"m-{key}", "key": key, "t": now, "game_time": facts["game_time"]}
        self.moments.append(m)
        self.alert("space", m["title"], key=f"space:{key}", ttl=40, facts=dict(facts, headline="maiden_flight"))

    def _platform_destroyed(self, p, now):
        where = platform_place(p)
        cause = None
        for t, name, text in reversed(self.hub_losses):
            if now - t < 600 and name in (None, p["name"]):
                m = re.search(r"\(by ([^)]*)\)", text)
                cause = m.group(1) if m else None
                break
        # the harness read it at its hub's death (chronicle.lua): where it flew, what killed it, the cargo it held
        hl = self.harness_lost.get(p["name"])
        details = lost_details(hl[1]) if hl and now - hl[0] < 600 else {}
        where = details.get("where") or where
        cause = details.get("cause") or cause
        left = sorted(self.platform_last)
        text = f"{p['name']} destroyed {where}" + (f" by {cause}" if cause else "")
        self.platforms_lost.append(dict({"name": p["name"], "where": where, "cause": cause, "t": now}, **details))
        self.alert("headline", text, key=f"lost:{p['name']}", ttl=600, facts={
            "headline": "platform_destroyed", "platform": p["name"], "where": where, "destroyed_by": cause,
            "what_it_means": "its hub is gone, so the platform and everything aboard it are lost",
            "cargo_lost": details.get("cargo"), "hit_most_by": details.get("hit_by"),
            "platforms_left": left or "none", "game_time": fmt_game_time(self.tick / 60)})

    LOST_SHOW_S = 120  # a lost platform stays in the widget this long, marked lost, with its cause

    def efficiency_news(self, now):
        """A notable change in the team's machines against the read about 30 minutes ago (efficiency.notable), for
        the hosts as a fact; None most of the time."""
        then = None
        for t, v in self.efficiency_hist:
            if now - t >= efficiency_mod.NEWS_WINDOW:
                then = v
        return efficiency_mod.notable(then, self.efficiency)

    def space_in_play(self):
        """Space beyond Nauvis (the space widget's active, without the science packs): a rocket, a platform, another
        planet with our entities, or an agent away from Nauvis."""
        sp = self.space
        return bool(sp.get("rockets") or sp.get("platforms") or len(sp.get("planets") or []) > 1
                    or any(a.surface and a.surface != "nauvis" for a in self.agents.values()))

    def space_snapshot(self, sci, now=None):
        now = now or time.time()
        sp = self.space
        packs = [dict(p, label=pack_label(p["item"])) for p in (sci.get("made") or {}).get("packs") or [] if p["item"] in SPACE_PACKS]
        planets = [planet_label(s) for s in sp.get("planets") or []]
        plats = []
        for i, p in enumerate(sp.get("platforms") or []):
            aboard = [a.display_name or a.name for a in self.agents.values() if a.platform == p.get("name") and a.alive]
            working = sorted({(self.agents[w["agent"]].display_name or w["agent"]) for w in self.work
                              if w.get("platform") == p.get("name") and now - w["t"] < 120 and w["agent"] in self.agents}
                             - set(aboard))
            card = platform_card(p, self.platform_hits.get(p.get("name")), aboard, working)
            stop = (self.platform_course.get(p.get("name")) or {}).get("stop")
            if stop and not card["route"] and self.tick >= stop["tick"]:  # (AK2) game seconds at the planet it is at
                card["waited_s"] = round((self.tick - stop["tick"]) / 60)
                if not stop["seen"]:
                    card["waited_more"] = True  # there when first read: at least that long
            danger = platform_danger(p.get("name"), self.platform_hits.get(p.get("name")), self.platform_losses.get(p.get("name")),
                                     p.get("ammo_rates"), self.tick, now, (card.get("hub") or {}).get("pct"))
            if danger:
                card["danger"] = danger
            card["_i"] = i
            plats.append(card)
        # under fire first, then the score's order
        plats.sort(key=lambda c: (-(c.get("hits_per_min") or 0), c.pop("_i")))
        lost = [dict(x, ago_s=round(now - x["t"])) for x in self.platforms_lost if now - x["t"] < self.LOST_SHOW_S]
        away = sorted({where_label(a.surface, a.platform) for a in self.agents.values() if a.surface and a.surface != "nauvis"})
        active = bool(sp.get("rockets") or plats or packs or len(planets) > 1 or away or lost)
        bits = []
        if len(planets) > 1:
            bits.append(f"{len(planets)} planets")
        if plats:
            bits.append(f"{len(plats)} platform" + ("s" if len(plats) > 1 else ""))
        sci_total = sum(p.get("total") or 0 for p in packs)
        if sci_total:
            bits.append(f"{fmt_count(sci_total)} space-age science")
        elif sp.get("rockets"):
            bits.append(f"{sp['rockets']} rocket" + ("s" if sp["rockets"] > 1 else ""))
        return {"space_age": self.space_age or active, "active": active, "rockets": sp.get("rockets") or 0,
                "planets": planets, "platforms": plats, "lost": lost, "science": packs, "away": away,
                # the widget holds its turn in the rotation while a platform is under fire or just lost
                "hot": bool(lost or any(c.get("hits_per_min") for c in plats)),
                "summary": " · ".join(bits) if active else None, "moments": list(self.moments)}

    def _rates(self, samples=None):
        """Per-minute rates over the last ~2.5 game minutes from `score` total deltas (score's items only; samples:
        used_samples for what the labs used)."""
        samples = self.prod_samples if samples is None else samples
        if len(samples) < 2:
            return {}
        t1, g1, p1 = samples[-1]
        for t0, g0, p0 in samples:
            if g1 - g0 <= 150:
                break
        if g1 <= g0:
            return {}
        return {k: (p1.get(k, 0) - p0.get(k, 0)) * 60.0 / (g1 - g0) for k in p1}

    def _item_row(self, n, latest, rate):
        series = self.flows.get(n)
        if series:
            series = [round(c / 2.0, 1) for c in series]  # 2-minute buckets -> per minute
        else:
            series = self._series_from_totals(n)
        total = latest.get(n) or (round(sum(self.flows.get(n) or [])) or 0)
        r = rate[n] if n in rate else (sum(series[-2:]) / len(series[-2:]) if series else None)
        return {"item": n, "total": total, "rate": None if r is None else round(r, 1), "series": series}

    def production(self, now):
        """Items for the production widget, most relevant first (up to 12, science packs excluded: see science())."""
        latest = self.prod_samples[-1][2] if self.prod_samples else {}
        rate = self._rates()
        stage = self.stage(latest)
        rows = []
        for n in ITEM_STAGE:
            if not (latest.get(n, 0) > 0 or sum(self.flows.get(n) or []) > 0):
                continue
            row = self._item_row(n, latest, rate)
            recent = sum((self.flows.get(n) or [])[-3:]) > 0 or (row["rate"] or 0) > 0
            if not recent:
                continue
            d = stage - ITEM_STAGE[n]
            w = 3.0 if d <= 0 else 2.0 if d == 1 else 1.0 if d == 2 else 0.5
            if n in ("iron-plate", "copper-plate"):
                w = max(w, 2.0)  # the base of everything stays on screen
            row["stage"] = ITEM_STAGE[n]
            row["score"] = round(w * (1 + math.log10(1 + max(0.0, row["rate"] or 0))), 3)
            rows.append(row)
        rows.sort(key=lambda r: -r["score"])
        return rows[:12]

    def stage(self, latest=None):
        """Furthest stage the factory has produced anything from (0 raw .. 5 rocket)."""
        latest = latest if latest is not None else (self.prod_samples[-1][2] if self.prod_samples else {})
        made = [n for n in list(ITEM_STAGE) + SCIENCE if latest.get(n, 0) > 0 or sum(self.flows.get(n) or []) > 0]
        return max([ITEM_STAGE.get(n, SCIENCE_STAGE.get(n, 0)) for n in made] or [0])

    def science(self, now):
        """Headline: science per minute as players mean it (research_units: research units a minute, the labs' use of
        packs in sets), with the labs' use per pack beside it (the running technology's packs, and any other used
        lately) and a per-minute series; made: packs made per minute, all colours, and per pack."""
        latest = self.prod_samples[-1][2] if self.prod_samples else {}
        rate = self._rates()
        made_rows = []
        for n in SCIENCE:
            if latest.get(n, 0) > 0 or sum(self.flows.get(n) or []) > 0:
                made_rows.append(self._item_row(n, latest, rate))
        made = {"per_min": round(sum(p["rate"] or 0 for p in made_rows), 1) if made_rows else None,
                "packs": [{"item": p["item"], "rate": p["rate"], "total": p["total"]} for p in made_rows]}
        # what the labs used: rates from the score's consumed totals, the series from the last hour's flows (else
        # from the totals seen since the stream started)
        used_latest = self.used_samples[-1][2] if self.used_samples else {}
        used_rate = self._rates(self.used_samples)
        series_by = {}
        for n in SCIENCE:
            if self.used_flows:  # one source for the whole series: the hour's flows, else the totals
                s = [round(c / 2.0, 1) for c in self.used_flows.get(n) or []]
            else:
                s = self._series_from_totals(n, samples=self.used_samples)
            if s:
                series_by[n] = s
        running = list(self.research.get("packs") or [])
        packs, per = [], {}
        for n in SCIENCE:
            s = series_by.get(n) or []
            r = used_rate[n] if n in used_rate else (sum(s[-2:]) / len(s[-2:]) if s else None)
            if r is None and n not in running:
                continue
            per[n] = r or 0
            if (r or 0) > 0 or n in running:
                packs.append({"item": n, "rate": None if r is None else round(r, 1), "running": n in running,
                              "used_total": used_latest.get(n)})
        has_used = bool(self.used_samples or self.used_flows)
        spm = round(research_units(per), 1) if has_used else None
        width = max((len(s) for s in series_by.values()), default=0)
        series = [round(research_units({n: (s[i - width + len(s)] if i - width + len(s) >= 0 else 0)
                                        for n, s in series_by.items()}), 1) for i in range(width)]
        stage = self.stage(latest)
        return {"spm": spm, "series": series, "stage": stage, "stage_label": STAGE_LABELS[stage], "packs": packs,
                "running": running, "made": made}

    def _series_from_totals(self, item, buckets=30, samples=None):
        samples = self.prod_samples if samples is None else samples
        if len(samples) < 2:
            return []
        out = []
        prev = None
        for t, g, p in samples:
            if prev and g > prev[0]:
                out.append(max(0.0, (p.get(item, 0) - prev[1]) * 60.0 / (g - prev[0])))
            prev = (g, p.get(item, 0))
        if len(out) > buckets:
            k = len(out) / buckets
            out = [sum(out[int(i * k):int((i + 1) * k)]) / max(1, int((i + 1) * k) - int(i * k)) for i in range(buckets)]
        return [round(v, 1) for v in out]

    def job_card(self, ag, plan_rows, now):
        """A card's job, labelled with where it comes from and its age (d20 batch54 N3): the agent's board_focus
        (board_focus rows, game time since it was set), else its team-plan line (game time since that line was set),
        else its notes.md "## Now" job line (wall time since the file was saved), else none. {job, job_from (focus,
        plan, notes or None), job_tick (game tick set: focus and plan), job_age_s, job_label}."""
        focus_rows = self.board.get("focus")
        f = (focus_rows or {}).get(ag.name)
        def game_age(tick):
            return max(0, int((self.tick - tick) / 60)) if isinstance(tick, (int, float)) and self.tick else None
        if f and f.get("id") is not None:
            text = f"#{f['id']} {f.get('title') or '(item gone)'}" + (f"; {f['step']}" if f.get("step") else "") + \
                (f"; blocker: {f['blocker']}" if f.get("blocker") else "")
            age = game_age(f.get("tick"))
            return {"job": clean_text(text), "job_from": "focus", "job_tick": f.get("tick"), "job_age_s": age,
                    "job_label": "focus, " + (f"set {fmt_age(age)} ago" if age is not None else "age unknown") +
                                 ("; its step shows no completion across checks" if f.get("stalled") else "")}
        none_set = "; no focus set" if focus_rows is not None else ""
        row = plan_rows.get(ag.name)
        if row:
            age = game_age(row.get("tick"))
            return {"job": row["text"], "job_from": "plan", "job_tick": row.get("tick"), "job_age_s": age,
                    "job_label": "plan line, " + (f"set {fmt_age(age)} ago" if age is not None else "age unknown") + none_set}
        if ag.notes_job:
            age = max(0, int(now - ag.notes_job_t)) if isinstance(ag.notes_job_t, (int, float)) else None
            return {"job": ag.notes_job, "job_from": "notes", "job_tick": None, "job_age_s": age,
                    "job_label": "notes.md Now line, " + (f"saved {fmt_age(age)} ago" if age is not None else "age unknown") + none_set}
        return {"job": None, "job_from": None, "job_tick": None, "job_age_s": None,
                "job_label": "no focus, plan line or notes job" if focus_rows is not None else "no plan line or notes job"}

    def work_card(self, ag, job, plan_rows):
        """A card's current work beside its job (d20 batch70 AF3, viewer Aurora): work, its watches, queue steps,
        standing order and repeating requests as lines (workcard.rows); plan_line, its team-plan line when the job
        shows its focus; stale, a line for its plan line or focus set before its current work began or not naming a
        test running (workcard.stale), with the times."""
        work = workcard.rows(ag.watches, ag.queues, ag.auto, ag.repeats, self.tick)
        row = plan_rows.get(ag.name)
        out = {"work": [w["line"] for w in work[:workcard.ROWS]] or None}
        texts = []
        if job.get("job_from") == "focus":
            texts.append(("focus", job.get("job_tick"), job.get("job")))
            if row:
                age = max(0, int((self.tick - row["tick"]) / 60)) if isinstance(row.get("tick"), (int, float)) and self.tick else None
                out["plan_line"] = row["text"]
                out["plan_line_label"] = "plan line, " + (f"set {fmt_age(age)} ago" if age is not None else "age unknown")
        if row:
            texts.append(("plan line", row.get("tick"), row["text"]))
        # (d23 batch123 CF1) the runtime's marks: a focus or plan line naming what a board change took away
        marks = []
        f = (self.board.get("focus") or {}).get(ag.name) if job.get("job_from") == "focus" else None
        if f and f.get("stale"):
            marks.append(workcard.short("focus " + clean_text(f["stale"]), workcard.LINE))
        if row and row.get("stale"):
            marks.append(workcard.short("plan line " + row["stale"], workcard.LINE))
        out["stale"] = marks + workcard.stale(texts, work, self.tick) or None
        return out

    def snapshot(self, now, cameras=None):
        self.snap_now = now  # (BI5) the time a project's owner_work reads its wait at
        cams_by_agent = {}
        for slot, cam in (cameras or {}).items():
            for name in cam.get("agents") or []:
                cams_by_agent.setdefault(name, slot)
        agents = []
        tok = {r["name"]: r for r in (self.tokens or {}).get("rows") or []}
        # each card's current job (shift05 07:57, a viewer: "displaying the current plan of each bot instead of the
        # motto"; d20 batch54 N3, viewer Aurora: "Old plan text still shows ... after assignments change"): job_card
        plan_rows = {d["agent"]: d for d in reversed((self.plan_snapshot() or {}).get("doing") or [])
                     if d.get("agent") and d.get("text")}
        for ag in self.agents.values():
            ag.decay(now)
            job = self.job_card(ag, plan_rows, now)
            wait_line = waitcard.line(ag.wait, self.tick, now)
            agents.append({
                "wait_line": wait_line,
                # the sleep's own reason (fh sleep --reason), else its last words about its own wait in chat
                "wait_reason": ((ag.wait or {}).get("reason") or waitcard.reason(self.chat, ag.name, self.tick, now)) if wait_line else None,
                **job,
                **self.work_card(ag, job, plan_rows),
                "name": ag.name, "kind": ag.kind, "display_name": ag.display_name, "color": ag.color,
                "glyph": ag.glyph, "motto": ag.motto, "profile_set": ag.profile_set, "model": ag.cfg.get("model"), "harness": ag.cfg.get("harness"),
                "role": ag.cfg.get("role"), "alive": ag.alive, "activity": self.activity(ag, now),
                "action": self.action_text(ag), "active": ag.active, "position": ag.position,
                "location": self.location(ag), "travel": ag.travel,
                "interest": round(ag.interest, 2),
                "last_said": ag.last_said, "camera": cams_by_agent.get(ag.name), "seen": ag.seen, "voice": ag.voice,
                "voice_description": ag.voice_description, "pronouns": ag.pronouns, "avatar": ag.avatar, "combat": ag.combat, "died_at": ag.died_at, "plan": ag.plan,
                # hurt | fighting | guard | None, and who hit it or what it shoots at (combat_state)
                "combat_state": ag.combat_state, "combat_info": ag.combat_info or None,
                "vehicle_fire": ag.vehicle_fire,
                "surface": ag.surface, "where": where_label(ag.surface, ag.platform) if ag.surface else None,
                "on_platform": bool(ag.platform), "attention": self.attention_row(ag, now), "auto": ag.auto,
                "resting_until": ag.resting["until"] if self.is_resting(ag, now) else None,
                "tokens": (tok.get(ag.name) or {}).get("total") or None,  # this shift's, for the card's small figure
            })
        res = self.research
        science = self.science(now)
        fights = self.fights_snapshot(now)
        # what each agent carries, wears and builds: one mode per agent (loadout.py), and the full rows for the site
        shown = self.loadouts.snapshot(agents, fights, now)
        for a in agents:
            a["loadout"] = shown.get(a["name"])
        loadouts = {n: dict(r, age_s=round(now - self.loadouts.seen_t.get(n, now), 1)) for n, r in self.loadouts.rows.items()}
        return {
            "now": now, "tick": self.tick, "tick_t": self.tick_t, "paused": self.paused, "game_time": fmt_game_time(self.tick / 60),
            "title": self.run.get("title"), "subtitle": self.run.get("subtitle"),
            # this shift's start and end and when the next is expected (start-team.sh), for the site's offline state
            "shift": self.run.get("shift"),
            "agents": agents,
            "chat": self.chat_window(),
            "viewer_replies": list(self.viewer_replies),
            "operator_requests": list(self.operator_requests),
            # the run's chronicle, newest last: the agents' entries and the events the harness saw (the site's live page;
            # the hosts read a new entry)
            "chronicle": {"entries": list(self.chronicle_entries)[-8:], "events": list(self.chronicle_events)[-12:]},
            "research": {"current": res["current"], "label": research_label(res["current"], res.get("repeating")), "progress": res["progress"],
                         "done_count": len(res["done"]), "recent": list(res["recent"])[:4],
                         "repeating": res.get("repeating") or []},
            "unused_unlocks": self.unused_unlocks(now),
            "research_news": self.research_news_snapshot(now),
            "darkness": self.darkness,
            "connected_players": self.connected_players,
            "basemap": dict(self.basemap, turret_state=self.turret_state) if self.basemap and self.turret_state else self.basemap,
            "planet_maps": dict(self.planet_maps),  # the other planets' coarse maps by surface (push_live sends one a push)
            # the map's pollution and spore layer, one row per surface (clouds.py; the overlay's map shots, the site)
            "clouds": [dict(c, age_s=round(now - self.clouds_t)) for c in self.clouds.values()] if self.clouds_t else [],
            # the library's placed areas with their hookups (libareas.lua; push_live sends them, the live map draws them)
            "library_areas": dict(self.library_areas, age_s=round(now - self.library_areas_t)) if self.library_areas else None,
            # each planet's networks and items' sources and consumers (netmap.lua; push_live sends one a push)
            "net_maps": {k: dict(m, age_s=round(now - t)) for k, (m, t) in self.net_maps.items()},
            # (d22 batch75 AK9) the charted ground under the map (push_live sends it as basemap.terrain_grid)
            "terrain_grid": dict(self.terrain_grid, age_s=round(now - self.terrain_grid["t"])) if self.terrain_grid and isinstance(self.terrain_grid.get("t"), (int, float)) else self.terrain_grid,
            "production": self.production(now),
            "science": science,
            "space": self.space_snapshot(science, now),
            "work": self.work_snapshot(now),
            "fights": fights,
            "incoming": self.incoming_snapshot(now),
            "big_enemies": self.big_snapshot(now),
            "hauling": self.hauling,
            "efficiency": self.efficiency,
            "efficiency_news": self.efficiency_news(now),
            "loadouts": loadouts,
            "tokens": self.tokens,
            "alerts": [a for a in self.alerts if a["until"] > now][-3:],
            "board": self.board_snapshot(),
            "reminders": self.reminders_snapshot(),
            "cameras": cameras or {},
            "errors": self.errors,
        }
