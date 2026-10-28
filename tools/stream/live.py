"""Live observations from a pog world, read-only.

With the eng/bots runtime (detected by the `camera` remote function) it polls `profiles` every round and per-agent
`status` round-robin (a third of the agents per round, so each agent's status is at most ~3 polls old). Before that
lands it reads `status` for every player index in the run config each round, so the page works against today's
worlds (e.g. the paused co-op save in world c).
"""
import math, os, re, time

import basemap_log
import turretsweep
import turretstate
import efficiency
import hauling
import chronicle_log
import operator_inbox
import planlog
import pacing
import terrain_grid
from harness import Harness
from model import SCIENCE, SPARK_ITEMS, notes_job
from work import WorkFeed
from waitcard import WaitFeed

FLOW_PARTS = 3  # (d24 batch184 QAA2) the flows read in three parts of the surfaces, one a poll


def sum_flows(parts):
    """{item: 30 counts}: the parts' series summed bucket by bucket (each part's own surfaces)."""
    out = {}
    for flows in parts:
        for item, series in (flows or {}).items():
            if not isinstance(series, list):
                continue
            have = out.setdefault(item, [0] * len(series))
            for i, c in enumerate(series[:len(have)]):
                have[i] += c
    return out

# (d26 batch222 CD) remote: a drive by remote view, "tank at (-40.0,-150.0) by remote view" (status active.remote)
PLAN_KEYS = ("kind", "until_tick", "total", "next_index", "placed", "built", "remaining", "bounds", "to", "stuck_s", "remote")
COMBAT_KEYS = ("auto", "position", "radius", "until_tick", "target", "fired_tick", "kills_10s", "hurt", "vehicle")
PROGRESS_EVERY = 120  # (d22 batch75 AK11) seconds between board_progress reads
FOCUS_RETRY = 600  # board_focus with no rows (a runtime before d20 batch54 N3): asked again after 10 min
AWAY_TILES = 48.0  # work this far from the body's position (same surface) is "away": the body's camera misses it

ATTACK_RECENT_TICKS = 60 * 30  # an attacked area counts as "now" for 30 game seconds
# status.alerts.latest lines: "in (x,y)-(x,y) N destroyed: ..." and, from eng/defensetools, "#7 [on S | on platform P]
# in (x,y)-(x,y) [continue:] N destroyed[ (+k since you were told)]: ..."
LOSS_RE = re.compile(r"^(?:losses )?(?:#(?P<id>\d+)(?: on (?:platform (?P<platform>.+?)|(?P<surface>\S+)))? )?"
                     r"in \((?P<x>-?\d+),(?P<y>-?\d+)\)(?:-\((?P<x2>-?\d+),(?P<y2>-?\d+)\))?(?: continue:)? (?P<total>\d+) destroyed"
                     r"(?: \(\+\d+ since you were told\))?: (?P<names>.*?)(?: by (?P<by>.*?))?, (?P<ago>\S+) ago$")
LOSS_RECENT_TICKS = 2 * 3600  # as RECENT_AGO: the last loss under 2 game minutes ago
CHUNK = 32.0  # status.alerts.attacked reports a chunk: its centre, the fight somewhere in its 32x32 tiles
RECENT_AGO = re.compile(r"^(?:.*-)?(?:\d+s|1m\d\ds)$")  # last part of the span under 2 minutes


def hit_label(entities):
    """status.alerts.attacked `entities` ("character x3", "gun-turret x12"): the x is a hit count, which the hosts read
    as a number of enemies or turrets on air (shake3), so the banner and replay titles name only what was hit."""
    name = re.sub(r"\s*x\d+$", "", (entities or "").strip()).replace("-", " ")
    return "an engineer" if name == "character" else name


def attacker_label(by):
    """describe_incident's "by 5 small-biter, 2 medium-biter" counts kills by each kind: "small biters". Our own
    entities come last as "friendly fire: 2 flamethrower-turret": alone, "friendly fire from flamethrower turrets". Where
    a burning turret stands ("2 flamethrower-turret at (80,90) (84,90)") is left out of the label."""
    first = re.sub(r" at \(-?[\d.]+,-?[\d.]+\)(?: \(-?[\d.]+,-?[\d.]+\))*", "", by or "").split(",")[0].strip()
    if first.startswith("friendly fire:"):
        name = attacker_label(first.split(":", 1)[1])
        return f"friendly fire from {name}" if name and name != "unknown sources" else "friendly fire"
    name = re.sub(r"^\d+\s+", "", first).replace("-", " ")
    return name + "s" if name and not name.endswith("s") else name


class LiveSource:
    STEP_READS = 8  # project reads (board {id}) at most per board refresh: changed projects first, the rest next time

    def full_steps(self, items):
        """Put each project's full step list on its row (`steps`, as board {id} gives it: "[x] 1. text (done by sol, 5m
        ago)" / "[ ] 2. text"); a list read only has its first three open steps (next_steps). Read again only when the
        project's updated_tick changed, STEP_READS at most a call; a project not read yet keeps next_steps only."""
        reads = 0
        for it in items:
            pid, tick = it.get("id"), it.get("updated_tick")
            if pid is None:
                continue
            have = self.project_steps.get(pid)
            if (not have or have[0] != tick) and reads < self.STEP_READS:
                reads += 1
                try:
                    res, _ = self.read("board", {"id": pid}, **self.reader())
                    have = (tick, list((res.get("item") or {}).get("steps") or []))
                    self.project_steps[pid] = have
                except Exception:
                    pass
            if have:
                it["steps"] = have[1]
        keep = {it.get("id") for it in items}
        for pid in [k for k in self.project_steps if k not in keep]:
            del self.project_steps[pid]

    def __init__(self, world, run, profiles="auto", flow_every=30.0, harness=None, status_share=3, journals=None):
        self.name = f"live:{world}"
        self.world = world
        self.h = harness or Harness(world)
        self.run = run
        self.agents_cfg = run.get("agents") or {}
        self.profiles_mode = profiles
        self.flow_every = flow_every
        self.next_flow = 0
        # (d24 batch184 QAA2) the flows read a third of the surfaces a poll, flow_every / FLOW_PARTS apart: each part is
        # read again every flow_every; the panel's figures are the parts' sum
        self.flow_part = 0
        self.flow_parts = {}  # part -> {item: 30 counts}
        self.chat_since = 0
        self.status_share = status_share
        self.status_cache = {}
        self.rr = 0
        self.caps = None
        self.next_probe = 0
        self.use_profiles = profiles == "on"
        self.peek_ok = None
        self.brief_ok = None
        self.has_board = False
        self.next_board_probe = 0
        self.board_seq = 0
        self.board_every = 15.0
        self.next_board = 0
        self.has_groups = False  # the runtime answers attack_groups_live (describe operator_reads)
        self.groups_every = 2.0
        self.next_groups = 0
        self.has_confess = False
        self.confess_seq = 0
        self.has_tells = False
        self.tell_seq = 0
        # agents' requests to the operator (tells.lua `operator`): appended to runs/RUN/operator-inbox.jsonl
        self.has_operator = False
        self.inbox_path = operator_inbox.path_for(journals)
        self.journals = journals
        self.plan_ticks_ok = None  # the runtime takes board {plan_ticks} (None: not asked yet)
        # each project's steps in full (board {id}), read again only when it changed (viewer Foobator, d15 08:31: "we cant
        # see the individual steps"): id -> (updated_tick, steps)
        self.project_steps = {}
        # hand hauling (hauling.lua `hauling`), every few minutes: runs/RUN/hauling.jsonl, and the shift's numbers
        self.has_hauling = False
        self.next_hauling = 0
        self.hauling_path = hauling.path_for(journals)
        self.hauling_first = (hauling.read_rows(self.hauling_path) or [None])[0] if self.hauling_path else None
        # production credited to who built the machine (efficiency.lua `efficiency`; Nick 15:50), every few minutes:
        # runs/RUN/efficiency.jsonl; the shift's numbers are the runtime's own
        self.has_efficiency = False
        self.next_efficiency = 0
        self.efficiency_path = efficiency.path_for(journals)
        # what each agent carries, wears and builds (loadout.lua `loadout`; Nick, 08:55): every few seconds
        self.has_loadout = False
        self.next_loadout = 0
        self.loadout_every = 4.0
        # pollution and spores per charted chunk on each surface an agent is on (threat.lua `clouds`; viewer Joonazan,
        # 13:00): the harness sweeps it about once a game minute, so a read a minute
        self.has_clouds = False
        self.next_clouds = 0
        self.clouds_every = 60.0
        # (d21 batch68 AD2, viewer Aurora) the library's placed areas with their hookups (libareas.lua `library_areas`):
        # two areas' hookups read a minute (each one find over its area)
        self.has_library_areas = False
        self.next_library_areas = 0
        self.library_areas_every = 60.0
        # (d21 batch68 AD3, viewer Aurora) each planet's electric and logistic networks and items' sources and consumers
        # (netmap.lua `net_map`, made in the background a planet a minute): a read every net_map_every seconds, the
        # planet whose map changed since this service last read it (the read's own listing says which)
        self.has_net_map = False
        self.next_net_map = 0
        self.net_map_every = 20.0
        self.net_map_seen = {}  # surface -> the tick of the map read
        self.net_map_listed = []  # the last read's [{surface, tick}]
        # (d22 batch75 AK9) the charted ground's tiles (terrain_grid.py; serve.py gives it its file); None: no reads
        self.terrain = None
        # (d22 batch97 BG3) the site's chart (chart.py; serve.py gives it runs/RUN/chart/); None: no reads
        self.chart = None
        self.has_chart = False
        self.terrain_sent = False
        self.notes_cache = {}  # agent -> (mtime, job line): notes.md is read again only when it changed
        # after the file's last request, or the earlier shifts' for a new one (the save holds them all)
        self.operator_seq = operator_inbox.start_seq(self.inbox_path) if self.inbox_path else 0
        # the run's chronicle (chronicle.lua, operator read; viewers Alex and syndesis 22:24): appended to
        # runs/RUN/chronicle.jsonl from where the run (or the runs it resumed from) left off
        self.has_chronicle = False
        self.chronicle_path = chronicle_log.path_for(journals)
        self.chronicle_seq, self.chronicle_eid = chronicle_log.start_cursors(self.chronicle_path) if self.chronicle_path else (0, 0)
        self.platform_every = 15.0
        self.next_platforms = 0
        self.basemap_every = 60.0  # the site's live map (300 s for an hour on 2026-10-14 while the read cost 0.6 s; the census made it ~12 ms)
        self.next_basemap = 0
        # (d19 batch42 B2) the turrets past the basemap's 600, read in its defence cells, a command an observe (1.4 ms
        # for 40 areas on world n, 2026-10-19 13:30; a pass of 6 read 1459 turrets)
        self.turrets = turretsweep.TurretSweep()
        # (d20 batch50 G1, viewer Aurora) whether each turret can fire: a pass over the same defence areas at most once a
        # minute, a command an observe when the sweep has none (at most 120 turrets a command: 2.4 ms on world n,
        # 2026-10-20; 7.0 ms on the d17 headless copy)
        self.tstate = turretstate.TurretState()
        self.ore_every = 300.0  # ore under and around the base: every resource tile there, so less often still
        self.next_ore = 0
        # the other planets' coarse maps (census.lua): one planet a minute, in turn (each a census read from storage)
        self.planet_every = 60.0
        self.next_planet = 0
        self.planet_turn = 0
        # (d26 batch233 VM) our vehicles where our force last saw them (census.lua vehicles), the live map's vehicles layer
        self.vehicles_every = 10.0
        self.next_vehicles = 0
        self.platform_detail = {}
        self.platform_views = {}
        # work away from the body (remote platform builds, far ghosts): the agents' fh journals beside stream.json
        self.work = WorkFeed(journals, list(self.agents_cfg)) if journals else None
        self.waits = self.work.waits if self.work else WaitFeed()
        self.probe()

    def probe(self):
        """Detect the eng/bots runtime; retried every minute until the world answers."""
        try:
            self.caps = self.h.probe()
        except Exception as e:
            self.caps = None
            self.next_probe = time.time() + 60
            print(f"[live] world {self.world}: probe failed ({e}); retrying in 60 s", flush=True)
            return
        self.use_profiles = self.profiles_mode == "on" or (self.profiles_mode == "auto" and bool(self.caps.get("camera")))
        print(f"[live] world {self.world}: {self.caps}; profiles "
              f"{'on' if self.use_profiles else 'off (status per player)'}", flush=True)

    def reader(self):
        """Who to read as: a configured bot, else the first configured player index."""
        for name, cfg in self.agents_cfg.items():
            if cfg.get("kind", "bot") == "bot" and "player" not in cfg:
                return {"bot": name}
        for cfg in self.agents_cfg.values():
            if cfg.get("player"):
                return {"player": cfg["player"]}
        return {"player": 1}

    def read(self, action, args=None, **who):
        """A read that leaves the agent's `team` hint cursors alone (eng/board skips hints for `peek: true`).
        Runtimes that reject an unknown `peek` argument get the plain read from then on; a failed read never
        stops anyone."""
        args = dict(args or {})
        if self.peek_ok is not False:
            try:
                res = self.h.dispatch(action, dict(args, peek=True), **who)
                self.peek_ok = True
                return res
            except RuntimeError as e:
                if "argument peek" not in str(e):
                    raise
                if self.peek_ok is None:
                    print(f"[live] runtime rejects peek on {action}: overlay reads will consume "
                          f"{who.get('bot') or who.get('player')}'s team hints", flush=True)
                self.peek_ok = False
        return self.h.dispatch(action, args, **who)

    def agent_status(self, name, cfg):
        """status {brief, alerts}: what the overlay reads, none of the factory and threat scans a full status runs
        (eng/statusbrief). A runtime without them gets the full status from then on."""
        who = {"player": cfg["player"]} if cfg.get("player") else {"bot": name}
        if self.brief_ok is not False:
            # work (d20 batch70 AF3): the agent's bounded watches for its card; a runtime without it is asked again
            # after FOCUS_RETRY seconds, so a deploy needs no restart here
            work = getattr(self, "work_ok", None) is not False or time.time() >= getattr(self, "work_retry_t", 0)
            try:
                res = self.read("status", dict({"brief": True, "alerts": True}, **({"work": True} if work else {})), **who)[0]
                self.brief_ok = True
                if work:
                    self.work_ok = True
                return res
            except RuntimeError as e:
                if work and re.search(r"argument work\b|work is an option", str(e)):
                    self.work_ok, self.work_retry_t = False, time.time() + FOCUS_RETRY
                    return self.agent_status(name, cfg)
                if not re.search(r"argument (brief|alerts)\b|alerts is an option", str(e)):
                    raise
                self.brief_ok = False
        return self.read("status", **who)[0]

    def status_round(self, names, errors):
        """Names whose status to refresh this round: all of them without profiles, a share of them with."""
        if not self.use_profiles or len(names) <= 3:
            return names
        n = max(1, math.ceil(len(names) / self.status_share))
        pick = [names[(self.rr + i) % len(names)] for i in range(n)]
        self.rr = (self.rr + n) % len(names)
        return pick

    def poll_flows(self, obs, errors, now):
        """(d24 batch184 QAA2) one part of the surfaces' flows when its time came (each part every flow_every), and the
        parts' sum as obs["flows"]; the labs' use with the first part (every flow_every)."""
        if now < self.next_flow:
            return
        self.next_flow = now + self.flow_every / FLOW_PARTS
        part, self.flow_part = self.flow_part, (self.flow_part + 1) % FLOW_PARTS
        try:
            self.flow_parts[part] = self.h.flows(SPARK_ITEMS, part, FLOW_PARTS)
            obs["flows"] = sum_flows(self.flow_parts.values())
        except Exception as e:
            errors["flows"] = str(e)
        if part == 0:  # the labs' use of each pack over the last hour: the science per minute series (3.1 ms on world n)
            try:
                obs["used_flows"] = self.h.used_flows(SCIENCE)
            except Exception as e:
                errors["used_flows"] = str(e)

    def observe(self):
        if self.caps is None and time.time() >= self.next_probe:
            self.probe()
        errors = {}
        obs = {"agents": [], "chat": [], "events": []}
        try:
            score = self.h.score()
            obs["tick"], obs["paused"] = score["tick"], score.get("paused")
            obs["produced"] = score.get("produced") or {}
            obs["consumed"] = score.get("consumed") or {}  # science packs the labs used: science per minute
            obs["entities"] = score.get("entities") or {}  # building counts, for the hosts' unused_unlocks
            obs["entities_counted"] = score.get("entities_counted") or []  # which buildings the score counts at all
            done = score.get("research_done") or []
            obs["research"] = {"current": score.get("current_research"), "done": done if isinstance(done, list) else [],
                               "packs": score.get("current_packs") or []}
            obs["space"] = {"rockets": score.get("rockets") or 0, "planets": score.get("planets") or [],
                            "platforms": score.get("platforms") or []}
        except Exception as e:
            errors["score"] = str(e)
        if (obs.get("space") or {}).get("platforms"):
            self.observe_platforms(obs["space"], errors)
        try:
            ex = self.h.extras()
            if "research" in obs:
                obs["research"].update(progress=ex.get("progress"), top_done=ex.get("top_done") or [])
                if "repeating" in ex:  # (d20 batch57 S4) the infinite technologies' levels; {} from Lua when none
                    obs["research"]["repeating"] = ex["repeating"] if isinstance(ex["repeating"], list) else []
            obs["power"] = {"machines": ex.get("electric_machines"), "starved": ex.get("starved")}
            obs["darkness"] = ex.get("darkness")
            # the game's connected players (hostview.py: the host view ends when his client leaves)
            obs["connected_players"] = ex.get("connected") if isinstance(ex.get("connected"), list) else []
        except Exception as e:
            errors["extras"] = str(e)
        self.poll_flows(obs, errors, time.time())
        if time.time() >= self.next_basemap:
            self.next_basemap = time.time() + self.basemap_every
            ore = time.time() >= self.next_ore
            try:
                obs["basemap"] = self.h.basemap(ore=ore)
                self.turrets.seen(obs["basemap"])
                obs["basemap"] = self.turrets.apply(obs["basemap"])
                self.tstate.seen(obs["basemap"])
                if ore and obs["basemap"].get("ore") is not None:  # (the harness census reads ore on its next pass)
                    self.next_ore = time.time() + self.ore_every
                try:  # the site's time-lapse: a snapshot per 10 game minutes in runs/RUN/basemap/
                    basemap_log.save(self.journals, obs["basemap"])
                except OSError as e:
                    errors["basemap_log"] = str(e)
            except Exception as e:
                errors["basemap"] = str(e)
        elif self.turrets.todo:
            try:
                self.turrets.step(self.h)
            except Exception as e:
                errors["turrets"] = str(e)
        elif self.tstate.due(time.time()):
            try:
                self.tstate.step(self.h, time.time())
                obs["turret_state"] = self.tstate.public()
            except Exception as e:
                errors["turret_state"] = str(e)
        if time.time() >= self.next_planet:
            self.next_planet = time.time() + self.planet_every
            try:
                names = sorted(p["name"] for p in self.h.planets() if isinstance(p, dict) and p.get("name"))
                obs["planet_names"] = names
                if names:
                    name = names[self.planet_turn % len(names)]
                    self.planet_turn += 1
                    m = self.h.planet_map(name)
                    if m:
                        obs["planet_map"] = m
            except Exception as e:
                errors["planet_map"] = str(e)
        if time.time() >= self.next_vehicles:
            self.next_vehicles = time.time() + self.vehicles_every
            try:
                v = self.h.census_vehicles()
                if v is not None:
                    obs["vehicles"] = dict(v, t=time.time())
            except Exception as e:
                errors["vehicles"] = str(e)

        profiles = {}
        if self.use_profiles:
            try:
                res, _ = self.h.dispatch("profiles", **self.reader())
                for p in res.get("profiles", []) if isinstance(res, dict) else res:
                    profiles[p["name"]] = p
            except Exception as e:
                errors["profiles"] = str(e)
        names = list(self.agents_cfg) or list(profiles)
        alerts_seen = False
        hits = None
        for name in self.status_round(names, errors):
            try:
                st = self.agent_status(name, self.agents_cfg.get(name, {}))
                self.status_cache[name] = st
                self.waits.status(name, st, st.get("tick", obs.get("tick")), time.time())
                if hits is None:
                    hits = []  # a status (with alerts) was read: no platform_hits rows means none hit lately
                if not alerts_seen and st.get("alerts"):
                    alerts_seen = True  # force-wide: one agent's copy is enough
                    obs["events"] += self.attack_events(st["alerts"], obs.get("tick") or st.get("tick") or 0)
                    obs["events"] += self.loss_events(st["alerts"], obs.get("tick") or st.get("tick"))
                    # asteroid hits per platform over the last minutes (eng/platformalerts), for the Space widget
                    hits = list(st["alerts"].get("platform_hits") or [])
            except Exception as e:
                errors[f"status:{name}"] = str(e)
        if hits is not None:
            obs["platform_hits"] = hits
        for name in names:
            cfg = self.agents_cfg.get(name, {})
            p = profiles.get(name, {})
            st = self.status_cache.get(name, {})
            a = {"name": name, "kind": p.get("kind") or cfg.get("kind", "bot")}
            for key in ("display_name", "color", "glyph", "motto", "voice", "voice_description", "avatar", "position",
                        "last_said", "alive", "active", "pronouns", "surface", "platform", "where", "travel"):
                if p.get(key) is not None:
                    a[key] = p[key]
            if p:  # `profile` never called: profiles reports no display name, colour or glyph
                a["profile_set"] = any(p.get(k) for k in ("display_name", "color", "glyph"))
                a["travel"] = p.get("travel")  # None once a bot has landed: the model must see the ride end
            if st:
                if not p:  # without profiles, status is the only source of position/alive/active
                    act = st.get("active")  # status: {kind, until_tick, ...} or false
                    a["active"] = act.get("kind") if isinstance(act, dict) else (act or False)
                    a["alive"] = st.get("alive", True)
                    a["position"] = st.get("position")
                    a["surface"] = st.get("surface")
                    trav = st.get("travel") or {}
                    a["travel"] = trav.get("state")
                    a["where"] = ("platform " + st["platform"]) if st.get("platform") and trav.get("state") in (None, "aboard") \
                        else ("cargo pod" if trav else st.get("surface"))
                a.setdefault("position", st.get("position"))
                a["connected"] = st.get("connected", True) if a["kind"] == "player" else True
                a["last"] = st.get("last")
                # what the shoot does now and the last hit (status combat and hurt): model.combat_state tells under
                # attack from fighting from a guard with nothing in range (viewer Joonazan, 13:36)
                c = st.get("combat")
                a["combat"] = {k: c[k] for k in COMBAT_KEYS if k in c} if isinstance(c, dict) else bool(c)
                a["hurt"] = st.get("hurt")
                # (d22 batch93 BC2) driving a spidertron: its range, rockets and the enemies in range (status brief)
                a["vehicle_fire"] = st.get("vehicle_fire") if isinstance(st.get("vehicle_fire"), dict) else None
                # a standing order running in the agent's queue (orders.lua): {name, reason, step, steps}, or None
                a["auto"] = st.get("order") or None
                # (d20 batch70 AF3) the card's work: its bounded watches (status work) and each queue lane's active step
                a["watches"] = st.get("watches") or None
                a["queues"] = st.get("queues") if isinstance(st.get("queues"), dict) else None
                # the director's look-ahead (onecam.py): the action running now as status reports it (kind, until_tick,
                # total/placed/remaining, bounds, destination), from the status poll this service makes anyway
                act = st.get("active")
                a["plan"] = {k: act[k] for k in PLAN_KEYS if act.get(k) is not None} if isinstance(act, dict) else None
                if st.get("surface"):  # Space Age: the planet or platform surface the body is on
                    a["surface"], a["platform"] = st["surface"], st.get("platform")
                a["dead_until_tick"] = st.get("dead_until_tick")
            if self.journals:
                a["notes_job"] = self.notes_job(name)
                a["notes_job_t"] = (self.notes_cache.get(name) or (None,))[0]  # when notes.md was saved (the card's age)
                # a rest between turns (tools/agy-quota.py resting.json: Gemini pacing its weekly quota), or None
                a["resting"] = pacing.resting(os.path.join(self.journals, name))
            obs["agents"].append(a)
        # Only `names` become agents: the run's team, or every profile when the run lists none. Profiles outside the
        # team (a human player such as Nick in shake8, fh players eng/players adds) are not agent cards.
        if self.work:
            obs["work"] = self.observe_work(obs["agents"], errors)
            # where each agent is paying attention (attention.py): its latest request with a position, area or list
            obs["attention"] = self.work.take_attention()
            now = time.time()
            units = self.work.vehicles.units(now)
            if units:  # (d26 batch232 VC) where the agents' remote vehicles are now (harness VEHICLES_LUA, 5.4 us each)
                try:
                    self.work.vehicles.apply_live(self.h.vehicles(units), now)
                except Exception as e:
                    errors["vehicles"] = f"{type(e).__name__}: {e}"
            for a in obs["agents"]:  # the same request again and again: the agent's own sampling (workcard.py)
                a["repeats"] = self.work.repeats.current(a["name"], now)
                # (d26 batch222 CD) its vehicle by remote view, from its journal's vehicle replies (onecam follows it)
                a["remote_vehicle"] = self.work.vehicles.current(a["name"], now)
                if a.get("position"):  # (d27 batch271 WS) a fresh row naming no surface acted on the body's
                    self.work.did.body_surface(a["name"], a.get("surface") or "nauvis", now)
                a["did"] = self.work.did.current(a["name"], now)  # (d26 batch240) its latest build, paste, silo load ...
                a["idle_s"] = self.work.clocks.current(a["name"], now)  # (batch240) its character idle so long, by its clocks

        for a in obs["agents"]:
            a["wait"] = self.waits.current(a["name"], obs.get("tick") or 0, time.time())

        try:
            res, _ = self.h.dispatch("chat", {"since": self.chat_since, "limit": 30, "peek": True}, **self.reader())
            obs["chat"] = res.get("messages", [])
            if obs["chat"]:
                self.chat_since = obs["chat"][-1]["seq"]
        except Exception as e:
            errors["chat"] = str(e)
        self.observe_board(obs, errors)
        self.observe_silos(obs, errors)
        obs["errors"] = errors
        return obs

    def observe_silos(self, obs, errors):
        """(d26 batch257 IB) The rocket silos' states every poll (launches.SiloFeed, harness SILOS_LUA: 0.093 ms for 15
        silos on world n): obs["silos"], the launch shot's (onecam maybe_launch); this poll's chronicle rocket rows name
        where each launch goes."""
        if not self.work or self.caps is None or not self.caps.get("harness"):
            return
        feed = self.work.silos
        feed.note_rockets((obs.get("chronicle") or {}).get("events"))
        try:
            got = feed.read(self.h)
        except Exception as e:
            errors["silos"] = f"{type(e).__name__}: {e}"
            return
        if got:
            obs["silos"] = got

    # ---- work away from the body ----------------------------------------------------------------------------
    def read_focus(self, errors):
        """Each agent's board_focus (d20 batch54 N3, viewer Aurora: job cards from the focus, with its age): the read's
        rows [{agent, id, title, step, blocker, verify, tick, stalled}]; None when the runtime gives no rows (an older
        one: asked again after FOCUS_RETRY seconds, so a deploy needs no restart here) or the read fails."""
        if getattr(self, "focus_ok", None) is False and time.time() < getattr(self, "focus_retry_t", 0):
            return None
        try:
            fr, _ = self.read("board_focus", {}, **self.reader())
        except Exception as e:
            if "unsupported action" in str(e) or "unknown action" in str(e):
                self.focus_ok, self.focus_retry_t = False, time.time() + FOCUS_RETRY
            else:
                errors["board_focus"] = str(e)
            return None
        rows = fr.get("rows") if isinstance(fr, dict) else None
        self.focus_ok = isinstance(rows, list)
        if not self.focus_ok:
            self.focus_retry_t = time.time() + FOCUS_RETRY
        return rows if self.focus_ok else None

    def read_progress(self, errors):
        """(d22 batch75 AK11, viewer Foobator site:4284: "can projects that are actively being worked on and blocked projects
        be easier to see on site? also, could you show blocker reason?") board_progress with no arguments: the stored
        checks of every owned open item (progress.lua: state, stalled, unchanged_checks, check_error, checked_s,
        last_change_s), rows by id; None when the runtime gives none (asked again after FOCUS_RETRY) or the read fails."""
        if getattr(self, "progress_ok", None) is False and time.time() < getattr(self, "progress_retry_t", 0):
            return None
        # 5.7 ms on world n (57 rows, 24 KB, d22 14:40): once every PROGRESS_EVERY, the last rows between
        if time.time() < getattr(self, "progress_next", 0):
            return getattr(self, "progress_rows", None)
        self.progress_next = time.time() + PROGRESS_EVERY
        try:
            pr, _ = self.read("board_progress", {}, **self.reader())
        except Exception as e:
            if "unsupported action" in str(e) or "unknown action" in str(e):
                self.progress_ok, self.progress_retry_t = False, time.time() + FOCUS_RETRY
            else:
                errors["board_progress"] = str(e)
            return None
        rows = pr.get("rows") if isinstance(pr, dict) else None
        if rows == {}:  # table_to_json writes an empty table as {}: no owned open item
            rows = []
        self.progress_ok = isinstance(rows, list)
        if not self.progress_ok:
            self.progress_retry_t = time.time() + FOCUS_RETRY
            return None
        self.progress_rows = [r for r in rows if isinstance(r, dict) and r.get("id") is not None]
        return self.progress_rows

    def notes_job(self, name):
        """The agent's job line from runs/RUN/AGENT/notes.md "## Now" (model.notes_job), or None."""
        path = os.path.join(self.journals, name, "notes.md")
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            return None
        hit = self.notes_cache.get(name)
        if not hit or hit[0] != mtime:
            try:
                with open(path, errors="replace") as f:
                    hit = (mtime, notes_job(f.read(200_000)))
            except OSError:
                return None
            self.notes_cache[name] = hit
        return hit[1]

    def observe_work(self, agents, errors):
        """New journal requests that land away from the agent's body: on a platform (the body never is, when it
        builds there remotely), on another surface than the body's (batch271: args.surface, Astra on Aquilo building on
        Nauvis), or AWAY_TILES or more from the body on its own surface. A row's surface is the request's, else the
        body's (the runtime acts there)."""
        try:
            reqs = self.work.poll()
        except Exception as e:
            errors["work"] = str(e)
            return []
        by = {a["name"]: a for a in agents}
        out = []
        for r in reqs:
            body = by.get(r["agent"]) or {}
            here = body.get("position")
            own = body.get("surface") or "nauvis"
            named = r.get("surface")
            if r["platform"]:
                if body.get("platform") == r["platform"]:
                    continue  # aboard that platform: its camera already shows the work
            elif named and named not in (own, body.get("platform")):
                pass  # another surface: the camera following the body never shows it
            elif not (r["position"] and here and math.hypot(r["position"]["x"] - here["x"],
                                                            r["position"]["y"] - here["y"]) >= AWAY_TILES):
                continue  # near the body (or no position to tell): the camera following it shows the work
            out.append(dict(r, surface=None if r["platform"] else (named or own)))
        return out

    # ---- Space Age platforms ------------------------------------------------------------------------------------
    # route and speed; and for the Space widget (model.platform_card) the defence, repair packs, damaged entities and
    # hub cargo (eng/platformalerts); ammo made/used and when it runs out in flight (onecam's danger shot; viewer
    # joonazan, d15 10:45)
    PLATFORM_FIELDS = ("state", "at", "speed", "schedule", "paused", "thrusters", "weight", "defense", "repair_packs",
                       "damaged", "damaged_count", "hub_items", "ammo_rates")

    def observe_platforms(self, space, errors):
        """Platform detail (state, location or route, speed, schedule) with a peek `platforms` read per platform,
        every platform_every seconds, at most 4 platforms; between reads the score's name and location stand."""
        now = time.time()
        if now >= self.next_platforms:
            self.next_platforms = now + self.platform_every
            detail = {}
            for row in space["platforms"][:4]:
                try:
                    # (d22 batch96 BF1) only these fields: the read then makes only their parts of the row (each of
                    # these 4 reads was 11-15 ms in one tick on a copy of world n, the whole row with its freight,
                    # engine and request lines)
                    res, _ = self.read("platforms", {"platform": row["name"], "fields": list(self.PLATFORM_FIELDS)},
                                       **self.reader())
                    for p in res.get("platforms") or []:
                        detail[p.get("name")] = {k: p.get(k) for k in self.PLATFORM_FIELDS if p.get(k) is not None}
                except Exception as e:
                    errors["platforms"] = str(e)
            self.platform_detail = detail
            # where a camera shows each platform: surface, hub, bounds (one read-only Lua call for all of them)
            if hasattr(self.h, "platform_views"):
                try:
                    self.platform_views = self.h.platform_views()
                except Exception as e:
                    errors["platform_views"] = str(e)
                self.add_hulls(self.platform_views, errors)
        views = getattr(self, "platform_views", {})

        def placed(name):
            """(d22 batch75 AK2, viewer Foobator: "the ship overview only has a progress bar for the first 2 that are
            in transit?") the views read's state, location or route and speed, every platform's (the detail above is
            read for the first 4 only, and the score's `at` says "in transit" without the route)."""
            w = (views.get(name) or {}).get("where")
            return {k: w[k] for k in ("state", "at", "speed", "paused") if w.get(k) is not None} if isinstance(w, dict) else {}
        # later keys win: the views read and the detail read (up to 15 s old) over the score row, the fresh location over
        # them (dict(row, **a, **b) raised "multiple values for keyword argument 'at'" from the 15:10 deploy)
        rows = []
        for row in space["platforms"]:
            read = {**placed(row["name"]), **self.platform_detail.get(row["name"], {})}
            rows.append({**row, **read, **({"view": views[row["name"]]} if row["name"] in views else {}), **self.fresh_at(row, read)})
        space["platforms"] = rows

    LONG_LEGS = ("solar-system-edge", "shattered-planet")

    @classmethod
    def long_leg(cls, view):
        """(d24 batch170 QM1) The view's `where` puts it on a space connection to or from the solar system edge or the
        shattered planet ("solar-system-edge->aquilo 1%")."""
        at = str(((view or {}).get("where") or {}).get("at") or "")
        ends = at.rsplit(" ", 1)[0].split("->") if "->" in at else []
        return any(e in cls.LONG_LEGS for e in ends)

    def add_hulls(self, views, errors):
        """(d24 batch170 QM1, viewer Caleb: the front of Asterion in flight) A platform flying a long leg gets its hull's
        box and bow from its foundation tiles (Harness.platform_hulls, each read again after HULL_EVERY) in its view:
        `hull` and `bow` {left, top, right, bottom}, for onecam's bow shot."""
        names = [n for n, v in (views or {}).items() if self.long_leg(v)]
        if not names or not hasattr(self.h, "platform_hulls"):
            return
        try:
            hulls = self.h.platform_hulls(names)
        except Exception as e:
            errors["platform_hulls"] = str(e)
            return
        for n, h in hulls.items():
            if n in views and h.get("surface") == views[n].get("surface"):
                views[n]["hull"], views[n]["bow"] = h.get("hull"), h.get("bow")

    @staticmethod
    def fresh_at(row, detail):
        """The score row is read every round, the detail every platform_every s: when they disagree on whether the
        platform is at a planet or travelling, the score's `at` stands (Sunward reached Nauvis at 14:14:32 while a
        detail read from before still put it on its route)."""
        at, dat = row.get("at"), detail.get("at")
        if not dat or not at:
            return {}
        if at != "in transit" or "->" not in dat:  # arrived (a planet now), or departed (detail still at a planet)
            return {"at": at}
        return {}

    # ---- team board (docs/BOARD-API.md) ------------------------------------------------------------------------
    def board_probe(self):
        """Board reads only once the running runtime lists `board_events`: an unknown action fails, and a failed
        non-read call stops the reading bot. `describe` is read-only and lists the actions. Re-checked every 5 min,
        since a runtime can be installed mid-run."""
        self.next_board_probe = time.time() + 300
        try:
            res, _ = self.h.dispatch("describe", **self.reader())
            actions = res.get("actions") or {}
            self.has_board = "board_events" in actions and "board" in actions
            self.has_confess = "confessions" in actions
            self.has_tells = "tells" in actions
            self.has_operator = "operator" in actions
            self.has_groups = "attack_groups_live" in (res.get("operator_reads") or [])
            self.has_big = "big_enemies_live" in (res.get("operator_reads") or [])
            self.has_hauling = "hauling" in (res.get("operator_reads") or [])
            self.has_haul_feed = "haul_feed" in (res.get("operator_reads") or [])
            self.has_efficiency = "efficiency" in (res.get("operator_reads") or [])
            self.has_loadout = "loadout" in (res.get("operator_reads") or [])
            self.has_clouds = "clouds" in (res.get("operator_reads") or [])
            self.has_library_areas = "library_areas" in (res.get("operator_reads") or [])
            self.has_net_map = "net_map" in (res.get("operator_reads") or [])
            self.has_chart = "chart" in (res.get("operator_reads") or [])
            self.has_chronicle = "chronicle" in (res.get("operator_reads") or [])
            # artillery shells in flight: serve.py reads them on their own pace (artillery_poller)
            self.has_artillery = "artillery_live" in (res.get("operator_reads") or [])
        except Exception as e:
            self.has_board = False
            print(f"[live] board probe failed: {e}", flush=True)
            return
        if self.has_board:
            print("[live] runtime has the team board; polling board_events", flush=True)

    def observe_groups(self, obs, errors):
        """Enemy groups on their way (harness attack_groups_live) and demolishers near our buildings
        (big_enemies_live), operator reads: each every ~2 s while it lists something, else every 10 s; a runtime
        without them is asked again with the board probe."""
        now = time.time()
        if getattr(self, "has_groups", False) and now >= self.next_groups:
            try:
                res, _ = self.h.operator_read("attack_groups_live", {})
                obs["attack_groups"] = res.get("groups") or []
                self.next_groups = now + (self.groups_every if obs["attack_groups"] else 10.0)
            except Exception as e:
                errors["attack_groups"] = str(e)
                self.next_groups = now + 30.0
        if getattr(self, "has_big", False) and now >= getattr(self, "next_big", 0):
            try:
                res, _ = self.h.operator_read("big_enemies_live", {})
                obs["big_enemies"] = res.get("enemies") or []
                self.next_big = now + (self.groups_every if obs["big_enemies"] else 10.0)
            except Exception as e:
                errors["big_enemies"] = str(e)
                self.next_big = now + 30.0

    def observe_hauling(self, obs, errors):
        """Hand hauling per agent (operator read `hauling`), every hauling.READ_EVERY seconds: each read is a row in
        runs/RUN/hauling.jsonl, and obs["hauling"] is the shift's numbers so far (this read less the file's first)."""
        now = time.time()
        if not getattr(self, "has_hauling", False) or now < self.next_hauling:
            return
        try:
            res, _ = self.h.operator_read("hauling", {"top": 10})
        except Exception as e:
            errors["hauling"] = str(e)
            self.next_hauling = now + 60.0
            return
        self.next_hauling = now + hauling.READ_EVERY
        team = set(self.agents_cfg) or None
        # (d17 batch35 D5) what feeds each agent's most repeated haul's destination now (haul_feed), kept in the row
        feeds = None
        probe = {"t": now, "agents": (res or {}).get("agents") or []}
        args = hauling.feed_args(hauling.shift_rows(self.hauling_first or probe, probe, team))
        if args and getattr(self, "has_haul_feed", False):
            try:
                fr, _ = self.h.operator_read("haul_feed", {"rows": args})
                feeds = {f.get("agent"): f for f in (fr or {}).get("rows") or [] if f.get("agent")}
            except Exception as e:
                errors["haul_feed"] = str(e)
        row = hauling.append(self.hauling_path, res, now, feeds)
        if row is None:
            return
        if self.hauling_first is None:
            self.hauling_first = row
        obs["hauling"] = {"rows": hauling.shift_rows(self.hauling_first, row, team), "since": self.hauling_first["t"],
                          "t": row["t"], "feeds": feeds}

    def observe_efficiency(self, obs, errors):
        """Production credited to who built the machine (operator read `efficiency`), every efficiency.READ_EVERY
        seconds: each read is a row in runs/RUN/efficiency.jsonl, and obs["efficiency"] the read for the card."""
        now = time.time()
        if not getattr(self, "has_efficiency", False) or now < self.next_efficiency:
            return
        try:
            res, _ = self.h.operator_read("efficiency")
        except Exception as e:
            errors["efficiency"] = str(e)
            self.next_efficiency = now + 60.0
            return
        self.next_efficiency = now + efficiency.READ_EVERY
        row = efficiency.append(self.efficiency_path, res, now)
        if row is not None:
            obs["efficiency"] = efficiency.view(row, set(self.agents_cfg) or None)

    def observe_loadout(self, obs, errors):
        """Each agent's guns and ammo, armor and equipment, largest stacks, craft queue and build progress (operator
        read `loadout`), every loadout_every seconds: obs["loadout"] is the read's rows."""
        now = time.time()
        if not getattr(self, "has_loadout", False) or now < self.next_loadout:
            return
        try:
            res, _ = self.h.operator_read("loadout", {"top": 8})
        except Exception as e:
            errors["loadout"] = str(e)
            self.next_loadout = now + 30.0
            return
        self.next_loadout = now + self.loadout_every
        if isinstance(res.get("agents"), list):
            obs["loadout"] = res["agents"]

    def observe_clouds(self, obs, errors):
        """Pollution and spores per charted chunk (operator read `clouds`), every clouds_every seconds: obs["clouds"]
        is the read's rows, one per surface."""
        now = time.time()
        if not getattr(self, "has_clouds", False) or now < self.next_clouds:
            return
        try:
            res, _ = self.h.operator_read("clouds", {})
        except Exception as e:
            errors["clouds"] = str(e)
            self.next_clouds = now + 120.0
            return
        self.next_clouds = now + self.clouds_every
        if isinstance(res.get("clouds"), list):
            obs["clouds"] = res["clouds"]

    def observe_library_areas(self, obs, errors):
        """The team library's placed areas (operator read `library_areas`), every library_areas_every seconds:
        obs["library_areas"] is the read {tick, areas, placements, shown}."""
        now = time.time()
        if not getattr(self, "has_library_areas", False) or now < self.next_library_areas:
            return
        try:
            res, _ = self.h.operator_read("library_areas", {})
        except Exception as e:
            errors["library_areas"] = str(e)
            self.next_library_areas = now + 120.0
            return
        self.next_library_areas = now + self.library_areas_every
        if isinstance(res.get("areas"), (list, dict)):
            obs["library_areas"] = dict(res, areas=res["areas"] if isinstance(res["areas"], list) else [])

    def observe_terrain(self, obs, errors):
        """(d22 batch75 AK9) the charted ground under the map (terrain_grid.py): a read every terrain_grid.EVERY seconds
        (the chunks next to the known ground, those under the agents; about 3 ms on world n), and obs["terrain_grid"]
        after each read, and once at the start from the grid kept in the run."""
        t = getattr(self, "terrain", None)
        if t is None:
            return
        ran = t.due() and t.read(self.h.lua, terrain_grid.seeds_from(obs.get("agents")))
        if ran or not getattr(self, "terrain_sent", False):
            g = t.grid()
            if g:
                obs["terrain_grid"] = g
                self.terrain_sent = True
        if t.error:
            errors["terrain_grid"] = t.error

    def observe_chart(self, obs, errors):
        """(d22 batch97 BG3) the site's chart (chart.py): one `chart` operator read every chart.EVERY seconds (under 10 ms
        on the x86 private copy), the cells it changed drawn into runs/RUN/chart/out/; obs["chart"] its status."""
        c = getattr(self, "chart", None)
        if c is None or not getattr(self, "has_chart", False):
            return
        if c.due():
            c.step(lambda args: self.h.operator_read("chart", args)[0])
            obs["chart"] = c.status()
            line = c.log_line()  # (cp6) the service log says the chart is going (shift60's log had no chart line)
            if line:
                print(line, flush=True)
        if c.error:
            errors["chart"] = c.error

    def observe_net_map(self, obs, errors):
        """A planet's networks map (operator read `net_map`), every net_map_every seconds: the first listed planet whose map
        is newer than the one read (none: the listing only). obs["net_map"] is that map, obs["net_map_listed"] the planets
        with a map."""
        now = time.time()
        if not getattr(self, "has_net_map", False) or now < self.next_net_map:
            return
        want = next((x["surface"] for x in self.net_map_listed if isinstance(x, dict) and isinstance(x.get("surface"), str)
                     and (x.get("tick") or 0) > self.net_map_seen.get(x["surface"], -1)), None)
        try:
            res, _ = self.h.operator_read("net_map", {"surface": want} if want else {})
        except Exception as e:
            errors["net_map"] = str(e)
            self.next_net_map = now + 120.0
            return
        self.next_net_map = now + self.net_map_every
        self.net_map_listed = res.get("surfaces") if isinstance(res.get("surfaces"), list) else []
        obs["net_map_listed"] = [x["surface"] for x in self.net_map_listed if isinstance(x, dict) and isinstance(x.get("surface"), str)]
        m = res.get("map")
        if isinstance(m, dict) and isinstance(m.get("surface"), str):
            self.net_map_seen[m["surface"]] = m.get("tick") or 0
            obs["net_map"] = m

    def observe_board(self, obs, errors):
        if self.caps is None or not self.caps.get("harness"):
            return
        if not self.has_board or not getattr(self, "has_groups", True) or not getattr(self, "has_hauling", True) \
                or not getattr(self, "has_loadout", True) or not getattr(self, "has_clouds", True) \
                or not getattr(self, "has_chronicle", True) or not getattr(self, "has_library_areas", True) \
                or not getattr(self, "has_net_map", True):
            if time.time() >= self.next_board_probe:
                self.board_probe()
        self.observe_groups(obs, errors)
        self.observe_hauling(obs, errors)
        self.observe_efficiency(obs, errors)
        self.observe_loadout(obs, errors)
        self.observe_clouds(obs, errors)
        self.observe_library_areas(obs, errors)
        self.observe_net_map(obs, errors)
        self.observe_terrain(obs, errors)
        self.observe_chart(obs, errors)
        if self.has_confess:  # confessionals (agent -> viewers only), read as the operator
            try:
                res, _ = self.h.operator_read("confessions", {"since": self.confess_seq, "limit": 30})
                obs["confessions"] = res.get("confessions") or []
                if res.get("cursor") is not None:
                    self.confess_seq = res["cursor"]
            except Exception as e:
                errors["confessions"] = str(e)
        if self.has_tells:  # tells (agent -> named teammates, outside the chat), read as the operator: the ticker
            try:
                res, _ = self.h.operator_read("tells", {"since": self.tell_seq, "limit": 30})
                obs["tells"] = res.get("tells") or []
                if res.get("cursor") is not None:
                    self.tell_seq = res["cursor"]
            except Exception as e:
                errors["tells"] = str(e)
        if self.has_operator:  # agents' requests to the operator, read as the operator: the inbox file and the ticker
            try:
                # (d28 batch299 IC) the runtime returns the oldest 30 after the cursor and how many more wait; the cursor
                # moves to the last row written, and the read pages until caught up (at most 8 pages a poll, the rest
                # next poll). An older runtime returned the newest 30 (no `more`): one read, as before.
                obs["operator_requests"] = []
                for _ in range(8):
                    res, _ = self.h.operator_read("operator_requests", {"since": self.operator_seq, "limit": 30})
                    if res.get("trimmed"):
                        errors["operator_requests_trimmed"] = (f"{res['trimmed']} requests after seq {self.operator_seq}"
                                                               " left the runtime's kept log before this read")
                    rows = operator_inbox.append(self.inbox_path, res.get("requests"), self.operator_seq)
                    obs["operator_requests"] += rows
                    if rows:
                        self.operator_seq = max(r["seq"] for r in rows)
                    elif res.get("cursor") is not None and res["cursor"] < self.operator_seq:
                        self.operator_seq = res["cursor"]  # a fresh world counts its requests from 1 again
                    if not rows or not res.get("more"):
                        break
            except Exception as e:
                errors["operator_requests"] = str(e)
        if getattr(self, "has_chronicle", False):  # the run's chronicle: new entries and events, every poll
            try:
                res, _ = self.h.operator_read("chronicle", {"since": self.chronicle_seq, "events_since": self.chronicle_eid,
                                                            "limit": 50})
                if (res.get("cursor") or 0) < self.chronicle_seq or (res.get("events_cursor") or 0) < self.chronicle_eid:
                    self.chronicle_seq, self.chronicle_eid = 0, 0  # a fresh world counts from 1 again
                entries, events = chronicle_log.append(getattr(self, "chronicle_path", None), res, self.chronicle_seq,
                                                       self.chronicle_eid)
                obs["chronicle"] = {"entries": entries, "events": events}
                if entries:
                    self.chronicle_seq = max(int(e["seq"]) for e in entries)
                if events:
                    self.chronicle_eid = max(int(e["id"]) for e in events)
            except Exception as e:
                errors["chronicle"] = str(e)
        if not self.has_board:
            return
        try:
            res, _ = self.h.dispatch("board_events", {"since_seq": self.board_seq}, **self.reader())
            events = res.get("events") or []
            obs["board_events"] = events
            cursor = res.get("cursor")
            if cursor is None and events:
                cursor = max(e.get("seq") or 0 for e in events)
            if cursor is not None:
                self.board_seq = cursor
        except Exception as e:
            errors["board_events"] = str(e)
        if time.time() >= self.next_board:
            self.next_board = time.time() + self.board_every
            # the team's reminder jobs (reminders.lua, d15 batch5 group I) for the site's panel; a runtime without them
            # refuses the action, and it is not asked again
            if getattr(self, "reminders_ok", None) is not False:
                try:
                    rem, _ = self.read("reminders", {"all": True}, **self.reader())
                    obs["reminders"] = {"jobs": rem.get("reminders") or [], "tick": rem.get("tick")}
                    self.reminders_ok = True
                except Exception as e:
                    if "unsupported action" in str(e) or "unknown action" in str(e):
                        self.reminders_ok = False
                    else:
                        errors["reminders"] = str(e)
            try:
                # with each plan line's tick (board plan_ticks: the site's Team plan says when each line changed);
                # an older runtime refuses the argument, and is asked without it from then on
                if self.plan_ticks_ok is not False:
                    try:
                        res, _ = self.read("board", {"limit": 60, "plan_ticks": True}, **self.reader())
                        self.plan_ticks_ok = True
                    except RuntimeError as e:
                        if "plan_ticks" not in str(e):
                            raise
                        self.plan_ticks_ok = False
                if self.plan_ticks_ok is False:
                    res, _ = self.read("board", {"limit": 60}, **self.reader())
                claims, _ = self.read("board", {"kind": "claim", "limit": 30}, **self.reader())
                try:  # open projects outlive the newest 60 items (eng/projects; an older runtime refuses the kind)
                    projects, _ = self.read("board", {"kind": "project", "status": "active", "limit": 30}, **self.reader())
                    # the last finished ones too, for the live page's "show all" (Foobator 08:31: "no way to browse hidden projects")
                    done, _ = self.read("board", {"kind": "project", "status": "done", "limit": 10}, **self.reader())
                    projects = {"items": (projects.get("items") or []) + (done.get("items") or [])}
                    self.full_steps(projects["items"])
                except Exception:
                    projects = {}
                # every active item, for the live page's open and in-progress lists (viewer joonazan, d15 08:19: "I can't
                # see the open jobs"); None when the read fails, and the page keeps its counts only
                try:
                    active = {"items": []}
                    for kind in ("task", "request"):
                        part, _ = self.read("board", {"kind": kind, "status": "active", "limit": 100}, **self.reader())
                        active["items"] += part.get("items") or []
                except Exception:
                    active = None
                # (d22 batch99 BI3, viewer Aurora site:4316: "Hidden jobs ... make it hard to check what's actually
                # finished") the finished tasks and requests too, for the site's full list (on world n at 16:20 the board
                # kept 18 done tasks and 8 done requests; each read about 0.1 s through fh)
                try:
                    finished = {"items": []}
                    for kind in ("task", "request"):
                        part, _ = self.read("board", {"kind": kind, "status": ["done", "dropped"], "limit": 60}, **self.reader())
                        finished["items"] += part.get("items") or []
                except Exception:
                    finished = None
                items = {it.get("id"): it for it in (res.get("items") or []) + (claims.get("items") or [])
                         + (projects.get("items") or []) + ((active or {}).get("items") or [])
                         + ((finished or {}).get("items") or [])}
                focus = self.read_focus(errors)
                progress = self.read_progress(errors)  # (d22 batch75 AK11) the progress checks' facts per owned item
                obs["board"] = {"items": list(items.values()), "open_unowned": res.get("open_unowned"), "focus": focus, "progress": progress,
                                "plan": res.get("plan"),  # the team plan (board_plan; absent on older runtimes)
                                "active_ids": [it.get("id") for it in active.get("items") or []] if isinstance(active, dict) else None,
                                "finished_ids": [it.get("id") for it in finished.get("items") or []] if isinstance(finished, dict) else None}
                if self.journals and "plan" in res:  # the plan a shift leaves, for its page on the site (planlog.py)
                    try:
                        planlog.save(self.journals, planlog.record(res.get("plan"), obs["board"]["items"],
                                                                   res.get("open_unowned"), res.get("tick")))
                    except OSError as e:
                        errors["plan_log"] = str(e)
            except Exception as e:
                errors["board"] = str(e)

    @staticmethod
    def loss_event(x, y, x2, y2, total, names, by, surface=None, platform=None, ident=None, tick=None):
        """One loss banner: where the camera frames it (the loss rectangle's centre and size, a single point 16
        tiles) on the incident's surface; a platform's surface goes to its platform (model.platform_of)."""
        what = ", ".join(n.strip().replace("-", " ") for n in (names or "").split(",")[:2])
        # a numbered line names only the platform: model.platform_of matches a platform by its name too
        surface = surface or platform or "nauvis"
        on = f"on {surface[:1].upper() + surface[1:]} " if surface != "nauvis" and not platform else ""
        text = f"{total} lost {on}near ({x}, {y}): {what}" + (f" (by {attacker_label(by)})" if by else "")
        x2, y2 = float(x if x2 is None else x2), float(y if y2 is None else y2)
        pos = {"x": (float(x) + x2) / 2, "y": (float(y) + y2) / 2,
               "extent": max(16.0, abs(x2 - float(x)), abs(y2 - float(y))), "surface": surface}
        key = f"loss:{surface}:#{ident}" if ident is not None else f"loss:{x},{y}" if surface == "nauvis" else f"loss:{surface}:{x},{y}"
        ev = {"kind": "loss", "text": text, "key": key, "ttl": 90, "position": pos}
        if isinstance(tick, (int, float)):
            ev["tick"] = tick  # the incident's last_tick: when it happened (replays.py times its clip from it)
        if platform:
            ev["platform"] = platform
        return ev

    @staticmethod
    def loss_events(alerts, tick=None):
        """status.alerts.incidents (rows with id, surface, platform, box, total, names, by, last_tick) -> loss banners
        (one per incident) on the incident's surface. 12:58 on 2026-10-13: Sol's 59 turrets lost on Vulcanus went to
        Nauvis (-223,74), an empty field, when the surface was read as nauvis. A runtime without rows: the text of
        status.alerts.latest, old ("in (12,-40)-(20,-31) 7 destroyed: ...") or numbered ("#7 on vulcanus in ...")."""
        out = []
        rows = alerts.get("incidents")
        if isinstance(rows, list) and rows:
            for r in rows[:3]:
                b = r.get("box") or {}
                if not all(isinstance(b.get(k), (int, float)) for k in ("x0", "y0", "x1", "y1")):
                    continue
                if tick is not None and isinstance(r.get("last_tick"), (int, float)) and tick - r["last_tick"] >= LOSS_RECENT_TICKS:
                    continue  # the alert window is 5 game minutes; only show losses from the last minute or so
                out.append(LiveSource.loss_event(b["x0"], b["y0"], b["x1"], b["y1"], r.get("total") or 0, r.get("names"),
                                                 r.get("by"), r.get("surface"), r.get("platform"), r.get("id"),
                                                 r.get("last_tick")))
            return out
        for line in (alerts.get("latest") or [])[:3]:
            m = LOSS_RE.match(line or "")
            if not m:
                continue
            if not RECENT_AGO.match(m.group("ago")):
                continue
            out.append(LiveSource.loss_event(m.group("x"), m.group("y"), m.group("x2"), m.group("y2"), int(m.group("total")),
                                             m.group("names"), m.group("by"), m.group("surface"), m.group("platform"),
                                             m.group("id")))
        return out

    @staticmethod
    def attack_events(alerts, tick):
        """status.alerts.attacked: [{chunk_centre{x,y}, hits, damage, last_tick, by, entities}] -> overlay events."""
        out = []
        for area in alerts.get("attacked") or []:
            if tick - (area.get("last_tick") or 0) > ATTACK_RECENT_TICKS:
                continue
            if not area.get("damage"):
                continue  # zero-damage hits: the crash site's fire, not an attack
            c = area.get("chunk_centre") or {}
            what = hit_label((area.get("entities") or "").split(",")[0])
            surface = area.get("surface") or "nauvis"
            # off Nauvis the text says the planet (the hosts joined Nauvis turret hits to Sol on Gleba, 11:15-12:57)
            on = f"on {surface[:1].upper() + surface[1:]} " if surface != "nauvis" else ""
            near = f"{on}near ({round(c.get('x', 0))}, {round(c.get('y', 0))})"
            text = f"Engineer under attack {near}" if what == "an engineer" else \
                f"Base under attack {near}" + (f": {what}" if what else "")
            out.append({"kind": "attack", "text": text, "key": f"area:{c.get('x')},{c.get('y')}", "ttl": 60,
                        "position": dict(c, extent=CHUNK, surface=surface)})
        return out

    def send_camera(self, body):
        return self.h.camera(body)

    def send_highlights(self, body):
        """highlights.py: the camera-only rings and labels, one operator dispatch per update."""
        return self.h.operator_draw("highlights", body)
