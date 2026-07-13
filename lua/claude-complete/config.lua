local M = {}

M.defaults = {
  -- The Claude CLI to shell out to, and the model passed to it.
  command = "claude",
  model = "sonnet",
  -- Extra CLI flags. `--model <model>` and `--system-prompt <prompt>` are added
  -- automatically. `--exclude-dynamic-system-prompt-sections` keeps output clean
  -- (no output-style "insight" prose leaking into completions).
  cli_args = {
    "-p",
    "--max-turns",
    "100",
    "--output-format",
    "stream-json",
    "--verbose",
    "--permission-mode",
    "bypassPermissions",
    "--exclude-dynamic-system-prompt-sections",
  },
  -- Abort a request that has not returned within this many milliseconds.
  timeout_ms = 60000,
  -- Insert-mode mappings. Set any entry to `false` to leave it unbound.
  keymaps = {
    trigger = "<C-g>",
    accept = "<Tab>",
    cancel = "<C-c>",
  },
  -- How much surrounding context to send.
  context = {
    inline_full_under = 300, -- send the whole file when it has fewer lines than this
    above = 150, -- otherwise, lines kept above the cursor
    below = 50, -- and below
    imports = 20, -- leading lines always included (imports/headers)
    diagnostics = 5, -- nearest LSP diagnostics to include
    tree = 15, -- top-level entries of the project tree
  },
  -- Automatic, Cursor-style lane: fast ghost text shown when you pause typing,
  -- served by one persistent lightweight worker (see worker.lua). Independent
  -- of the manual <C-g> lane above. Opt in with `auto.enabled = true`.
  auto = {
    enabled = false, -- off by default; users opt in
    model = "claude-haiku-4-5", -- a cheap, fast model is strongly recommended
    debounce_ms = 350, -- idle time before a completion is requested
    idle_shutdown_min = 10, -- stop the worker after this many idle minutes
    max_filesize_kb = 500, -- skip buffers larger than this
    max_lines = 10000, -- skip buffers with more lines than this
    disabled_filetypes = { "TelescopePrompt", "snacks_picker_input", "oil" },
    -- Environment for the worker process only (extends, does not replace, the
    -- inherited env). MAX_THINKING_TOKENS=0 disables haiku's interleaved
    -- thinking, ~halving warm latency (~3.3s → ~1.7s). Set to {} to keep it.
    worker_env = { MAX_THINKING_TOKENS = "0" },
  },
  -- Override to steer the completion behaviour.
  system_prompt = nil, -- nil → built-in prompt (see context.lua)
  highlights = {
    -- Ghost text. `link` is colourscheme-agnostic; pass fg/bg/italic instead for a custom look.
    ghost = { link = "Comment" },
  },
  -- Progress UI. `rich` uses a coloured tool-activity panel via snacks.nvim when
  -- available; otherwise an in-place cmdline spinner is used. `context_line` shows
  -- what was sent (file, lines, branch) at the top of the panel.
  ui = { rich = true, context_line = true },
}

M.options = vim.deepcopy(M.defaults)

---@param opts table|nil
---@return table
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- Lists must replace, not index-merge.
  if opts and opts.cli_args then
    M.options.cli_args = opts.cli_args
  end
  -- Replace worker_env wholesale so users can clear the default (e.g. `{}`).
  if opts and opts.auto and opts.auto.worker_env ~= nil then
    M.options.auto.worker_env = opts.auto.worker_env
  end
  return M.options
end

return M
