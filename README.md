# claude-complete.nvim

AI code completion for Neovim, powered by the [Claude Code](https://www.claude.com/product/claude-code) CLI.

Press a key in insert mode and Claude reads the surrounding code (imports, the cursor window, LSP diagnostics, open buffers, the project tree), explores the project with its tools when it needs to, and returns a multi-line completion as ghost text. Accept with another key.

```text
function parseConfig(raw: string): Config {
  ┊const parsed = JSON.parse(raw);           ← ghost text
  ┊return ConfigSchema.parse(parsed);
}
```

## Requirements

- Neovim >= 0.10
- The `claude` CLI on your `PATH`, authenticated (`claude` once to sign in)
- Optional: [snacks.nvim](https://github.com/folke/snacks.nvim) for the rich tool-activity panel (a clean cmdline spinner is used otherwise)

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "ramanshrivastava/claude-complete.nvim",
  event = "InsertEnter",
  opts = {},
}
```

## Usage

| Key (insert mode) | Action |
| --- | --- |
| `<C-g>` | Request a completion at the cursor |
| `<Tab>` | Accept the suggestion |
| `<C-c>` | Cancel an in-flight request |

All keys are configurable (see below). Typing, leaving insert mode, or moving the cursor dismisses the suggestion.

## Configuration

`opts` is merged over the defaults:

```lua
{
  command = "claude",        -- CLI to invoke
  model = "sonnet",          -- passed as --model
  cli_args = {               -- extra flags (--model is appended automatically)
    "-p", "--max-turns", "100", "--output-format", "stream-json",
    "--verbose", "--permission-mode", "bypassPermissions",
  },
  timeout_ms = 60000,
  keymaps = {                -- set any to false to leave it unbound
    trigger = "<C-g>",
    accept = "<Tab>",
    cancel = "<C-c>",
  },
  context = {
    inline_full_under = 300, -- send the whole file when shorter than this
    above = 150,             -- otherwise lines kept above the cursor
    below = 50,              -- and below
    imports = 20,            -- leading lines always included
    diagnostics = 5,         -- nearest LSP diagnostics to include
    tree = 15,               -- top-level project-tree entries
  },
  system_prompt = nil,       -- string to replace the built-in prompt
  highlights = {
    ghost = { link = "Comment" }, -- or { fg = "#b4befe", italic = true }
  },
  ui = { rich = true },      -- rich snacks panel when available, else cmdline spinner
}
```

### Custom keys via lazy

```lua
{
  "ramanshrivastava/claude-complete.nvim",
  keys = { { "<C-g>", mode = "i" } },
  opts = { keymaps = { trigger = "<C-g>", accept = "<Tab>" } },
}
```

## How it works

The plugin shells out to `claude -p` with `--output-format stream-json`, sends the gathered context on stdin, streams the tool-use events to drive the progress UI, and renders the final assistant text as ghost text. No data leaves your machine except through the Claude CLI you already use.

## License

MIT
