local config = require("claude-complete.config")
local worker = require("claude-complete.worker")
local ghost = require("claude-complete.ghost")
local claude = require("claude-complete.claude")

--- The automatic, Cursor-style completion lane: shows fast ghost text when the
--- user pauses typing. Lightweight FIM context, one persistent worker, and the
--- same ghost/accept machinery as the manual <C-g> lane.
local M = {}

local ABOVE = 60 -- lines of prefix context above the cursor
local BELOW = 20 -- lines of suffix context below the cursor

local debounce_timer = nil ---@type uv_timer_t?
local augroup = nil ---@type integer?
local enabled = false

--- blink.cmp menu open? Guarded — blink may be absent or its API may change.
---@return boolean
local function completion_menu_visible()
  if package.loaded["blink.cmp"] then
    local ok, visible = pcall(function()
      return require("blink.cmp").is_visible()
    end)
    if ok and visible then
      return true
    end
  end
  -- Fall back to the native pum (nvim-cmp etc.).
  return vim.fn.pumvisible() == 1
end

--- Whether an automatic completion should be attempted for the current buffer.
---@return boolean
local function should_trigger()
  if not enabled or worker.is_disabled() then
    return false
  end
  if vim.api.nvim_get_mode().mode ~= "i" then
    return false
  end
  -- Never step on the manual lane or an already-visible suggestion.
  if claude.is_running() or ghost.is_active() then
    return false
  end
  -- By default we coexist with the completion menu (Copilot/Cursor behaviour):
  -- blink auto-opens on nearly every pause, so skipping when it is visible
  -- starves the lane. `show_with_menu = false` restores the old guard.
  if not config.options.auto.show_with_menu and completion_menu_visible() then
    return false
  end

  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.bo[bufnr].modifiable or vim.bo[bufnr].buftype ~= "" then
    return false
  end
  local ft = vim.bo[bufnr].filetype
  if vim.tbl_contains(config.options.auto.disabled_filetypes, ft) then
    return false
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count > config.options.auto.max_lines then
    return false
  end
  local bytes = vim.api.nvim_buf_get_offset(bufnr, line_count)
  if bytes > 0 and bytes > config.options.auto.max_filesize_kb * 1024 then
    return false
  end
  return true
end

--- Build the light FIM prompt: file/lang header + prefix + <CURSOR> + suffix.
---@return string
local function build_prompt()
  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  local relpath = name ~= "" and vim.fn.fnamemodify(name, ":~:.") or "[No Name]"
  local ft = vim.bo[bufnr].filetype
  if ft == "" then
    ft = "text"
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1], cursor[2]
  local total = vim.api.nvim_buf_line_count(bufnr)

  local lo = math.max(1, row - ABOVE)
  local hi = math.min(total, row + BELOW)
  local cur = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""

  local prefix = {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, lo - 1, row - 1, false)) do
    prefix[#prefix + 1] = l
  end
  prefix[#prefix + 1] = cur:sub(1, col)

  local suffix = { cur:sub(col + 1) }
  for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, row, hi, false)) do
    suffix[#suffix + 1] = l
  end

  return string.format(
    "<file>%s</file>\n<language>%s</language>\n\n%s<CURSOR>%s",
    relpath,
    ft,
    table.concat(prefix, "\n"),
    table.concat(suffix, "\n")
  )
end

--- A short, human name for the badge: drop the "claude-" prefix and any trailing
--- 8-digit date, e.g. "claude-haiku-4-5-20251001" → "haiku-4-5".
---@param model string
---@return string
local function short_model(model)
  return (model:gsub("^claude%-", ""):gsub("%-%d%d%d%d%d%d%d%d$", ""))
end

--- The source badge for the current config, or nil when disabled.
---@return string?
local function hint_text()
  local h = config.options.auto.hint
  if not h or not h.enabled then
    return nil
  end
  return h.text or ("󰚩 " .. short_model(config.options.auto.model))
end

-- Case-insensitive tag bodies for Lua patterns (Lua has no /i flag).
local THINKING = "[Tt][Hh][Ii][Nn][Kk][Ii][Nn][Gg]" -- <thinking>
local THINK = "[Tt][Hh][Ii][Nn][Kk]" -- <think>

--- Strip in-band reasoning wrappers. With MAX_THINKING_TOKENS=0 some models
--- leak <thinking>…</thinking> spans as plain assistant text instead of code.
--- Removes complete spans, a lone unterminated opening tag (drop to end), and
--- any stray tags. `.` matches newlines in Lua patterns, so `.-`/`.*` span
--- multiple lines. Returns the whitespace-trimmed remainder.
---@param text string?
---@return string
local function strip_reasoning(text)
  if not text or text == "" then
    return ""
  end
  local t = text
  -- Complete spans first (non-greedy), both tag variants.
  t = t:gsub("<" .. THINKING .. ">.-</" .. THINKING .. ">", "")
  t = t:gsub("<" .. THINK .. ">.-</" .. THINK .. ">", "")
  -- Unterminated opening tag: drop it and everything after.
  t = t:gsub("<" .. THINKING .. ">.*", "")
  t = t:gsub("<" .. THINK .. ">.*", "")
  -- Any stray opening/closing tags left behind.
  t = t:gsub("</?" .. THINKING .. ">", "")
  t = t:gsub("</?" .. THINK .. ">", "")
  return vim.trim(t)
end

--- Strip stray code fences and blank edges the model may emit despite the prompt.
---@param text string
---@return string[]
local function to_lines(text)
  local lines = {}
  for _, line in ipairs(vim.split(text, "\n", { trimempty = false })) do
    if not line:match("^%s*```%w*%s*$") then
      lines[#lines + 1] = line
    end
  end
  while #lines > 0 and lines[1] == "" do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return lines
end

--- Full sanitize pipeline: drop reasoning wrappers, then fences/blank edges.
--- Whitespace-only or reasoning-only output yields no lines (no ghost shown).
---@param text string?
---@return string[]
local function sanitize(text)
  local stripped = strip_reasoning(text)
  if stripped == "" then
    return {}
  end
  return to_lines(stripped)
end

local function request()
  if not should_trigger() then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local origin = vim.api.nvim_win_get_cursor(0)

  worker.request(build_prompt(), function(text, err)
    if err or not text then
      return -- auto lane fails silently; the worker handles restarts/notices
    end
    -- Discard if the user moved on or the context changed under us.
    if vim.api.nvim_get_mode().mode ~= "i" then
      return
    end
    if vim.api.nvim_get_current_buf() ~= bufnr then
      return
    end
    local cursor = vim.api.nvim_win_get_cursor(0)
    if cursor[1] ~= origin[1] or cursor[2] ~= origin[2] then
      return
    end
    if claude.is_running() or ghost.is_active() then
      return
    end
    -- In conservative mode, also bail if the menu opened during the round-trip.
    if not config.options.auto.show_with_menu and completion_menu_visible() then
      return
    end
    local lines = sanitize(text)
    if #lines > 0 then
      ghost.show(lines, hint_text())
    end
  end)
end

--- (Re)start the idle debounce that fires the next request.
local function arm_debounce()
  if not debounce_timer then
    debounce_timer = vim.uv.new_timer()
  end
  debounce_timer:stop()
  debounce_timer:start(config.options.auto.debounce_ms, 0, vim.schedule_wrap(request))
end

--- Buffer content changed (a keystroke, paste, or accepting a completion-menu
--- item). Any such change invalidates the current suggestion, so dismiss the
--- ghost and cancel the in-flight request before re-arming the debounce. This
--- is the one true conflict when coexisting with the menu: accepting a menu
--- item is a programmatic change (no InsertCharPre), so we clear the ghost here.
local function on_change()
  worker.cancel()
  ghost.dismiss()
  arm_debounce()
end

--- Cursor held idle in insert mode. Only re-arm the debounce — do NOT dismiss:
--- the user may be reading a just-shown suggestion, and CursorHoldI fires after
--- idle, which would otherwise erase it.
local function on_hold()
  arm_debounce()
end

--- Wire the autocmds that drive the auto lane. Idempotent.
function M.enable()
  if enabled then
    return
  end
  worker.enable()
  enabled = true

  augroup = vim.api.nvim_create_augroup("ClaudeCompleteAuto", { clear = true })
  vim.api.nvim_create_autocmd("TextChangedI", { group = augroup, callback = on_change })
  vim.api.nvim_create_autocmd("CursorHoldI", { group = augroup, callback = on_hold })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = augroup,
    callback = function()
      worker.cancel()
      if debounce_timer then
        debounce_timer:stop()
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
      worker.shutdown()
    end,
  })
end

--- Tear the auto lane down: stop autocmds, cancel work, shut the worker.
function M.disable()
  enabled = false
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end
  if debounce_timer then
    debounce_timer:stop()
  end
  worker.shutdown()
end

---@return boolean
function M.is_enabled()
  return enabled
end

-- Internal seam for headless tests (tests/worker_spec.lua). Not public API.
M._sanitize = sanitize

--- Toggle the lane, returning the new state.
---@return boolean enabled
function M.toggle()
  if enabled then
    M.disable()
  else
    M.enable()
  end
  return enabled
end

return M
