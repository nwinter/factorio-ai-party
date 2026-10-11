#!/usr/bin/env python3
"""Per-step timing and context size from Codex rollouts and Claude Code session logs.

Usage: transcript_steps.py codex|claude FILE [END_UTC_ISO]
A "step" is one model call that ends in tool calls. For each step: think = time from the last tool result (or user
prompt) to the model's first tool call; exec = time from that call to its result. Prints totals, medians, p90, the
number of ./fh invocations inside the shell commands, the context size per step (input tokens incl. cache), and
compactions.
"""
import datetime as dt, json, re, statistics, sys


def ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def pct(xs, q):
    xs = sorted(xs)
    return round(xs[min(len(xs) - 1, int(q * len(xs)))], 1) if xs else None


def codex(path, end):
    events = []  # (t, kind, data)
    for line in open(path):
        d = json.loads(line)
        t = ts(d["timestamp"])
        if end and t > end:
            break
        p = d.get("payload") or {}
        typ = (d["type"], p.get("type"))
        if typ in {("response_item", "custom_tool_call"), ("response_item", "function_call")}:
            events.append((t, "call", p.get("input") or p.get("arguments") or ""))
        elif typ in {("response_item", "custom_tool_call_output"), ("response_item", "function_call_output")}:
            out = p.get("output")
            text = out if isinstance(out, str) else "".join(o.get("text", "") for o in out or [])
            events.append((t, "result", text))
        elif typ == ("event_msg", "token_count") and p.get("info"):
            last = p["info"].get("last_token_usage") or {}
            events.append((t, "tokens", last.get("input_tokens", 0)))
        elif typ == ("event_msg", "user_message") or (typ == ("response_item", "message") and p.get("role") == "user"):
            events.append((t, "user", ""))
        elif "compact" in str(typ[0]) + str(typ[1]):
            events.append((t, "compact", ""))
    return events


def claude(path, end):
    events = []
    seen = set()
    for line in open(path):
        d = json.loads(line)
        if "timestamp" not in d:
            continue
        t = ts(d["timestamp"])
        if end and t > end:
            break
        if d.get("type") == "system" and d.get("subtype") == "compact_boundary":
            events.append((t, "compact", ""))
        msg = d.get("message") or {}
        content = msg.get("content")
        if d.get("type") == "assistant":
            u = msg.get("usage") or {}
            mid = msg.get("id")
            if mid not in seen and u:
                seen.add(mid)
                events.append((t, "tokens", u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) + u.get("cache_creation_input_tokens", 0)))
            for c in content or []:
                if c.get("type") == "tool_use":
                    events.append((t, "call", json.dumps(c.get("input"))))
        elif d.get("type") == "user":
            if isinstance(content, str):
                events.append((t, "user", content))
            else:
                for c in content or []:
                    if c.get("type") == "tool_result":
                        cc = c.get("content")
                        text = cc if isinstance(cc, str) else "".join(x.get("text", "") for x in cc or [] if isinstance(x, dict))
                        events.append((t, "result", text))
                    elif c.get("type") == "text" and not d.get("isMeta"):
                        events.append((t, "user", c.get("text", "")))
    return events


def main():
    kind, path = sys.argv[1], sys.argv[2]
    end = ts(sys.argv[3]) if len(sys.argv) > 3 else None
    events = (codex if kind == "codex" else claude)(path, end)
    think, execs, outs, fh, ctx = [], [], [], 0, []
    last_ready = None  # when the model last got new input
    pending = []
    calls = 0
    for t, k, data in events:
        if k in ("user", "result"):
            if k == "result" and pending:
                execs.append(t - pending.pop(0))
                outs.append(len(data))
            last_ready = t
        elif k == "call":
            calls += 1
            fh += len(re.findall(r"\./fh\b", data))
            if last_ready is not None:
                think.append(t - last_ready)
                last_ready = None
            pending.append(t)
        elif k == "tokens":
            ctx.append((t, data))
    span = events[-1][0] - events[0][0]
    peak = max(ctx, key=lambda x: x[1]) if ctx else (0, 0)
    comp = [t for t, k, _ in events if k == "compact"]
    res = dict(
        span_min=round(span / 60, 1), tool_calls=calls, fh_invocations=fh, model_steps=len(think),
        think_total_min=round(sum(think) / 60, 1), think_median_s=pct(think, 0.5), think_p90_s=pct(think, 0.9),
        exec_total_min=round(sum(execs) / 60, 1), exec_median_s=pct(execs, 0.5), exec_p90_s=pct(execs, 0.9),
        exec_over_30s=sum(1 for e in execs if e > 30), out_chars_total=sum(outs), out_chars_median=pct(outs, 0.5),
        out_chars_p90=pct(outs, 0.9), out_chars_max=max(outs) if outs else 0,
        ctx_first=ctx[0][1] if ctx else None, ctx_peak=peak[1],
        ctx_peak_at=dt.datetime.fromtimestamp(peak[0], dt.timezone(dt.timedelta(hours=-7))).strftime("%H:%M") if ctx else None,
        ctx_last=ctx[-1][1] if ctx else None, compactions=len(comp),
        user_prompts=sum(1 for _, k, _ in events if k == "user"),
    )
    print(json.dumps(res))
    # Think time and context per 10-minute window: does latency grow with context?
    t0, win, last = events[0][0], {}, None
    for t, k, data in events:
        w = win.setdefault(int((t - t0) // 600), {"think": [], "ctx": []})
        if k == "tokens":
            w["ctx"].append(data)
        elif k in ("user", "result"):
            last = t
        elif k == "call" and last is not None:
            w["think"].append(t - last)
            last = None
    print("  " + " | ".join(f"{i * 10}-{i * 10 + 10}m n={len(v['think'])} think med {statistics.median(v['think']):.1f}s "
                            f"sum {sum(v['think']) / 60:.1f}m ctx {max(v['ctx'] or [0]) // 1000}K"
                            for i, v in sorted(win.items()) if v["think"]))


if __name__ == "__main__":
    main()
