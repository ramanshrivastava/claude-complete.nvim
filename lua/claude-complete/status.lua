local config = require("claude-complete.config")
local claude = require("claude-complete.claude")
local context = require("claude-complete.context")

local M = {}

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local NOTIF_ID = "claude_complete_status"
local notif_ns = vim.api.nvim_create_namespace("claude_complete_status")

local timer, frame, started, structured

---@param ms integer
---@return string
local function fmt_dur(ms)
  local s = ms / 1000
  return s < 10 and string.format("%.1fs", s) or string.format("%ds", math.floor(s))
end

local function has_rich()
  return config.options.ui.rich and _G.Snacks ~= nil and Snacks.notifier ~= nil
end

---@param frame_char string
---@param elapsed integer
---@return string
local function title(frame_char, elapsed)
  return string.format("%s Claude · %s · %ds", frame_char, config.options.model, elapsed)
end

--- Build the panel body: a context line, the tool activity, and a footer.
---@return table[] rows, string body
local function build(tools, count, elapsed)
  local rows, body = {}, {}

  local s = config.options.ui.context_line and context.summary()
  if s then
    local line = string.format("%s (%s) · %d lines · %s", s.relpath, s.ft, s.sent_lines, s.branch)
    rows[#rows + 1] = { text = line, kind = "context" }
    body[#body + 1] = line
  end

  if #tools == 0 then
    rows[#rows + 1] = { text = "Thinking…", kind = "thinking" }
    body[#body + 1] = "Thinking…"
  else
    local namew = 0
    for _, t in ipairs(tools) do
      namew = math.max(namew, #t.name)
    end
    for _, t in ipairs(tools) do
      local prefix = t.status == "running" and "▸ "
        or (t.status == "error" and "  ✗ " or "  ✓ ")
      local line = prefix .. t.name .. string.rep(" ", namew - #t.name)
      if t.param then
        line = line .. "  " .. t.param
      end
      if t.status ~= "running" and t.duration_ms then
        line = line .. string.rep(" ", 4) .. fmt_dur(t.duration_ms)
      end
      rows[#rows + 1] = {
        text = line,
        kind = t.status == "running" and "current" or "history",
        prefix = prefix,
        status = t.status,
      }
      body[#body + 1] = line
    end
    local width = 0
    for _, l in ipairs(body) do
      width = math.max(width, vim.fn.strdisplaywidth(l))
    end
    local footer = string.format("⚡ %d tools · %ds", count, elapsed)
    rows[#rows + 1] = { text = string.rep("─", width), kind = "sep" }
    rows[#rows + 1] = { text = footer, kind = "footer" }
    body[#body + 1] = rows[#rows - 1].text
    body[#body + 1] = footer
  end

  return rows, table.concat(body, "\n")
end

--- Colour the snacks notification buffer: prefix by status, the rest by row kind.
local function apply_highlights(buf)
  if not structured or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, notif_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local function mark(row, col, ecol, hl)
    vim.api.nvim_buf_set_extmark(buf, notif_ns, row, col, { end_col = ecol, hl_group = hl })
  end
  for i, e in ipairs(structured) do
    local text = lines[i]
    if not text then
      break
    end
    local whole = {
      context = "ClaudeCompleteContext",
      thinking = "ClaudeCompleteThinking",
      sep = "ClaudeCompleteSep",
      footer = "ClaudeCompleteFooter",
    }
    if whole[e.kind] then
      mark(i - 1, 0, #text, whole[e.kind])
    else
      local plen = #(e.prefix or "")
      local pre = e.status == "running" and "ClaudeCompleteArrow"
        or (e.status == "error" and "ClaudeCompleteError" or "ClaudeCompleteSuccess")
      mark(i - 1, 0, plen, pre)
      mark(
        i - 1,
        plen,
        #text,
        e.kind == "current" and "ClaudeCompleteCurrent" or "ClaudeCompleteHistory"
      )
    end
  end
end

local function render(frame_char, elapsed, rows, body)
  if has_rich() then
    Snacks.notifier.notify(body, "info", {
      id = NOTIF_ID,
      title = title(frame_char, elapsed),
      icon = "",
      hl = { title = "ClaudeCompleteTitle" },
      opts = function(n)
        if n.win and n.win.buf and vim.api.nvim_buf_is_valid(n.win.buf) then
          apply_highlights(n.win.buf)
        end
      end,
    })
  else
    local action = rows[#rows] and rows[#rows].kind ~= "footer" and rows[#rows].text
      or (rows[1] and rows[1].text)
      or "…"
    vim.api.nvim_echo({
      { title(frame_char, elapsed), "ClaudeCompleteTitle" },
      { "  " .. action:gsub("^%s*[▸✓✗]%s*", ""), "Comment" },
    }, false, {})
  end
end

function M.start()
  M.stop()
  frame, started = 0, vim.uv.now()
  timer = vim.uv.new_timer()
  timer:start(
    0,
    100,
    vim.schedule_wrap(function()
      if not claude.is_running() then
        return
      end
      frame = frame + 1
      local scan = claude.scan()
      local elapsed = math.floor((vim.uv.now() - started) / 1000)
      local rows, body = build(scan.tools, scan.count, elapsed)
      structured = rows
      render(FRAMES[(frame % #FRAMES) + 1], elapsed, rows, body)
    end)
  )
end

--- A single, non-intrusive line for the auto lane (toggle, disable notices).
--- Deliberately minimal — the auto lane must not spam the live panel per request.
---@param msg string
---@param level integer?
function M.notify_auto(msg, level)
  local opts = { title = "claude-complete" }
  if has_rich() then
    opts.id = NOTIF_ID .. "_auto"
  end
  vim.notify(msg, level or vim.log.levels.INFO, opts)
end

function M.stop()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  structured = nil
  vim.schedule(function()
    if has_rich() then
      Snacks.notifier.hide(NOTIF_ID)
    else
      vim.api.nvim_echo({ { "" } }, false, {})
    end
  end)
end

return M
