"""Live observations from a pog world, read-only.

With the eng/bots runtime (detected by the `camera` remote function) it polls `profiles` plus per-agent `status`.
Before that lands it falls back to `status` for the player indices in the run config, so the page works against
today's worlds (e.g. the paused co-op save in world c).
"""
import time

from harness import Harness
from model import SPARK_ITEMS


class LiveSource:
    def __init__(self, world, run, profiles="auto", flow_every=30.0, harness=None):
        self.name = f"live:{world}"
        self.h = harness or Harness(world)
        self.run = run
        self.agents_cfg = run.get("agents") or {}
        self.flow_every = flow_every
        self.next_flow = 0
        self.chat_since = 0
        self.chat_backlog = []
        self.caps = self.h.probe()
        self.use_profiles = profiles == "on" or (profiles == "auto" and self.caps.get("camera"))
        print(f"[live] world {world}: {self.caps}; profiles {'on' if self.use_profiles else 'off (status per player)'}",
              flush=True)

    def reader(self):
        """Who to read as: a configured bot, else the first configured player index."""
        for name, cfg in self.agents_cfg.items():
            if cfg.get("kind", "bot") == "bot" and "player" not in cfg:
                return {"bot": name}
        for cfg in self.agents_cfg.values():
            if cfg.get("player"):
                return {"player": cfg["player"]}
        return {"player": 1}

    def agent_status(self, name, cfg):
        if cfg.get("player"):
            return self.h.dispatch("status", player=cfg["player"])[0]
        return self.h.dispatch("status", bot=name)[0]

    def observe(self):
        errors = {}
        obs = {"agents": [], "chat": []}
        try:
            score = self.h.score()
            obs["tick"], obs["paused"] = score["tick"], score.get("paused")
            obs["produced"] = score.get("produced") or {}
            done = score.get("research_done") or []
            obs["research"] = {"current": score.get("current_research"), "done": done if isinstance(done, list) else []}
        except Exception as e:
            errors["score"] = str(e)
        try:
            ex = self.h.extras()
            if "research" in obs:
                obs["research"].update(progress=ex.get("progress"), top_done=ex.get("top_done") or [])
            obs["power"] = {"machines": ex.get("electric_machines"), "starved": ex.get("starved")}
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
                for p in res.get("profiles", res if isinstance(res, list) else []):
                    profiles[p["name"]] = p
            except Exception as e:
                errors["profiles"] = str(e)
        names = list(self.agents_cfg) or list(profiles)
        for name in names:
            cfg = self.agents_cfg.get(name, {})
            p = profiles.get(name, {})
            a = {"name": name, "kind": p.get("kind") or cfg.get("kind", "bot")}
            for key in ("display_name", "color", "glyph", "motto", "position", "last_said"):
                if p.get(key) is not None:
                    a[key] = p[key]
            if "alive" in p:
                a["alive"] = p["alive"]
            if "active" in p:
                a["active"] = p["active"]
            try:
                st = self.agent_status(name, cfg)
                a.setdefault("position", st.get("position"))
                act = st.get("active")  # status: {kind, until_tick, ...} or false
                a.setdefault("active", act.get("kind") if isinstance(act, dict) else (act or False))
                a["alive"] = st.get("alive", a.get("alive", True))
                a["connected"] = st.get("connected", True) if a["kind"] == "player" else True
                a["last"] = st.get("last")
                a["combat"] = bool(st.get("combat"))
                a["dead_until_tick"] = st.get("dead_until_tick")
            except Exception as e:
                errors[f"status:{name}"] = str(e)
            obs["agents"].append(a)
        for name, p in profiles.items():
            if name not in self.agents_cfg:
                obs["agents"].append({k: p.get(k) for k in ("name", "kind", "display_name", "color", "glyph", "motto",
                                                             "position", "alive", "active", "last_said")})

        try:
            res, _ = self.h.dispatch("chat", {"since": self.chat_since, "limit": 30, "peek": True}, **self.reader())
            obs["chat"] = res.get("messages", [])
            if obs["chat"]:
                self.chat_since = obs["chat"][-1]["seq"]
        except Exception as e:
            errors["chat"] = str(e)
        obs["errors"] = errors
        return obs

    def send_camera(self, body):
        return self.h.camera(body)
