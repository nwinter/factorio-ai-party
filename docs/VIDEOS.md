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

## The whole run, private (tools/archive_upload.py, batch169)

    python3 tools/archive_upload.py --inventory       # each shift's recordings, minutes covered, gaps
    python3 tools/archive_upload.py --dry-run         # each shift's plan, size and time; nothing copied or sent
    python3 tools/archive_upload.py --shifts 2,4      # upload those; --shifts 1-69 --limit 10; again to resume

- **Recordings:** the masters on the Extreme SSD (`pog-recordings/` public-run, C-pog-recordings,
  C-pog-recordings-moved, D-pog-recordings) and the box's `D:\pog\recordings` and `C:\pog\recordings` (one ssh with
  ffprobe there). The SSD's copy of a name comes first. Replay_ clips, empty files and a file still being written (no
  duration) are left out. Durations are kept in `/Volumes/Extreme SSD/pog-videos/durations.json`.
- **Plan:** shift_video's window and segments. One file with no cut goes up as it is. A box file is first copied by
  scp to `/Volumes/Extreme SSD/pog-videos/tmp/`, and its size is checked. Several files, or a cut, are joined there
  without re-encoding (the concat demuxer, `-c copy`, shift_video's inpoint/outpoint), after a check that their
  streams match. The join's duration is checked against the plan.
- **Upload:** shift_video builds `runs/RUN/video/` from the same recording list, then yt_upload goes up with
  `--privacy private --no-playlist --max-mbps 200 --videos-json ~/code/pog-operator/video-work/videos-private.json`.
  A shift whose id is in that manifest or in `runs/RUN/video/upload.json` is skipped. Once the id is in, what the tool
  wrote to tmp for the shift is removed. The masters are only read.
- **d24 inventory:** shifts 1-69 all have recordings, from 73 masters on the SSD and 8 files on the box. Most start
  about 3 minutes into the shift's window (OBS starts after start-team's helpers). The longer gaps are shift59's last
  1h38 and 32 minutes of shift18. 9 shifts need a join (2, 5, 13, 14, 18, 19, 24, 29, 31). All 22 files of those joins
  are HEVC 1920x1080 at 30 fps with AAC 48 kHz stereo. The dry run gave 68 uploads, 1,043 GB, about 12 hours at
  200 Mbit/s, and 68 of the 100 uploads a day.

## Chapters and description

YouTube's rules are that the first chapter is at 0:00, there are at least three, and each is at least 10 s long. The
tool keeps chapters 90 s apart and picks at most 24:
1. Milestones (weight 85 or more), heaviest first. Two milestones too close for two chapters share one title.
2. Big moments (60 to 84), heaviest first.
3. The rest (30 to 59), spread over the whole recording. Each pick is the heaviest after its weight is scaled down by
   how near it is to a chapter already placed (full weight from total / 24 away).
4. A stretch of more than 45 minutes with no chapter gets its heaviest moment of weight 20 to 29, else an hour mark.
   Hour marks also fill in when there are fewer than three chapters.

Weights, heaviest first. "First" and "before" mean in the run: the earlier shifts' chronicles along the world's
resumed-from chain, plus the planets the shift's first score lists.
- 100: the first arrival at the solar system edge, the Space Age victory ("Asterion reaches the solar system edge: the
  Space Age victory"). 99: the first arrival at the Shattered Planet. 96: the first platform to reach a planet.
- 95: landing on a planet. 92: the first rocket. 91: a platform lost. 90: a platform built, and a departure for the
  edge or the Shattered Planet that no platform made before.
- Milestone technologies (45 to 80): the rocket silo and space science weigh most, early ones such as automation least.
- 66 and 64: a platform setting out for the Shattered Planet again, or reaching the edge again. 60: setting out for the
  edge again. Only the first of the shift for each platform and place; later ones are routine.
- 55 to 85: a fight in which one loss alert reached 10 buildings, placed at that alert.
- 50: each thousandth rocket. 48: a platform's first visit to a place (it never arrived, left or was built there
  before; only once an earlier shift has a chronicle).
- 45 and 38: an agent's first death; 42: up to three viewer questions that an agent answered by name within three
  minutes. 36: another new technology; 26: a repeating technology's next level.
- 35, 30 and 20: the hosts' spotlight, overview and production, and recap segments. 33: the agents' chronicle entries.
  34: a platform taken down.
- Under 10: routine trips (every other arrival and departure) and other rockets. They are never chapters, and the
  description sums the trips by route.

Shifts from 15 on have a chronicle.jsonl, which gives platforms, trips and research at their exact times. Before that,
research, rockets and platforms come from the score log, written every 2 minutes, and their chapters sit at the
middle of the interval in which they first appear. A repeating technology keeps its name from level to level, so
only the chronicle sees its next level.

The title is the heaviest moment, plus a second one when it weighs 60 or more, is about another platform or kind, and
both fit. "What happened" lists, heaviest first:
- the notable moments;
- the new technologies, with what research finished;
- the rockets;
- the routine trips summed by route ("352 routine platform trips: 166 between Gleba and Nauvis (Cinder, Meridian-V,
  Swiftlet and others); ...");
- science per minute, deaths and the biggest fight.

The description then gives:
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

## Whole shifts on R2 (batch211: tools/archive/r2_shifts.py)

    python3 tools/archive/r2_shifts.py shift01 [shift02 ...]      # or --shifts 2-69; --dry-run prints the plan

One shift at a time: the index (archive.py, the run's offsets copied in, no clip cut), the encode at nice 19 with
hls.py's ladder into `/Volumes/Extreme SSD/pog-hls/RUN/full/`, the upload to `RUN/full/` at or under 150 Mbit/s
(jobs rise from 4 while the measured rate is under 80% of the cap, never past 16, and stop rising at the cap; puts
pause while `tools/obs.py stream-status` shows skipped frames rising or congestion), a HEAD of every object at the
public URL against its local size, then `RUN/full/receipt.json` in R2 and in `~/code/pog-operator/r2-receipts/`,
the local folder removed and the shift's row in `~/code/pog-operator/r2-status-d25.md` marked complete. A shift
with a receipt is skipped; an encode with its encode.json is reused; an interrupted upload puts only what is missing.

- Keys: `RUN/full/master.m3u8`, `RUN/full/{1080,540}/index.m3u8` and `pNN/{init.mp4,segNNNN.m4s}` (one `pNN` per
  recording; the rung playlist plays them back to back with a discontinuity), `captions.vtt` (on the joined video),
  `shift.json` (the index cut to the shift plus `parts`: [video s, wall t, seconds, name]; no local paths),
  `encode.json`, `receipt.json` (objects, bytes, the masters used, the duration covered, the time).
- Watch: https://pub-107dd9c2d81e4ef687f434b9c598414b.r2.dev/player/index.html?src=../RUN/full/master.m3u8&data=../RUN/full/shift.json&vtt=../RUN/full/captions.vtt
  (the player maps the video's time to wall time through `parts`).

`python3 tools/test_r2_shifts.py`: a made-up shift with two recordings, a fake runner, r2_put and HEAD (no ffmpeg,
network or clock).
