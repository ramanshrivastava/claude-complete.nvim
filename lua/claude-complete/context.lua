local config = require("claude-complete.config")

local M = {}

local DEFAULT_SYSTEM_PROMPT = [[You are an expert code completion engine inside a Neovim editor.
Given file context and cursor position, output ONLY the code to insert at the cursor.

PHILOSOPHY:
- Generate completions the user could not easily type themselves.
- Suggest the most valuable continuation, not obvious stubs or boilerplate.
- Use correct types, imported symbols, and the patterns of the surrounding code.

RULES:
- Output ONLY raw code. No markdown, no backticks, no explanation.
- Mid-line: complete the current expression or statement.
- New line: generate the next logical block (1-30 lines).
- Match the existing style exactly: indentation, naming, async patterns.
- Never repeat code that exists before the cursor.
- Never output incomplete blocks; always close braces, parens, and brackets.
- Prefer already-imported symbols. If unsure, output nothing.

TOOLS:
- Use tools only to avoid hallucinating wrong API names or signatures.
- Do not over-explore; this is completion, not a project audit.]]

---@return string[]
local function git_branch()
  local branch = vim.fn.system("git branch --show-current 2>/dev/null"):gsub("%s+$", "")
  return vim.v.shell_error == 0 and branch ~= "" and branch or "N/A"
end

---@return string[]
local function open_buffers()
  local paths = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buflisted then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then
        paths[#paths + 1] = vim.fn.fnamemodify(name, ":~:.")
      end
    end
  end
  return paths
end

---@param bufnr integer
---@param row integer
---@return string[]
local function nearby_diagnostics(bufnr, row)
  local out = {}
  local diags = vim.diagnostic.get(bufnr, { severity = { min = vim.diagnostic.severity.WARN } })
  table.sort(diags, function(a, b)
    return math.abs(a.lnum - row) < math.abs(b.lnum - row)
  end)
  for i = 1, math.min(config.options.context.diagnostics, #diags) do
    local d = diags[i]
    local sev = d.severity == vim.diagnostic.severity.ERROR and "ERROR" or "WARN"
    out[#out + 1] = string.format("L%d: [%s] %s", d.lnum + 1, sev, d.message)
  end
  return out
end

--- Collect file, cursor, code window, diagnostics, open buffers and project tree.
---@return string
function M.gather()
  local cfg = config.options.context
  local bufnr = vim.api.nvim_get_current_buf()
  local relpath = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":~:.")
  local ft = vim.bo[bufnr].filetype
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1], cursor[2]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local total = #lines

  local imports = vim.list_slice(lines, 1, math.min(cfg.imports, total))

  local code, lo, hi
  if total < cfg.inline_full_under then
    lo, hi = 1, total
  else
    lo, hi = math.max(1, row - cfg.above), math.min(total, row + cfg.below)
  end
  code = {}
  for i = lo, hi do
    code[#code + 1] = (i == row) and (">>> CURSOR <<< " .. lines[i]) or lines[i]
  end

  local parts = {
    string.format("FILE: %s (%s)", relpath, ft),
    string.format("CURSOR: line %d, col %d", row, col),
    string.format("GIT BRANCH: %s", git_branch()),
    "",
    "=== IMPORTS ===",
    table.concat(imports, "\n"),
    "",
    "=== CODE CONTEXT ===",
    table.concat(code, "\n"),
  }

  local diags = nearby_diagnostics(bufnr, row)
  if #diags > 0 then
    vim.list_extend(parts, { "", "=== LSP DIAGNOSTICS ===", table.concat(diags, "\n") })
  end

  vim.list_extend(parts, { "", "=== OPEN BUFFERS ===", table.concat(open_buffers(), "\n") })

  local tree = vim.fn.system(("ls -1 2>/dev/null | head -%d"):format(cfg.tree)):gsub("%s+$", "")
  vim.list_extend(parts, { "", "=== PROJECT TREE ===", tree })

  M._summary = { relpath = relpath, ft = ft, sent_lines = hi - lo + 1, branch = git_branch() }
  return table.concat(parts, "\n")
end

--- What the most recent gather() sent, for the progress panel.
---@return { relpath: string, ft: string, sent_lines: integer, branch: string }?
function M.summary()
  return M._summary
end

--- The system prompt, passed to the CLI via --system-prompt (replaces the default).
---@return string
function M.system_prompt()
  return config.options.system_prompt or DEFAULT_SYSTEM_PROMPT
end

--- The user message: the gathered context.
---@return string
function M.build_context()
  return "CONTEXT:\n" .. M.gather()
end

return M
