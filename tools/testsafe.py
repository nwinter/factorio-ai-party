"""What a test runs a repo script with (d24 batch186, operator 18:38: tools/test_shift_recovery.py's copy of
stop-team.sh stopped the live site pusher on every gate run, 18:03-18:32). The gate runs the tests in the live checkout
(/Users/owner/code/player-of-games, after git merge --no-commit), so ROOT there is the live checkout and its runs/ the
live runs.

env(**over): os.environ without the operator's POG_*, FH_* and FACTORIO_RCON_* settings, with POG_TEST=1, then `over`.
Under POG_TEST=1 the tools that reach live things refuse their live defaults (docs/TESTS-LIVE.md lists them):
tools/pog.py (RCON to a world's port), tools/obs.py (OBS), tools/winps.sh (ssh to the box), tools/stop-team.sh (OBS
outputs), tools/new-run.sh (the world's RCON password), tools/obs-recover.sh (the lock in runs/), site/build.py (the
repo's runs/ as its source). tools/test_live_guard.py checks each, and that every test running a repo shell script
passes env() (or strips POG_* and sets POG_TEST=1 itself).
"""
import os

DROP = ("POG_", "FH_", "FACTORIO_RCON_")


def env(**over):
    out = {k: v for k, v in os.environ.items() if not k.startswith(DROP)}
    out["POG_TEST"] = "1"
    out.update({k: str(v) for k, v in over.items()})
    return out


def active():
    """True in a test run (POG_TEST=1)."""
    return os.environ.get("POG_TEST") == "1"
