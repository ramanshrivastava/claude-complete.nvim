-- Headless smoke tests for the auto lane. Run with:
--   nvim --headless -u NONE \
--     --cmd 'set rtp+=.' \
--     -c 'luafile tests/worker_spec.lua'
-- Exits non-zero on the first failure.

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then
    passed = passed + 1
    print("ok   - " .. name)
  else
    failed = failed + 1
    print("FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
  end
end

-- 1. All modules load without error.
for _, mod in ipairs({
  "claude-complete.config",
  "claude-complete.worker",
  "claude-complete.auto",
  "claude-complete.ghost",
  "claude-complete.status",
  "claude-complete.health",
  "claude-complete",
}) do
  local ok, err = pcall(require, mod)
  check("require " .. mod, ok, err)
end

local config = require("claude-complete.config")
local worker = require("claude-complete.worker")

-- 2. Config exposes the auto defaults.
config.setup({})
local a = config.options.auto
check("auto defaults present", type(a) == "table" and a.enabled == false)
check("auto model default", a.model == "claude-haiku-4-5")
check("auto disabled_filetypes", vim.tbl_contains(a.disabled_filetypes, "oil"))
check("worker_env disables thinking", a.worker_env.MAX_THINKING_TOKENS == "0")

-- worker_env must be replaceable wholesale (so users can clear the default).
config.setup({ auto = { worker_env = {} } })
check("worker_env override clears default", next(config.options.auto.worker_env) == nil)
config.setup({}) -- restore defaults for the rest of the suite

-- Helper: feed a full turn's stdout lines through the real parser and capture
-- what the current request receives.
local function run_turn(lines, gen)
  local it = worker._internal
  it.reset()
  it.state.generation = gen or 1
  local captured = {}
  it.state.queue = {
    { gen = gen or 1, on_done = function(text, err)
      captured.text, captured.err, captured.called = text, err, true
    end, started_at = vim.uv.now() },
  }
  -- Split the fixture into chunks to exercise partial-line buffering: feed
  -- everything, then a final "" flush so the assembler emits the last line.
  local chunk = vim.deepcopy(lines)
  chunk[#chunk + 1] = ""
  it.feed(chunk)
  return captured
end

-- Real stream-json shapes captured from the CLI experiment (2026-07).
local assistant = vim.json.encode({
  type = "assistant",
  message = { role = "assistant", content = { { type = "text", text = "    return a + b" } } },
})
local thinking = vim.json.encode({
  type = "assistant",
  message = { role = "assistant", content = { { type = "thinking", thinking = "hmm" } } },
})
local result_ok = vim.json.encode({ type = "result", subtype = "success", is_error = false })
local result_err = vim.json.encode({ type = "result", subtype = "error_during_execution", is_error = true })
local init = vim.json.encode({ type = "system", subtype = "init", session_id = "x" })

-- 3. A successful turn: text extracted, thinking + system lines ignored.
local ok_turn = run_turn({ init, thinking, assistant, result_ok })
check("success turn delivers text", ok_turn.called and ok_turn.text == "    return a + b", ok_turn.text)
check("success turn no error", ok_turn.err == nil)

-- 4. Multi-block assistant text is concatenated.
local a1 = vim.json.encode({
  type = "assistant",
  message = { role = "assistant", content = { { type = "text", text = "foo" } } },
})
local a2 = vim.json.encode({
  type = "assistant",
  message = { role = "assistant", content = { { type = "text", text = "bar" } } },
})
local multi = run_turn({ a1, a2, result_ok })
check("multi-block text concatenated", multi.text == "foobar", multi.text)

-- 5. An error result surfaces an error, not text.
local errturn = run_turn({ init, result_err })
check("error result → err", errturn.err ~= nil and errturn.text == nil, errturn.err)

-- 6. Stale responses (generation mismatch) are dropped.
do
  local it = worker._internal
  it.reset()
  it.state.generation = 5 -- newer request already superseded gen 4
  local hit = false
  it.state.queue = {
    { gen = 4, on_done = function() hit = true end, started_at = vim.uv.now() },
  }
  local chunk = { assistant, result_ok, "" }
  it.feed(chunk)
  check("stale response dropped", hit == false)
end

-- 7. Partial-line buffering: a JSON object split across two feed() calls.
do
  local it = worker._internal
  it.reset()
  it.state.generation = 1
  local got = {}
  it.state.queue = {
    { gen = 1, on_done = function(t) got.text = t end, started_at = vim.uv.now() },
  }
  local half = math.floor(#assistant / 2)
  it.feed({ assistant:sub(1, half) }) -- no newline yet → buffered
  it.feed({ assistant:sub(half + 1), result_ok, "" })
  check("split JSON line reassembled", got.text == "    return a + b", got.text)
end

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qall!")
end
