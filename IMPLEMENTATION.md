# pi-bridge.nvim Implementation Plan

## Directory Structure

```text
pi-bridge.nvim/
├── plugin/
│   └── pi-bridge.lua          -- fallback command registration (non-lazy managers)
├── lua/
│   └── pi-bridge/
│       ├── init.lua            -- setup(), public API, orchestration
│       ├── socket.lua          -- libuv Unix socket: connect, send, recv, framing
│       ├── dispatch.lua        -- inbound message type → handler routing
│       ├── context.lua         -- gather buffer/selection context from Neovim
│       ├── launch.lua          -- auto-launch pi in a terminal split
│       ├── ui.lua              -- vim.notify, highlights, statusline
│       ├── log.lua             -- file logger (append-only, level-filtered)
│       └── health.lua          -- :checkhealth pi-bridge
├── tests/
│   ├── helpers.lua             -- mock socket server, tmpdir, wait_until
│   ├── test_log.lua            -- log level filtering, formatting, unwritable path
│   ├── test_context.lua        -- normal/visual mode, selection, empty buffer
│   ├── test_socket.lua         -- connect, send, receive, partial frames, reconnect
│   └── test_init.lua           -- setup validation, commands, keymaps, prompt flow
├── scripts/
│   └── minimal_init.lua        -- test harness rtp setup
├── doc/
│   └── pi-bridge.nvim.txt     -- :help pi-bridge.nvim
├── Makefile                    -- `make test` runs full suite
├── README.md                   -- (exists)
└── IMPLEMENTATION.md           -- (this file)
```

**Why this shape:**

- `plugin/` is a thin fallback for non-lazy managers — one guarded command registration.
- `lua/pi-bridge/` is the module root — `require("pi-bridge")` hits `init.lua`.
- Each module owns one concern. No base classes, no inheritance.
- `dispatch.lua` is a routing table, not an event bus — `socket.lua` calls it, it calls handlers. One level of indirection, no magic.
- `ui.lua` isolates all Neovim UI calls (`vim.notify`, highlights, statusline) so no other module touches the display.
- `launch.lua` is isolated because it touches terminal buffers and has polling logic — keeping it separate prevents `socket.lua` from knowing about Neovim's terminal API.
- `log.lua` is a leaf dependency with no imports from the rest of the plugin.

---

## Module Responsibilities

### `init.lua` — Orchestrator

- `setup(opts)`: merge user config with defaults, validate, store config, register `:PiBridge` command and keymaps, log startup. Sets `vim.g.loaded_pi_bridge`.
- `prompt(opts?)`: the main action — gather context, ensure connection, send message.
- `ensure_connection()`: try existing connection → try connect → try auto-launch → error.
- Owns the connection lifecycle (connect on first prompt, reconnect on drop).
- No UI code. No socket code. Calls into `context`, `socket`, `launch`.

### `socket.lua` — Transport

- `connect(path, on_message)`: open libuv pipe, wire read callback with NDJSON framing, return handle.
- `send(handle, msg)`: serialize + write + newline.
- `close(handle)`: graceful shutdown.
- Pure transport. No knowledge of message semantics, Neovim APIs, or config.

### `dispatch.lua` — Message Router

- `register(msg_type, fn)`: register a handler for a message type.
- `dispatch(msg)`: look up `msg.type` in handler table, call the handler. A plain table lookup — `handlers[msg.type](msg)`. No base class, no emitter, no middleware.
- `init.lua` wires handlers once in `setup()`. Adding a new event type is one `register()` call.

### `context.lua` — Neovim State Reader

- `get(mode)`: returns `{ file, cwd, content, mode }` by reading current buffer/selection.
- `get_visual_selection()`: extract visual selection range + lines.
- Pure functions (read-only Neovim state). No side effects, no I/O.
- Grows by adding new getters (diagnostics, images) — no existing code changes.

### `launch.lua` — Process Manager

- `prompt_launch(config)`: ask user to confirm via `vim.ui.select`, then open split, run `pi` in terminal buffer, poll for socket. Returns handle or nil.
- `is_pi_split_valid(state)`: check if the user closed the split.
- Polls `vim.uv.fs_stat()` on the socket path — no busy-wait, uses `vim.uv.new_timer()`.
- Returns a result, never throws. Caller decides what to do on failure.
- Never launches pi without explicit user confirmation.

### `ui.lua` — Neovim UI

- `notify(msg, level)`: wrapper around `vim.notify` with pi-bridge prefix.
- `on_agent_start(msg)`, `on_agent_end(msg)`: statusline updates.
- `on_file_edited(msg)`: highlight edited buffer (optional).
- Owns all user-facing output. No other module calls `vim.notify` directly.
- Grows by adding new event handlers — each is a standalone function.

### `log.lua` — Logger

- `init(path, level)`: open log file.
- `log(level, msg)`: append timestamped line if level >= threshold.
- `trace/debug/info/warn/error(msg)`: convenience wrappers.
- Swallows all I/O errors. Never crashes the plugin.

### `plugin/pi-bridge.lua` — Fallback Entry Point

- Registers `:PiBridge` command (calls `require("pi-bridge").prompt()`).
- Guarded by `vim.g.loaded_pi_bridge` — skips if `setup()` already ran.
- Exists for native packages and vim-plug users who don't use a lazy loader.
- For lazy.nvim/packer users: this file is never loaded — the `cmd`/`keys` triggers load the plugin on demand, and `setup()` registers the command.

### `doc/pi-bridge.nvim.txt` — Help

- Standard Neovim help file covering setup, commands, config, troubleshooting.

---

## Phased Implementation

### Phase 1: Foundation ✅

**Goal:** Skeleton that compiles, loads, and logs. No socket yet.

**Status:** Complete. All files created, syntax validated.

| File                     | What to build                                                                                                |
|--------------------------|--------------------------------------------------------------------------------------------------------------|
| `lua/pi-bridge/init.lua` | `setup(opts)` — merge defaults, validate, store config, warn on `autochdir`.                                 |
| `lua/pi-bridge/log.lua`  | `init(path, level)`, `log(level, msg)`, level helpers. Append-only file I/O via `vim.uv.fs_open`/`fs_write`. |
| `plugin/pi-bridge.lua`   | Register `:PiBridge` with `vim.g.loaded_pi_bridge` guard. Fallback for non-lazy managers.                    |
| `doc/pi-bridge.nvim.txt` | Skeleton help file with `*pi-bridge.nvim*` tag.                                                              |

**Config shape:**

```lua
-- defaults (merged with user opts in setup())
{
  split_direction = "vertical",
  split_size = nil,
  auto_launch = true,
  launch_timeout = 10,
  launch_cmd = { "pi" },
  keymaps = { prompt = "<leader>ai" },
  log_level = "info",
}
```

**Validation rules:**

- `split_direction` ∈ `{"vertical", "horizontal"}`
- `split_size` is `nil` or positive integer
- `launch_timeout` is positive number
- `launch_cmd` is non-empty list of strings
- `log_level` ∈ `{"trace", "debug", "info", "warn", "error"}`
- `keymaps` is `false` or table with `prompt` (string or false)

**Exit criteria:** `require("pi-bridge").setup({})` runs without error, creates log file, `:PiBridge` is registered.

---

### Phase 2: Socket + Context + Prompt Flow ✅

**Goal:** End-to-end message flow: Neovim → socket → pi extension.

**Status:** Complete. Socket, context, and prompt flow implemented. VimLeavePre cleanup added.

| File                        | What to build                                                                                               |
|-----------------------------|-------------------------------------------------------------------------------------------------------------|
| `lua/pi-bridge/socket.lua`  | `connect(path, on_message)`, `send(handle, msg)`, `close(handle)`. NDJSON framing with buffer accumulation. |
| `lua/pi-bridge/context.lua` | `get(mode)` — returns context table. `get_visual_selection()` — visual range extraction.                    |
| `lua/pi-bridge/init.lua`    | Wire `prompt()` → `context.get()` → `socket.send()`. Connection stored as module-local upvalue.             |

**Socket implementation notes:**

- Use `vim.uv.new_pipe(false)` — this is the libuv Unix domain socket primitive.
- `pipe:connect(path, cb)` — async connect, cb fires on success/error.
- `pipe:read_start(cb)` — cb receives `(err, data)`. Buffer partial data, split on `\n`, parse each complete line as JSON.
- `pipe:write(data)` — write `json_encode(msg) .. "\n"`.
- Connection state: `nil` (disconnected) or `{ pipe, path, on_message, read_buffer }`.
- On read error or EOF: set state to `nil`, log it. Next `prompt()` triggers reconnect.

**Context shape (sent over wire):**

```lua
{
  type = "prompt",
  text = "user's message",
  context = {
    file = "/absolute/path/to/file.lua",
    cwd = "/project/root",
    content = "buffer or selection content",
    mode = "normal" | "visual",
  }
}
```

**Prompt flow:**

```text
prompt(opts?)
  ├─ opts.text or vim.ui.input() → user message
  ├─ context.get(mode) → context table
  ├─ ensure_connection() → socket handle
  └─ socket.send(handle, { type="prompt", text=text, context=ctx })
```

**Exit criteria:** `<leader>ai` → type message → appears in pi TUI as a user message with file context. Works with pi already running.

**Tests:** 35/35 passing (`make test`). Covers log levels, context extraction, socket connect/send/receive/partial frames/disconnect/reconnect, setup validation, command/keymap registration, prompt flow.

---

### Phase 3: Auto-Launch ✅

**Goal:** If pi isn't running, offer to launch it. User must confirm.

**Status:** Complete. `lua/pi-bridge/launch.lua` implemented; `socket.connect()` made blocking via `vim.wait()`; `init.lua`'s `ensure_connection()` refactored to callback-based to accommodate async launch. 8 launch tests added; full suite 43/43 passing.

| File                       | What to build                                                                                             |
|----------------------------|-----------------------------------------------------------------------------------------------------------|
| `lua/pi-bridge/launch.lua` | `prompt_launch(config)` — ask user, open split, terminal pi, poll socket. `is_pi_split_valid(state)`.     |
| `lua/pi-bridge/init.lua`   | `ensure_connection()` — try connect → if fail and `auto_launch` → call `prompt_launch()` → retry connect. |

**Launch flow:**

```text
ensure_connection()
  ├─ try connect to socket
  │    ├─ success → return handle
  │    └─ failure →
  │         ├─ auto_launch = false → error: "socket not found, launch pi manually"
  │         └─ auto_launch = true → prompt_launch(config)
  │              ├─ vim.ui.select({"Yes", "No"}, { prompt = "No pi instance found. Launch one?" })
  │              │    ├─ "No" or dismissed → return nil (caller shows error)
  │              │    └─ "Yes" →
  │              │         ├─ vim.cmd(split_cmd)           -- :vsplit or :split
  │              │         ├─ vim.cmd("terminal " .. cmd)  -- run pi in terminal
  │              │         ├─ store { win, buf } for later validation
  │              │         └─ poll for socket (uv.new_timer, 200ms interval, timeout)
  │              │              ├─ found → return handle
  │              │              └─ timeout → error: "pi failed to start within Ns"
  └─
```

**Edge cases:**

| Scenario                   | Behavior                                                                          |
|----------------------------|-----------------------------------------------------------------------------------|
| User declines launch       | Prompt dismissed or "No" → `vim.notify("pi-bridge: not connected.", WARN)`        |
| User closes pi split       | `is_pi_split_valid()` returns false → next prompt asks again                      |
| Socket exists but stale    | `connect()` fails → treat as no socket → prompt to launch                         |
| Launch already in progress | Queue message (don't spawn second pi)                                             |
| `auto_launch = false`      | `vim.notify("pi-bridge: socket not found. Launch pi manually.", ERROR)`           |
| Launch timeout             | `vim.notify("pi-bridge: pi failed to start within Ns", ERROR)`                    |

**Exit criteria:** `<leader>ai` → no pi running → user confirms → pi launches in split → message sent. User declines → polite warning, no split opened.

**Implementation notes:**

- `socket.connect()` now blocks via `vim.wait(timeout, condition, interval)` so callers can rely on a real success/failure return (the previous async version returned `true` for in-flight connects, breaking the launch-retry path).
- `prompt_launch(config, socket_path, on_ready)` is the public async API. It is callback-based because polling pi's socket appearance is fundamentally async.
- Pending calls are coalesced via module-local `pending` queue — if a second `prompt_launch` runs while the first is polling, both callbacks fire with the same result (no double-launch).
- If `is_pi_split_valid()` returns true at call time, the UI prompt is skipped and we go straight to polling (pi may be slow to start the socket, but the split is open).
- Polling uses `vim.uv.new_timer()` at 200ms intervals — never `vim.wait` (would block the editor).
- `pi_split = { win, buf }` is cleared lazily when `is_pi_split_valid()` detects the user closed the split.

---

### Phase 4: Outbound Events ✅

**Goal:** Receive events from pi and act on them in Neovim.

**Status:** Complete. `dispatch.lua` and `ui.lua` implemented; `init.lua` wires handlers in `setup()`. 19 new tests; full suite 62/62 passing.

| File                         | What to build                                                                                       |
|------------------------------|-----------------------------------------------------------------------------------------------------|
| `lua/pi-bridge/dispatch.lua` | `register(msg_type, fn)`, `dispatch(msg)`. Routing table for inbound messages.                      |
| `lua/pi-bridge/ui.lua`       | `notify()`, `on_agent_start/end()`, `on_file_edited()`. All user-facing output.                     |
| `lua/pi-bridge/init.lua`     | Wire `dispatch.register()` calls in `setup()`. Connect `socket.on_message` to `dispatch.dispatch`.  |

**Wiring in `init.lua`:**

```lua
-- inside setup(), after socket is connected
socket.on_message = dispatch.dispatch

dispatch.register("agent_start", ui.on_agent_start)
dispatch.register("agent_end", ui.on_agent_end)
dispatch.register("file_edited", ui.on_file_edited)
```

**Adding a new event type:**

1. Add handler to `ui.lua` (e.g., `on_tool_execution(msg)`)
2. Add one line in `init.lua`: `dispatch.register("tool_execution", ui.on_tool_execution)`
3. No other code changes.

**Exit criteria:** pi pushes `agent_start` → Neovim shows notification. pi pushes `file_edited` → buffer highlights update.

---

### Phase 5: Polish + Docs

**Goal:** Production-ready. Healthcheck, docs, error handling.

| File                       | What to build                                                                                  |
|----------------------------|------------------------------------------------------------------------------------------------|
| `lua/pi-bridge/health.lua` | `:checkhealth pi-bridge` — read-only checks: pi binary, socket dir, extension, config.         |
| `doc/pi-bridge.nvim.txt`   | Full help: setup, commands, config, troubleshooting, architecture.                             |
| `lua/pi-bridge/init.lua`   | Graceful error handling: `vim.notify` on failures, never crash. Connection timeout on send.    |
| `plugin/pi-bridge.lua`     | Cleanup autocmd: close socket on `VimLeavePre`.                                                |

**Healthcheck checks (read-only — never launches pi, never modifies state):**

1. `pi` binary found in `$PATH`
2. `~/.pi/agent/pi-bridge/sockets/` directory exists (or can be created)
3. pi-bridge.ext is installed (check for `~/.pi/agent/extensions/pi-bridge.ts` or similar)
4. `vim.o.autochdir` status (warning if enabled)
5. Current socket status (connected / disconnected / never connected)

**Exit criteria:** `:checkhealth pi-bridge` passes, `:help pi-bridge.nvim` is complete, plugin handles all error paths gracefully.

---

## Design Decisions

### Why `vim.uv` directly, not `vim.fn.sockconnect`

`vim.fn.sockconnect("unix", path, { rpc = true })` expects Neovim's msgpack-RPC protocol. We need raw NDJSON over a Unix socket. `vim.uv.new_pipe()` gives us a raw stream — no protocol mismatch, no hacks.

### Why connection-per-session, not connect-per-prompt

Connecting on every prompt adds latency and races with pi's socket lifecycle. A persistent connection detects pi exits (EOF) and reconnects cleanly. The connection is a single libuv pipe — negligible resource cost.

### Why poll with `uv.new_timer`, not `vim.wait`

`vim.wait` blocks the event loop. `uv.new_timer` is non-blocking — Neovim stays responsive during socket polling. The timer fires every 200ms, checks `fs_stat`, and resolves/rejects via callback.

### Why `dispatch.lua` instead of an event bus

`dispatch.lua` is a table lookup — `handlers[msg.type](msg)`. It is not an event emitter: no wildcard matching, no bubbling, no middleware, no `off()`. Handlers are registered once in `setup()` and never change at runtime. The indirection exists so that `socket.lua` stays message-agnostic (it doesn't know what `agent_start` means) and `init.lua` doesn't become a switch statement. Adding a new message type is one `register()` call with no existing code changes.

### Why `plugin/` exists alongside lazy-load support

Two paths to the same result — `vim.g.loaded_pi_bridge` prevents double registration:

- **lazy.nvim / packer**: `cmd = "PiBridge"` and `keys = { "<leader>ai" }` defer the plugin entirely. `plugin/` never runs. `setup()` registers the command and keymaps on first trigger. True lazy-load.
- **Native packages / vim-plug**: `plugin/` runs at startup, registers `:PiBridge`. User calls `setup()` for keymaps and config. No lazy-load, but the command is always discoverable.

The `plugin/` file is a thin fallback — one command registration, guarded. The expensive work (socket connect, context gather) is always deferred to `prompt()`.

### Why separate `launch.lua` from `socket.lua`

`launch.lua` depends on Neovim's terminal API (`vim.cmd.terminal`, window management). `socket.lua` depends on `vim.uv` (libuv). Mixing them couples transport to UI. Keeping them separate means `socket.lua` can be tested without Neovim's terminal, and `launch.lua` can be swapped (e.g., tmux launch) without touching transport.
