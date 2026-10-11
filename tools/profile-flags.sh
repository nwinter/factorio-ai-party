# Clean-profile launch words, sourced by tools/launch-agent.sh and tools/context-probe.sh --profile so the probe checks
# what the agents get (docs/LAUNCH2-NOTES.md). Strings, not arrays: launch-agent.sh pastes them into a pane command.

# Claude Code env (after `env`): no inherited API credentials or parent session, no claude.ai MCP servers or Chrome,
# no "The user hasn't heard from you in a while" reminder (CLAUDE_CODE_SILENT_TURN_REMINDER, shake3: Opus 36 times)
# and no git status and recent commits (CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS, same as includeGitInstructions false).
# Two parts because env stops reading -u options at the first assignment: env $claude_unset [ROUTE WORDS] $claude_vars.
claude_unset="-u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY -u CLAUDE_CODE_SESSION_ID -u CLAUDECODE"
claude_vars="ENABLE_CLAUDEAI_MCP_SERVERS=false CLAUDE_CODE_ENABLE_CFC=false CLAUDE_CODE_SILENT_TURN_REMINDER=0 CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS=1"
# --setting-sources project,local: the route's user settings.json (hooks such as peon-ping, plugins, effort) stays out;
# login lives outside settings. --tools: only the tools the game uses (also shrinks the post-compaction floor).
claude_flags="--permission-mode dontAsk --setting-sources project,local --tools Bash,Read,Edit,Write,Grep,Glob --strict-mcp-config --mcp-config '{\"mcpServers\":{}}' --no-chrome --disable-slash-commands"

# Grok Build env: skip the Claude- and Cursor-compatible skills, rules, named instruction files, hooks and MCP servers
# (the 3 MCP servers that failed at every start in shake3 came from Cursor's .mcp.json), managed MCP servers and
# cross-session memory. Grok has no switch for $GROK_HOME/rules, $GROK_HOME/hooks or ~/.agents/skills.
grok_env="GROK_CLAUDE_SKILLS_ENABLED=false GROK_CLAUDE_MCPS_ENABLED=false GROK_CLAUDE_RULES_ENABLED=false GROK_CLAUDE_HOOKS_ENABLED=false GROK_CLAUDE_AGENTS_ENABLED=false GROK_CURSOR_SKILLS_ENABLED=false GROK_CURSOR_MCPS_ENABLED=false GROK_CURSOR_RULES_ENABLED=false GROK_CURSOR_HOOKS_ENABLED=false GROK_CURSOR_AGENTS_ENABLED=false GROK_MANAGED_MCPS_ENABLED=false GROK_MEMORY=0"
# Shake2's Grok was denied `./fh ... > describe.json` and `python3 -c` despite the .claude allowlist; redirects into the
# workspace count as edits. Loops stay unapproved (Grok runs unsandboxed).
grok_allow="--permission-mode dontAsk --allow 'Bash(./fh *)' --allow 'Bash(./shot *)' --allow 'Bash(python3 *)' --allow 'Edit(./**)' --allow 'Write(./**)'"
