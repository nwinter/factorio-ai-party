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
"""


def main():
    rows = moments.parse(MD)
    assert [m["n"] for m in rows] == [1, 3, 20] and rows[0]["theme"] == "Owning the mistake" and rows[2]["theme"] == "Friction"
    a, m3, g = rows
    assert (a["agents"], a["shift"], a["time"], a["title"]) == (["astra"], 7, "15:59 to 16:03", "four corrections in four minutes")
    # "tell to Gemini": the moment's agent speaks, to Gemini
    assert a["quotes"] == [{"who": "astra", "kind": "tell to Gemini, 16:00",
                            "text": "I just ran the actual Python sum and it prints900. You were right."}]
    assert a["seen"] == ["voiced", "private"] and a["fits"] == ["memo", "clip"] and a["context"].startswith("Astra told")
    assert m3["agents"] == ["gemini", "muse"] and [q["who"] for q in m3["quotes"]] == ["muse", "gemini"]
    assert m3["quotes"][0]["text"] == "That 2.1k EC is already spent... The drought is upstream iron, per astra."
    assert g["seen"] == ["chat", "private"] and g["fits"] == ["memo", "chat"]
    # the committed data parses from the committed document
    doc = (SITE.parent / "docs" / "studies" / "2026-10-13-agent-moments.md").read_text()
    assert json.loads((SITE / "content" / "moments.json").read_text()) == moments.parse(doc), "moments.json is stale: rerun site/moments.py"
    # the /chat/ highlights: newest shift first, quotes escaped and through clean(), who saw it
    tmp = SITE / "content" / "_test_moments.json"
    tmp.write_text(json.dumps(rows))
    try:
        loaded = highlights.load_moments(lambda s: s.replace("2.1k", "[n]"), tmp)
    finally:
        tmp.unlink()
    assert loaded[1]["quotes"][0]["text"].startswith("That [n] EC")
    names = {"astra": "Astra", "gemini": "Gemini", "muse": "Muse", "grok": "Grok"}
    sec = highlights.moments_section(loaded, lambda k: {"name": names[k]}, lambda s: html.escape(str(s), quote=True))
    assert sec.startswith('<section class="hl-highlights" id="highlights"><h2>Highlights<span class="h-sub">3 moments</span>')
    assert sec.index('id="m1"') < sec.index('id="m3"') < sec.index('id="m20"')  # shift 7 all, by number
    assert "Gemini, Muse · Shift 7 · 17:45 to 17:50 PDT" in sec
    assert "<cite>Astra · tell to Gemini, 16:00</cite>" in sec and "<script>" not in sec and "&lt;script&gt;" in sec
    assert '<p class="m-seen">Seen: <span class="voiced">On stream</span><span class="private">Private</span></p>' in sec
    assert highlights.moments_section([], None, None) == "" and highlights.load_moments(str, SITE / "content" / "none.json") == []
    print("moments: ok (the document as data, speakers and kinds, who saw it, /chat/ highlights)")


if __name__ == "__main__":
    main()
