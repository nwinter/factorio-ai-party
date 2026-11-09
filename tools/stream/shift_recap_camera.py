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
    target = None
    if name and subject.get("type") == "platform":
        row = next((p for p in (snapshot.get("space") or {}).get("platforms", [])
                    if str(p.get("name", "")).casefold() == name and (p.get("view") or {}).get("surface")), None)
        if row:
            target = platform_shot(row["view"], frac=frac, overview=True)
    elif name:
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
        # An unresolved subject still owns the current shot. Returning None used to
        # invite a quiet tour or ordinary story cut in the middle of its narration.
        target = {"hold_current": True, "zoom": .65}
    # Recap framing is fixed for a line; the ordinary tall-ship pan must not reset
    # or leave its subject while a delayed/reloaded narration is still playing.
    target.pop("pan", None)
    return dict(target, id=f"shift-recap:{recap.get('run')}:{recap.get('phase')}:{recap.get('id')}",
                label="Shift recap · " + (subject.get("name") or "current view"), until=now + 120,
                recap=True)


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
    surface = frame.get("surface") or (frame.get("frame") or {}).get("surface") or (camera.get("shot") or {}).get("surface")
    ship = next((p.get("name") for p in (snapshot.get("space") or {}).get("platforms", [])
                 if surface and (p.get("view") or {}).get("surface") == surface), None)
    name = ((frame.get("platform") or frame.get("ship") or {}).get("name") or ship or surface) if visible else None
    if name and name.startswith("platform-"):
        name = None
    return dict(recap, live={"subject": name})
