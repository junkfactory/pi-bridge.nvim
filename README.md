# pi-bridge.nvim

Neovim plugin for [pi](https://github.com/earendil-works/pi-coding-agent) integration via Unix socket. Pairs with [pi-bridge.ext](https://github.com/junkfactory/pi-bridge.ext).

## Architecture

```text
┌─────────────┐     Unix Socket     ┌─────────────────┐
│  pi (TUI)   │◄──────────────────► │ pi-bridge.nvim  │
│  + extension│     JSON msgs       │ (Lua)           │
└─────────────┘                     └─────────────────┘
```

Send prompts with buffer/selection context to pi directly from Neovim. Responses render in pi's TUI — no custom chat buffer needed.

## Install

Requires [pi-bridge.ext](https://github.com/junkfactory/pi-bridge.ext) installed in pi (see [pi-bridge.ext install](https://github.com/junkfactory/pi-bridge.ext#install)).

### lazy.nvim

```lua
{
  "junkfactory/pi-bridge.nvim",
  opts = {
    -- see Setup section for all options
  },
}
```

lazy.nvim automatically calls `require("pi-bridge").setup(opts)` — no `config = function()` needed.

### Native packages

```bash
mkdir -p ~/.local/share/nvim/site/pack/plugins/start
git clone https://github.com/junkfactory/pi-bridge.nvim.git \
  ~/.local/share/nvim/site/pack/plugins/start/pi-bridge.nvim
```

Restart nvim after cloning. The plugin loads automatically.

### From a local clone (development)

Clone the repo and point your plugin manager at it. Edits under `lua/` are picked up on the next `:source` or nvim restart.

**lazy.nvim** — use `dir` so lazy loads the local checkout instead of fetching from GitHub:

```lua
{
  dir = "/absolute/path/to/pi-bridge.nvim",
  name = "pi-bridge.nvim",  -- preserve the plugin name for lazy's bookkeeping
  opts = {
    -- see Setup section for all options
  },
}
```

Run `:Lazy install` once to register; subsequent edits in the clone take effect after restarting nvim or running `:Lazy reload pi-bridge.nvim`.

**Native packages** (no plugin manager) — symlink the clone into `pack/local/start` so Neovim auto-loads it on startup:

```bash
mkdir -p ~/.local/share/nvim/site/pack/local/start
ln -s /absolute/path/to/pi-bridge.nvim \
      ~/.local/share/nvim/site/pack/local/start/pi-bridge.nvim
```

Restart nvim after editing files under `lua/`, `plugin/`, or `doc/` so Neovim re-scans the runtimepath. The symlink stays in sync with your working tree automatically.

## Usage

| Mode   | Mapping      | Action                                                              |
|--------|--------------|---------------------------------------------------------------------|
| Normal | `<leader>ai` | Send prompt (use `@this`, `@selection`, `@diagnostics` for context) |
| Visual | `<leader>ai` | Send prompt + selection as context                                  |

Or use the command:

```vim
:PiBridge              " prompt for message
:PiBridge hello world  " send message directly
```

All responses render in pi's TUI — streaming text, tool calls, diffs, etc.

## Placeholders

Include context directly in your message using placeholders:

| Placeholder    | Replaces with                           | Example                         |
|----------------|-----------------------------------------|---------------------------------|
| `@this`        | Current line with line number           | `line 25: local x = 1`          |
| `@selection`   | Visual selection (empty in normal mode) | Selected text                   |
| `@diagnostics` | LSP diagnostics for current buffer      | `L1:C1 [ERROR] unused variable` |

Examples:

```vim
:PiBridge fix @this
:PiBridge explain @selection
:PiBridge fix these @diagnostics
:PiBridge refactor @this and check @diagnostics
```

Unknown `@tokens` pass through unchanged. Typing `@` in the prompt shows autocomplete suggestions.

## Setup

```lua
require("pi-bridge").setup({
  -- Split direction: "vertical" or "horizontal"
  split_direction = "vertical",

  -- Split size (percentage or absolute lines/cols)
  -- nil = use Neovim defaults (50%)
  split_size = nil,  -- e.g., 80 for 80 cols vertical, 20 for 20 lines horizontal

  -- Auto-launch pi if socket missing/invalid
  auto_launch = true,

  -- Max seconds to wait for socket after launching pi
  launch_timeout = 10,

  -- Command to launch pi (allows custom args, env, etc.)
  launch_cmd = { "pi" },

  -- Keymaps (set to false to disable default keymap)
  keymaps = {
    prompt = "<leader>ai",  -- normal + visual mode
  },

  -- Log level: "trace" | "debug" | "info" | "warn" | "error"
  log_level = "info",
})
```

### Keymaps

Remap or disable:

```lua
-- Custom key
keymaps = { prompt = "<leader>p" },

-- Disable defaults (use :PiBridge command)
keymaps = false,
```

## How It Works

### Socket Discovery

On `<leader>ai`:

1. Get `cwd` from `vim.fn.getcwd()`
2. Walk from `cwd` upward toward `$HOME`, probing each directory for an active socket
3. The socket path is `~/.pi/agent/pi-bridge/sockets/<sha256(dir)>.sock` — same hash algorithm as pi-bridge.ext
4. On no hit → auto-launch pi (if enabled)

The upward walk means opening Neovim in `src/foo/bar/` finds the pi instance running at the project root without requiring `:cd` first. The walk stops at `$HOME` and never probes filesystem root.

### Auto-Launch

When the socket doesn't exist or connection fails:

1. Open a split (configured direction)
2. Run `pi` in a terminal buffer
3. Wait for socket to appear (polls every 200ms up to `launch_timeout`)
4. Connect and send message

| Scenario                             | Behavior                                                 |
|--------------------------------------|----------------------------------------------------------|
| Socket exists but connection refused | Relaunch                                                 |
| User closes pi split manually        | Next prompt detects missing socket, relaunches           |
| Pi exits unexpectedly                | Socket disappears, next prompt triggers relaunch         |
| `auto_launch = false`                | Error: "pi-bridge socket not found. Launch pi manually." |

### Startup Checks

On `setup()`, warns if `vim.o.autochdir` is enabled — socket matching uses cwd, which `autochdir` changes per-file.

## Cwd Contract

Sockets are keyed by `sha256(cwd)`. Each project directory gets its own socket — there is no global singleton and no shared registry. The resolver walks from your current directory upward to `$HOME` to find the nearest active socket, which makes nested buffers work without configuration.

`autochdir` is **not supported**. Because `autochdir` changes cwd per-buffer, the socket you reach depends on which file is active rather than which project you intended. The plugin warns on `setup()` if it is enabled and `:checkhealth pi-bridge` flags it under a dedicated `autochdir` line.

For project switching, use:

- `:cd {path}` — change cwd for the whole window
- `:lcd {path}` — change cwd for the current window only

Both work normally. Avoid `autochdir` and avoid changing cwd with autocommands that fire on every buffer change.

### `:checkhealth pi-bridge` states

Health distinguishes between "is there a server" and "is Neovim connected to it". Two different things, two different reports:

| Output                                                                       | Meaning                                                                                |
|------------------------------------------------------------------------------|----------------------------------------------------------------------------------------|
| `OK Socket: connected`                                                       | Persistent Neovim connection is up. Sending prompts will work.                         |
| `INFO Socket available, Neovim not connected: <path>`                        | pi is running but Neovim hasn't connected yet. Run `:PiBridge` to connect.             |
| `WARN Socket file present but unreachable: <path> (<reason>)`                | Stale socket file from a previous crash. Remove it or relaunch pi.                     |
| `INFO Socket: not connected (no socket file in cwd)`                         | No server in this cwd. Auto-launch will start one if enabled.                          |

`:checkhealth` only inspects state; it never opens or closes the persistent connection.

## Logging

Logs to `vim.fn.stdpath("log") .. "/pi-bridge.nvim.log"` (resolves to `~/.local/state/nvim/log/pi-bridge.nvim.log` on Linux).

- Socket connection attempts (success/failure, path)
- Auto-launch triggers
- Messages sent to pi (prompt + context summary)
- Events received from pi

## Running Tests

```bash
make test                  # run all tests
make test-context          # context module only
make test-placeholders     # placeholders module only
make test-init             # init module only
make test-resolve          # socket resolver only
make test-health           # :checkhealth only
```

Requires Neovim 0.10+ and [mini.nvim](https://github.com/echasnovski/mini.nvim) (auto-fetched as a test dependency).

## Related

- [pi-bridge.ext](https://github.com/junkfactory/pi-bridge.ext) — Pi extension side
