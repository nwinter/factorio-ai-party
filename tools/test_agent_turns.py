#!/usr/bin/env python3
"""tools/agent_turns.py on made-up session logs, no real ones read: python3 tools/test_agent_turns.py

d27 batch275 HW: a Claude Code transcript (a 900 s Bash call, a short one, a compaction, a thinking block) and a Codex
rollout (two quick exec calls, a reasoning item, a compaction) give the steps, the hours inside calls of 5+ minutes,
the waits and the turns as the logs hold them.
"""
import io, json, os, shutil, sys, tempfile
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agent_turns as T  # noqa: E402


def w(path, rows):
    with open(path, "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")


def main():
    d = tempfile.mkdtemp()
    try:
        claude = os.path.join(d, "claude", f"{T.REPO}-runs-shift90-opus")
        os.makedirs(claude)
        w(os.path.join(claude, "s.jsonl"), [
            {"type": "user", "timestamp": "2026-10-28T10:00:00Z", "message": {"role": "user", "content": "Read AGENTS.md"}},
            {"type": "assistant", "timestamp": "2026-10-28T10:00:05Z", "message": {"usage": {"output_tokens": 40}, "content": [
                {"type": "thinking", "thinking": ""},
                {"type": "tool_use", "id": "a", "name": "Bash", "input": {"command": "./fh call status"}}]}},
            {"type": "user", "timestamp": "2026-10-28T10:00:07Z", "message": {"content": [{"type": "tool_result", "tool_use_id": "a", "content": "ok"}]}},
            {"type": "assistant", "timestamp": "2026-10-28T10:00:10Z", "message": {"usage": {"output_tokens": 20}, "content": [
                {"type": "text", "text": "Waiting."},
                {"type": "tool_use", "id": "b", "name": "Bash", "input": {"command": "./fh wait --until tell --max 900"}}]}},
            {"type": "user", "timestamp": "2026-10-28T10:15:10Z", "message": {"content": [{"type": "tool_result", "tool_use_id": "b", "content": "woke"}]}},
            {"type": "user", "timestamp": "2026-10-28T10:20:00Z", "isCompactSummary": True, "message": {"content": "summary"}},
        ])
        codex = os.path.join(d, "codex", "sessions", "2026", "10", "28")
        os.makedirs(codex)
        w(os.path.join(codex, "rollout-x.jsonl"), [
            {"timestamp": "2026-10-28T10:00:00Z", "type": "session_meta", "payload": {"cwd": "/x/runs/shift90/astra"}},
            {"timestamp": "2026-10-28T10:00:00Z", "type": "event_msg", "payload": {"type": "task_started"}},
            {"timestamp": "2026-10-28T10:00:01Z", "type": "response_item", "payload": {"type": "reasoning"}},
            {"timestamp": "2026-10-28T10:00:02Z", "type": "response_item", "payload": {"type": "custom_tool_call", "call_id": "1", "name": "exec", "input": "./fh sleep 50"}},
            {"timestamp": "2026-10-28T10:00:03Z", "type": "response_item", "payload": {"type": "custom_tool_call_output", "call_id": "1"}},
            {"timestamp": "2026-10-28T10:00:04Z", "type": "response_item", "payload": {"type": "custom_tool_call", "call_id": "2", "name": "exec", "input": "./fh call board"}},
            {"timestamp": "2026-10-28T10:00:05Z", "type": "response_item", "payload": {"type": "custom_tool_call_output", "call_id": "2"}},
            {"timestamp": "2026-10-28T10:30:00Z", "type": "compacted", "payload": {}},
            {"timestamp": "2026-10-28T11:00:00Z", "type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {"output_tokens": 900}}}},
        ])
        T.CLAUDE_PROJECTS, T.CODEX_HOMES = os.path.join(d, "claude"), os.path.join(d, "codex")
        buf = io.StringIO()
        with redirect_stdout(buf):
            T.main(["--shifts", "90", "--agents", "astra,opus", "--calls", os.path.join(d, "calls")])
        rows = {r.split("\t")[0]: dict(zip(T.HEAD, r.split("\t"))) for r in buf.getvalue().splitlines()[1:]}
        o, a = rows["opus"], rows["astra"]
        assert (o["steps"], o["calls_5min"], o["h_in_5min"], o["waits"], o["turns"], o["compacts"], o["thinking"], o["texts"],
                o["out_tok"]) == ("2", "1", "0.25", "1", "1", "1", "1", "1", "60"), o
        assert (a["steps"], a["calls_5min"], a["waits"], a["turns"], a["compacts"], a["thinking"], a["out_tok"], a["hours"]) == \
            ("2", "0", "1", "1", "1", "1", "900", "1.0"), a
        lines = open(os.path.join(d, "calls", "calls-opus-90.tsv")).read().splitlines()
        assert lines[1] == "10:00:10\t900\tBash ./fh wait --until tell --max 900", lines
        print("agent_turns: ok")
    finally:
        shutil.rmtree(d)


if __name__ == "__main__":
    main()
