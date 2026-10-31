"""File-only media refresh and preparation diagnostics; never regenerates speech."""
import hashlib
import json
from pathlib import Path

import shift_recap_visuals as visuals


def header_error(data, suffix):
    """Cheap admission check. Capture verifies decoding; rehearsal checks browser loading too."""
    if not data:
        return "empty asset"
    signatures = {".png": data.startswith(b"\x89PNG\r\n\x1a\n"),
                  ".jpg": data.startswith(b"\xff\xd8") and data.endswith(b"\xff\xd9"),
                  ".jpeg": data.startswith(b"\xff\xd8") and data.endswith(b"\xff\xd9"),
                  ".webp": data.startswith(b"RIFF") and data[8:12] == b"WEBP"}
    return "invalid image bytes" if suffix in signatures and not signatures[suffix] else None


def signature(run, out):
    """Stat indexed sources and prepared images too: arrivals, replacements and deletions matter."""
    import shift_recap as recap
    run, out = Path(run), Path(out)
    paths = {run / "recap-media.json"}
    paths.update((run / "mapframes").glob("*"))
    catalog = recap.read_json(run / "recap-media.json", [])
    for row in catalog if isinstance(catalog, list) else []:
        if isinstance(row, dict) and isinstance(row.get("path"), str):
            path = (run / row["path"]).resolve()
            if path.is_relative_to(run.resolve()):
                paths.add(path)
    paths.update(p for p in (out / "assets").glob("*") if visuals.ASSET.fullmatch(p.name))
    records = []
    for path in sorted(paths):
        try:
            st = path.stat()
            records.append((str(path), st.st_size, st.st_mtime_ns))
        except OSError:
            records.append((str(path), None, None))
    return hashlib.sha256(json.dumps(records).encode()).hexdigest()


def checked(manifest, out):
    """Bad prepared assets remain diagnostic candidates, never on-air media."""
    errors, stills = list(manifest.get("media_errors", [])), []
    for row in manifest.get("stills", []):
        row = dict(row)
        row.pop("error", None)
        media = visuals.media_record(row)
        if not media:
            errors.append(dict(row, error="invalid prepared media metadata"))
            continue
        path = Path(out) / "assets" / media["asset"]
        try:
            data = path.read_bytes()
            error = header_error(data, path.suffix)
            if hashlib.sha256(data).hexdigest()[:24] != path.stem:
                error = "asset content hash mismatch"
            if error:
                raise ValueError(error)
        except (OSError, ValueError) as exc:
            row["error"] = str(exc)
            errors.append(dict(row, path="assets/" + media["asset"]))
        stills.append(row)
    return visuals.bind(dict(manifest, stills=stills, media_errors=errors))


def refresh(run, out, manifest, *, force=False, media_until=None):
    """Caller holds .prepare.lock. Publish only after all new assets are copied and checked."""
    import shift_recap as recap
    out = Path(out)
    if not force and manifest.get("media_signature") == signature(run, out):
        return manifest
    errors = []
    # Preserve imported legacy media; managed sources are reread, including removals.
    legacy = [r for r in manifest.get("stills", [])
              if not str(r.get("source", "")).startswith("recap-media.json:")]
    config = recap.read_json(Path(run) / "stream.json", {}) or {}
    media_through = max(manifest["through"], (config.get("shift") or {}).get("end") or manifest["through"])
    if media_until is not None:
        media_through = media_until
    fresh = recap.stills(run, media_through, out, errors)
    unique = {(r["asset"], r.get("t"), r.get("subject"), r.get("platform"), r.get("surface")): r
              for r in legacy + fresh}
    manifest = checked(dict(manifest, stills=sorted(unique.values(), key=lambda r: r["t"]),
                            media_through=media_through, media_errors=errors), out)
    manifest["media_signature"] = signature(run, out)
    recap.save_json(out / "manifest.json", manifest)
    recap.export(manifest, out)
    review = manifest["media_review"]
    summary = (f"[shift-recap] media {review['bound']}/{review['total']} beats; "
               f"{len(review['asset_errors'])} failed assets" + ("; WARNING: NO BOUND MEDIA" if review["no_media"] else ""))
    print(summary, flush=True)
    with (out / "prep.log").open("a") as log:
        log.write(summary + "\n")
        for beat in review["beats"]:
            if beat["status"] == "missing" or beat["errors"]:
                log.write(json.dumps(beat, ensure_ascii=False) + "\n")
    return manifest


def refresh_saved(run, out):
    import fcntl
    import shift_recap as recap
    out = Path(out)
    with (out / ".prepare.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        manifest = recap.read_json(out / "manifest.json")
        return refresh(run, out, manifest) if manifest else None
