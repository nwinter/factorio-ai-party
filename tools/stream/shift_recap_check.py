"""Local recap claim checks. No network; diagnostics retain the claim and its citations."""
from decimal import Decimal, InvalidOperation
import re

NUMBER = re.compile(r"\d+(?:,\d{3})*(?:\.\d+)?")
CLOCK = re.compile(r"\b\d+h\d+m\b|\b\d{1,2}:\d{2}(?::\d{2})?\b")
QUANTITY = r"(?:seconds?|minutes?|hours?|percent|launch\w*|hits?|kills?)\b"


def numbers(text, source_text=False):
    """Exact values, including written-out source quantities; never round or use a tolerance."""
    import caster
    # Clock components cannot license unrelated quantities. Clocks have their own exact check.
    text = CLOCK.sub(" ", text)
    found = []
    for m in NUMBER.finditer(text):
        try:
            found.append((m.group(), Decimal(m.group().replace(",", ""))))
        except InvalidOperation:
            pass
    # Agent records often join a written count to an uppercase abbreviation (sixMIL).
    words_text = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", text) if source_text else text
    for words, value in caster.spelled_numbers(words_text.lower()):
        # 'one of the ships' / 'the other one' are not count claims.
        if source_text or value != 1 or re.search(r"\b" + re.escape(words) + r"[ -]+" + QUANTITY, text.lower()):
            match = re.search(r"\b" + r"[ -]+".join(re.escape(w) for w in words.split()) + r"\b", words_text, re.I)
            found.append((match.group() if match else words, Decimal(value)))
    return found


def source(row):
    return {k: row.get(k) for k in ("id", "source", "row", "text", "game_time", "wall_time")}


def facts(row):
    return " ".join(str(row.get(k) or "") for k in ("text", "game_time", "wall_time"))


def issues(lines, evidence, clean):
    """All failures, indexed by 1-based line. A single failure never poisons other lines."""
    by_id = {r["id"]: r for r in evidence["rows"]}
    failures = []
    if not isinstance(lines, list) or not 1 <= len(lines) <= 40:
        return [{"line": None, "reason": "expected 1..40 lines", "claim": lines}]
    for index, line in enumerate(lines, 1):
        refs = line.get("sources") if isinstance(line, dict) else None
        cited = [by_id[x] for x in refs if isinstance(x, str) and x in by_id] if isinstance(refs, list) else []

        def fail(reason, field="text", claim=None, **extra):
            failures.append({"line": index, "field": field, "reason": reason,
                             "claim": claim if claim is not None else line,
                             "sources": [source(r) for r in cited], **extra})

        if not isinstance(line, dict) or line.get("speaker") not in ("Rook", "Vale"):
            fail("unknown speaker")
            continue
        if not isinstance(refs, list) or not refs or len(cited) != len(refs):
            fail("unknown or missing source")
            continue
        text, title = line.get("text"), line.get("title")
        if not isinstance(text, str) or not text.strip() or len(text) > 1800 or not isinstance(title, str) or len(title) > 80:
            fail("invalid text or title")
            continue
        known = {value for r in cited for _, value in numbers(r["text"], source_text=True)}
        cited_facts = " ".join(facts(r) for r in cited)
        for field, claim in (("text", text), ("title", title)):
            if clean(claim) != " ".join(claim.split()):
                fail("private or overlong text", field, claim)
                continue
            for clock in CLOCK.findall(claim):
                if clock not in cited_facts:
                    fail("time absent from cited record", field, claim, number=clock)
            # The record's run label establishes its shift number, only in that context.
            run_number = re.fullmatch(r"shift(\d+)", str(evidence.get("run", "")))
            numeric_claim = claim
            if run_number:
                numeric_claim = re.sub(r"\bshift[ -]+" + run_number[1] + r"\b", "this shift", claim, flags=re.I)
            for token, value in numbers(numeric_claim):
                if value not in known:
                    elsewhere = [source(r) for r in evidence["rows"] if r["id"] not in refs
                                 and value in {v for _, v in numbers(r["text"], source_text=True)}][:8]
                    fail("number absent from cited record", field, claim,
                         number=token, value=str(value), known_numbers=sorted(str(v) for v in known),
                         uncited_matches=elsewhere)
            if evidence.get("partial") and re.search(r"\bshift (?:ends?|closes?|finished|ended)\b|\bend of (?:the |this )?shift\b", claim, re.I):
                fail("early preparation presented as the shift's end", field, claim)
    return failures
