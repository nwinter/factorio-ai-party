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
| `target` | yes | the shot: a planet spot `{surface, x, y, zoom}` or a ship `{platform: NAME}` (below) |
| `caption` | no | at most 80 characters (60 reads best); the shot's on-screen label |
| `narration` | no | the text the narrator reads; `prepare` renders it to a clip |
| `facts` | no | for the operator: claims and their sources; never aired |
| `min_seconds` | no | the stop lasts at least this long (a beat to look at something after the narration) |
| `hold_s` | no | seconds added after the narration's tail (0 to 30) |
| `seconds` | no | the length of a stop **without** narration (default 8). Not used when there is a narration |
| `move` | no | the camera moving within the stop: pan, zoom, a path (below) |

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
python3 tools/stream/tour.py prepare SCRIPT      # render every narration (one narrator voice); re-run after edits
python3 tools/stream/tour.py dry-run SCRIPT      # the timeline: lengths, skips, notes; no camera, no audio
python3 tools/stream/tour.py run SCRIPT          # on air (--from ID resumes; --lead/--tail change 0.8 and 1.5 s)
python3 tools/stream/tour.py stop                # from another terminal: ends the tour cleanly
```
