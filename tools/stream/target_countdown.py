"""Public countdown facts from this shift's target.json only; no game reads."""
import math
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import run_target


def facts(run):
    """Re-read every snapshot so edits, clear, and shift carry take effect immediately.

    Only the public goal/time leave the service; operator notes and attribution do not.
    Bad or partially written dates must not break the stream ticker.
    """
    if not run:
        return None
    try:
        target = run_target.read(run)
        if not target:
            return None
        at = run_target.epoch(target["at"])
        if not math.isfinite(at):
            return None
        return {"goal": target["goal"].strip(), "at": target["at"], "at_epoch": at}
    except (ValueError, TypeError, OverflowError, KeyError):
        return None
