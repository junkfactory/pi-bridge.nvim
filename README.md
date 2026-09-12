# pi-bridge.nvim

Talk to [pi](https://github.com/earendil-works/pi-coding-agent) from Neovim. Hit `<leader>ai`, type your question with [placeholders](#placeholders) like `@this` or `@selection` to include code context — pi streams its response in the TUI.

No copy-pasting. No context switching. Just ask.

```vim
:PiBridge fix @this              " send current line
:PiBridge explain @selection     " send visual selection
:PiBridge fix these @diagnostics " send LSP errors
:PiBridge review @buffer         " send entire file
```

pi auto-launches in a split if it's not running. Buffers auto-refresh from disk when the agent finishes. Works per-project — each directory gets its own pi instance.

Pairs with [pi-bridge.ext](https://github.com/junkfactory/pi-bridge.ext) (the pi extension that receives messages).

## Install

Requires [pi-bridge.ext](https://github.com/junkfactory/pi-bridge.ext) installed in pi (see [pi-bridge.ext install](https://github.com/junkfactory/pi-bridge.ext#install)).

### lazy.nvim

Pin to releases (recommended):

```lua
{
  "junkfactory/pi-bridge.nvim",
  version = "*",  -- latest tagged release
  cmd = "PiBridge",
  keys = {
    { "<leader>ai", mode = { "n", "v" }, desc = "Ask pi" },
  },
  opts = {
    -- see Setup section for all options
  },
}
```

Or track main (may encounter instability):

```lua
{
  "junkfactory/pi-bridge.nvim",
  -- no version key; tracks main
  cmd = "PiBridge",
  keys = {
    { "<leader>ai", mode = { "n", "v" }, desc = "Ask pi" },
  },
  opts = {},
}
```

lazy.nvim automatically calls `require("pi-bridge").setup(opts)` — no `config = function()` needed.

### Native packages

Pin to a release (recommended):

```bash
mkdir -p ~/.local/share/nvim/site/pack/plugins/start
git clone --branch v0.1.0 --depth 1 https://github.com/junkfactory/pi-bridge.nvim.git \
  ~/.local/share/nvim/site/pack/plugins/start/pi-bridge.nvim
```

Or track main (may encounter instability):

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

## Releasing

Each repo ([pi-bridge.nvim](https://github.com/junkfactory/pi-bridge.nvim/releases), [pi-bridge.ext](https://github.com/junkfactory/pi-bridge.ext/releases)) is released independently. The exception is a **socket protocol change** — both repos are then tagged at the same version.

Releases are triggered by tagging. The `tag.sh` script handles validation, build checks, tagging, and pushing:

```bash
./.github/ci/tag.sh 0.1.2   # no 'v' prefix — script adds it
```

This runs the full test suite (`make test`), creates a `v0.1.2` jj tag on main, and pushes. The push triggers a CI job that creates the GitHub release with auto-generated notes.

### Cross-repo pairing

After both releases exist, a daily CI job appends a pairing line (e.g. "Requires pi-bridge.ext v0.1.2") to each release's notes.

### Dry run

```bash
DRY_RUN=1 ./.github/ci/tag.sh 0.1.2
```

Runs checks and prints the tag/push commands without mutating anything.

### Version pinning

Prefer `version = "*"` while pre-1.0 — semver guarantees are soft before 1.0, so tracking the latest tag is safer than pinning.

## Usage

| Mode   | Mapping      | Action                               |
|--------|--------------|--------------------------------------|
| Normal | `<leader>ai` | Prompt for a message                 |
| Visual | `<leader>ai` | Prompt with selection as context     |

Or use the command:

```vim
:PiBridge              " prompt for message
:PiBridge hello world  " send message directly
```

All responses render in pi's TUI — streaming text, tool calls, diffs, etc.

### Placeholders

Include context directly in your message using placeholders:

| Placeholder    | Replaces with                                            | Example                         |
|----------------|----------------------------------------------------------|---------------------------------|
| `@this`        | Current line with line number                            | `line 25: local x = 1`          |
| `@selection`   | Visual selection (empty in normal mode)                  | Selected text                   |
| `@buffer`      | Absolute path to current buffer                          | `/path/to/file.lua`             |
| `@buffers`     | Newline-separated list of open buffer paths              | `/path/a.lua\n/path/b.lua`      |
| `@content`     | Content of current buffer (truncated at ~900KB if large) | Full buffer contents            |
| `@diagnostics` | LSP diagnostics for current buffer                       | `L1:C1 [ERROR] unused variable` |

Examples:

```vim
:PiBridge fix @this
:PiBridge explain @selection
:PiBridge fix these @diagnostics
:PiBridge refactor @this and check @diagnostics
:PiBridge review @buffer
:PiBridge summarize @content
:PiBridge compare @buffers
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

  -- Edit approval prompt: when pi is about to edit/write a file,
  -- Neovim shows a y/a/n picker (vim.ui.select) — the diff itself
  -- renders in pi's TUI. Set false to opt out (pi falls back to its
  -- own TUI overlay because no approval_ack arrives within 1s).
  edit_approval_prompt = true,
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

```text
┌─────────────┐     Unix Socket     ┌─────────────────┐
│  pi (TUI)   │◄──────────────────► │ pi-bridge.nvim  │
│  + extension│     JSON msgs       │ (Lua)           │
└─────────────┘                     └─────────────────┘
```

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

## Edit Approval Prompt

When pi is about to apply its `edit` or `write` tool, it sends an `approval_request` over the socket. pi-bridge.nvim renders the decision with `vim.ui.select` — the same picker the launch prompt uses, so it follows whatever picker plugin you have configured. The unified diff itself is shown in pi's TUI as a widget above the editor; Neovim is only the decision surface:

| Choice  | Decision | Effect                                              |
|---------|----------|-----------------------------------------------------|
| `y`     | `yes`    | Approve this single tool call                       |
| `a`     | `all`    | Approve all future edits to that file this session  |
| `n`     | `no`     | Reject the tool call (pi narrates the rejection)    |
| `<Esc>` | `no`     | Dismissed picker — same as `n`                      |

An `approval_ack` is sent the moment the request arrives so pi knows Neovim took over (its own fallback overlay appears only if no ack arrives within 1s).

If the buffer for the target file is loaded and `&modified`, the prompt notes it — the diff is always computed from disk, so what you see is what pi will apply.

### Disabling

```lua
require("pi-bridge").setup({ edit_approval_prompt = false })
```

With this set, nvim never opens the picker or acks; pi sees no ack within 1s and falls back to its own in-TUI overlay. The protocol stays wired (you can flip it back on per-session) but nvim will not surface the prompt.

### Protocol pairing

`approval_request`, `approval_resolved`, `approval_ack`, and `approval_response` are new NDJSON message types. Both `pi-bridge.nvim` and `pi-bridge.ext` must be tagged at the same version when this protocol is in use — see [Releasing](#releasing) for the paired-tag rule.

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
make test-approval         # edit approval prompt only
```

Requires Neovim 0.12.5+ and [mini.nvim](https://github.com/echasnovski/mini.nvim) (auto-fetched as a test dependency).

## Related

- [pi-bridge.ext](https://github.com/junkfactory/pi-bridge.ext) — Pi extension side
- Inspired by [opencode.nvim](https://github.com/nickjvandyke/opencode.nvim).
