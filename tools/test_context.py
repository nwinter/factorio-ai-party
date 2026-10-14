#!/usr/bin/env python3
"""Offline checks for tools/context.py: generated settings and the hook flows. python3 tools/test_context.py"""
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CTX = os.path.join(ROOT, "tools", "context.py")
sys.path.insert(0, os.path.join(ROOT, "tools"))
import context  # noqa: E402


def run(*args, stdin=""):
    return subprocess.run([sys.executable, CTX, *args], input=stdin, capture_output=True, text=True, check=True).stdout


def transcript(path, tokens):
    usage = {"input_tokens": 10, "cache_creation_input_tokens": 1000, "cache_read_input_tokens": tokens - 1110,
             "output_tokens": 100}
    with open(path, "a") as f:
        f.write(json.dumps({"type": "user", "message": {"content": "x"}}) + "\n")
        f.write(json.dumps({"type": "assistant", "message": {"usage": usage}}) + "\n")


def log_events(d):
    return [json.loads(l)["event"] + ":" + str(json.loads(l).get("action", "")) for l in open(os.path.join(d, "context.log"))]


def main():
    # Claude Code fires at min(floor(E * pct / 100), E - 13000) with E = W - 20000.
    for at in (40000, 60000, 80000, 200000, 250000):
        w, pct = context.claude_window(at)
        e = w - 20000
        fire = min(e * int(pct) // 100, e - 13000) if pct else e - 13000
        assert w >= 100000 and fire == at, (at, w, pct, fire)

    with tempfile.TemporaryDirectory() as run_dir:
        d = os.path.join(run_dir, "haiku")
        os.mkdir(d)
        open(os.path.join(d, "notes.md"), "w").write("# Notes\n\n## Now\nGoal: smelting at -40,-20\n")
        assert run("setup", "claude", "haiku", d).strip() == ""
        cfg = json.load(open(os.path.join(d, ".claude", "settings.json")))
        assert cfg["autoCompactWindow"] == 113000 and "env" not in cfg
        tr = os.path.join(d, "t.jsonl")
        post = lambda: run("hook", "post-tool", "--at", "80000",
                           stdin=json.dumps({"cwd": d, "transcript_path": tr, "hook_event_name": "PostToolUse"}))
        transcript(tr, 50000)
        assert post() == "", "no nudge far from the threshold"
        transcript(tr, 70000)
        out = json.loads(post())["hookSpecificOutput"]
        assert out["hookEventName"] == "PostToolUse" and "Update notes.md" in out["additionalContext"]
        assert post() == "", "one nudge per context window"
        run("hook", "pre-compact", stdin=json.dumps({"cwd": d, "transcript_path": tr, "trigger": "auto"}))
        run("hook", "post-compact", stdin=json.dumps({"cwd": d, "transcript_path": tr, "trigger": "auto",
                                                      "compact_summary": "S1"}))
        text = run("hook", "session-compact", stdin=json.dumps({"cwd": d, "source": "compact"}))
        assert "just compacted" in text and "smelting at -40,-20" in text
        assert "S1" in open(os.path.join(d, "compactions.md")).read()
        assert post() == "", "Claude re-injects through SessionStart, not post-tool"
        transcript(tr, 62000)   # shake2: Haiku's context right after a compaction was 51-59K, above the old 60K warning
        assert post() == "", "no nudge in the first half of the room above the post-compaction floor"
        transcript(tr, 72000)
        assert "Update notes.md" in post(), "nudge re-arms after a compaction"
        assert log_events(d) == ["post-tool:nudge", "pre-compact:", "post-compact:", "session-compact:",
                                 "post-tool:nudge"], log_events(d)
        line = run("report", run_dir)
        assert line.startswith("haiku") and "compactions=1" in line and "reinjects=1" in line and "nudges=2" in line \
            and "tokens_at_compaction=[70000]" in line, line

    # No automatic compaction in the last 2 minutes (exit 2 blocks it in Claude Code), unless the context has run on
    # past the point; a manual one and an earlier one go ahead.
    import time
    with tempfile.TemporaryDirectory() as d:
        run("setup", "claude", "haiku", d)
        cmd = json.load(open(os.path.join(d, ".claude", "settings.json")))["hooks"]["PreCompact"][0]["hooks"][0]["command"]
        assert "--skip-late 120 --at 80000" in cmd, cmd
        tr = os.path.join(d, "t.jsonl")
        transcript(tr, 80500)
        pre = lambda trigger: subprocess.run([sys.executable, CTX, "hook", "pre-compact", "--skip-late", "120", "--at",
                                              "80000"], input=json.dumps({"cwd": d, "transcript_path": tr,
                                                                          "trigger": trigger}),
                                             capture_output=True, text=True).returncode
        deadline = lambda s: open(os.path.join(d, "deadline.txt"), "w").write(
            time.strftime("%Y-%m-%d %H:%M PDT", time.localtime(time.time() + s)))
        deadline(90)   # 30 to 90 s left
        assert pre("auto") == 2 and pre("manual") == 0
        transcript(tr, 90000)
        assert pre("auto") == 0, "past compact_at + LATE_ROOM it compacts rather than overflow"
        deadline(600)
        transcript(tr, 80500)
        assert pre("auto") == 0
        assert [e for e in log_events(d) if e.startswith("pre-compact")] == \
            ["pre-compact:skip-late", "pre-compact:", "pre-compact:", "pre-compact:"], log_events(d)

    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, "notes.md"), "w").write("x" * 20000)
        assert run("setup", "grok", "grok-4.7", d).strip() == "GROK_AUTO_COMPACT_THRESHOLD_PERCENT=60"
        hooks = json.load(open(os.path.join(ROOT, ".grok", "hooks", "context.json")))["hooks"]
        assert "--mark" in hooks["PostCompact"][0]["hooks"][0]["command"]
        run("hook", "post-compact", "--mark", stdin=json.dumps({"cwd": d, "trigger": "auto"}))
        ctx = json.loads(run("hook", "post-tool", stdin=json.dumps({"cwd": d})))["hookSpecificOutput"]["additionalContext"]
        # the post-compaction brief (fix 8 of docs/studies/2026-10-13-agent-minds.md), not the whole notes.md
        assert ctx.startswith("Your context was just compacted. A brief of at most 3 KB") and len(ctx) <= 3000, ctx[:300]
        assert "AGENTS.md is still loaded" not in ctx  # (Grok reads it as a file)
        assert run("hook", "post-tool", stdin=json.dumps({"cwd": d})) == "", "re-inject once"

    with tempfile.TemporaryDirectory() as d:   # the brief carries Now; the Log stays in notes.md
        log = "\n".join(f"- 1h{i:02d}m: event {i}" for i in range(39))
        open(os.path.join(d, "notes.md"), "w").write(f"# Notes\n\n## Now\nGoal: g\n\n## Log\n{log}\n")
        run("setup", "grok", "grok-4.7", d)
        run("hook", "post-compact", "--mark", stdin=json.dumps({"cwd": d, "trigger": "auto"}))
        ctx = json.loads(run("hook", "post-tool", stdin=json.dumps({"cwd": d})))["hookSpecificOutput"]["additionalContext"]
        assert "## Now (notes.md)\nGoal: g" in ctx and "event 38" not in ctx, ctx

    with tempfile.TemporaryDirectory() as d:   # the repo-wide Grok hooks also see sessions outside agent workspaces
        run("hook", "post-compact", "--mark", stdin=json.dumps({"cwd": d}))
        assert os.listdir(d) == [], "hooks do nothing without the setup marker"

    with tempfile.TemporaryDirectory() as d:
        run("setup", "codex", "gpt-6.1-sol", d)
        import tomllib
        cfg = tomllib.load(open(os.path.join(d, ".codex", "config.toml"), "rb"))
        assert cfg["model_context_window"] == 272000 and cfg["model_auto_compact_token_limit"] == 140000
        assert os.path.exists(cfg["experimental_compact_prompt_file"])
        # Muse applies the fractions to a 512K effective window (shake2 compacted at 0.191 x 512000 = 97,792).
        opts = run("setup", "muse", "muse-spark-1.3", d).split()
        assert "context_compaction.soft_threshold=0.391" in opts and "context_compaction.hard_threshold=0.441" in opts, opts
        hooks = json.load(open(os.path.join(d, ".muse", "hooks.json")))["hooks"]
        assert hooks["SessionStart"][0]["matcher"] == "compact"
    assert run("limit", "agy", "gemini-3.8-flash-high").strip() == "120000"  # 6397d59: 120k, turns capped at 300 s
    assert run("limit", "codex", "gpt-7-unknown").strip() == "140000", "kind fallback row"
    assert run("agy-tokens", "/nonexistent").strip() == "0"
    print("ok")


if __name__ == "__main__":
    main()
