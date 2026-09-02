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

| Mode   | Mapping      | Action                                  |
|--------|--------------|-----------------------------------------|
| Normal | `<leader>ai` | Send prompt + current buffer as context |
| Visual | `<leader>ai` | Send prompt + selection as context      |

Or use the command:

```vim
:PiBridge              " prompt for message
:PiBridge hello world  " send message directly
```

All responses render in pi's TUI — streaming text, tool calls, diffs, etc.

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
2. Compute `sha256(cwd)` — same algorithm as pi-bridge.ext
3. Connect to `~/.pi/agent/pi-bridge/sockets/<sha256>.sock`
4. On failure → auto-launch pi (if enabled)

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

## Logging

Logs to `vim.fn.stdpath("log") .. "/pi-bridge.nvim.log"` (resolves to `~/.local/state/nvim/log/pi-bridge.nvim.log` on Linux).

- Socket connection attempts (success/failure, path)
- Auto-launch triggers
- Messages sent to pi (prompt + context summary)
- Events received from pi

## Related

- [pi-bridge.ext](https://github.com/junkfactory/pi-bridge.ext) — Pi extension side
