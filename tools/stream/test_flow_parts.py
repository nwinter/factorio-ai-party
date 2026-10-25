#!/usr/bin/env python3
"""The stream's flows read in parts (d24 batch184 QAA2, operator-todo d24 09:55: FLOW_LUA about 10 ms on world n every
30 s; on a copy of world n's 18:11 save the surfaces took about 23 ms and table_to_json 34.6 ms for its 5.5 KB of float
counts). python3 tools/stream/test_flow_parts.py

- FLOW_LUA (run in a real Lua with mocked statistics when `lua` is installed): one part of the surfaces is read (the
  planets dealt out in turn, a platform by its index mod parts); each quality is summed as before; the reply's text
  holds each count rounded to a whole number.
- live.py: one part a poll, flow_every / 3 apart, so each part is read again every flow_every; the panel's flows are
  the parts' sum; the labs' use with the first part, every flow_every.
"""
import json, os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
sys.dont_write_bytecode = True
import harness  # noqa: E402
import live  # noqa: E402

MOCK = r"""
local function flowfor(per)
  return function(a)
    local id = a.name
    local key = type(id) == "table" and (id.name .. "@" .. id.quality) or id
    local v = per[key]
    if not v then return 0 end
    if a.precision_index == 1 then return v * 30 end
    return v + (a.sample_index or 0) / 100
  end
end
local function stats(per, totals, counts)
  return {input_counts = totals, get_input_count = function(id)
    local key = type(id) == "table" and (id.name .. "@" .. id.quality) or id
    return counts[key] or 0 end, get_flow_count = flowfor(per)}
end
local S = {
  {index = 1, planet = {}, st = stats({["iron-plate"] = 1.4}, {["iron-plate"] = 900}, {["iron-plate"] = 900})},
  {index = 2, st = stats({["iron-plate"] = 100}, {["iron-plate"] = 50}, {["iron-plate"] = 50})},
  {index = 3, planet = {}, st = stats({}, {}, {})},
  {index = 4, planet = {}, st = stats({["iron-plate"] = 2.2, ["iron-plate@rare"] = 0.6, ["copper-plate"] = 7}, {["iron-plate"] = 80, ["copper-plate"] = 5},
    {["iron-plate"] = 60, ["iron-plate@rare"] = 20, ["copper-plate"] = 5})},
}
local by = {}
for _, s in ipairs(S) do by[s] = s.st end
game = {forces = {player = {get_item_production_statistics = function(s) return by[s] end}}, surfaces = S}
prototypes = {quality = {normal = {}, rare = {}, ["quality-unknown"] = {hidden = true}}, item = {["iron-plate"] = {}, ["copper-plate"] = {}}}
defines = {flow_precision_index = {one_hour = 1, ten_hours = 2}}
helpers = {table_to_json = function() error("the reply is built as text, not by table_to_json") end}
rcon = {print = function(t) io.write(t) end}
"""


def lua_tests():
    if not shutil.which("lua"):
        print("flow parts: Lua part skipped (no lua)")
        return
    def run(part, parts):
        lua = harness.FLOW_LUA.replace("ITEMS", '{"iron-plate","copper-plate"}').replace("SPLIT", f"{parts}, {part}")
        r = subprocess.run(["lua", "-"], input=MOCK + harness.one_line(lua), capture_output=True, text=True, timeout=10)
        assert r.returncode == 0, r.stderr
        return json.loads(r.stdout)
    # planets 1, 3, 4 are the 1st, 2nd and 3rd planets: parts 0, 1, 2; platform 2 by its index: part 2. Bucket b of the
    # ten-hour samples (30 the oldest) is read into 31 - b
    two = run(2, 3)  # platform 2 (iron 100) and planet 4 (iron 2.2 normal and 0.6 rare, copper 7)
    assert sorted(two) == ["copper-plate", "iron-plate"], two
    assert len(two["iron-plate"]) == 30 and all(isinstance(c, int) for c in two["iron-plate"]), two
    assert two["iron-plate"][0] == round(100.30 + 2.2 + 0.30 + 0.6 + 0.30) == 104, two["iron-plate"]
    assert two["iron-plate"][29] == round(100.01 + 2.2 + 0.01 + 0.6 + 0.01) == 103, two["iron-plate"]
    assert two["copper-plate"][0] == 7, two  # 7.30
    zero = run(0, 3)  # planet 1 alone
    assert sorted(zero) == ["iron-plate"] and zero["iron-plate"][0] == 2 and zero["iron-plate"][29] == 1, zero  # 1.70, 1.41
    assert run(1, 3) == {}, run(1, 3)  # planet 3: nothing made there
    # one part of one: every surface, as the read was before (the same sums, rounded)
    whole = run(0, 1)
    assert whole["iron-plate"][0] == round(1.4 + 0.3 + 100.3 + 2.2 + 0.3 + 0.6 + 0.3), whole


class Fake:
    def __init__(self):
        self.calls = []

    def flows(self, items, part=0, parts=1):
        self.calls.append(("flows", part, parts))
        return {"iron-plate": [part + 1] * 30, f"only-{part}": [1] * 30}

    def used_flows(self, items):
        self.calls.append(("used",))
        return {"automation-science-pack": [4] * 30}


def poll_tests():
    src = live.LiveSource.__new__(live.LiveSource)  # the flows' fields alone (no harness, no run)
    src.h, src.flow_every, src.next_flow, src.flow_part, src.flow_parts = Fake(), 30.0, 0, 0, {}
    seen = []
    for t in range(0, 61, 5):
        obs, errors = {}, {}
        src.poll_flows(obs, errors, float(t))
        seen.append((t, obs.get("flows"), "used_flows" in obs))
        assert not errors, errors
    calls = src.h.calls
    # a part every 10 s: 0, 1, 2, 0, 1, 2, 0 at 0..60 s; the labs' use with part 0 only (every 30 s)
    assert [c for c in calls if c[0] == "flows"] == [("flows", p, 3) for p in (0, 1, 2, 0, 1, 2, 0)], calls
    assert sum(1 for c in calls if c[0] == "used") == 3, calls
    polled = [s for s in seen if s[1] is not None]
    assert [s[0] for s in polled] == [0, 10, 20, 30, 40, 50, 60], polled
    # the panel's flows: the parts' sum, each part's own items kept
    after = polled[2][1]
    assert after["iron-plate"] == [1 + 2 + 3] * 30 and after["only-0"] == [1] * 30 and after["only-2"] == [1] * 30, after
    assert [s[2] for s in polled] == [True, False, False, True, False, False, True], polled
    assert live.sum_flows([{"a": [1, 2]}, {"a": [3, 4], "b": [5, 5]}, None, {"c": "x"}]) == {"a": [4, 6], "b": [5, 5]}


def main():
    lua_tests()
    poll_tests()
    print("flow parts: ok (one part of the surfaces a read, counts as whole numbers in text, a part a poll every 10 s, "
          "the parts summed)")


if __name__ == "__main__":
    main()
