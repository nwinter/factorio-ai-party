"""Resolve an agent's journal attention to its work surface, never its parked character."""
import attention

FRESH_S = 120


def focus(agent, platforms):
    """None means local/stale; an unresolved remote platform still counts as remote (wait for its view)."""
    a = agent or {}
    att = a.get("attention") or {}
    if att.get("age_s", 0) > FRESH_S or not att:
        return None
    name = att.get("platform")
    surface = att.get("surface")
    if not name and surface:
        name = next((n for n, p in platforms.items() if surface in (n, (p.get("view") or {}).get("surface"))), None)
    if name:
        if a.get("platform") == name:
            return None
        surface = ((platforms.get(name) or {}).get("view") or {}).get("surface")
    elif not surface or surface == (a.get("surface") or "nauvis"):
        return None
    return dict(att, platform=name, surface=surface)


def shot(d, agent, now):
    """(has remote focus, ready shot or None). Keep subject ownership for scoring, speech and operator follow."""
    att = focus(agent, d.plat_rows)
    if not att:
        return False, None
    if not att.get("surface") or (not att.get("platform") and not att.get("position")):
        return True, None
    name, who = agent["name"], agent.get("display_name") or agent["name"]
    att["text"] = att.get("text") or attention.text(att)
    target = d.attention_target(att, name, who, now + FRESH_S)
    target.update(subject=name, remote_work=True, solo_zoom=target["zoom"])
    # The resolved destination is fixed while pan_step moves the acknowledged camera position.
    target["remote_position"] = dict(target["position"])
    if target.get("pan"):
        target["position"] = dict(target["position"], y=target["pan"]["y0"])
        # Remote work can outlive this attention sample, or enter during an older story/hold.
        # Give its pan its own clock and a fixed leg, independent of since/until being retained.
        target["pan_since"] = now
        target["pan"] = dict(target["pan"], speed=d.pan_speed(dict(target, since=now)),
                             bow_s=target["pan"].get("bow_s", d.PAN_END_S))
    if att.get("platform"):
        target["platform"] = dict(name=att["platform"], why="remote", agent=name, label=target["work"])
    return True, target


def same(a, b):
    """Same requested work destination, not the pan's current view or a changing caption."""
    return all(a.get(k) == b.get(k) for k in ("remote_work", "surface", "zoom")) and \
        a.get("remote_position", a.get("position")) == b.get("remote_position", b.get("position")) and \
        (a.get("platform") or {}).get("name") == (b.get("platform") or {}).get("name")
