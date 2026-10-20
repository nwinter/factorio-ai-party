"""The stream service's harness client reads board_focus (no arguments) and refuses its writing form (d20 operator fix:
batch54 N3's job cards found no focus rows on world n because board_focus was not an allowed read)."""
import harness


class Fake(harness.Harness):
    def __init__(self):
        self.sent = []

    def command(self, cmd):
        self.sent.append(cmd)
        return '{"ok": true, "result": {"rows": [], "tick": 5}, "tick": 5}'


def main():
    h = Fake()
    res, tick = h.dispatch("board_focus", {"peek": True}, bot="astra")
    assert res == {"rows": [], "tick": 5} and tick == 5, res
    assert len(h.sent) == 1 and "board_focus" in h.sent[0]
    for bad in ({"id": 12}, {"id": 12, "peek": True}, {"step": "x"}):
        try:
            h.dispatch("board_focus", bad, bot="astra")
        except ValueError:
            pass
        else:
            raise AssertionError(f"board_focus {bad} was sent")
    assert len(h.sent) == 1
    try:
        h.dispatch("board_post", {}, bot="astra")
    except ValueError:
        pass
    else:
        raise AssertionError("board_post was sent")
    print("ok")


if __name__ == "__main__":
    main()
