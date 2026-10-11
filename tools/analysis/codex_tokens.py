#!/usr/bin/env python3
"""Codex rollout: per-step input/cached/output/reasoning tokens and step latency by 10-minute window.

Usage: codex_tokens.py FILE [END_UTC_ISO]
Step latency = token_count event time minus the previous tool output (or prompt) time, i.e. one model response.
"""
import datetime as dt, json, statistics, sys


def ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def main():
    path = sys.argv[1]
    end = ts(sys.argv[2]) if len(sys.argv) > 2 else None
    t0 = ready = None
    rows, types = [], {}
    for line in open(path):
        d = json.loads(line)
        t = ts(d["timestamp"])
        if end and t > end:
            break
        t0 = t0 or t
        p = d.get("payload") or {}
        key = f"{d['type']}/{p.get('type')}"
        types[key] = types.get(key, 0) + 1
        if key in ("response_item/custom_tool_call_output", "response_item/function_call_output", "event_msg/user_message"):
            ready = t
        if key == "event_msg/token_count" and p.get("info"):
            u = p["info"].get("last_token_usage") or {}
            rows.append(dict(t=t, lat=(t - ready) if ready else None, inp=u.get("input_tokens", 0),
                             cached=u.get("cached_input_tokens", 0), out=u.get("output_tokens", 0),
                             reason=u.get("reasoning_output_tokens", 0)))
    print({k: v for k, v in sorted(types.items()) if "compact" in k or "user" in k or "task" in k or "abort" in k})
    for i in range(0, 7):
        w = [r for r in rows if i * 600 <= r["t"] - t0 < (i + 1) * 600]
        if not w:
            continue
        lat = [r["lat"] for r in w if r["lat"] is not None and r["lat"] < 600]
        print(f"{i * 10:2d}-{i * 10 + 10}m steps={len(w):3d} lat_med={statistics.median(lat) if lat else 0:5.1f}s "
              f"in_med={statistics.median(r['inp'] for r in w) / 1000:5.0f}K cached%={100 * sum(r['cached'] for r in w) / max(1, sum(r['inp'] for r in w)):3.0f} "
              f"out_med={statistics.median(r['out'] for r in w):5.0f} out_p90={sorted(r['out'] for r in w)[int(.9 * len(w))]:5d} "
              f"reason_med={statistics.median(r['reason'] for r in w):4.0f}")


if __name__ == "__main__":
    main()
