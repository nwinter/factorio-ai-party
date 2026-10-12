"""Live observations from a pog world, read-only.

With the eng/bots runtime (detected by the `camera` remote function) it polls `profiles` every round and per-agent
`status` round-robin (a third of the agents per round, so each agent's status is at most ~3 polls old). Before that
lands it reads `status` for every player index in the run config each round, so the page works against today's
worlds (e.g. the paused co-op save in world c).
"""
import math, re, time

from harness import Harness
from model import SPARK_ITEMS

ATTACK_RECENT_TICKS = 60 * 30  # an attacked area counts as "now" for 30 game seconds
LOSS_RE = re.compile(r"^(?:losses )?in \((-?\d+),(-?\d+)\)(?:-\(-?\d+,-?\d+\))? (\d+) destroyed: (.*?)(?: by (.*?))?, (\S+) ago$")
RECENT_AGO = re.compile(r"^(?:.*-)?(?:\d+s|1m\d\ds)$")  # last part of the span under 2 minutes


def hit_label(entities):
    """status.alerts.attacked `entities` ("character x3", "gun-turret x12"): the x is a hit count, which the hosts read
    as a number of enemies or turrets on air (shake3), so the banner and replay titles name only what was hit."""
    name = re.sub(r"\s*x\d+$", "", (entities or "").strip()).replace("-", " ")
    return "an engineer" if name == "character" else name


def attacker_label(by):
    """describe_incident's "by 5 small-biter, 2 medium-biter" counts kills by each kind: "small biters"."""
    name = re.sub(r"^\d+\s+", "", (by or "").split(",")[0].strip()).replace("-", " ")
    return name + "s" if name and not name.endswith("s") else name


class LiveSource:
    def __init__(self, world, run, profiles="auto", flow_every=30.0, harness=None, status_share=3):
        self.name = f"live:{world}"
        self.world = world
        self.h = harness or Harness(world)
        self.run = run
        self.agents_cfg = run.get("agents") or {}
        self.profiles_mode = profiles
        self.flow_every = flow_every
        self.next_flow = 0
        self.chat_since = 0
        self.status_share = status_share
        self.status_cache = {}
        self.rr = 0
        self.caps = None
        self.next_probe = 0
        self.use_profiles = profiles == "on"
        self.peek_ok = None
        self.has_board = False
        self.next_board_probe = 0
        self.board_seq = 0
        self.board_every = 15.0
        self.next_board = 0
        self.has_confess = False
        self.confess_seq = 0
        self.has_tells = False
        self.tell_seq = 0
        self.platform_every = 15.0
        self.next_platforms = 0
        self.platform_detail = {}
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
        if cfg.get("player"):
            return self.read("status", player=cfg["player"])[0]
        return self.read("status", bot=name)[0]

    def status_round(self, names, errors):
        """Names whose status to refresh this round: all of them without profiles, a share of them with."""
        if not self.use_profiles or len(names) <= 3:
            return names
        n = max(1, math.ceil(len(names) / self.status_share))
        pick = [names[(self.rr + i) % len(names)] for i in range(n)]
        self.rr = (self.rr + n) % len(names)
        return pick

    def observe(self):
        if self.caps is None and time.time() >= self.next_probe:
            self.probe()
        errors = {}
        obs = {"agents": [], "chat": [], "events": []}
        try:
            score = self.h.score()
            obs["tick"], obs["paused"] = score["tick"], score.get("paused")
            obs["produced"] = score.get("produced") or {}
            done = score.get("research_done") or []
            obs["research"] = {"current": score.get("current_research"), "done": done if isinstance(done, list) else []}
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
            obs["power"] = {"machines": ex.get("electric_machines"), "starved": ex.get("starved")}
            obs["darkness"] = ex.get("darkness")
        except Exception as e:
            errors["extras"] = str(e)
        if time.time() >= self.next_flow:
            self.next_flow = time.time() + self.flow_every
            try:
                obs["flows"] = self.h.flows(SPARK_ITEMS)
            except Exception as e:
                errors["flows"] = str(e)

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
        for name in self.status_round(names, errors):
            try:
                st = self.agent_status(name, self.agents_cfg.get(name, {}))
                self.status_cache[name] = st
                if not alerts_seen and st.get("alerts"):
                    alerts_seen = True  # force-wide: one agent's copy is enough
                    obs["events"] += self.attack_events(st["alerts"], obs.get("tick") or st.get("tick") or 0)
                    obs["events"] += self.loss_events(st["alerts"])
            except Exception as e:
                errors[f"status:{name}"] = str(e)
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
                a["combat"] = bool(st.get("combat"))
                if st.get("surface"):  # Space Age: the planet or platform surface the body is on
                    a["surface"], a["platform"] = st["surface"], st.get("platform")
                a["dead_until_tick"] = st.get("dead_until_tick")
            obs["agents"].append(a)
        # Only `names` become agents: the run's team, or every profile when the run lists none. Profiles outside the
        # team (a human player such as Nick in shake8, fh players eng/players adds) are not agent cards.

        try:
            res, _ = self.h.dispatch("chat", {"since": self.chat_since, "limit": 30, "peek": True}, **self.reader())
            obs["chat"] = res.get("messages", [])
            if obs["chat"]:
                self.chat_since = obs["chat"][-1]["seq"]
        except Exception as e:
            errors["chat"] = str(e)
        self.observe_board(obs, errors)
        obs["errors"] = errors
        return obs

    # ---- Space Age platforms ------------------------------------------------------------------------------------
    def observe_platforms(self, space, errors):
        """Platform detail (state, location or route, speed, schedule) with a peek `platforms` read per platform,
        every platform_every seconds, at most 4 platforms; between reads the score's name and location stand."""
        now = time.time()
        if now >= self.next_platforms:
            self.next_platforms = now + self.platform_every
            detail = {}
            for row in space["platforms"][:4]:
                try:
                    res, _ = self.read("platforms", {"platform": row["name"]}, **self.reader())
                    for p in res.get("platforms") or []:
                        detail[p.get("name")] = {k: p.get(k) for k in ("state", "at", "speed", "schedule", "paused",
                                                                       "thrusters", "weight") if p.get(k) is not None}
                except Exception as e:
                    errors["platforms"] = str(e)
            self.platform_detail = detail
        space["platforms"] = [dict(row, **self.platform_detail.get(row["name"], {})) for row in space["platforms"]]

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
        except Exception as e:
            self.has_board = False
            print(f"[live] board probe failed: {e}", flush=True)
            return
        if self.has_board:
            print("[live] runtime has the team board; polling board_events", flush=True)

    def observe_board(self, obs, errors):
        if self.caps is None or not self.caps.get("harness"):
            return
        if not self.has_board:
            if time.time() >= self.next_board_probe:
                self.board_probe()
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
            try:
                res, _ = self.read("board", {"limit": 60}, **self.reader())
                claims, _ = self.read("board", {"kind": "claim", "limit": 30}, **self.reader())
                items = {it.get("id"): it for it in (res.get("items") or []) + (claims.get("items") or [])}
                obs["board"] = {"items": list(items.values()), "open_unowned": res.get("open_unowned")}
            except Exception as e:
                errors["board"] = str(e)

    @staticmethod
    def loss_events(alerts):
        """status.alerts.latest: describe_incident() lines, e.g. "in (12,-40)-(20,-31) 7 destroyed: 4 stone-wall,
        3 gun-turret by 5 small-biter, 1m10s-0s ago" -> loss banners (one per area)."""
        out = []
        for line in (alerts.get("latest") or [])[:3]:
            m = LOSS_RE.match(line or "")
            if not m:
                continue
            x, y, total, names, by, ago = m.group(1), m.group(2), int(m.group(3)), m.group(4), m.group(5), m.group(6)
            if not RECENT_AGO.match(ago):
                continue  # the alert window is 5 game minutes; only show losses from the last minute or so
            what = ", ".join(n.strip().replace("-", " ") for n in names.split(",")[:2])
            text = f"{total} lost near ({x}, {y}): {what}" + (f" (by {attacker_label(by)})" if by else "")
            out.append({"kind": "loss", "text": text, "key": f"loss:{x},{y}", "ttl": 90,
                        "position": {"x": float(x), "y": float(y)}})
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
            near = f"near ({round(c.get('x', 0))}, {round(c.get('y', 0))})"
            text = f"Engineer under attack {near}" if what == "an engineer" else \
                f"Base under attack {near}" + (f": {what}" if what else "")
            out.append({"kind": "attack", "text": text, "key": f"area:{c.get('x')},{c.get('y')}", "ttl": 60,
                        "position": c})
        return out

    def send_camera(self, body):
        return self.h.camera(body)
