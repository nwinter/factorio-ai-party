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

Without an operator override, a moving platform is featured automatically on a leg to or from the solar-system edge or Shattered Planet, or a connection of at least 100,000 km (`director.auto_feature_km` in stream.json). The setting records `source: "auto"`; one ship is selected, the furthest out. Deep-route ranking accounts for inward travel, using the existing score's route distance and length. The feature lasts until arrival, a reversal or a confirmed loss. A turnaround stays ended across restarts and shifts until the ship docks; it cannot instantly requalify on the reverse leg. New departures can qualify again. No game reads are added.

An explicit `set` wins over automatic selection. An explicit `clear` also suppresses automatic coverage, so clearing a ship never immediately selects it again. To release that override:

```sh
python3 tools/stream/featured.py --run-dir runs/shift104 auto
```

When an operator setting reaches its requested end condition, other ships and later departures may qualify automatically. `director.auto_feature: false` disables automatic selection for isolated directing simulations.

Work shots follow journal attention on a different surface or platform, including `platform=`, `surface=` with a position/area, and `lane="platform:NAME"`. Platform reads and other tools with those structured destinations count too. `work.WorkFeed` supplies requests already read by the service; `model` attaches the surface and source age, and `remotework` resolves the ready frame. The main shot, speech/follow shots and auxiliary cameras show the work with the agent's name, instead of the parked body. Existing remote-vehicle views still apply. Attention expires after 120 seconds or changes with a newer located request. Unknown platform geometry waits without sending a body substitute. Failed sends retain the acknowledged frame and existing bounded retries.

`python3 tools/stream/replay_remote_work.py` compares the archived shift104 02:00–05:00 main-camera decisions against these policies. The checked-in fixture identifies the two director logs, Astra's journal and score samples by path and SHA-256. Other camera destinations are held at their recorded choices; synthetic geometry is used only to measure airtime, so this is not a claim about rendered pixels. The full-window baseline already includes batch373 after its 03:16:48 restart; the output also reports the earlier window separately.

Verification: `python3 tools/stream/test_featured.py` uses the real director with stub sends and simulated clocks. On the live stream after operator merge/restart, enable the preference in the current run, check director/cuts logs and visually confirm the program's bow/whole-ship framing and inset. This change does not restart the stream or operate OBS.
