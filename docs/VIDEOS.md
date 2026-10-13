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
