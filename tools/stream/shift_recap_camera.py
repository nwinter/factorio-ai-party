"""Recap camera cues from existing snapshots only; the normal director owns movement.

No OBS, RCON or file writes. Operator holds and urgent shots keep their usual priority.
Never advertise a requested subject as on air before the compositor acknowledges it.
"""
from model import platform_shot


def cue(recap, snapshot, now, frac=1.0):
    if not recap or not recap.get("active") or recap.get("holding"):
        return None
    subject = recap.get("subject") or {}
    name = str(subject.get("name") or "").casefold()
    if not name:
        return None
    target = None
    if subject.get("type") == "platform":
        row = next((p for p in (snapshot.get("space") or {}).get("platforms", [])
                    if str(p.get("name", "")).casefold() == name and (p.get("view") or {}).get("surface")), None)
        if row:
            target = platform_shot(row["view"], frac=frac, overview=True)
    else:
        agents = [a for a in snapshot.get("agents", []) if not a.get("dead") and a.get("position")
                  and str(a.get("surface") or a["position"].get("surface", "")).casefold() == name]
        if agents:
            target = {"follow": agents[0]["name"], "zoom": .65}
        else:
            # A remembered on-air frame is a safe existing location, even without agents.
            frame = next((f for f in (snapshot.get("cameras") or {}).values()
                          if str(f.get("surface", "")).casefold() == name and f.get("position")), None)
            if frame:
                target = {"position": frame["position"], "surface": frame["surface"], "zoom": frame.get("zoom", .65)}
    if not target:
        return None
    return dict(target, id=f"shift-recap:{recap.get('run')}:{recap.get('phase')}:{recap.get('id')}",
                label="Shift recap · " + subject["name"], until=now + 120)


def on_air(recap, snapshot):
    if not recap:
        return recap
    cuts = snapshot.get("cuts") or {}
    program = cuts.get("on_air") or {}
    frames = program.get("frames") or {}
    frame = frames.get("main") or {}
    camera = (program.get("cameras") or {}).get(frame.get("client", "main")) or {}
    # Only committed, non-pending compositor state can name the visible subject.
    visible = cuts.get("connected") and not cuts.get("error") and not camera.get("pending") and not program.get("host")
    name = ((frame.get("platform") or frame.get("ship") or {}).get("name") or frame.get("surface")) if visible else None
    if name and name.startswith("platform-"):
        name = None
    return dict(recap, live={"subject": name})
