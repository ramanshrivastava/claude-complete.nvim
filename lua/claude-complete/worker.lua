local config = require("claude-complete.config")

--- Persistent, single-process worker for the automatic completion lane.
---
--- One long-lived `claude` process is started lazily and reused across many
--- request/response cycles. Requests are written to stdin as stream-json user
--- messages; responses are parsed off stdout and delivered per request.
---
--- VERIFIED (empirically, 2026-07): with `--max-turns 1` the CLI does NOT exit
--- after the first turn. The process stays alive, and each additional user
--- message on stdin drives another single-shot turn delimited by a
--- `{"type":"result"}` line. So the "persistent multi-turn" approach is used —
--- no per-request respawn, no warm-spare pool needed. `--max-turns 1` simply
--- guarantees each turn is single-shot (no tool-loop) which keeps it fast.
local M = {}

-- FIM (fill-in-the-middle) system prompt. Kept terse on purpose: at this latency
-- budget every output/input token counts. Keeps responses to raw continuation
-- text only; the CLI exposes no max-tokens flag, so the length cap is a prompt
-- instruction.
local SYSTEM_PROMPT = [[Inline code-completion engine. The caret is marked <CURSOR>; text before it is the prefix, text after is the suffix. You cannot read files or use any tools — complete using ONLY the provided prefix and suffix, immediately. Your ENTIRE output is inserted verbatim into the file at the caret, so it must be raw code only. Output ONLY the raw text to insert to continue the code — never any prose, preamble, explanation, commentary, greeting, or question; never markdown or code fences; never <thinking>/<think> or any XML/markup wrapper or reasoning; no leading/trailing blank lines. Do not restate the task or say what you are about to do. Never repeat text already adjacent to the caret. Match the surrounding indentation and style. Keep it short (at most ~10 lines) and stop at a natural boundary. If nothing useful fits, output nothing at all.]]

---@alias ClaudeCompleteReq { gen: integer, on_done: fun(text: string?, err: string?), prompt: string, started_at: integer }

-- IMPORTANT — send serialization. The CLI reads stream-json user messages off
-- stdin, but it COALESCES/DROPS messages that arrive mid-turn (they land as
-- "queue-operation" entries in its transcript and some never become turns).
-- Sending a new request while a turn is in flight therefore desynchronises
-- request↔result matching and jams the lane (the newest, only-deliverable
-- request never meets its result). So we send AT MOST ONE message at a time:
-- `inflight` is the request currently on the wire; `pending` holds the single
-- most-recent not-yet-sent request (replacing any older one). `pending` is only
-- written to stdin once `inflight`'s `result` line arrives.
local state = {
  job = nil, ---@type integer?
  model = nil, ---@type string?  model the running job was started with
  partial = "", ---@type string  incomplete trailing stdout chunk
  parts = {}, ---@type string[]  assistant text collected for the in-progress turn
  inflight = nil, ---@type ClaudeCompleteReq?  request currently on the wire
  pending = nil, ---@type ClaudeCompleteReq?  newest request awaiting the wire
  generation = 0, ---@type integer  latest request id; older responses are stale
  failures = 0, ---@type integer  consecutive crashes with no successful result
  disabled = false, ---@type boolean  auto lane disabled for the session
  cooldown_until = 0, ---@type integer  do not (re)start before this time (backoff)
  stopping = false, ---@type boolean  intentional stop in progress (suppress restart)
  idle_timer = nil, ---@type uv_timer_t?
  last_request_at = nil, ---@type integer?
  last_latency_ms = nil, ---@type integer?
}

local MAX_RETRIES = 3

-- Indirection so headless tests can capture what would be written to stdin.
local sender = vim.fn.chansend

---@return boolean
function M.is_running()
  return state.job ~= nil
end

---@return boolean
function M.is_disabled()
  return state.disabled
end

--- A snapshot for :checkhealth / the toggle command.
---@return { running: boolean, disabled: boolean, model: string?, last_latency_ms: integer? }
function M.status()
  return {
    running = state.job ~= nil,
    disabled = state.disabled,
    model = state.model,
    last_latency_ms = state.last_latency_ms,
  }
end

--- Write a request to stdin now, restamping its start time so latency measures
--- CLI time (not queue wait), and marking it in flight. Returns whether it sent.
---@param req ClaudeCompleteReq
---@return boolean sent
local function send(req)
  req.started_at = vim.uv.now()
  local msg = vim.json.encode({
    type = "user",
    message = { role = "user", content = { { type = "text", text = req.prompt } } },
  })
  local ok = pcall(sender, state.job, msg .. "\n")
  if ok then
    state.inflight = req
    return true
  end
  return false
end

--- Deliver the finished turn to the in-flight request (dropping it if a newer
--- request superseded it), then flush any pending request onto the now-free wire.
---@param text string?
---@param err string?
local function deliver(text, err)
  local req = state.inflight
  state.inflight = nil
  if req then
    if req.gen == state.generation then
      if not err then
        state.failures = 0
        state.last_latency_ms = vim.uv.now() - req.started_at
      end
      req.on_done(text, err)
    end
    -- else stale: the user typed again after this request was sent → drop it.
  end

  -- The wire is free — send the newest pending request, if any.
  if state.pending and state.job then
    local p = state.pending
    state.pending = nil
    if not send(p) and p.gen == state.generation then
      p.on_done(nil, "failed to send request")
    end
  end
end

--- Fail the in-flight and pending requests (used on unexpected death). Callbacks
--- fire only for the current generation; older ones are silently dropped.
---@param err string
local function flush_error(err)
  local reqs = {}
  if state.inflight then
    reqs[#reqs + 1] = state.inflight
    state.inflight = nil
  end
  if state.pending then
    reqs[#reqs + 1] = state.pending
    state.pending = nil
  end
  for _, req in ipairs(reqs) do
    if req.gen == state.generation then
      req.on_done(nil, err)
    end
  end
end

--- Parse one decoded stdout object, accumulating assistant text and completing
--- the turn on the `result` line.
---@param obj table
local function handle_message(obj)
  if obj.type == "assistant" then
    local content = obj.message and obj.message.content
    if type(content) == "table" then
      for _, block in ipairs(content) do
        if block.type == "text" and block.text then
          state.parts[#state.parts + 1] = block.text
        end
      end
    end
  elseif obj.type == "result" then
    local text = table.concat(state.parts, "")
    state.parts = {}
    if obj.subtype == "success" and not obj.is_error then
      deliver(text, nil)
    elseif obj.subtype == "error_max_turns" then
      -- The turn was spent before a final answer (e.g. a tool-call attempt,
      -- now prevented by --tools ""). Not a failure — just no completion, so
      -- deliver empty text (no error path, no failure-counter bump).
      deliver("", nil)
    else
      deliver(nil, obj.subtype or "error")
    end
  end
end

---@param chunk string[]  the `data` list from on_stdout
local function feed(chunk)
  if #chunk == 0 then
    return
  end
  chunk[1] = state.partial .. chunk[1]
  state.partial = table.remove(chunk) -- last element is an incomplete line
  for _, line in ipairs(chunk) do
    if line ~= "" then
      local ok, obj = pcall(vim.json.decode, line)
      if ok and type(obj) == "table" and obj.type then
        handle_message(obj)
      end
    end
  end
end

local function stop_idle_timer()
  if state.idle_timer then
    state.idle_timer:stop()
    state.idle_timer:close()
    state.idle_timer = nil
  end
end

--- Shut the worker down (idle timeout, config change, or Vim exit). Intentional
--- stops do not count as failures and do not trigger a restart.
function M.shutdown()
  stop_idle_timer()
  if state.job then
    state.stopping = true
    pcall(vim.fn.jobstop, state.job)
    state.job = nil
  end
  state.partial, state.parts = "", {}
  flush_error("worker stopped")
end

local function arm_idle_timer()
  stop_idle_timer()
  local minutes = config.options.auto.idle_shutdown_min
  if not minutes or minutes <= 0 then
    return
  end
  local ms = math.floor(minutes * 60 * 1000)
  state.idle_timer = vim.uv.new_timer()
  state.idle_timer:start(
    ms,
    ms,
    vim.schedule_wrap(function()
      if state.last_request_at and (vim.uv.now() - state.last_request_at) >= ms then
        M.shutdown()
      end
    end)
  )
end

---@return boolean started
local function start()
  local cfg = config.options
  if state.disabled then
    return false
  end
  if vim.fn.executable(cfg.command) ~= 1 then
    state.disabled = true
    return false
  end
  if vim.uv.now() < state.cooldown_until then
    return false -- still in backoff
  end

  local model = cfg.auto.model
  local cmd = {
    cfg.command,
    "-p",
    "--input-format",
    "stream-json",
    "--output-format",
    "stream-json",
    "--verbose",
    "--model",
    model,
    "--max-turns",
    "1",
    -- Disable ALL built-in tools. haiku otherwise tries to read the file (a
    -- tool-call turn) which burns the single --max-turns 1 turn → the CLI ends
    -- with `error_max_turns` and no completion. With no tools available it must
    -- answer directly in one turn. Measured: ~33% of requests hit
    -- error_max_turns without this, 0% with it.
    "--tools",
    "",
    "--permission-mode",
    "bypassPermissions",
    "--exclude-dynamic-system-prompt-sections",
    "--system-prompt",
    SYSTEM_PROMPT,
  }

  state.partial, state.parts = "", {}
  state.stopping = false

  -- Disable extended "thinking" for THIS worker only (never the manual lane).
  -- haiku's interleaved thinking is the dominant latency tail; turning it off
  -- roughly halves warm full-completion latency. Measured (claude-haiku-4-5,
  -- warm avg of 3 requests): ~3.31s with thinking → ~1.71s with
  -- MAX_THINKING_TOKENS=0. `env` extends (does not replace) the inherited
  -- environment, so subscription auth is preserved.
  local worker_env = type(cfg.auto.worker_env) == "table" and cfg.auto.worker_env or nil
  local job = vim.fn.jobstart(cmd, {
    stdin = "pipe",
    stdout_buffered = false,
    env = worker_env,
    on_stdout = function(_, data)
      feed(data or {})
    end,
    on_stderr = function() end,
    on_exit = vim.schedule_wrap(function(_, _)
      state.job = nil
      state.partial, state.parts = "", {}
      if state.stopping then
        state.stopping = false
        return
      end
      -- Unexpected death: fail pending work, count it, back off, maybe disable.
      flush_error("worker exited")
      state.failures = state.failures + 1
      if state.failures >= MAX_RETRIES then
        state.disabled = true
        stop_idle_timer()
        vim.notify(
          "claude-complete: auto lane disabled after repeated worker failures (:ClaudeCompleteAuto on to retry)",
          vim.log.levels.WARN
        )
      else
        state.cooldown_until = vim.uv.now() + state.failures * 1000
      end
    end),
  })

  if not job or job <= 0 then
    state.job = nil
    state.failures = state.failures + 1
    if state.failures >= MAX_RETRIES then
      state.disabled = true
    end
    return false
  end
  state.job = job
  state.model = model
  arm_idle_timer()
  return true
end

--- Cancel the in-flight request without killing the process: bumping the
--- generation makes its eventual result stale (and dropped on arrival).
function M.cancel()
  state.generation = state.generation + 1
end

--- Re-enable the auto lane after it was disabled (crash loop or manual off).
function M.enable()
  state.disabled = false
  state.failures = 0
  state.cooldown_until = 0
end

--- Request a completion. Only the newest request's result is delivered; older
--- ones are superseded. At most one message is on the wire at a time: if a turn
--- is in flight, this request waits in the single `pending` slot (replacing any
--- older pending, whose callback is silently dropped — its context was already
--- cancelled) and is sent when the in-flight turn's result arrives.
---@param prompt string  the FIM user-message text
---@param on_done fun(text: string?, err: string?)
function M.request(prompt, on_done)
  if state.disabled then
    on_done(nil, "auto lane disabled")
    return
  end
  -- Restart if the configured model changed under a running worker.
  if state.job and state.model ~= config.options.auto.model then
    M.shutdown()
  end
  if not state.job and not start() then
    on_done(nil, "worker unavailable")
    return
  end

  state.generation = state.generation + 1
  state.last_request_at = vim.uv.now()
  local req = { gen = state.generation, on_done = on_done, prompt = prompt, started_at = vim.uv.now() }

  if state.inflight then
    -- A turn is on the wire; hold the newest request. Replace (and silently
    -- drop) any older pending — blink/the ghost lane already cancelled it.
    state.pending = req
  elseif not send(req) then
    on_done(nil, "failed to send request")
  end
end

-- Internal seam for headless tests only (tests/worker_spec.lua). Exercises the
-- real stdout line assembler and message handler without spawning a process.
-- Not part of the public API.
M._internal = {
  state = state,
  feed = feed,
  send = send,
  --- Override the stdin writer to capture messages instead of sending them.
  ---@param fn fun(job: integer, data: string): any
  set_sender = function(fn)
    sender = fn
  end,
  reset_sender = function()
    sender = vim.fn.chansend
  end,
  reset = function()
    state.inflight, state.pending = nil, nil
    state.parts, state.partial = {}, ""
    state.generation = 0
    state.last_latency_ms = nil
    state.job = nil
  end,
}

return M
