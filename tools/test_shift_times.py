#!/usr/bin/env python3
"""tools/shift_times.py: python3 tools/test_shift_times.py

The shift's end is its start plus its minutes; the next shift is expected then, unless POG_NEXT_SHIFT says HH:MM
(the next such time, today or tomorrow), an ISO time, or none; a bad value falls back to the expected time."""
import datetime, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shift_times import shift  # noqa: E402


def main():
    now = datetime.datetime(2026, 10, 11, 22, 47, 0).timestamp()
    s = shift(240, "", now)
    assert s == {"start": round(now), "end": round(now + 14400), "next": round(now + 14400), "next_exact": False}, s
    later = shift(240, "02:50", now)  # after midnight: tomorrow
    assert later["next"] == round(datetime.datetime(2026, 10, 12, 2, 50).timestamp()) and later["next_exact"], later
    same_day = shift(60, "23:30", now)
    assert same_day["next"] == round(datetime.datetime(2026, 10, 11, 23, 30).timestamp())
    iso = shift(60, "2026-10-12T09:00:00-07:00", now)
    assert iso["next"] == round(datetime.datetime.fromisoformat("2026-10-12T09:00:00-07:00").timestamp()) and iso["next_exact"]
    assert shift(60, "none", now)["next"] is None
    assert shift(60, "soon", now) == shift(60, "", now)  # not a time: the expected one, with a warning on stderr
    print("shift times: ok")


if __name__ == "__main__":
    main()
