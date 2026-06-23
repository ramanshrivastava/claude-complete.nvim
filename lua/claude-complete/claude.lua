local config = require("claude-complete.config")

local M = {}

local state = {
  job = nil, ---@type integer?
  stdout = {}, ---@type string[]
  stderr = {}, ---@type string[]
  scanned = 0, ---@type integer  index of the last stdout line scanned for tools
  tools = {}, ---@type table[]    recent tool events (newest last, capped at 5)
  timeout = nil, ---@type uv_timer_t?
}

---@return boolean
function M.is_running()
  return state.job ~= nil
end

--- Newest tool-activity events seen so far (incrementally parsed).
---@return { tools: table[], count: integer }
function M.scan()
  for i = state.scanned + 1, #state.stdout do
    local line = state.stdout[i]
    if line:find("tool_use", 1, true) then
      local name = line:match('"name"%s*:%s*"([^"]*)"')
      if name then
        local param = line:match('"file_path"%s*:%s*"([^"]*)"')
          or line:match('"path"%s*:%s*"([^"]*)"')
          or line:match('"command"%s*:%s*"([^"]*)"')
          or line:match('"pattern"%s*:%s*"([^"]*)"')
          or line:match('"query"%s*:%s*"([^"]*)"')
          or line:match('"url"%s*:%s*"([^"]*)"')
        if param and #param > 60 then
          param = param:sub(1, 60)
        end
        state.tools[#state.tools + 1] =
          { name = name, param = param, started_at = vim.uv.now(), status = "running" }
        if #state.tools > 5 then
          table.remove(state.tools, 1)
        end
      end
    elseif line:find("tool_result", 1, true) then
      local is_error = line:find('"is_error"%s*:%s*true') ~= nil
      for h = #state.tools, 1, -1 do
        if state.tools[h].status == "running" then
          state.tools[h].status = is_error and "error" or "done"
          state.tools[h].duration_ms = vim.uv.now() - state.tools[h].started_at
          break
        end
      end
    end
  end
  state.scanned = #state.stdout
  return { tools = state.tools, count = #state.tools }
end

---@param lines string[]
---@return string?
local function parse_suggestion(lines)
  local text
  for _, line in ipairs(lines) do
    local ok, obj = pcall(vim.json.decode, line)
    if ok and type(obj) == "table" and obj.type == "assistant" then
      local content = obj.message and obj.message.content
      if type(content) == "table" then
        for _, block in ipairs(content) do
          if block.type == "text" and block.text then
            text = block.text
          end
        end
      end
    end
  end
  return text
end

--- Keep only code: drop markdown code fences, and "★ Insight" blocks that some
--- output styles inject between ─── separators.
---@param text string?
---@return string?
local function sanitize(text)
  if not text then
    return nil
  end
  local out, skipping = {}, false
  for _, line in ipairs(vim.split(text, "\n")) do
    if line:find("★ Insight", 1, true) then
      skipping = true
    elseif skipping and line:match("^[`%s]*[─-]+[`%s]*$") then
      skipping = false
    elseif not skipping and not line:match("^%s*```%w*%s*$") then
      out[#out + 1] = line
    end
  end
  return table.concat(out, "\n")
end

function M.cancel()
  if state.timeout then
    state.timeout:stop()
    state.timeout:close()
    state.timeout = nil
  end
  if state.job then
    pcall(vim.fn.jobstop, state.job)
    state.job = nil
  end
  state.stdout, state.stderr, state.tools, state.scanned = {}, {}, {}, 0
end

--- Run the CLI with `context` on stdin under `system` (--system-prompt).
--- Calls `on_done(suggestion|nil, err|nil)`.
---@param context string
---@param system string
---@param on_done fun(suggestion: string?, err: string?)
---@return boolean started
function M.run(context, system, on_done)
  local cfg = config.options
  if vim.fn.executable(cfg.command) ~= 1 then
    on_done(nil, cfg.command .. " not found in PATH")
    return false
  end
  M.cancel()

  local cmd = { cfg.command }
  vim.list_extend(cmd, cfg.cli_args)
  vim.list_extend(cmd, { "--model", cfg.model, "--system-prompt", system })

  state.job = vim.fn.jobstart(cmd, {
    stdin = "pipe",
    stdout_buffered = false,
    on_stdout = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= "" then
          state.stdout[#state.stdout + 1] = line
        end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= "" then
          state.stderr[#state.stderr + 1] = line
        end
      end
    end,
    on_exit = vim.schedule_wrap(function(_, code)
      local stdout, stderr = state.stdout, state.stderr
      M.cancel()
      if code ~= 0 then
        on_done(nil, #stderr > 0 and table.concat(stderr, " ") or "exited " .. code)
      else
        on_done(sanitize(parse_suggestion(stdout)), nil)
      end
    end),
  })

  if not state.job or state.job <= 0 then
    state.job = nil
    on_done(nil, "failed to start " .. cfg.command)
    return false
  end

  vim.fn.chansend(state.job, context)
  vim.fn.chanclose(state.job, "stdin")

  state.timeout = vim.uv.new_timer()
  state.timeout:start(
    cfg.timeout_ms,
    0,
    vim.schedule_wrap(function()
      if state.job then
        M.cancel()
        on_done(nil, ("timed out (%dms)"):format(cfg.timeout_ms))
      end
    end)
  )
  return true
end

return M
