local config = require("claude-complete.config")
local claude = require("claude-complete.claude")

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

--- Turn the tool history into colourable rows plus a plain body.
---@return table[] structured, string body
local function build(tools, count, elapsed)
  local rows, body = {}, {}
  if #tools == 0 then
    rows[1] = { text = "Thinking…", kind = "thinking" }
    return rows, "Thinking…"
  end
  for _, t in ipairs(tools) do
    local prefix = t.status == "running" and "▸ "
      or (t.status == "error" and "  ✗ " or "  ✓ ")
    local line = prefix .. t.name .. (t.param and ("  " .. t.param) or "")
    local timing
    if t.status ~= "running" and t.duration_ms then
      timing = fmt_dur(t.duration_ms)
      line = line .. string.rep(" ", 6) .. timing
    end
    rows[#rows + 1] = {
      text = line,
      kind = t.status == "running" and "current" or "history",
      name = t.name,
      param = t.param,
      prefix = prefix,
      status = t.status,
      timing = timing,
    }
    body[#body + 1] = line
  end
  local width = 0
  for _, l in ipairs(body) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  rows[#rows + 1] = { text = string.rep("─", width), kind = "sep" }
  rows[#rows + 1] = { text = string.format("⚡ %d tools · %ds", count, elapsed), kind = "footer" }
  vim.list_extend(body, { rows[#rows - 1].text, rows[#rows].text })
  return rows, table.concat(body, "\n")
end

--- Paint extmark highlights onto the snacks notification buffer.
local function apply_highlights(buf)
  if not structured or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, notif_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, e in ipairs(structured) do
    local text = lines[i]
    if not text then
      break
    end
    local row = i - 1
    local function mark(col, ecol, hl)
      vim.api.nvim_buf_set_extmark(buf, notif_ns, row, col, { end_col = ecol, hl_group = hl })
    end
    if e.kind == "thinking" then
      mark(0, #text, "ClaudeCompleteThinking")
    elseif e.kind == "sep" then
      mark(0, #text, "ClaudeCompleteSep")
    elseif e.kind == "footer" then
      mark(0, #text, "ClaudeCompleteFooter")
    else
      local plen = #(e.prefix or "")
      local pre_hl = e.status == "running" and "ClaudeCompleteArrow"
        or (e.status == "error" and "ClaudeCompleteError" or "ClaudeCompleteSuccess")
      mark(0, plen, pre_hl)
      local nend = plen + #(e.name or "")
      if nend <= #text then
        mark(plen, nend, e.kind == "current" and "ClaudeCompleteCurrent" or "ClaudeCompleteHistory")
      end
      local pend = #text
      if e.param then
        if e.timing then
          pend = #text - #e.timing - 6
        end
        if nend + 2 < pend then
          mark(nend + 2, pend, "ClaudeCompleteParam")
        end
      end
      if e.timing then
        mark(#text - #e.timing, #text, "ClaudeCompleteTiming")
      end
    end
  end
end

local function render(frame_char, rows, body)
  if has_rich() then
    Snacks.notifier.notify(body, "info", {
      id = NOTIF_ID,
      title = frame_char .. " Claude",
      icon = "",
      hl = { title = "ClaudeCompleteTitle" },
      opts = function(n)
        if n.win and n.win.buf and vim.api.nvim_buf_is_valid(n.win.buf) then
          apply_highlights(n.win.buf)
        end
      end,
    })
  else
    local action = rows[1] and rows[1].text:gsub("^%s*[▸✓✗]%s*", "") or "…"
    vim.api.nvim_echo(
      { { frame_char .. " Claude ", "ClaudeCompleteTitle" }, { "· " .. action, "Comment" } },
      false,
      {}
    )
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
      local rows, body = build(scan.tools, scan.count, math.floor((vim.uv.now() - started) / 1000))
      structured = rows
      render(FRAMES[(frame % #FRAMES) + 1], rows, body)
    end)
  )
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
