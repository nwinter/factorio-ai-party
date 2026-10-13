#!/usr/bin/env python3
"""Viewer lines deleted on YouTube or listed by hand stay off the site: python3 site/test_moderation.py

- a deletion by id hides that viewer's line, also as relayed ("@agent " in front, or trimmed with "…");
- a deletion by author hides every line by that name, in every shift; another viewer's same words stay;
- site/hidden-viewers.json: a name hides all its lines, a text hides that line from anyone;
- the build: the shift page loses the lines (and its viewer count), the agents' answers stay, check.py passes.
"""
import json, os, subprocess, sys, tempfile
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE))
import moderation  # noqa: E402
import test_longrun  # noqa: E402  (its made-up shifts: s1, s2 that did not start, s3)


def main():
    with tempfile.TemporaryDirectory() as d:
        root = Path(d) / "runs"
        root.mkdir()
        (root / "a").mkdir()
        (root / "b").mkdir()
        (root / "a" / "viewer-deletions.jsonl").write_text(
            json.dumps({"t": 1, "kind": "id", "ident": "yt:1", "source": "youtube", "name": "Fan One",
                        "texts": ["build more turrets near the north wall please"]}) + "\n" + "not json\n")
        (root / "b" / "viewer-deletions.jsonl").write_text(
            json.dumps({"t": 2, "kind": "author", "ident": "yt:abc", "source": "youtube", "name": "rudebob",
                        "texts": ["first rude line"]}) + "\n")
        manual = Path(d) / "hidden.json"
        manual.write_text(json.dumps({"names": ["@Spammy"], "texts": ["buy cheap coins"]}))
        h = moderation.load(root, manual)
        assert h.hides("Fan One", "build more turrets near the north wall please")
        assert h.hides("fan one", "@astra build more turrets near the north wall please"), "the relay's @prefix"
        assert h.hides("Fan One", "@astra @sol Build more turrets near the north…"), "trimmed by the relay"
        assert not h.hides("Fan One", "something else"), "only the deleted line of an id deletion"
        assert not h.hides("Someone", "build more turrets near the north wall please"), "another viewer's same words"
        assert h.hides("RudeBob", "anything at all") and h.hides("rudebob", "a later line"), "an author: every line"
        assert h.hides("spammy", "hello") and h.hides("Anyone", "Buy cheap coins"), "the manual list"
        assert not moderation.load(Path(d) / "none", Path(d) / "missing.json"), "nothing to hide"

        # the build: the made-up long run's viewer line "@sonnet build turrets?" (fan_1), deleted by id
        runs = Path(d) / "lr"
        runs.mkdir()
        test_longrun.make(runs)
        (runs / "s1" / "viewer-deletions.jsonl").write_text(json.dumps(
            {"t": 3, "kind": "id", "ident": "yt:9", "source": "youtube", "name": "fan_1", "texts": ["build turrets?"]}) + "\n")
        content = json.loads((SITE / "content" / "site.json").read_text())
        content.pop("run_start", None)
        (Path(d) / "site.json").write_text(json.dumps(content))
        out = Path(d) / "dist"
        env = dict(os.environ, POG_HIDDEN_VIEWERS=str(Path(d) / "empty.json"), POG_OG_SHIFTS=str(Path(d) / "og"))
        subprocess.run([sys.executable, str(SITE / "build.py"), "--out", str(out), "--runs-dir", str(runs),
                        "--content", str(Path(d) / "site.json")], check=True, capture_output=True, env=env)
        r = subprocess.run([sys.executable, str(SITE / "check.py"), str(out)], capture_output=True, text=True)
        assert r.returncode == 0, r.stdout
        sp = (out / "runs" / "long" / "shift-1" / "index.html").read_text()
        assert "build turrets?" not in sp and "fan_1</span>" not in sp, "the deleted viewer line is gone"
        assert "two turrets going up now" in sp, "the agent's own answer stays"
        # the manual list hides by name the same way
        (Path(d) / "list.json").write_text(json.dumps({"names": ["FAN_1"], "texts": []}))
        (runs / "s1" / "viewer-deletions.jsonl").unlink()
        env["POG_HIDDEN_VIEWERS"] = str(Path(d) / "list.json")
        subprocess.run([sys.executable, str(SITE / "build.py"), "--out", str(out), "--runs-dir", str(runs),
                        "--content", str(Path(d) / "site.json")], check=True, capture_output=True, env=env)
        sp = (out / "runs" / "long" / "shift-1" / "index.html").read_text()
        assert "build turrets?" not in sp
        env["POG_HIDDEN_VIEWERS"] = str(Path(d) / "empty.json")  # and without either, the line shows
        subprocess.run([sys.executable, str(SITE / "build.py"), "--out", str(out), "--runs-dir", str(runs),
                        "--content", str(Path(d) / "site.json")], check=True, capture_output=True, env=env)
        sp = (out / "runs" / "long" / "shift-1" / "index.html").read_text()
        assert "build turrets?" in sp and "two turrets going up now" in sp
    print("moderation: ok (by id with the relay's @prefix and trim, by author in every shift, the manual list, the build)")


if __name__ == "__main__":
    main()
