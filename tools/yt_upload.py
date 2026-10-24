#!/usr/bin/env python3
"""Upload a shift's video to YouTube (docs/VIDEOS.md): YouTube Data API v3, standard library only.

  python3 tools/yt_upload.py RUN --file shift02.mp4 --dry-run   # prints every request it would send; no auth, no network
  python3 tools/yt_upload.py auth                               # once: browser sign-in, stores the token
  python3 tools/yt_upload.py RUN --file shift02.mp4 [--privacy public|unlisted|private] [--playlist TITLE] [--max-mbps N]

RUN's video folder (runs/RUN/video/, from tools/shift_video.py) gives the title, description, tags and thumbnail.
Steps: videos.insert as a resumable upload (64 MiB chunks; an interrupted upload resumes from runs/RUN/video/upload.json
on the next run), thumbnails.set, the playlist (found by title among the channel's playlists, created if missing) and
playlistItems.insert. Then site/content/videos.json gets the shift's video id, title, description and chapters, for the
site's /runs/long/ (commit it and run tools/site-refresh.sh).

Auth: an OAuth client of type "Desktop app" from the Google Cloud console, saved as ~/.config/pog/youtube-client.json.
`auth` runs the installed-app flow (loopback redirect, PKCE) for the scopes youtube.upload and youtube, and keeps the
refresh token in ~/.config/pog/youtube-token.json (mode 600). Tokens are never printed or written anywhere else.

Quota (developers.google.com/youtube/v3/determine_quota_cost, 2026-10-08): videos.insert is 1 call of 100 a day in the
Video Uploads bucket; thumbnails.set 50, playlists.list 1, playlists.insert 50, playlistItems.insert 50 units of the
default 10,000 a day.
"""
import argparse
import base64
import datetime
import hashlib
import http.server
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CONF = Path(os.environ.get("POG_YT_CONF", Path.home() / ".config" / "pog"))
CLIENT = CONF / "youtube-client.json"
TOKEN = CONF / "youtube-token.json"
SCOPES = ["https://www.googleapis.com/auth/youtube.upload", "https://www.googleapis.com/auth/youtube"]
AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"
API = "https://www.googleapis.com/youtube/v3"
UPLOAD = "https://www.googleapis.com/upload/youtube/v3"
CHUNK = 64 * 1024 * 1024  # a multiple of 256 KiB, as resumable uploads require
PLAYLIST = "Factorio AI Party"
PLAYLIST_ABOUT = ("Every shift of the Factorio AI Party: nine AI agents from five labs build one Factorio: Space Age "
                  "factory together, live, by the same rules as a human player. https://factorio.nickwinter.net")
QUOTA = {"videos.insert": "1 of 100 uploads a day", "thumbnails.set": 50, "playlists.list": 1, "playlists.insert": 50,
         "playlistItems.insert": 50}


# ---------------------------------------------------------------- auth

def client():
    try:
        c = json.loads(CLIENT.read_text())
    except (OSError, ValueError):
        raise SystemExit(f"no OAuth client: save a Desktop-app client's JSON from the Google Cloud console as {CLIENT}")
    c = c.get("installed") or c.get("web") or c
    return c["client_id"], c["client_secret"]


def post_form(url, fields):
    req = urllib.request.Request(url, urllib.parse.urlencode(fields).encode(), method="POST",
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        raise SystemExit(f"{url}: HTTP {e.code} {json.loads(body).get('error', '') if body.startswith('{') else ''}")


def save_token(tok):
    CONF.mkdir(parents=True, exist_ok=True)
    fd = os.open(TOKEN, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(tok, f)
    os.chmod(TOKEN, 0o600)


def auth():
    """The installed-app flow: a one-shot server on 127.0.0.1 takes Google's redirect with the code."""
    cid, secret = client()
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    got = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            got.update({k: v[0] for k, v in q.items()})
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"Signed in. You can close this tab and go back to the terminal.")

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    redirect = f"http://127.0.0.1:{srv.server_address[1]}/"
    url = AUTH_URL + "?" + urllib.parse.urlencode({
        "client_id": cid, "redirect_uri": redirect, "response_type": "code", "scope": " ".join(SCOPES),
        "access_type": "offline", "prompt": "consent", "state": state,
        "code_challenge": challenge, "code_challenge_method": "S256"})
    print("Open this in a browser signed in to the channel's Google account:\n" + url, flush=True)
    srv.timeout = 300
    while "code" not in got and "error" not in got:
        srv.handle_request()
        if not got:
            raise SystemExit("no sign-in within 5 minutes")
    if got.get("state") != state or "code" not in got:
        raise SystemExit(f"sign-in failed: {got.get('error', 'state mismatch')}")
    tok = post_form(TOKEN_URL, {"code": got["code"], "client_id": cid, "client_secret": secret,
                                "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier})
    if not tok.get("refresh_token"):
        raise SystemExit("Google sent no refresh token (revoke the app's access and run auth again)")
    save_token({"refresh_token": tok["refresh_token"], "access_token": tok["access_token"],
                "expires": time.time() + tok.get("expires_in", 3600) - 60, "scope": tok.get("scope", "")})
    print(f"token saved in {TOKEN} (scopes: {tok.get('scope', '')})")


def access_token():
    try:
        tok = json.loads(TOKEN.read_text())
    except (OSError, ValueError):
        raise SystemExit(f"not signed in: python3 tools/yt_upload.py auth (writes {TOKEN})")
    if tok.get("expires", 0) > time.time():
        return tok["access_token"]
    cid, secret = client()
    new = post_form(TOKEN_URL, {"refresh_token": tok["refresh_token"], "client_id": cid, "client_secret": secret,
                                "grant_type": "refresh_token"})
    tok.update(access_token=new["access_token"], expires=time.time() + new.get("expires_in", 3600) - 60)
    save_token(tok)
    return tok["access_token"]


# ---------------------------------------------------------------- API

class Api:
    """Every request goes through call(); with dry=True it prints instead (Authorization never shown)."""

    def __init__(self, dry):
        self.dry = dry
        self.sent = []

    def call(self, method, url, body=None, headers=None, raw=None, quota=None, want_headers=False):
        headers = dict(headers or {})
        self.sent.append((method, url.split("?")[0], quota))
        if self.dry:
            print(f"\n{method} {url}")
            for k, v in headers.items():
                print(f"  {k}: {v}")
            print("  Authorization: Bearer (token from " + str(TOKEN) + ")")
            if body is not None:
                print("  " + json.dumps(body, indent=1, ensure_ascii=False).replace("\n", "\n  "))
            if raw is not None:
                print(f"  ({raw} bytes)" if isinstance(raw, int) else f"  ({len(raw)} bytes)")
            if quota:
                print(f"  quota: {quota}")
            return ({}, {}) if want_headers else {}
        headers["Authorization"] = "Bearer " + access_token()
        data = raw
        if body is not None:
            data = json.dumps(body).encode()
            headers.setdefault("Content-Type", "application/json; charset=UTF-8")
        for attempt in range(6):
            req = urllib.request.Request(url, data, headers=headers, method=method)
            try:
                with urllib.request.urlopen(req, timeout=120) as r:
                    text = r.read().decode() or "{}"
                    out = json.loads(text)
                    return (out, dict(r.headers)) if want_headers else out
            except urllib.error.HTTPError as e:
                text = e.read().decode(errors="replace")
                if e.code in (500, 502, 503, 504) and attempt < 5:
                    time.sleep(2 ** attempt)
                    continue
                raise SystemExit(f"{method} {url.split('?')[0]}: HTTP {e.code} {text[:400]}")
            except (urllib.error.URLError, TimeoutError) as e:
                if attempt < 5:
                    time.sleep(2 ** attempt)
                    continue
                raise SystemExit(f"{method} {url.split('?')[0]}: {e}")


def video_type(path):
    """The upload's media type by the file's suffix (d24: the shift files go up as OBS recorded them, .mkv)."""
    return {".mp4": "video/mp4", ".mkv": "video/x-matroska", ".mov": "video/quicktime",
            ".webm": "video/webm"}.get(path.suffix.lower(), "application/octet-stream")


def upload_video(api, path, meta, state, state_file, max_mbps=None):
    """videos.insert, resumable: start a session (or reuse the one in state_file), then PUT CHUNK-sized pieces; a
    308 says how much arrived, a 5xx or a dropped connection asks the session where to go on. max_mbps: 8 MiB pieces
    and a pause after each, so the average stays under it (room for a live stream on the same uplink)."""
    chunk = 8 * 1024 * 1024 if max_mbps else CHUNK
    size = path.stat().st_size if path.exists() else int(state.get("size_estimate", 0))
    url = f"{UPLOAD}/videos?uploadType=resumable&part=snippet,status"
    kind = video_type(path)
    head = {"X-Upload-Content-Length": str(size), "X-Upload-Content-Type": kind}
    if api.dry:
        api.call("POST", url, body=meta, headers=head, quota=QUOTA["videos.insert"])
        chunks = max(1, -(-size // chunk))
        rate = f", at most {max_mbps} Mbit/s: about {size * 8 / max_mbps / 1e6 / 60:.0f} min" if max_mbps else ""
        print(f"\nPUT (the session URL from the reply's Location header)\n  Content-Type: {kind}\n"
              f"  {chunks} chunk(s) of up to {chunk // 2**20} MiB, Content-Range: bytes A-B/{size}"
              f"\n  ({size / 1e9:.2f} GB{'' if path.exists() else ', estimated: no file yet'}{rate})")
        return "VIDEO_ID"
    session = state.get("session") if state.get("size") == size and state.get("file") == str(path) else None
    if not session:
        _, h = api.call("POST", url, body=meta, headers=head, quota=QUOTA["videos.insert"], want_headers=True)
        session = h.get("Location") or h.get("location")
        state.update(session=session, size=size, file=str(path), started=datetime.datetime.now().isoformat())
        write_state(state_file, state)
    done = probe(session, size)
    with open(path, "rb") as f:
        while True:
            if done >= size:
                break
            f.seek(done)
            piece = f.read(chunk)
            began = time.time()
            req = urllib.request.Request(session, piece, method="PUT", headers={
                "Authorization": "Bearer " + access_token(), "Content-Type": kind,
                "Content-Range": f"bytes {done}-{done + len(piece) - 1}/{size}"})
            try:
                with urllib.request.urlopen(req, timeout=600) as r:
                    video = json.load(r)
                    state.update(video_id=video["id"], session=None)
                    write_state(state_file, state)
                    return video["id"]
            except urllib.error.HTTPError as e:
                if e.code == 308:
                    rng = e.headers.get("Range")
                    done = int(rng.split("-")[1]) + 1 if rng else 0
                    print(f"  {done / size:6.1%} of {size / 1e9:.2f} GB", flush=True)
                    if max_mbps:
                        time.sleep(max(0.0, len(piece) * 8 / (max_mbps * 1e6) - (time.time() - began)))
                    continue
                if e.code in (500, 502, 503, 504):
                    time.sleep(5)
                    done = probe(session, size)
                    continue
                raise SystemExit(f"upload: HTTP {e.code} {e.read()[:300]!r} (run again to resume)")
            except (urllib.error.URLError, TimeoutError, ConnectionError):
                time.sleep(10)
                done = probe(session, size)
    return probe_done(session, size)


def probe(session, size):
    """How many bytes the session has: PUT with an empty body and Content-Range bytes */SIZE."""
    req = urllib.request.Request(session, b"", method="PUT", headers={
        "Authorization": "Bearer " + access_token(), "Content-Range": f"bytes */{size}"})
    try:
        with urllib.request.urlopen(req, timeout=60):
            return size
    except urllib.error.HTTPError as e:
        if e.code == 308:
            rng = e.headers.get("Range")
            return int(rng.split("-")[1]) + 1 if rng else 0
        if e.code == 404:
            raise SystemExit("the upload session expired (a week at most): delete upload.json's session and run again")
        raise SystemExit(f"upload status: HTTP {e.code}")


def probe_done(session, size):
    req = urllib.request.Request(session, b"", method="PUT", headers={
        "Authorization": "Bearer " + access_token(), "Content-Range": f"bytes */{size}"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)["id"]


def write_state(path, state):
    """upload.json: the session URL lets anyone with it finish this upload, so it stays private (mode 600)."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(state, f, indent=1)


def thumbnail(api, vid, thumb):
    data = thumb.read_bytes()
    kind = "image/png"
    if len(data) > 2_000_000:  # thumbnails.set takes 2 MB at most
        from io import BytesIO
        from PIL import Image
        buf = BytesIO()
        Image.open(thumb).convert("RGB").save(buf, "JPEG", quality=88)
        data, kind = buf.getvalue(), "image/jpeg"
    api.call("POST", f"{UPLOAD}/thumbnails/set?videoId={vid}", headers={"Content-Type": kind},
             raw=data if not api.dry else len(data), quota=QUOTA["thumbnails.set"])


def playlist_id(api, title):
    page = ""
    while True:
        r = api.call("GET", f"{API}/playlists?part=snippet&mine=true&maxResults=50{page}", quota=QUOTA["playlists.list"])
        for p in r.get("items", []):
            if p["snippet"]["title"] == title:
                return p["id"]
        if not r.get("nextPageToken"):
            break
        page = "&pageToken=" + r["nextPageToken"]
    if api.dry:
        print(f"  (if no playlist is titled {title!r}:)")
    r = api.call("POST", f"{API}/playlists?part=snippet,status",
                 body={"snippet": {"title": title, "description": PLAYLIST_ABOUT}, "status": {"privacyStatus": "public"}},
                 quota=QUOTA["playlists.insert"])
    return r.get("id", "PLAYLIST_ID")


def timeline(segments):
    """video.json's recording segments as [[wall start, wall end]] (ISO, in video order): the site maps a moment of
    the shift to seconds into the video with them (tools/shift_video.py offset())."""
    out = []
    for s in segments:
        try:
            t0 = datetime.datetime.fromisoformat(s["file_start"])
            out.append([(t0 + datetime.timedelta(seconds=s["in"])).isoformat(timespec="seconds"),
                        (t0 + datetime.timedelta(seconds=s["out"])).isoformat(timespec="seconds")])
        except (KeyError, TypeError, ValueError):
            return []
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run", help="a shift folder name, or `auth`")
    ap.add_argument("--file", help="the re-encoded video (the box's C:\\pog\\videos\\RUN.mp4, copied here)")
    ap.add_argument("--runs-dir", default=os.environ.get("POG_SITE_RUNS") or str(
        REPO / "runs" if (REPO / "runs").is_dir() else Path.home() / "code" / "player-of-games" / "runs"))
    ap.add_argument("--video-dir", help="default runs/RUN/video")
    ap.add_argument("--privacy", default="public", choices=["public", "unlisted", "private"])
    ap.add_argument("--playlist", default=PLAYLIST)
    ap.add_argument("--no-playlist", action="store_true",
                    help="add the video to no playlist (a private test: the playlist is created public when missing)")
    ap.add_argument("--videos-json", default=str(REPO / "site" / "content" / "videos.json"))
    ap.add_argument("--no-thumb", action="store_true")
    ap.add_argument("--max-mbps", type=float, help="cap the upload's average rate (during a live stream)")
    ap.add_argument("--force", action="store_true", help="upload a shift still on, or one whose recording was estimated")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    if a.run == "auth":
        return auth()
    vdir = Path(a.video_dir) if a.video_dir else Path(a.runs_dir) / a.run / "video"
    try:
        v = json.loads((vdir / "video.json").read_text())
    except (OSError, ValueError):
        raise SystemExit(f"no {vdir}/video.json: python3 tools/shift_video.py {a.run} --recordings LIST first")
    if (v.get("running") or v.get("estimated")) and not (a.force or a.dry_run):
        raise SystemExit(f"{a.run}: video.json was made " + ("while the shift was on" if v.get("running") else
                         "without the box's recording list") + ": run shift_video.py again (or --force)")
    path = Path(a.file) if a.file else Path("(no --file)")
    if not a.dry_run and not path.exists():
        raise SystemExit(f"no video file {path}")
    meta = {"snippet": {"title": v["title"], "description": v["description"], "tags": v["tags"],
                        "categoryId": v.get("category_id", "20"), "defaultLanguage": "en",
                        "defaultAudioLanguage": "en"},
            "status": {"privacyStatus": a.privacy, "selfDeclaredMadeForKids": False, "embeddable": True,
                       "license": "youtube"}}
    state_file = vdir / "upload.json"
    try:
        state = json.loads(state_file.read_text())
    except (OSError, ValueError):
        state = {}
    state.setdefault("size_estimate", int(v.get("size_gb", 0) * 1e9))
    api = Api(a.dry_run)
    if a.dry_run:
        print(f"DRY RUN for {a.run}: nothing is sent, no sign-in needed.\ntitle: {v['title']}")
    vid = state.get("video_id") if not a.dry_run else None
    if vid:
        print(f"already uploaded as {vid} (upload.json); going on with the thumbnail and playlist")
    else:
        vid = upload_video(api, path, meta, state, state_file, a.max_mbps)
    thumb = Path(v["thumbnail"]) if v.get("thumbnail") else vdir / "thumb.png"
    if not a.no_thumb and thumb.exists() and not state.get("thumbnail_set"):
        thumbnail(api, vid, thumb)
        state["thumbnail_set"] = not a.dry_run
    if not a.no_playlist and not state.get("playlist_item"):
        pid = playlist_id(api, a.playlist)
        r = api.call("POST", f"{API}/playlistItems?part=snippet",
                     body={"snippet": {"playlistId": pid, "resourceId": {"kind": "youtube#video", "videoId": vid}}},
                     quota=QUOTA["playlistItems.insert"])
        state.update(playlist_id=pid, playlist_item=r.get("id") if not a.dry_run else None)
    units = sum(q for _, _, q in api.sent if isinstance(q, int))
    if a.dry_run:
        print(f"\nquota: 1 upload of the 100 a day, and {units} of the 10,000 daily units "
              f"({units - QUOTA['playlists.insert']} when the playlist exists)")
        print(f"then: {a.videos_json} gets {a.run}: {{id, title, description, chapters, playlist}} for the site")
        return
    write_state(state_file, state)
    site = json.loads(Path(a.videos_json).read_text()) if Path(a.videos_json).exists() else {}
    site[a.run] = {"id": vid, "shift": v["shift"], "title": v["title"], "description": v["description"],
                   "chapters": v["chapters"], "playlist": state.get("playlist_id"),
                   "uploaded": datetime.date.today().isoformat(),
                   # the wall-clock span of each recording in the joined video, so the site can link any moment
                   "timeline": timeline(v.get("segments") or [])}
    Path(a.videos_json).write_text(json.dumps(site, indent=1, ensure_ascii=False) + "\n")
    print(f"https://www.youtube.com/watch?v={vid} ({a.privacy}); playlist {state.get('playlist_id')}; "
          f"{a.videos_json} updated: commit it and run tools/site-refresh.sh")


if __name__ == "__main__":
    main()
