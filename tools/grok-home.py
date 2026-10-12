#!/usr/bin/env python3
"""Run-local GROK_HOME for a game workspace, so Grok Build loads none of the owner's home rules, hooks, skills or
plugins (smoke-l4 still listed ~/.grok/rules/agent-tooling.md, the ~/.agents/skills skills and two plugins; Grok has
no per-launch switch for them, docs/LAUNCH2-NOTES.md).

  tools/grok-home.py setup DIR ENSURE_SECONDS   write DIR/.grok-home and make sure the owner's login has at least
                                                ENSURE_SECONDS left; prints the env words for the launch line
  tools/grok-home.py token                      auth provider (GROK_AUTH_PROVIDER_COMMAND): prints the owner's
                                                current access token as JSON, read-only

Login: the run home has no auth.json of its own to refresh. Grok runs the `token` command, which reads the owner's
~/.grok/auth.json and prints its access token with the time it has left. Before the launch, `setup` checks that
time; if it is short, it runs the owner's own grok in its own home with a larger early-refresh window, so Grok
refreshes the owner's login exactly as it does in the owner's sessions (GROK_AUTH_EARLY_INVALIDATION_SECS). Nothing
in ~/.grok is copied, edited or replaced by this script. Sessions: DIR/.grok-home/sessions links to ~/.grok/sessions,
so session files stay where tools/context.py and the run analysis look for them.
"""
import shutil
import datetime
import json
import os
import subprocess
import sys
import time

OWNER = os.path.expanduser("~/.grok")
HERE = os.path.abspath(__file__)
GROK = os.path.join(OWNER, "bin", "grok")   # `grok` on PATH is a wrapper that refuses an unknown GROK_HOME

# Grok's built-in product skills (Grok 1.0.50, as its model listed them); they live in the binary, not in a folder.
BUNDLED = ["build-with-ai", "code-review", "create-skill", "create-workflow", "design", "docx", "execute-plan",
           "game-assets", "imagine", "implement", "learn", "long-running-background-tasks", "pdf", "pptx", "pr-babysit",
           "resume-claude", "resume-codex", "resume-cursor", "review", "skill-design-principles", "statusline",
           "threejs-frame-conventions"]

CONFIG = """# Written by tools/grok-home.py for a game workspace (not the owner's config).
[cli]
auto_update = false

# A fresh home opens the TUI with the "Help improve Grok [Opt out] [Opt in]" prompt; the owner's home has answered it.
[privacy]
privacy_banner_acked = "{acked}"

[compat.claude]
skills = false
rules = false
agents = false
mcps = false
hooks = false

[compat.cursor]
skills = false
rules = false
agents = false
mcps = false
hooks = false

[skills]
ignore = [{ignore}]
disabled = [{bundled}]

[plugins]
disabled = [{plugins}]

[subagents]
enabled = {full}

[workflows]
enabled = {full}
"""


def owner_token():
    """(entry, seconds left) for the owner's freshest Grok login, or (None, 0)."""
    try:
        data = json.load(open(os.path.join(OWNER, "auth.json")))
    except (OSError, ValueError):
        return None, 0
    best, left = None, 0
    for entry in data.values():
        if not isinstance(entry, dict) or not entry.get("key"):
            continue
        try:
            t = datetime.datetime.fromisoformat(entry["expires_at"].replace("Z", "+00:00")).timestamp() - time.time()
        except (KeyError, ValueError, AttributeError):
            t = 0
        if best is None or t > left:
            best, left = entry, t
    return best, int(left)


def refresh(window):
    """Have the owner's grok, in its own home, refresh the owner's login if it has under `window` seconds left."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GROK_")}
    env["GROK_AUTH_EARLY_INVALIDATION_SECS"] = str(window + 300)
    for cmd in ([GROK, "models"], [GROK, "-p", "Reply with the word ok.", "--max-turns", "1"]):
        try:
            subprocess.run(cmd, env=env, cwd=os.path.expanduser("~"), stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=90)
        except (OSError, subprocess.TimeoutExpired):
            pass
        if owner_token()[1] >= window:
            return True
    return False


def setup(d, ensure):
    home = os.path.join(d, ".grok-home")
    os.makedirs(home, mode=0o700, exist_ok=True)
    # ~/.agents/skills is a fixed skill root; ignore it and each entry's real path (aws-spot links elsewhere).
    root = os.path.expanduser("~/.agents/skills")
    skills = [root, os.path.realpath(root)]
    if os.path.isdir(root):
        skills += [os.path.realpath(os.path.join(root, n)) for n in sorted(os.listdir(root))]
    plugins = []
    try:   # Claude Code plugins Grok lists as user plugins (claude-hud, code-simplifier)
        installed = json.load(open(os.path.expanduser("~/.claude/plugins/installed_plugins.json")))
        plugins = [p for key in (installed.get("plugins") or installed) for p in (key, key.split("@")[0])]
    except (OSError, ValueError, AttributeError):
        pass
    with open(os.path.join(home, "config.toml"), "w") as f:
        f.write(CONFIG.replace("{ignore}", ", ".join(json.dumps(s) for s in dict.fromkeys(skills)))
                .replace("{plugins}", ", ".join(json.dumps(p) for p in dict.fromkeys(plugins)))
                .replace("{bundled}", ", ".join(json.dumps(b) for b in BUNDLED))
                # POG_FULL_TOOLS=1 (tools/full_tools.py): spawn_subagent and the workflow tool stay.
                .replace("{full}", "true" if os.environ.get("POG_FULL_TOOLS") == "1" else "false")
                .replace("{acked}", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())))
    link = os.path.join(home, "sessions")
    if not os.path.lexists(link):
        os.symlink(os.path.join(OWNER, "sessions"), link)
    # Herdr's own Grok integration (installed by Herdr, reports the session to it; tools/supervise.sh reads the pane's
    # agent state) stays; the owner's local-session-profile hook does not. Neither reaches the model.
    herdr = os.path.join(OWNER, "hooks", "herdr.json")
    os.makedirs(os.path.join(home, "hooks"), exist_ok=True)
    # A copy, never a link: Grok's sandbox refuses a hook path with a symlink in it (shake8: Grok would not start).
    if os.path.exists(herdr) and not os.path.lexists(os.path.join(home, "hooks", "herdr.json")):
        shutil.copyfile(herdr, os.path.join(home, "hooks", "herdr.json"))
    if owner_token()[1] < ensure and not refresh(ensure):
        print(f"grok-home: the owner's Grok login has {owner_token()[1]} s left and did not refresh", file=sys.stderr)
    # Grok runs the provider only on a sign-in or a refresh; with no credential a headless start just fails ("Not
    # signed in"), so sign the run home in once. Its auth.json then holds the access token only (no refresh token).
    env = dict(os.environ, GROK_HOME=home, GROK_AUTH_PROVIDER_COMMAND=f"python3 {HERE} token")
    try:
        subprocess.run([GROK, "login"], env=env, cwd=d, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        pass
    if not os.path.exists(os.path.join(home, "auth.json")):
        print("grok-home: signing the run home in failed", file=sys.stderr)
    # GROK_FOLDER_TRUST=0: the run home has no trusted_folders.toml; the repo's project hooks must still load.
    print(f"GROK_HOME='{home}' GROK_FOLDER_TRUST=0 GROK_AUTH_PROVIDER_COMMAND='python3 {HERE} token'")


def token():
    entry, left = owner_token()
    if entry is None or left <= 0:
        sys.exit(1)   # Grok then shows its sign-in screen; `setup` refreshes before each launch
    print(json.dumps({"access_token": entry["key"], "expires_in": left,
                      "issuer": entry.get("oidc_issuer") or "https://auth.x.ai"}))


if __name__ == "__main__":
    if sys.argv[1:2] == ["setup"]:
        setup(sys.argv[2], int(sys.argv[3]))
    elif sys.argv[1:2] == ["token"]:
        token()
    else:
        sys.exit(__doc__)
