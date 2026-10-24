# Shift videos on YouTube

YouTube keeps no archive of a live stream longer than 12 hours, so each shift becomes its own video, with chapters
and a description built from the shift's logs. Each video goes into a "Factorio AI Party" playlist and is embedded on
the site's /runs/long/ page and on a page for that shift. Everything up to the upload is built and tested. The upload
needs Google permissions that have not been granted yet (see "Permissions" below).

## The pipeline, per shift (after it ends)

1. **Recording list.** `python3 tools/shift_video.py --list-cmd` prints the `ssh pogwin` command. It lists
   `D:\pog\recordings` and `C:\pog\recordings` (C: since 21:25 on Oct 12), with ffprobe durations if ffprobe is on the
   box. Save the output as `recordings.txt`. OBS names its files by the box's clock, which is PST all year (UTC-8): a
   file named `2026-10-12 17-36-32.mkv` started at 18:36:32 PDT. The tool converts the times and leaves out `Replay_`
   clips. A file that overlaps the shift by less than a minute belongs to the shift before or after it and is left
   out.
2. **Build.** `python3 tools/shift_video.py shiftNN --recordings recordings.txt` writes the following into
   `runs/shiftNN/video/`:
   - `video.json`: title, description, chapters, tags, segments, box commands
   - `description.txt`
   - `concat.txt` and `encode.cmd`
   - `thumb.png`, and `thumb.html` to re-render the thumbnail by hand

   Without `--recordings`, the tool assumes a single recording that starts when start-team's helpers came up, and
   marks `video.json` as `"estimated": true`. The uploader refuses a file built that way, or built while the shift
   was still on, unless you pass `--force`.
3. **Re-encode on the box** (the commands are in `encode.cmd`, nothing has been run):
   `scp runs/shiftNN/video/concat.txt pogwin:C:/pog/videos/shiftNN.txt`, the same for `encode.cmd` as
   `shiftNN.cmd`, then
   `ssh pogwin "schtasks /create /f /tn pog-encode-shiftNN /sc once /st 23:59 /tr C:\pog\videos\shiftNN.cmd && schtasks /run /tn pog-encode-shiftNN"`.
   A scheduled task keeps running after the SSH session ends; the batch file deletes the task when it finishes.
   - **The encode:** ffmpeg joins the shift's files (the concat demuxer, with in/out points when a file runs past the
     shift), then encodes HEVC on Quick Sync (`hevc_qsv`) at 2,000 kbit/s video plus 128 kbit/s AAC. That comes to
     0.96 GB an hour, or 3.8 GB for a 4-hour shift. It runs at `/low` priority and logs to `C:\pog\videos\shiftNN.log`.
   - **When to run it:** when no stream is live. The stream also encodes on Quick Sync (NVENC is unavailable: driver
     535.98).
   - **During a stream:** `encode.cmd` has a commented CPU line (`libx265 -preset fast`, two threads) as the
     alternative. It will be slower than real time.
   - **Resolution:** the source keeps its resolution. A 720p stream gives 720p; add
     `-vf scale=1920:1080:flags=lanczos` before `-c:v` if YouTube should get 1080p from it.
   - **Not checked yet:** whether ffmpeg is on the box (`encode.cmd` stops with a hint:
     `winget install Gyan.FFmpeg`), and how fast `hevc_qsv` runs there. This session could not reach the box over SSH.
4. **Thumbnail frame (optional).** `video.json`'s `box.frame` is an ffmpeg command that grabs a frame at the shift's
   biggest moment. Copy the frame back and run step 2 again with `--frame frame.jpg`. Without a frame, the thumbnail
   uses an agent's camera shot from `runs/shiftNN/*/shots/` (a rocket, platform or base shot first) or
   `site/og/bg.jpg`. The thumbnail is drawn with Playwright's headless shell, like `site/og_card.py`, with the
   agents' pixel portraits. Where the shell cannot start (as in Claude Code's sandbox), Pillow draws a plainer card
   with initials.
5. **Copy and upload from the Mac.** `scp pogwin:C:/pog/videos/shiftNN.mp4 ~/pog-videos/`, then
   `python3 tools/yt_upload.py shiftNN --file ~/pog-videos/shiftNN.mp4 --dry-run`, then the same without `--dry-run`.
   - **What it does:** a resumable `videos.insert` in 64 MiB chunks, then `thumbnails.set` (it converts the thumbnail
     to JPEG if it is over 2 MB), then finds or creates the playlist and adds the video with `playlistItems.insert`.
   - **Interrupted uploads:** running the same command again resumes from `runs/shiftNN/video/upload.json` (mode 600,
     since it holds the session URL).
   - **Afterwards:** commit `site/content/videos.json` and run `tools/site-refresh.sh`.

## Chapters and description

YouTube's rules are that the first chapter is at 0:00, there are at least three, and each is at least 10 s long. The
tool keeps chapters 90 s apart, picks at most 24, heaviest first, and fills in with hour marks if there are fewer
than three. Candidates, by weight:
- planets reached and platforms arriving or leaving
- the first rocket, then later rockets
- platforms built
- milestone technologies: the rocket silo and space science weigh most, early ones such as automation weigh least
- fights in which one loss alert reached 10 buildings, placed at that alert
- each agent's first death
- the hosts' spotlight, overview and production segments
- up to three viewer questions that an agent answered by name within three minutes

Research, rockets and platforms come from the score log, which is written every 2 minutes. Their chapters sit at the
middle of the interval in which they first appear. The description gives:
- the shift's research, rockets, platforms, science per minute, deaths and its biggest fight
- the three viewer Q&As
- the team, and the hosts
- the chapters
- links to the shift's page and to the site

The tool never uses the operator's chat lines, start.log text or journals. Chat starts at the shift's first score
tick, because chat.jsonl begins with the tail of the previous shift. Viewer names appear as they did on stream. The
operator's own chat name is left out.

## Permissions Nick must grant (once)

1. **Google Cloud project:** enable YouTube Data API v3 and configure the OAuth consent screen (External). Set the
   publishing status to "In production". In "Testing", Google expires refresh tokens after 7 days, so `auth` would
   be needed weekly. An unverified app in production shows a warning at sign-in, which is fine for one user.
2. **OAuth client:** type "Desktop app". Save its JSON as `~/.config/pog/youtube-client.json`.
3. **Sign in once:** run `python3 tools/yt_upload.py auth` and sign in in a browser with the account that owns the
   channel (for a Brand Account, pick the channel). It asks for the `youtube.upload` and `youtube` scopes and keeps
   the refresh token in `~/.config/pog/youtube-token.json` (mode 600). The tool never prints tokens.
4. **Verify the channel by phone** (YouTube Studio, Settings, Channel, Feature eligibility). YouTube requires this
   for videos longer than 15 minutes and for custom thumbnails.

The task note's figure of 1,600 units per upload is out of date. The current API docs (updated 2026-10-08) say:
- `videos.insert` counts against a separate Video Uploads bucket of 100 calls a day.
- Each shift also costs 101 of the default 10,000 units a day (151 the first time, when the playlist is created).
- Videos uploaded from unverified API projects are no longer restricted to private.

## Bandwidth

- **Size:** a 4-hour shift is about 3.8 GB at 0.96 GB an hour. The raw recordings are larger: the stream's bitrate
  of 6 to 12 Mbit/s comes to 2.7 to 5.4 GB an hour. Copying from the box to the Mac is on the LAN.
- **Upload times:** 3.8 GB takes about 25 minutes at 20 Mbit/s up, and about 50 minutes at 10 Mbit/s.
- **During a live stream:** the upload shares the uplink with the stream (6 to 12 Mbit/s).
  `yt_upload.py --max-mbps N` caps the upload's average rate with 8 MiB chunks and pauses between them. Better still,
  upload between shifts.

## Site

`site/build.py --videos site/content/videos.json` (the default) reads the uploaded shifts. Each one with a valid
video id gets three things:
- a link from its row on /runs/long/
- an embed under "Shift videos" (youtube-nocookie, lazy-loaded)
- a page at `/runs/long/shift-N/` with the embed, the description (without the chapter list), its stats and the
  chapters as links to their times on YouTube

Without the file there are no embeds and no shift pages. The same change fixes the long-run table's deaths and loss
alerts. The director's log has written `<- death:` / `<- loss:` since shift01, so the table showed 0 / 0. One alert
on two director lines counts once.

## Tests

`python3 tools/test_shift_video.py` runs the pipeline on a made-up pair of shifts. It covers:
- the box clock, a shift split over two files, and other shifts' files at the edges
- a log over midnight
- the chapter rules and picks
- the description's limits and what it leaves out
- the box plan
- the uploader's dry run, and its refusal of a shift still on

`python3 site/test_longrun.py` covers the video embeds, shift pages and the new death and loss counts.

# The video archive (tools/archive/, batch126: a first working test)

A per-shift index keyed on wall-clock UTC seconds, captions from the voiced lines, ranked candidate clips, and an HLS
sample with a player page (report-D's plan). All local and read-only on the masters (`/Volumes/Extreme SSD/
pog-recordings`, never moved or renamed); the R2 bucket `pog-archive` holds web renditions only.

    python3 tools/archive/archive.py shift48 --out DIR --recordings "/Volumes/Extreme SSD/pog-recordings/D-pog-recordings" \
        --runs-dir ~/code/player-of-games/runs --logs-dir ~/code/player-of-games/tools/stream/logs [--cut 3]

writes DIR/shift48-index.json, DIR/calibration.json, a captions file per recording and DIR/clips/ (candidates.json,
review.md, the cut MP4s). Its parts, each a CLI of its own:

- `archive_index.py`: the index. `t` is epoch seconds everywhere; tick is an attribute mapped through the score rows
  (`clock`). Recordings come from the drive (names are the box's PST clock), gaps are spans of the shift with no file,
  on-air intervals from the director's ON AIR lines (replays override them; a camera on a platform that is lost falls
  back), events from the chronicle, the director's lines and the viewer answers, voiced lines from audio-played.jsonl
  joined to the caster jsonl, chat from chat.jsonl and the viewers logs (site/moderation.py's deletions applied).
- `calibrate.py`: the offset between the Mac's log clock and a recording, by sliding the logged speech over the
  recording's loudness in six 8-minute windows (about 7 s a recording). shift48: +8.6 s in all six windows, drift
  0.06 s an hour; caption onsets then land a median 0.3 s before the speech.
- `captions.py`: WebVTT with speaker voice tags, for a whole recording or a window (a clip, a sample).
- `clips.py`: the ranked candidates and `--cut N` (H.264 MP4, +faststart, at nice 19).
- `hls.py`: an HLS sample (1080p CRF 23 capped at 6 Mbit/s and 540p at 1.2 Mbit/s, fMP4 4 s segments, keyframes
  every 2 s) and the sample.json its player reads. One encode at a time, nice 19.
- `player/index.html`: the prototype player (hls.js; lanes for on air, danger, progress, viewers, agents and voices;
  a side panel with the on-air subject, who is speaking, the stats as of that second and the last chat lines).
  `?src=`, `?data=`, `?vtt=` point it at any copy; `?t=EPOCH` seeks.
- `r2_put.py`: uploads a folder under a key prefix with content types and cache rules; `r2-cors.json` is the
  bucket's CORS. Bucket layout: `SHIFT/hls/...` (a whole shift), `SHIFT/sample-HHMM/...` (a test sample),
  `SHIFT/clips/CLIP-ID.{mp4,vtt}`, `SHIFT/captions.vtt`, `SHIFT/index.json`, `player/index.html`.

`python3 tools/test_video_archive.py` runs it all on a made-up shift (no ffmpeg, no clock).

## The clip library (batch129: old moments for the tour and the director)

    python3 tools/archive/catalogue.py build                     # every ended shift with a master on the SSD
    python3 tools/archive/catalogue.py search --kind death --agent opus --planet nauvis --text "artillery"
    python3 tools/archive/catalogue.py best --md FILE             # the run's best 50, for the tour writer
    python3 tools/archive/clipmaker.py s48-platform_lost-001      # cut, upload, print {url, seconds, ...}
    python3 tools/archive/clipmaker.py --range "2026-10-20 18:25:20" "2026-10-20 18:26:10"

- The catalogue (`runs/archive/catalogue.json` in the main checkout, gitignored) holds each shift's row, each
  recording with its fitted offset, and one entry per candidate clip: id `s48-platform_lost-001` (shift, event id),
  kind, title, times, the shift's score and the run's `rank` (a bonus for the first of its kind in the run), why,
  agents, planet, platform, the voiced lines inside it, and `flags` (no footage, no fitted offset, a hidden viewer's
  chat on the full frame). Per-shift indexes go to `runs/archive/shifts/`, offsets to `runs/archive/calibration.json`.
  Shifts 1-13 (and 14 to 23:37) have no audio-played.jsonl: their voiced lines are the caster rows pushed to the page.
- A clip is H.264 CRF 23 with the program's sound, cropped by default to the program's camera column (x 24, y 24,
  1208x1032: the overlay's main camera, which is today's camera hole; no sidebar or chat), `--frame full` for the whole
  frame. One encode at a time (a lock file), nice 19; cached by id in `runs/archive/clips/made.json`.
- On R2: `clips/ID.mp4` (`clips/ID-full.mp4`), `clips/ID.vtt`, `clips/ID.json` (title, caption "from shift 48,
  Oct 20", when, seconds, size), public at https://pub-107dd9c2d81e4ef687f434b9c598414b.r2.dev/clips/ID.mp4. The
  maker refuses a clip that would take the bucket over 19 GB.

`python3 tools/test_clip_library.py` checks the catalogue and the maker on the same made-up shift (no ffmpeg, no
network).
