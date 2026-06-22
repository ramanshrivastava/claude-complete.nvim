local config = require("claude-complete.config")

local M = {}

local ns = vim.api.nvim_create_namespace("claude_complete_ghost")
local HL = "ClaudeCompleteGhost"
local DISPLAY_MAX = 20

local active = nil ---@type { lines: string[], bufnr: integer, row: integer, col: integer, key: string|false }?

---@return boolean
function M.is_active()
  return active ~= nil
end

--- Show `lines` as ghost text at the cursor and bind the accept key (buffer-local).
---@param lines string[]
function M.show(lines)
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local virt_lines = {}
  for i = 2, math.min(#lines, DISPLAY_MAX) do
    virt_lines[#virt_lines + 1] = { { lines[i], HL } }
  end
  if #lines > DISPLAY_MAX then
    virt_lines[#virt_lines + 1] =
      { { ("  … (accept to insert all %d lines)"):format(#lines), HL } }
  end

  vim.api.nvim_buf_set_extmark(bufnr, ns, cursor[1] - 1, cursor[2], {
    virt_text = { { lines[1] or "", HL } },
    virt_text_pos = "inline",
    virt_lines = #virt_lines > 0 and virt_lines or nil,
  })

  local key = config.options.keymaps.accept
  if key then
    vim.keymap.set("i", key, M.accept, { buffer = bufnr, nowait = true })
  end
  active = { lines = lines, bufnr = bufnr, row = cursor[1], col = cursor[2], key = key }
end

--- Insert the suggestion at the stored cursor position.
function M.accept()
  if not active then
    return
  end
  local a = active
  vim.api.nvim_buf_clear_namespace(a.bufnr, ns, 0, -1)

  local line = vim.api.nvim_buf_get_lines(a.bufnr, a.row - 1, a.row, false)[1] or ""
  local before, after = line:sub(1, a.col), line:sub(a.col + 1)

  local new = {}
  for i, l in ipairs(a.lines) do
    new[i] = (i == 1) and (before .. l) or l
  end
  new[#new] = new[#new] .. after
  vim.api.nvim_buf_set_lines(a.bufnr, a.row - 1, a.row, false, new)
  vim.api.nvim_win_set_cursor(0, { a.row - 1 + #a.lines, #new[#new] - #after })

  M.dismiss()
end

--- Clear the ghost text and unbind the accept key.
function M.dismiss()
  if not active then
    return
  end
  if vim.api.nvim_buf_is_valid(active.bufnr) then
    vim.api.nvim_buf_clear_namespace(active.bufnr, ns, 0, -1)
    if active.key then
      pcall(vim.keymap.del, "i", active.key, { buffer = active.bufnr })
    end
  end
  active = nil
end

return M
