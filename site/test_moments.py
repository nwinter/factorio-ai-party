"""site/moments.py: the moments document as data (speakers, kinds, who saw it, where it fits), and the /chat/ page's
highlights from it (site/highlights.py). Run: python3 site/test_moments.py"""
import html, json, sys
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE))
sys.dont_write_bytecode = True
import highlights, moments  # noqa: E402

MD = """# Moments

## 1. Owning the mistake

**1. Astra, shift07, 15:59 to 16:03: four corrections in four minutes**
- Quote (tell to Gemini, 16:00): "I just ran the actual Python sum and it prints900. You were right."
- Context: Astra told Gemini the kit was 1080 kg.
- Seen: private (tells), the research retraction was voiced. Fits: clip, memo.

**3. Muse and Gemini, shift07, 17:45 to 17:50: the 2,187 circuits in Muse's pocket**
- Quote (Muse, tell 17:45): "That 2.1k EC is already spent... The drought is upstream iron, per astra."
- Quote (Gemini, thought 17:47): "Muse's inventory shows 2,187 electronic circuits."
- Seen: private, except Gemini's hype line (voiced). Fits: clip, memo.

## 2. Friction

**20. Grok, shift07, 16:48 to 16:56: the whitelist**
- Quote (confession 16:56): "The green line was never short of machines <script>"
- Seen: thought private, confession on /chat/. Fits: /chat/, memo.

**18. Sonnet, shift07, 16:58: "Fair criticism."**
- Quote (working text): "Fair criticism. I'll read chat and status now."
- Quote (voiced): "fair point, I was stuck in a courier loop. Now checking chat each cycle."
- Context: a viewer had asked twice why Sonnet just waits.
- Seen: working text private, reply voiced. Fits: /chat/, memo.

**25. Opus and Gemini, shift05 10:32 / shift06 11:09: the same refinery bug, found twice**
- Quote (Opus, chat 10:32): "Heads up for next shift: refineries are full_output again."
- Quote (Gemini, thought 11:09): "This solid fuel backup is the root cause."
- Seen: Opus chat, Gemini private. Fits: memo.
"""


def main():
    rows = moments.parse(MD)
    assert [m["n"] for m in rows] == [1, 3, 20, 18, 25] and rows[0]["theme"] == "Owning the mistake" and rows[2]["theme"] == "Friction"
    a, m3, g = rows[:3]
    assert (a["agents"], a["shift"], a["time"], a["title"]) == (["astra"], 7, "15:59 to 16:03", "four corrections in four minutes")
    # "tell to Gemini": the moment's agent speaks, to Gemini
    assert a["quotes"] == [{"who": "astra", "kind": "tell to Gemini, 16:00",
                            "text": "I just ran the actual Python sum and it prints900. You were right."}]
    assert a["seen"] == ["voiced", "private"] and a["fits"] == ["memo", "clip"] and a["context"].startswith("Astra told")
    assert m3["agents"] == ["gemini", "muse"] and [q["who"] for q in m3["quotes"]] == ["muse", "gemini"]
    assert m3["quotes"][0]["text"] == "That 2.1k EC is already spent... The drought is upstream iron, per astra."
    assert g["seen"] == ["chat", "private"] and g["fits"] == ["memo", "chat"]

    # Only what viewers saw leaves the study (operator, 2026-10-13): voiced, chat and confession quotes; a moment with
    # none goes (#1: a private tell; #3: tells and thoughts); one whose agent said nothing public goes (#25: Gemini's
    # rediscovery was a thought); the time comes from the kept quotes; a title quoting unseen words is replaced (#18);
    # no context lines.
    pub = moments.seen_only(rows)
    assert [m["n"] for m in pub] == [20, 18], pub
    g2, s2 = pub
    assert g2["time"] == "16:56" and g2["seen"] == ["chat"] and "context" not in g2 and "theme" not in g2
    assert [q["kind"] for q in s2["quotes"]] == ["voiced"] and s2["seen"] == ["voiced"] and s2["agents"] == ["sonnet"]
    assert s2["title"] == "fair point, I was stuck in ..." and "Fair criticism" not in json.dumps(s2)
    # the committed data is the public part of the committed document
    doc = (SITE.parent / "docs" / "studies" / "2026-10-13-agent-moments.md").read_text()
    data = json.loads((SITE / "content" / "moments.json").read_text())
    assert data == moments.seen_only(moments.parse(doc)), "moments.json is stale: rerun site/moments.py"
    kinds = [q["kind"] for m in data for q in m["quotes"]]
    assert kinds and all(moments.PUBLIC.search(k.lower()) for k in kinds) and not any("context" in m for m in data)
    # the /chat/ highlights: newest shift first, quotes escaped and through clean(), who saw it; a private quote that
    # reached the file anyway is skipped
    leak = dict(pub[0], n=99, shift=8, quotes=[{"who": "grok", "kind": "thought", "text": "private"}])
    mixed = dict(pub[1], quotes=pub[1]["quotes"] + [{"who": "sonnet", "kind": "working text", "text": "not seen"}])
    tmp = SITE / "content" / "_test_moments.json"
    tmp.write_text(json.dumps([pub[0], mixed, leak]))
    try:
        loaded = highlights.load_moments(lambda s: s.replace("courier", "[c]"), tmp)
    finally:
        tmp.unlink()
    assert [m["n"] for m in loaded] == [20, 18] and [q["text"] for q in loaded[1]["quotes"]] == [
        "fair point, I was stuck in a [c] loop. Now checking chat each cycle."]
    names = {"grok": "Grok", "sonnet": "Sonnet"}
    sec = highlights.moments_section(loaded, lambda k: {"name": names[k]}, lambda s: html.escape(str(s), quote=True))
    assert sec.startswith('<section class="hl-highlights" id="highlights"><h2>Highlights<span class="h-sub">2 moments</span>')
    assert sec.index('id="m18"') < sec.index('id="m20"')  # shift 7 both, by number
    assert "Grok · Shift 7 · 16:56 PDT" in sec and "<h3>The whitelist</h3>" in sec
    assert "<cite>Grok · confession 16:56</cite>" in sec and "<script>" not in sec and "&lt;script&gt;" in sec
    assert '<p class="m-seen">Seen: <span class="voiced">On stream</span></p>' in sec and "Private" not in sec
    assert highlights.moments_section([], None, None) == "" and highlights.load_moments(str, SITE / "content" / "none.json") == []
    print("moments: ok (the document as data, speakers and kinds, who saw it, /chat/ highlights)")


if __name__ == "__main__":
    main()
