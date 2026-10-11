#!/usr/bin/env python3
"""Tests for tools/quota_check.py and tools/agy-quota.py (run: python3 tools/test_quota.py)."""
import json
import os
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import quota_check  # noqa: E402

TEAM = "astra\tcodex\tcodex-b\tgpt-6-astra\tlow\tA\tCodex\ngemini\tagy\t-\tgemini-3.8-flash-high\t-\tG\tAntigravity\n"


def brief(gemini_pct, reset_in):
    now = 1_791_710_460   # 2026-10-11 05:21 PDT, shake5's start
    w = lambda label, pct, reset: {"label": label, "percent": pct, "resets_at": now + reset, "duration_minutes": 300}
    return now, {"profiles": [
        {"id": "codex_account_b", "command": "codex-b", "windows": [w("Codex · Weekly", 13, 86400)]},
        {"id": "agy_local", "command": "agy", "windows": [w("Gemini · 5-hour", gemini_pct, reset_in),
                                                           w("Claude/GPT · 5-hour", 0, 3600)]}]}


def main():
    with tempfile.TemporaryDirectory() as d:
        team = os.path.join(d, "team.tsv")
        open(team, "w").write(TEAM)
        # shake5: Gemini at 72%, resetting in 1h54m; at 36%/h it runs dry 47 minutes into a one-hour shift.
        now, b = brief(72, 6840)
        lines = quota_check.check(b, team, 60, now)
        warn = [l for l in lines if l.startswith("WARNING")]
        assert len(warn) == 1 and "Gemini · 5-hour" in warn[0], lines
        assert f"at about {time.strftime('%H:%M', time.localtime(now + 28 / 36 * 3600))}" in warn[0], warn
        assert not any("Claude/GPT" in l for l in lines), "agy's Claude/GPT window does not count for Gemini"
        assert any(l.startswith("quota codex_account_b (astra)") and l.endswith("ok (about 14% at "
                   + time.strftime("%H:%M", time.localtime(now + 3600)) + ")") for l in lines), lines
        # Full now, resetting 20 minutes into a two-hour run: warns (dry now); 100 min at 36%/h after the reset is 60%.
        now, b = brief(100, 1200)
        warn = [l for l in quota_check.check(b, team, 120, now) if l.startswith("WARNING")]
        assert len(warn) == 1 and "run dry now" in warn[0] and "it resets at" in warn[0], warn
        # Plenty of room: no warning.
        now, b = brief(10, 6000)
        assert not [l for l in quota_check.check(b, team, 60, now) if l.startswith("WARNING")]
        # An unknown route warns instead of failing.
        open(team, "a").write("x\tclaude\tnosuch\thaiku\tlow\tX\tClaude Code\n")
        assert any("no ai-usage profile" in l for l in quota_check.check(b, team, 60, now))
        # The script prints a data note first and never fails.
        bf = os.path.join(d, "brief.json")
        json.dump(b, open(bf, "w"))
        out = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "quota_check.py"), team, "60", "--brief", bf,
                              "--now", str(now)], capture_output=True, text=True)
        assert out.returncode == 0 and out.stdout.startswith("quota data: from "), out
    print("quota_check: ok")


if __name__ == "__main__":
    main()
