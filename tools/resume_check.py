#!/usr/bin/env python3
"""Did a resumed shift carry over? tools/resume_check.py RUN_DIR [WORLD]

Reads the previous run from RUN_DIR/resumed-from (its directory: runs/PREV here, else ~/code/player-of-games/runs/PREV,
or --previous DIR) and compares, over RCON and from the files:
- game time: the world's tick now against the previous run's last score (the save may be up to one autosave older);
- factory: technologies researched and building counts then and now;
- bots: every team member of this run has a bot, alive or respawning, and what positions they hold;
- workspaces: each notes.md starts with the carry-over line and holds the previous shift's notes; prompt.md has the
  resume sentence.
Prints a report; exits 1 when something did not carry over.
"""
import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)


def previous_dir(run_dir, given=None):
    if given:
        return given
    prev = open(os.path.join(run_dir, "resumed-from")).read().strip()
    for d in (os.path.join(ROOT, "runs", prev), os.path.expanduser(f"~/code/player-of-games/runs/{prev}")):
        if os.path.isdir(d):
            return d
    raise SystemExit(f"no run directory for {prev}")


def last_score(run_dir):
    rows = []
    for line in open(os.path.join(run_dir, "scores.jsonl")):
        try:
            rows.append(json.loads(line)["score"])
        except (ValueError, KeyError):
            pass
    return max(rows, key=lambda s: s.get("tick", 0)) if rows else None


def compare(prev, now, prev_bots, now_bots, members, workspaces, sentence, prompt):
    """Report lines and problems, from plain data (tested offline in tools/test_resume.py)."""
    lines, problems = [], []
    pt, nt = (prev or {}).get("tick", 0), now.get("tick", 0)
    lines.append(f"game time: previous run's last score tick {pt} ({pt / 3600:.1f} min), world now {nt} ({nt / 3600:.1f} min)")
    if nt < pt - 6 * 3600:
        problems.append(f"the world is {(pt - nt) / 3600:.1f} game minutes behind the previous run's last score: an old save?")
    if nt < 3600 and pt > 3600:
        problems.append("the world is at its first game minute: a fresh map, not the save")
    pd, nd = set((prev or {}).get("research_done") or []), set(now.get("research_done") or [])
    lines.append(f"research: {len(pd)} done then, {len(nd)} now" + (f"; missing now: {', '.join(sorted(pd - nd))}" if pd - nd else ""))
    if len(pd - nd) > 2:
        problems.append(f"{len(pd - nd)} technologies done in the previous run are not done now")
    pe, ne = (prev or {}).get("entities") or {}, now.get("entities") or {}
    for name in sorted(set(pe) | set(ne), key=lambda k: -(pe.get(k, 0)))[:8]:
        lines.append(f"  {name}: {pe.get(name, 0)} then, {ne.get(name, 0)} now")
    if sum(pe.values()) and sum(ne.values()) < 0.8 * sum(pe.values()):
        problems.append(f"buildings: {sum(ne.values())} now against {sum(pe.values())} then")
    for m in members:
        b = now_bots.get(m)
        was = prev_bots.get(m) if prev_bots else None
        if not b:
            problems.append(f"bot {m}: missing")
            continue
        pos = b.get("position") or {}
        lines.append(f"bot {m}: {'alive' if b.get('alive') else 'dead'} at {pos.get('x', 0):.0f},{pos.get('y', 0):.0f}"
                     + (" (kept from the save)" if was is not False else ""))
    for m, (notes, prev_notes) in workspaces.items():
        if notes is None:
            problems.append(f"{m}: no notes.md")
        elif prev_notes is None:
            lines.append(f"{m}: fresh notes.md (no notes in the previous run)")
        elif not notes.startswith("(Carried over from the previous shift") or prev_notes.strip() not in notes:
            problems.append(f"{m}: notes.md is not the previous shift's notes under the carry-over line")
        else:
            lines.append(f"{m}: notes.md carried over ({len(prev_notes.splitlines())} lines)")
    if sentence not in (prompt or ""):
        problems.append("prompt.md lacks the resume sentence")
    return lines, problems


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir")
    ap.add_argument("world", nargs="?", default="n")
    ap.add_argument("--previous")
    a = ap.parse_args()
    import pog
    import team_bots
    prev_dir = previous_dir(a.run_dir, a.previous)
    pw = open(os.path.expanduser(f"~/.config/pog/rcon-{a.world}.pw")).read().strip()
    r = pog.Rcon("127.0.0.1", pog.PORTS[a.world], pw)
    now = json.loads(subprocess.run([sys.executable, os.path.join(HERE, "pog.py"), "--world", a.world, "score"],
                                    capture_output=True, text=True, check=True).stdout)
    team = os.path.join(a.run_dir, "team.txt")
    members = [l.split("|")[0].strip() for l in open(team) if l.strip()] if os.path.exists(team) else []
    workspaces = {}
    for m in members:
        p, q = os.path.join(a.run_dir, m, "notes.md"), os.path.join(prev_dir, m, "notes.md")
        workspaces[m] = (open(p).read() if os.path.exists(p) else None, open(q).read() if os.path.exists(q) else None)
    sentence = subprocess.run(["bash", os.path.join(HERE, "launch-agent.sh"), "--resume-sentence"], capture_output=True,
                              text=True).stdout.strip()
    prompt_path = os.path.join(a.run_dir, "prompt.md")
    lines, problems = compare(last_score(prev_dir), now, None, team_bots.existing(r), members, workspaces, sentence,
                              open(prompt_path).read() if os.path.exists(prompt_path) else "")
    print(f"resume check: {a.run_dir} from {prev_dir} on world {a.world}")
    print("\n".join(lines))
    print("problems:\n- " + "\n- ".join(problems) if problems else "carried over: ok")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
