# Architecture

## Why Lua plus a CLI adapter

The expensive and latency-sensitive work belongs inside Factorio. Lua sees the authoritative simulation and can apply input on every tick. RCON carries coarse commands and bounded observations; it is not used once per entity or per frame. Walking, mining, and combat run between agent decisions. World simulation continues at its normal speed.

An all-Lua external CLI would still need sockets, JSON, image writing, argument parsing, and portable packaging outside Factorio's sandbox. Node provides those facilities without production dependencies. TypeScript checks the host's transport and orchestration code. Neither the host nor its language owns gameplay policy. Other clients can implement the same tiny JSON protocol.

The CLI is the primary interface because agents already have shell tools. It supports individual commands, a persistent JSON-lines transport, and sequential plans. An MCP adapter could be added later without changing the game protocol, but none is necessary to play.

## Components

- `mod/agent-harness_0.1.0/control.lua`: stable remote interface, event registration, runtime installation, deduplication, save/load.
- `runtime.lua`: character validation, bounded observations, player inputs, item-conserving operations, active-job scheduler.
- Sibling Lua modules: gameplay extensions, loaded normally at startup and bundled for deployment.
- `host/rcon.ts`: authenticated TCP framing, bounded allocation, deadlines, serialization, explicit uncertainty after transport failure.
- `host/harness.ts`: JSON envelopes, Lua string encoding, optional journal.
- `host/bundle.ts`: atomic Lua module bundle, retained in the save.
- `host/cli.ts`: commands, stream, plans, watch, JSON results.
- `host/view.ts`: dependency-free schematic PNG from already observed data.

## Wire protocol

The host invokes `remote.call("agent_harness", "dispatch", json)` through `/silent-command`, and prints the returned JSON to RCON. Requests are `{id, action, player, args}`. Replies are `{id, ok, tick, result}` or `{id, ok:false, tick, error:{code,message}}`.

Factorio returns one potentially large RCON response frame per command. TCP chunks are not message boundaries. The transport handles arbitrary fragmentation and rejects malformed lengths, IDs, terminators, and UTF-8. It does not use Source's unsupported response delimiter trick.

An ID identifies a request, not a job-completion guarantee. Timed actions return acceptance and an ending tick. Poll `status` or use `--wait`; observe again to verify progress. Walking can be blocked by collision. Mining can finish early when its target disappears. Combat damage depends on ammunition, range, cooldown, equipment, and the actual game state.

There is one controller per player. Separate players can be addressed, but competing agents controlling the same player need external coordination. RCON authentication is the trust boundary; runtime install is intentionally privileged. This is survival-rule enforcement for the normal tool path, not protection against a malicious server operator.

## Hot reload contract

A runtime exports `dispatch(request)`, `tick(event)`, and `stop_all()`. Its module top level must only construct functions and constants. Persistent state lives under `storage.agent_harness`, never in a host cache. On load the runtime is compiled from stored source without changing game state. Functions and Lua closures are not serialized.

The host bundles sibling `.lua` modules into a lexical `require` table and falls back to Factorio's `require` for engine libraries. Changes are validated before replacement. This protects against compile/contract errors; it cannot undo side effects from badly written trusted top-level code. A tick-handler error stops controls, records a structured fault, and quarantines the tick loop. Diagnostic requests remain available; successful deployment clears quarantine. This is bounded recovery, not automatic rewriting of defective code.

New commands go into the runtime's handler table and its `describe` metadata. Add a deterministic fixture proving both the useful behavior and the conservation/permission edge case. Keep expensive scans bounded, use engine methods for normal player mechanics, and avoid copying world state to the host unnecessarily.

## Official references

- [Factorio 2.0 runtime API](https://lua-api.factorio.com/2.0.72/index-runtime.html)
- [LuaPlayer](https://lua-api.factorio.com/2.0.72/classes/LuaPlayer.html): player inputs, reach, crafting, cursor building.
- [LuaItemStack](https://lua-api.factorio.com/2.0.72/classes/LuaItemStack.html): blueprint serialization and construction.
- [LuaGameScript](https://lua-api.factorio.com/2.0.72/classes/LuaGameScript.html): screenshots do nothing on a headless server.
- [Storage lifecycle](https://lua-api.factorio.com/2.0.72/auxiliary/storage.html)
- [CLI parameters](https://wiki.factorio.com/Command_line_parameters)
- [Factorio developer clarification of RCON responses](https://forums.factorio.com/viewtopic.php?t=86598)

## Control horizon

The queue is the fast execution layer of an observe–act–replan loop. Each step has an ID and starts on a game tick. Shooting is a separate control channel from walking/mining/repair, so a nonwaiting shooting step can cover several movement steps. Auto targeting scans at a lower rate than firing input and bounds its candidate count. This reduces work in dense enemy populations while keeping firing input responsive.

Queue edits use optimistic revisions: the agent reads a revision, proposes a splice of pending steps, and gets a conflict if simulation progress has changed that queue in the meantime. The agent can then inspect and replan. Cancellation interrupts controls immediately on dispatch, pauses the queue, and either preserves or clears pending work. A direct gameplay intervention also pauses a running queue, preventing the next tick from silently restoring an obsolete command.

The queue is not a general planner or learned VLA model. Collision avoidance, path planning, target priorities beyond nearest hostile, and recovery decisions remain agent responsibilities or future Lua controllers. Completion records distinguish elapsed duration from lost targets/reach/tool exhaustion. A walk's elapsed duration does not establish arrival at a goal.

## Graphical sessions and desktop ownership

The default launcher creates a private server plus a graphical client. The server provides a stable RCON endpoint; the client supplies Factorio's real player connection and renderer. Both use session-owned configuration, mod copies, data directories, ports, and logs. Existing saves are copied before use. Headless mode explicitly omits the graphical process.

By default the client is an ordinary window on the user's desktop. With `--niri` (or `FH_NIRI=1`), it lives inside a nested compositor managed by `niri-harness`. The launcher verifies the host's unfocused nested-window rule before spawning. It skips the harness's post-launch focus restoration because restoring an old window could interrupt a user's intervening focus change. No host focus action is issued. This is separate from the in-game control loop: gameplay uses Factorio's API, not desktop keystrokes.

Session credentials live in a private file. State records process IDs and their start times, so shutdown refuses PID reuse. Normal shutdown first saves the world and checks for a complete ZIP before stopping owned processes. Failed starts retain logs and ownership metadata for diagnosis. Session directories are not silently reused or overwritten.
