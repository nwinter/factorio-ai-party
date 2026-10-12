# time.sleep for the agents' Python (PYTHONPATH in their launch environment; tools/launch-agent.sh, profile-flags.sh
# sleepcap_env): one wait longer than POG_SLEEP_CAP_SECONDS (60) waits that long, with one line on stderr per process,
# because a Python sleep is a wait no tell, mention or attack can end (docs/studies/shake11.md, P1 item 3: Sonnet's
# `python3 -c "import time;time.sleep(1200)"`). Untouched: POG_SLEEP_CAP not 1, and scripts under
# POG_SLEEP_CAP_EXEMPT (our tools/, bin/, vendor/). The Python's own sitecustomize (Homebrew's adds its site-packages)
# runs after this one, as it would without it.
import os
import sys


def _install():
    import time
    real = time.sleep
    try:
        cap = float(os.environ.get("POG_SLEEP_CAP_SECONDS", "60"))
    except ValueError:
        cap = 60.0
    roots = [os.path.realpath(p) for p in os.environ.get("POG_SLEEP_CAP_EXEMPT", "").split(os.pathsep) if p]
    told = []

    def ours():
        main = sys.argv[0] if sys.argv else ""
        if not main or main in ("-c", "-m", "-"):
            return False
        path = os.path.realpath(main)
        return any(path.startswith(r + os.sep) for r in roots)

    def sleep(seconds):
        try:
            over = seconds > cap
        except TypeError:
            return real(seconds)  # the real error for a bad argument
        if over and not ours():
            if not told:
                told.append(1)
                print("./fh sleep N waits longer and wakes on tells, mentions and attacks", file=sys.stderr, flush=True)
            return real(cap)
        return real(seconds)

    sleep.__doc__ = real.__doc__
    time.sleep = sleep


def _chain():
    """Run the next sitecustomize on sys.path (the interpreter's own), which this module shadows."""
    here = os.path.dirname(os.path.realpath(__file__))
    for entry in list(sys.path):
        try:
            if not entry or os.path.realpath(entry) == here:
                continue
        except (TypeError, ValueError):
            continue
        path = os.path.join(entry, "sitecustomize.py")
        if os.path.isfile(path):
            import importlib.util
            spec = importlib.util.spec_from_file_location("_pog_next_sitecustomize", path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return


if os.environ.get("POG_SLEEP_CAP") == "1":
    try:
        _install()
    except Exception:  # never break the agent's Python over the cap
        pass
_chain()
