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

### target

- A planet spot: `{"surface": "nauvis", "x": 208, "y": 158, "zoom": 0.6}`. `surface` is nauvis, vulcanus, gleba,
  fulgora or aquilo. `x` and `y` are map tiles, the centre of the shot. `zoom` is 0.3 to 3 (default 0.75; higher is
  closer; 0.3 shows about 200 tiles across, 1.0 about 60). The whole frame must be on ground the team has charted:
  the service checks it and an uncharted stop is skipped. A closer zoom frames less ground.
- A ship: `{"platform": "Asterion"}`: the whole ship, framed as the director frames it. A ship that is not ours
  now is skipped (dry-run marks it). `{"platform": "Asterion", "x": 0, "y": -20, "zoom": 1.2}` is a spot on its deck
  (platform tiles, the hub at about 0, 0).

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
