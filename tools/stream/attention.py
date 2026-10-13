"""Where an agent is paying attention (operator task 2026-10-13, after Nick: "can we give a better feel in the stream
for what they are paying attention to?").

An agent's camera follows its character, but the agent looks and works through its requests: shifts 05-06 journals
had ~10% of the actions that name a map position target a spot more than 15 tiles from the character (Sol 28%,
Astra 20%, Luna 18%), mostly inspect, then transfer, configure, and remote place_ghosts / deconstruct; observe
(scan) and place_ghosts carry areas and lists. A platform action names its platform (the character stays on Nauvis).

point(action, args) reads one journal request (work.py tails runs/RUN/AGENT/journal.jsonl) into an attention point:
its kind (looking, building, configuring, moving items), a verb, what it handles, and where (centre, extent,
platform). model.py keeps each agent's latest with its age; onecam.py shows a far one in the inset beside the
character on air ("Sol · placing ghosts 40 m north"); the site's live map draws a line from the character to it.
"""
import math

# action -> (kind, verb). Requests without a position (observe with only a radius scans around the character, status,
# chat, crafting) are no attention point; move_to is where the character goes, and its camera goes along.
ACTIONS = {
    "observe": ("looking", "scanning"),
    "inspect": ("looking", "inspecting"),
    "placements": ("looking", "looking for room"),
    "place_ghosts": ("building", "placing ghosts"),
    "paste": ("building", "pasting a blueprint"),
    "blueprint_place": ("building", "pasting a blueprint"),
    "deconstruct": ("building", "marking for removal"),
    "cancel_deconstruction": ("building", "cancelling removal"),
    "build": ("building", "building"),
    "construct": ("building", "building"),
    "repair": ("building", "repairing"),
    "rotate": ("configuring", "rotating"),
    "configure": ("configuring", "configuring"),
    "requests": ("configuring", "setting requests"),
    "circuit": ("configuring", "wiring"),
    "platform_schedule": ("configuring", "scheduling"),
    "transfer": ("moving items", "moving"),
    "collect": ("moving items", "collecting"),
    "mine": ("moving items", "mining"),
    "rearm": ("moving items", "rearming"),
    "refuel": ("moving items", "refuelling"),
    "shoot": ("fighting", "shooting at"),
    "drop": ("moving items", "dropping cargo"),
    "launch": ("moving items", "launching a rocket"),
}
KINDS = ("looking", "building", "configuring", "moving items", "fighting")
FAR = 15.0  # tiles: attention this far from the character is "elsewhere" (the measured 10% above)


def _xy(p):
    if isinstance(p, dict) and isinstance(p.get("x"), (int, float)) and isinstance(p.get("y"), (int, float)):
        return float(p["x"]), float(p["y"])
    if isinstance(p, (list, tuple)) and len(p) == 2 and all(isinstance(v, (int, float)) for v in p):
        return float(p[0]), float(p[1])
    return None


def _spread(pts):
    """[(x, y)] -> (centre, extent: the bounding box's longer side)."""
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    c = {"x": round((min(xs) + max(xs)) / 2, 1), "y": round((min(ys) + max(ys)) / 2, 1)}
    return c, round(max(max(xs) - min(xs), max(ys) - min(ys)), 1)


def where(args):
    """A request's args -> (centre {x, y}, extent in tiles) or (None, 0): position, area, positions, or the positions in
    a list of entities, builds or tiles. A blueprint paste's position is its centre (extent unknown: 0)."""
    p = _xy(args.get("position"))
    if p:
        return {"x": p[0], "y": p[1]}, 0.0
    area = args.get("area")
    if isinstance(area, dict):
        lt, rb = _xy(area.get("left_top")), _xy(area.get("right_bottom"))
        if lt and rb:
            return _spread([lt, rb])
    for key in ("positions", "entities", "builds", "tiles", "placements"):
        rows = args.get(key)
        if isinstance(rows, dict):  # place_ghosts tiles: {name, area}
            return where(rows)
        if not isinstance(rows, list):
            continue
        pts = [_xy(r.get("position") if isinstance(r, dict) and "position" in r else r) for r in rows[:500]]
        pts = [q for q in pts if q]
        if pts:
            return _spread(pts)
    return None, 0.0


def human(name):
    return str(name).replace("-", " ").replace("_", " ") if name else ""


def point(action, args):
    """One request -> {kind, action, verb, what, position, extent, platform} or None (no position, not an attention
    action)."""
    if action not in ACTIONS or not isinstance(args, dict):
        return None
    pos, extent = where(args)
    plat = args.get("platform") if isinstance(args.get("platform"), str) else None
    if not pos and not plat:
        return None
    kind, verb = ACTIONS[action]
    what = ""
    if action == "transfer":
        verb = "taking" if args.get("direction") == "to_player" else "loading"
        what = human(args.get("item")) or "items"
    elif action == "collect":
        what = human(args.get("item"))
    elif action in ("rearm", "refuel") and isinstance(args.get("positions"), list) and args["positions"]:
        n = len(args["positions"])
        what = f"{n} turret{'s' if n != 1 else ''}" if action == "rearm" else f"{n} machine{'s' if n != 1 else ''}"
    elif action in ("inspect", "configure", "place_ghosts") and isinstance(args.get("name"), str):
        what = human(args["name"])
    elif action == "place_ghosts" and isinstance(args.get("entities"), list) and args["entities"]:
        names = {e.get("name") for e in args["entities"] if isinstance(e, dict) and e.get("name")}
        if len(names) == 1:
            what = human(names.pop())
    return {"kind": kind, "action": action, "verb": verb, "what": what, "position": pos, "extent": extent,
            "platform": plat}


COMPASS = ["east", "northeast", "north", "northwest", "west", "southwest", "south", "southeast"]


def bearing(frm, to):
    """Compass word from one map point to another (Factorio's y grows southward)."""
    ang = math.degrees(math.atan2(-(to["y"] - frm["y"]), to["x"] - frm["x"])) % 360
    return COMPASS[int((ang + 22.5) // 45) % 8]


def place(att, body, landmarks=()):
    """Where the attention is, for a label: "on Sunward", "at the smelter row" (a run landmark), "40 m north" (from the
    character), "nearby", or "at (120, -40)"."""
    if att.get("platform"):
        prep = {"launch": "to", "drop": "from"}.get(att.get("action"), "on")
        return f"{prep} {att['platform']}"
    p = att.get("position")
    if not p:
        return ""
    for lm in landmarks or ():
        if math.hypot(p["x"] - lm["x"], p["y"] - lm["y"]) <= lm.get("r", 30):
            return f"at {lm['name']}"
    if body and body.get("x") is not None:
        d = math.hypot(p["x"] - body["x"], p["y"] - body["y"])
        if d < FAR:
            return "nearby"
        return f"{int(round(d / 5) * 5)} m {bearing(body, p)}"
    return f"at ({round(p['x'])}, {round(p['y'])})"


def head(att):
    """What the agent does there, without where: "placing gun turret ghosts", "taking iron plate", "inspecting" (the
    camera highlight's label sits on the spot itself)."""
    if att.get("action") == "place_ghosts" and att.get("what"):
        return f"placing {att['what']} ghosts"
    return f"{att['verb']} {att['what']}".strip() if att.get("what") else att["verb"]


def text(att, body=None, landmarks=()):
    """"placing ghosts 40 m north", "taking iron plate at the smelter row", "configuring on Sunward"."""
    where_ = place(att, body, landmarks)
    return f"{head(att)} {where_}".strip()
