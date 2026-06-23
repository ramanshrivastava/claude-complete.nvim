local config = require("claude-complete.config")
local context = require("claude-complete.context")
local claude = require("claude-complete.claude")
local ghost = require("claude-complete.ghost")
local status = require("claude-complete.status")

local M = {}

-- Status-panel groups link to standard highlights so any colourscheme themes them.
local STATUS_LINKS = {
  ClaudeCompleteTitle = "Title",
  ClaudeCompleteContext = "Comment",
  ClaudeCompleteCurrent = "Function",
  ClaudeCompleteHistory = "Comment",
  ClaudeCompleteParam = "NonText",
  ClaudeCompleteSep = "NonText",
  ClaudeCompleteFooter = "Comment",
  ClaudeCompleteArrow = "DiagnosticWarn",
  ClaudeCompleteThinking = "DiagnosticHint",
  ClaudeCompleteSuccess = "DiagnosticOk",
  ClaudeCompleteError = "DiagnosticError",
  ClaudeCompleteTiming = "NonText",
}

local function define_highlights()
  vim.api.nvim_set_hl(0, "ClaudeCompleteGhost", config.options.highlights.ghost)
  for group, link in pairs(STATUS_LINKS) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

local function strip_blank_edges(lines)
  while #lines > 0 and lines[1] == "" do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return lines
end

--- Request a completion at the cursor and show it as ghost text.
function M.trigger()
  local origin = vim.api.nvim_win_get_cursor(0)
  ghost.dismiss()
  status.start()
  claude.run(context.build_context(), context.system_prompt(), function(suggestion, err)
    status.stop()
    if err then
      vim.notify("claude-complete: " .. err, vim.log.levels.WARN)
      return
    end
    local cursor = vim.api.nvim_win_get_cursor(0)
    if cursor[1] ~= origin[1] or cursor[2] ~= origin[2] then
      return -- the user moved on; discard
    end
    local lines = strip_blank_edges(vim.split(suggestion or "", "\n", { trimempty = false }))
    if #lines > 0 then
      ghost.show(lines)
    end
  end)
end

--- Cancel an in-flight request and clear any pending ghost text.
function M.cancel()
  claude.cancel()
  status.stop()
  ghost.dismiss()
end

local function wire()
  local map = config.options.keymaps
  if map.trigger then
    vim.keymap.set("i", map.trigger, M.trigger, { desc = "Claude: complete at cursor" })
  end
  if map.cancel then
    vim.keymap.set("i", map.cancel, function()
      if claude.is_running() then
        M.cancel()
      else
        vim.api.nvim_feedkeys(vim.keycode(map.cancel), "n", false)
      end
    end, { desc = "Claude: cancel completion" })
  end

  local group = vim.api.nvim_create_augroup("ClaudeComplete", { clear = true })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    callback = function()
      M.cancel()
    end,
  })
  vim.api.nvim_create_autocmd("InsertCharPre", {
    group = group,
    callback = function()
      ghost.dismiss()
    end,
  })
end

---@param opts table|nil
function M.setup(opts)
  config.setup(opts)
  define_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = define_highlights })
  wire()
end

return M
