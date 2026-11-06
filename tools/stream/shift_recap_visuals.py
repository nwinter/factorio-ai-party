"""Bind prepared beats to recorded media. No capture, network or game client."""
import datetime as dt
import math
import re

import shift_recap_detail as detail

PLANETS = ("nauvis", "vulcanus", "fulgora", "gleba", "aquilo")
ASSET = re.compile(r"[a-f0-9]{24}\.(?:webp|png|jpg|jpeg|mp4|webm)\Z")
MAX_CLIP_BYTES = 16 * 1024 * 1024
VERSION = 4


def clock(t):
    return dt.datetime.fromtimestamp(t).astimezone().strftime("%H:%M %Z")


def label(value):
    text = " ".join(str(value or "").split())[:80]
    if re.search(r"[/\\\\@]|(?:api[_ -]?key|password|token)\s*[=:]", text, re.I):
        return ""
    return text


def media_record(row):
    """Accept cp3's saved stills too; its caption contains the original surface metadata."""
    if not ASSET.fullmatch(str(row.get("asset", ""))) or not isinstance(row.get("t"), (int, float)) or not math.isfinite(row["t"]):
        return None
    subject = label(row.get("platform") or row.get("subject") or row.get("surface"))
    if not subject:
        legacy = re.match(r"^Recorded still: ([^·]+) ·", row.get("caption", ""))
        subject = label(legacy[1]) if legacy else ""
    if not subject:
        return None
    kind = "video" if row["asset"].endswith((".mp4", ".webm")) else "image"
    offset = row.get("offset", 0)
    offset = max(0, offset) if isinstance(offset, (int, float)) and math.isfinite(offset) else 0
    return {"asset": row["asset"], "kind": kind, "subject": subject, "t": row["t"],
            "subject_type": "platform" if row.get("platform") or row.get("subject_type") == "platform" else "surface",
            "recorded_time": clock(row["t"]), "offset": offset,
            "duration": row.get("duration", 0), "view": detail.view(row)}


def mentioned(text, names):
    return {n for n in names if re.search(r"(?<![\w])" + re.escape(n) + r"(?![\w])", text, re.I)}


def bind(manifest):
    """Stable per-beat choices; an unlabelled or unrelated picture never fills a gap.

    Ship names take precedence over the planet a ship happens to be visiting. An explicit
    subject in the narration takes precedence over incidental subjects in cited background.
    Time chooses the nearest view of that subject, not proof that it pictures the exact event.
    """
    evidence = manifest.get("evidence") or {}
    rows = {r["id"]: r for r in evidence.get("rows", [])}
    start, end = evidence.get("start", 0), manifest.get("through", evidence.get("until", 0))
    media = [m for row in manifest.get("stills", []) if not row.get("error")
             and (m := media_record(row)) and start <= m["t"] <= manifest.get("media_through", end)]
    ships = {m["subject"] for m in media if m["subject_type"] == "platform"}
    ships.update(label(r.get("platform") or r.get("subject")) for r in manifest.get("media_errors", [])
                 if r.get("platform") or r.get("subject_type") == "platform")
    ships.discard("")
    for row in rows.values():
        if row.get("platform"):
            ships.add(label(row["platform"]))
        match = re.search(r"\bplatform (.+?) (?:left|arrived|was|is|created|renamed|lost|deleted)\b", row["text"], re.I)
        if match:
            ships.add(match[1].strip())
    surfaces = set(PLANETS) | {m["subject"] for m in media if m["subject_type"] == "surface"}
    surfaces.update(label(r["surface"]) for r in rows.values() if r.get("surface") and not r.get("platform"))
    surfaces.update(label(r["surface"]) for r in manifest.get("media_errors", []) if r.get("surface") and not r.get("platform"))
    visuals = {}
    for phase in ("transition", "recap"):
        for line in manifest.get("transition" if phase == "transition" else "lines", []):
            refs = [rows[r] for r in line.get("sources", []) if r in rows]
            times = sorted(r["t"] for r in refs if isinstance(r.get("t"), (int, float)))
            wanted = detail.target(line, refs)
            stamp = wanted['record_t'] if wanted and wanted.get('record_t') is not None else times[-1] if times else end
            time_label = ("Record · " + clock(stamp)) if times else ("Record through " + clock(end))
            text = line.get("title", "") + " " + line.get("text", "")
            context = " ".join(r["text"] for r in refs)
            targets = mentioned(line.get("title", ""), ships) or mentioned(text, ships)
            subject_type = "platform"
            if not targets:
                targets = mentioned(context, ships)
            if not targets:
                targets = {label(r["platform"]) for r in refs if r.get("platform")}
            if not targets:
                targets, subject_type = mentioned(text, surfaces), "surface"
            if not targets:
                targets, subject_type = mentioned(context, surfaces), "surface"
            if not targets:
                targets = {label(r["surface"]) for r in refs if r.get("surface") and not r.get("platform")}
                subject_type = "surface"
            # A planet mentioned as a ship's dock/route is not a picture of that ship.
            # When its identity is absent, prefer a neutral card to a generic factory view.
            if subject_type == "surface" and re.search(r"\b(?:hull|propulsion|aft|stern|flight|shakedown|refit|dock(?:ed)?|departure)\b", text, re.I):
                targets = set()
            if len({s.casefold() for s in targets}) > 1:
                targets = set()
            choices = [m for m in media if m["subject_type"] == subject_type
                       and m["subject"].casefold() in {s.casefold() for s in targets}]
            # Moving footage must cover the cited record time. A still remains useful in
            # the offline audit, but never substitutes for gameplay on air. Legacy clips
            # without an interval cannot establish that they show this moment.
            clips = [m for m in choices if m["kind"] == "video"
                     and isinstance(m["duration"], (int, float)) and math.isfinite(m["duration"])
                     and 0 < m["duration"] <= 20
                     and m["t"] <= stamp < m["t"] + m["duration"]]
            pictures = [m for m in choices if m["kind"] == "image"]
            pool = clips or pictures
            chosen = min(pool, key=lambda m: (abs(m["t"] - stamp), m["asset"])) if pool else None
            fallback = None
            if wanted:
                anchored = [(m, a) for m in pictures if (a := detail.anchor(m, wanted, stamp))]
                if anchored:
                    selected, a = min(anchored, key=lambda pair: (abs(pair[0]['t'] - stamp), pair[0]['asset']))
                    chosen = dict(selected, detail=a,
                                  recorded_time=dt.datetime.fromtimestamp(selected['t']).astimezone().strftime('%Y-%m-%d %H:%M:%S %Z'))
                else:
                    # A generic ship image is context, never evidence of the named detail.
                    chosen = min(pictures, key=lambda m: (abs(m['t'] - stamp), m['asset'])) if pictures else None
                    fallback = ('MAP' if chosen and (chosen.get('view') or {}).get('kind') == 'map' else 'OVERVIEW') + ' FALLBACK · target detail not recorded'
                    if chosen:
                        chosen = dict(chosen, fallback=fallback)
            failures = [r for r in manifest.get("media_errors", [])
                        if (label(r.get("platform") or r.get("subject") or r.get("surface"))).casefold()
                        in {s.casefold() for s in targets}]
            visuals[line["id"]] = {"media": chosen, "time_label": time_label, "asset_errors": failures,
                "fallback": fallback,
                "binding": {"target": wanted, "subjects": sorted(targets), "subject_type": subject_type, "record_t": stamp,
                            "evidence_ids": [r["id"] for r in refs],
                            "reason": "dated frame contains target position" if chosen and chosen.get("detail") else fallback or ("nearest recorded view of the subject" if chosen else "no matching recorded media")}}
    beats = [{"id": line["id"], "title": line.get("title", ""),
              "status": "bound" if visuals[line["id"]]["media"] else "missing",
              "target": visuals[line["id"]]["binding"].get("target"),
              "reason": visuals[line["id"]]["binding"]["reason"],
              "footage": "overview" if (visuals[line["id"]]["media"] or {}).get("fallback") else "detail" if (visuals[line["id"]]["media"] or {}).get("detail") else "clip" if (visuals[line["id"]]["media"] or {}).get("kind") == "video" else "live",
              "subjects": visuals[line["id"]]["binding"]["subjects"],
              "errors": visuals[line["id"]]["asset_errors"]}
             for line in manifest.get("transition", []) + manifest.get("lines", [])]
    bound = sum(b["status"] == "bound" for b in beats)
    review = {"bound": bound, "total": len(beats), "no_media": bound == 0,
              "overviews": sum(b["footage"] == "overview" for b in beats),
              "details": sum(b["footage"] == "detail" for b in beats),
              "clips": sum(b["footage"] == "clip" for b in beats),
              "live": sum(b["footage"] == "live" for b in beats),
              "beats": beats, "asset_errors": manifest.get("media_errors", [])}
    return dict(manifest, visual_version=VERSION, visuals=visuals, media_review=review)


def public(manifest, line, phase, *, asset_prefix="/shift-recap/assets/", holding=False, elapsed=0):
    visual = manifest.get("visuals", {}).get(line.get("id")) or {}
    media = visual.get("media")
    if media and media["kind"] != "video" and not (media.get("detail") or media.get("fallback")):
        media = None
    binding = visual.get("binding") or {}
    subjects = binding.get("subjects") or []
    return {"active": True, "phase": phase, "run": manifest["run"], "id": line.get("id"),
            "title": line.get("title", "Shift recap"), "speaker": line.get("speaker"),
            "text": line.get("text", ""), "time_label": visual.get("time_label", "Recorded shift"),
            "fallback": visual.get("fallback"),
            "holding": holding, "elapsed": max(0, elapsed),
            "subject": {"name": subjects[0], "type": binding.get("subject_type")} if len(subjects) == 1 else None,
            "media": dict(media, url=asset_prefix + media["asset"]) if media else None}
