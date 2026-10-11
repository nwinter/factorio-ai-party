"""One vote mechanism for the agents' votes on human players and the viewers' mute votes.

Callers keep the ballots and say who may vote; this module decides. A vote carries once the yes ballots of eligible
voters are more than half the electorate (and at least `min_yes`), fails once the no ballots are, and expires at its
deadline otherwise. Ballots of voters outside the electorate (no longer active) do not count.

- Agents (tools/players.py): ballots live in the game (the harness `vote` action, players.lua); the electorate is
  the agents active in the last 10 minutes (operator `votes_open`); time is game ticks. RULES["agents"].
- Viewers (tools/stream/viewers.py, the mute vote): `Book` keeps ballots in memory and `Activity` remembers who
  chatted lately; the electorate is the viewers active in the window; time is seconds. RULES["viewers"].

    book, seen = Book(RULES["viewers"]), Activity(RULES["viewers"].window)
    seen.saw("bob", now); seen.saw("ann", now)
    book.cast("bob", "mute", "spammer9", now, reason="spam")
    for vote, result in book.decide(seen.active(now), now):
        ...  # result["outcome"] is carried, failed or expired; act on carried
"""
from dataclasses import dataclass, field


@dataclass(frozen=True)
class Rule:
    window: float          # how long a vote stays open, and how recent counts as active (the caller's time unit)
    min_yes: int = 1       # never fewer yes ballots than this
    min_electorate: int = 1


RULES = {
    "agents": Rule(window=10 * 60 * 60),            # game ticks: 10 minutes
    "viewers": Rule(window=10 * 60, min_yes=3, min_electorate=3),  # seconds
}


def needed(electorate, rule):
    """Yes ballots that carry a vote: more than half the electorate, at least rule.min_yes."""
    return max(rule.min_yes, electorate // 2 + 1)


def tally(ballots, electorate, now, deadline, rule):
    """ballots {voter: True|False}; electorate: the voters eligible now. Returns {outcome: carried|failed|expired|open,
    yes, no (sorted eligible voters), electorate (count), needed}."""
    eligible = set(electorate)
    yes = sorted(v for v, b in ballots.items() if b and v in eligible)
    no = sorted(v for v, b in ballots.items() if not b and v in eligible)
    n = len(eligible)
    need = needed(n, rule)
    if n >= rule.min_electorate and len(yes) >= need:
        outcome = "carried"
    elif len(no) >= need:
        outcome = "failed"
    elif now >= deadline:
        outcome = "expired"
    else:
        outcome = "open"
    return {"outcome": outcome, "yes": yes, "no": no, "electorate": n, "needed": need}


def describe(result):
    """One line for chat, the stream and logs: '3 yes, 1 no of 5 active; 3 needed'."""
    return f"{len(result['yes'])} yes, {len(result['no'])} no of {result['electorate']} active; {result['needed']} needed"


class Activity:
    """Who was active within `window` of now (viewers who chatted)."""

    def __init__(self, window):
        self.window = window
        self.last = {}

    def saw(self, who, now):
        self.last[who] = now

    def active(self, now):
        for who in [w for w, t in self.last.items() if now - t > self.window]:
            del self.last[who]
        return set(self.last)


@dataclass
class Vote:
    id: int
    kind: str
    target: str
    reason: str
    opened_by: str
    opened: float
    deadline: float
    ballots: dict = field(default_factory=dict)
    result: dict = None


class Book:
    """Votes kept in memory, for callers without their own store (the viewers' mute vote). One open vote per kind and
    target; a voter's later ballot replaces their earlier one."""

    def __init__(self, rule):
        self.rule = rule
        self.votes = []
        self.seq = 0

    def open_vote(self, kind, target):
        return next((v for v in self.votes if v.result is None and v.kind == kind and v.target == target), None)

    def cast(self, voter, kind, target, now, yes=True, reason=""):
        """Returns the vote, or None for a no ballot with no open vote to oppose."""
        vote = self.open_vote(kind, target)
        if vote is None:
            if not yes:
                return None
            self.seq += 1
            vote = Vote(self.seq, kind, target, reason, voter, now, now + self.rule.window)
            self.votes.append(vote)
            self.votes = [v for v in self.votes if v.result is None] + [v for v in self.votes if v.result is not None][-50:]
        vote.ballots[voter] = yes
        return vote

    def decide(self, electorate, now):
        """Close the votes that are decided; returns [(vote, result)] for them."""
        out = []
        for vote in self.votes:
            if vote.result is None:
                result = tally(vote.ballots, electorate, now, vote.deadline, self.rule)
                if result["outcome"] != "open":
                    vote.result = result
                    out.append((vote, result))
        return out
