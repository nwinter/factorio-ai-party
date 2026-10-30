# Featured platform

`featured.py` sets a preference for the OneCam director using its existing platform telemetry. It sends no game commands itself. Run it against the **current run folder**; the running stream service reads changes on its next director step. Service restarts and later shifts linked by `resumed-from` retain the preference.

For Resolute's final run, end at Shattered Planet, a confirmed loss, or the attempt turning back/landing after flight:

```sh
python3 tools/stream/featured.py --run-dir runs/shift104 set Resolute --arrival shattered-planet --attempt-end
python3 tools/stream/featured.py --run-dir runs/shift104 status
python3 tools/stream/featured.py --run-dir runs/shift104 clear
```

A timed preference instead (the timestamp must include a timezone):

```sh
python3 tools/stream/featured.py --run-dir runs/shift104 set Resolute --at 2026-10-30T12:00:00Z
```

End conditions can be combined; the first observed match ends the preference. `--attempt-end` observes a reversal of a previously observed directed leg, `turned_back`, or landing after observed flight. Observed departure/direction survives restarts and shifts. A confirmed platform-loss entry also ends the preference. Missing telemetry or a temporarily absent camera view does not mean the attempt ended. An operator can always `clear` or start a new preference explicitly.

The director aims for three minutes of bow/defense framing, one minute of whole-ship context, then 90 seconds for other coverage with the ship in a free inset. These are editorial intervals, not a guaranteed airtime quota: attacks, deaths, significant losses, active battles, replays, segments and explicit operator pins retain priority. Fresh encounters, repairs/builds and platform milestones bring the featured ship back sooner. Work follows the platform's surface, including an engineer working remotely from the ground. Bounds refresh as the ship changes; existing camera-send retries and compositor readiness still apply. A single camera without a panel has no inset.

Settings live in `RUN/director-featured.json`. End/clear records remain as tombstones so a previous shift's active preference cannot return. A fresh run outside the resume chain inherits nothing. Director logs identify `featured platform NAME`; camera labels identify `Featured: NAME` with the framing, and the stream snapshot exposes `featured_platform`, including end reason. This is separate from `/platform`, which is an exclusive operator hold.

Verification: `python3 tools/stream/test_featured.py` uses the real director with stub sends and simulated clocks. On the live stream after operator merge/restart, enable the preference in the current run, check director/cuts logs and visually confirm the program's bow/whole-ship framing and inset. This change does not restart the stream or operate OBS.
