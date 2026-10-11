#!/usr/bin/env python3
"""PreToolUse hook for game workspaces: pre-approve shell commands built only from game-safe parts.

Claude Code's dontAsk mode denied `for x in ...; do ./fh call transfer --args "{...$x...}"; done` 12 times in shake2
(docs/studies/shake2.md, section 3) although every part matched the allowlist, and Haiku stopped playing over it.
This hook answers "allow" when every simple command in the line starts with an allowed program, the only shell
syntax is lists, pipes, loops and conditionals over those commands, variables are plain `$name`/`${name}`, and
redirects go to /dev/null or to relative paths inside the workspace. Anything else (command substitution, heredocs,
absolute or parent paths, other programs) gets no answer, so the normal permission rules decide. Commands still run
in Claude Code's sandbox.

  tools/permit.py            reads the hook payload on stdin, prints the decision JSON or nothing
  tools/permit.py --check CMD    prints allow or pass (tests)
"""
import json
import re
import shlex
import sys

PROGRAMS = {"./fh", "./shot", "sleep", "echo", "printf", "date", "cat", "grep", "head", "tail", "python3", "jq",
            "wc", "sort", "uniq", "rg", "ls", "true", "false", "test", "["}
KEYWORDS = {"do", "done", "then", "else", "fi", "!", "{", "}"}
CONTROL = {";", "&&", "||", "|", "&", "(", ")", ";;"}
REDIRECTS = {">", ">>", "<", ">&", "&>", ">|", "&>>", "<>"}
FORBIDDEN = ("$(", "`", "<(", ">(", "<<", "\\\n")
NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*$")
# $name, ${name}, $1, $@ are fine; ${name:-...} and other expansions are not.
BAD_EXPANSION = re.compile(r"\$\{(?![A-Za-z_][A-Za-z0-9_]*\})|\$[^A-Za-z0-9_@{]")


def safe_path(word):
    return word == "/dev/null" or word.isdigit() or not (word.startswith(("/", "~")) or ".." in word.split("/"))


def decide(command):
    if any(s in command for s in FORBIDDEN) or BAD_EXPANSION.search(command):
        return False
    lex = shlex.shlex(command.replace("\n", " ; "), posix=True, punctuation_chars=";&|<>()")
    lex.whitespace_split = True
    try:
        tokens = list(lex)
    except ValueError:
        return False
    start, in_for, expect_target = True, False, False
    for tok in tokens:
        if expect_target:
            if not safe_path(tok):
                return False
            expect_target = False
            continue
        if tok in CONTROL:
            start, in_for = True, False
            continue
        if tok in REDIRECTS:
            expect_target = True
            continue
        if re.fullmatch(r"\d*(>>?|<|>&|&>)", tok):   # 2>, 1>> (shlex keeps a leading fd digit apart)
            expect_target = True
            continue
        if in_for:
            continue   # the loop's word list is data
        if start:
            if tok in KEYWORDS:
                continue
            if tok in ("while", "until", "if", "elif"):
                continue   # the condition is a command and is checked as one
            if tok == "for":
                in_for = True
                continue
            if tok not in PROGRAMS:
                return False
            start = False
        elif tok.startswith(("/", "~")) and tok != "/dev/null":
            return False   # absolute or home paths as arguments: leave those to the normal rules
    return not expect_target


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--check":
        print("allow" if decide(sys.argv[2]) else "pass")
        return
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return
    if payload.get("tool_name") != "Bash":
        return
    command = (payload.get("tool_input") or {}).get("command") or ""
    if command and decide(command):
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse", "permissionDecision": "allow",
            "permissionDecisionReason": "game command: allowed programs, loops and workspace redirects only"}}))


if __name__ == "__main__":
    main()
