#!/usr/bin/env python3
"""Run an interactive CLI under a pseudo-terminal for a while and print the text it drew (tools/profile-probe.sh).

  tools/tui-capture.py SECONDS [--keys-after S:KEYS ...] -- PROGRAM ARGS...

Headless probes miss first-run screens that only the TUI shows (smoke-l4g: Grok in a fresh GROK_HOME made no
requests). The screen text is printed with escape sequences stripped and repeated lines dropped. --keys-after S:KEYS
types KEYS (Python escapes, e.g. "\\r") S seconds after the start, to try answering a screen.
"""
import codecs
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time


def main():
    args = sys.argv[1:]
    secs = float(args.pop(0))
    keys = []
    while args and args[0] == "--keys-after":
        when, text = args[1].split(":", 1)
        keys.append((float(when), codecs.decode(text, "unicode_escape").encode()))
        args = args[2:]
    if args and args[0] == "--":
        args = args[1:]
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(args[0], args)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    buf, start = b"", time.time()
    while time.time() - start < secs:
        for when, text in list(keys):
            if time.time() - start >= when:
                os.write(fd, text)
                keys.remove((when, text))
        r, _, _ = select.select([fd], [], [], 0.3)
        if not r:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        if b"\x1b[6n" in chunk:   # cursor position query: answer so the TUI does not wait
            os.write(fd, b"\x1b[1;1R")
        if b"\x1b[c" in chunk or b"\x1b[0c" in chunk:
            os.write(fd, b"\x1b[?62;22c")
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass
    text = re.sub(rb"\x1b\[[0-9;?<>=]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[()][0-9A-Za-z]|\x1b[=>78]",
                  b"\n", buf)
    seen = []
    for line in text.decode("utf-8", "replace").splitlines():
        line = re.sub(r"\s{2,}", "  ", line).strip()
        if line and line not in seen:
            seen.append(line)
    print(f"tui: {len(buf)} bytes in {secs:.0f} s, {len(seen)} distinct lines")
    print("\n".join(seen[:60]))
    if len(seen) > 60:
        print("[...]")
        print("\n".join(seen[max(60, len(seen) - 60):]))


if __name__ == "__main__":
    main()
