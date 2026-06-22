local M = {}

M.defaults = {
  -- The Claude CLI to shell out to, and the model passed to it.
  command = "claude",
  model = "sonnet",
  -- Extra CLI flags. `--model <model>` is added automatically.
  cli_args = {
    "-p",
    "--max-turns",
    "100",
    "--output-format",
    "stream-json",
    "--verbose",
    "--permission-mode",
    "bypassPermissions",
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
  -- Override to steer the completion behaviour.
  system_prompt = nil, -- nil → built-in prompt (see context.lua)
  highlights = {
    -- Ghost text. `link` is colourscheme-agnostic; pass fg/bg/italic instead for a custom look.
    ghost = { link = "Comment" },
  },
  -- Progress UI. `rich` uses a coloured tool-activity panel via snacks.nvim when
  -- available; otherwise an in-place vim.notify spinner is used.
  ui = { rich = true },
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
  return M.options
end

return M
