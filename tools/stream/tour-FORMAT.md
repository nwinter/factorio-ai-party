# Tour script format (tools/stream/tour.py)

A tour script is a JSON file: a list of stops, or `{"stops": [...]}`. The tour plays the stops in order, one camera
shot each, with one narrator reading each stop's narration. Check a script with
`python3 tools/stream/tour.py dry-run SCRIPT`: it prints the timeline and says which stops cannot air and why.

## A stop

```json
{
  "id": "nauvis-labs",
  "target": {"surface": "nauvis", "x": 208, "y": 158, "zoom": 0.6},
  "caption": "22 labs, 115 science a minute",
  "narration": "Forty to a hundred and ten words, read by the narrator.",
  "facts": [{"claim": "22 labs", "source": "runs/shift63/chart/out/index.json"}]
}
```

| field | required | what it does |
|---|---|---|
| `id` | yes | a unique name: the log and `--from ID` (resume) use it |
| `target` | yes (a clip stop: no) | the shot: a planet spot `{surface, x, y, zoom}` or a ship `{platform: NAME}` (below) |
| `caption` | no | at most 80 characters (60 reads best); the shot's on-screen label |
| `narration` | no | the text the narrator reads; `prepare` renders it to a clip |
| `facts` | no | for the operator: claims and their sources; never aired |
| `min_seconds` | no | the stop lasts at least this long (a beat to look at something after the narration) |
| `hold_s` | no | seconds added after the narration's tail (0 to 30) |
| `seconds` | no | the length of a stop **without** narration (default 8). Not used when there is a narration |
| `move` | no | the camera moving within the stop: pan, zoom, a path (below) |
| `marks` | no | arrows, circles, boxes and labels drawn at map positions over the shot (below) |
| `subtitles` | no | `true` (default): the narration as captions; `false`; `"top"` (below) |
| `clip` | no | an old clip from the archive played in the camera instead of a live shot (below); `target` is optional then |

### target

- A planet spot: `{"surface": "nauvis", "x": 208, "y": 158, "zoom": 0.6}`. `surface` is nauvis, vulcanus, gleba,
  fulgora or aquilo. `x` and `y` are map tiles, the centre of the shot. `zoom` is 0.3 to 3 (default 0.75; higher is
  closer; the camera column shows about 40 tiles across at 1.0 and 130 at 0.3). The whole frame must be on ground the team has charted:
  the service checks it and an uncharted stop is skipped. A closer zoom frames less ground.
- A ship: `{"platform": "Asterion"}`: the whole ship, framed as the director frames it. A ship that is not ours
  now is skipped (dry-run marks it). `{"platform": "Asterion", "x": 0, "y": -20, "zoom": 1.2}` is a spot on its deck
  (platform tiles, the hub at about 0, 0).

## move: the camera within a stop

Without `move` a planet spot is a still shot, and a whole ship pans slowly bow to stern when it is taller than the
frame. A `move` moves the camera smoothly over the stop, eased at both ends, played by the game every tick.

| form | what it does |
|---|---|
| `{"to": {"x": 240, "y": 160, "zoom": 0.8}}` | pan (and zoom) from the target to that spot; a missing x, y or zoom keeps the target's |
| `{"zoom": 1.2}` | zoom in (or out) in place |
| `{"path": [{"x": 220, "y": 150}, {"x": 260, "y": 120, "zoom": 0.6}]}` | through those points in a smooth curve, from the target (a point without zoom keeps the last one's) |
| `"hold"` | a still shot (a ship: no pan) |
| `[{"zoom": 1.0}, "hold", {"to": {"x": 300}}]` | one after another, each from where the last ended; without times they share the stop evenly |

Each move may say when, in seconds from the cut: `"from_s": 2` (default the start, or where the last ended),
`"to_s": 30` (default the stop's end; `"end"`, or a negative number counted back from the end: `-3` is 3 s before
it), and `"ease"`: `"inout"` (default: starts and stops gently), `"in"`, `"out"` or `"linear"`. The stop's length
comes from its narration, so `"to_s": "end"` and the defaults follow the clip.

- Zoom stays within 0.3 to 3; at most 16 points in a stop's moves.
- Every point of a planet move must be charted ground (the frame there is checked like the target); a refusal
  names the point ("move point 2: ..."), and the stop is skipped.
- On a ship, give a path (its first point is the start, in platform tiles), or a deck spot in the target
  (`{"platform": "Asterion", "x": 0, "y": -40, "zoom": 1}`) with `to` or `zoom`.
- `dry-run` prints each move with its times.

## marks: annotations on the shot

`marks` is a list (at most 12) of things drawn over the camera at map positions. They stay on their spot while the
camera moves, and fade in and out (0.3 s).

```json
"marks": [
  {"type": "circle", "at": {"x": 52, "y": 54}, "radius": 4, "text": "the landing pad"},
  {"type": "arrow", "at": {"x": 75, "y": 30}, "from": "ne", "text": "the first assemblers", "from_s": 8},
  {"type": "box", "at": {"x": 45, "y": 52}, "w": 10, "h": 6, "color": "yellow", "text": "old smelters", "to_s": -2},
  {"type": "label", "at": {"x": 70, "y": 52}, "text": "2 belts, 15/s", "color": "green"}
]
```

| type | draws | its own fields |
|---|---|---|
| `circle` | a ring round the spot, the text below it | `radius` in tiles (default 6) |
| `arrow` | an arrow pointing at the spot, the text at its tail | `from`: the tail's side, `n`, `ne`, `e`, `se`, `s`, `sw`, `w`, `nw` (default) or a map spot `{x, y}`; `length` in pixels (30 to 400, default 110) |
| `box` | a rectangle centred on the spot, the text below it | `w`, `h` in tiles (default 12) |
| `label` | a dot on the spot and the text beside it | `text` is required |

Every mark: `at` {x, y} (map tiles on the stop's surface; a ship's in platform tiles), `text` (at most 60
characters), `from_s` and `to_s` (seconds from the cut, like a move's; default the whole stop; `"end"` or a negative
number counts from the end), `color` (`orange` default, `yellow`, `red`, `green`, `blue`, `white`, or `#rrggbb`).

- A mark only shows while its spot is in the frame. `dry-run` lists each stop's marks and says when one is out of
  the frame while it should show ("mark 2 out of the frame at 12 s"); it cannot check a whole ship's frame (the
  director frames it at run time).
- Text is kept inside the camera; long text near an edge is moved in.
- An urgent event (an attack) can still put a small inset window over the top right of the camera.

## clip: an old moment from the archive

A stop can play a recorded clip of the stream instead of a live shot: an earlier battle, a first launch, a death.

```json
{"id": "first-death", "clip": {"id": "s01-death-006"}, "caption": "The first death",
 "narration": "On the first day, the first death: Opus, alone at the edge of the base."}
```

| clip field | what it does |
|---|---|
| `id` | a clip from the archive's clip library (batch129): `s48-platform_lost-001` and the like. `tools/archive/catalogue.py search` and runs/archive/catalogue.json list them; the operator's scratchpad tour/clip-moments.md has the writer's best 50; `python3 tools/archive/clipmaker.py ID` makes one not cut yet |
| `url` | instead of `id`: any http(s) link to an .mp4 (then give `seconds`) |
| `start_s` | seconds into the clip to start from (default 0) |
| `seconds` | how much of it to play (default: to its end) |
| `caption` | the archive badge's text (default the library's, e.g. "from shift 48, Oct 20") |

- The clip fills the camera, with an ARCHIVE badge at the top left (its caption and title). It plays **muted**: its
  own sound is the old hosts' voices and that hour's game, and the narrator speaks over it. The stream's live game
  sound goes on underneath, as on every stop.
- The stop lasts at least the clip (its play time + 0.5 s); a narration longer than the clip holds its last frame.
- `target` is optional on a clip stop: without one the camera stays on the last shot, behind the clip. With one, the
  camera goes there (so the stop after it can cut from there). A clip stop has no `move` without a target, and no
  `marks` (they belong to the map, not the clip).
- The clips already show the old speech bubbles low in the frame, so a clip stop's subtitles go at the top unless it
  says `"subtitles": "bottom"`.
- `dry-run` looks each clip up in the library (its length and caption) and marks a clip that is not there; `run`
  skips that stop.

## Subtitles

The narration is shown as captions in the camera while the narrator reads it, a phrase at a time (one or two
lines), timed to the clip: `prepare` cuts the narration at its punctuation and puts each break on the narrator's
pause there. Write punctuation where the narrator should breathe; a clause longer than about 84 characters is cut at
words. The stop's caption stays as the shot's label in the bar under the camera.

`"subtitles": false` turns them off for a stop (the narrator's caption box shows instead), `"top"` puts them at the
top of the camera (a stop playing an old clip, whose own speech bubbles sit low). `tour.py run --no-subtitles` turns
them off for the whole tour.

## Timing

Every narrated stop is: **the cut**, 0.8 s, the narration (its clip's measured length), 1.5 s, then the next cut.
`hold_s` adds time after the narration; `min_seconds` sets a floor. The tour runs on one clock: the camera cut and the
narration's first word are scheduled to the moment, so there is no dead air and no early or late line. Write the
narration for the shot; the shot lasts as long as the narration takes to read (about 2.5 words a second, so 100
words is about 42 s on screen).

When an agent's voiced line is waiting at the end of a stop, the tour holds that stop for the line's length (the agent
speaks over the shot after the narration); the timeline's total does not include these.

## Commands

```
python3 tools/stream/tour.py prepare SCRIPT      # render every narration (one narrator voice) and time its captions
python3 tools/stream/tour.py dry-run SCRIPT      # the timeline: lengths, moves, marks, clips, skips; no camera, no audio
python3 tools/stream/tour.py run SCRIPT          # on air
python3 tools/stream/tour.py stop                # from another terminal: ends the tour cleanly
```

`run` and `dry-run` take `--from ID` (resume at that stop), `--lead` and `--tail` (the 0.8 and 1.5 s around a
narration) and `--clip-base` (another clip library). `run` also takes `--no-subtitles` and `--no-agent-gaps`.
Re-run `prepare` after editing a narration: only the changed clips are rendered again.
