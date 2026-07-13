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

-- 8. Auto-lane source badge (ghost.lua). Display-only: present when shown with
-- a hint, never inserted on accept, absent when omitted.
do
  local ghost = require("claude-complete.ghost")
  local gns = vim.api.nvim_get_namespaces()["claude_complete_ghost"]

  local function badge_present(buf, needle)
    local marks = vim.api.nvim_buf_get_extmarks(buf, gns, 0, -1, { details = true })
    for _, m in ipairs(marks) do
      local vt = m[4] and m[4].virt_text
      if vt then
        for _, chunk in ipairs(vt) do
          if type(chunk[1]) == "string" and chunk[1]:find(needle, 1, true) then
            return true
          end
        end
      end
    end
    return false
  end

  vim.cmd("enew!")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "def add(a, b):", "" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  ghost.show({ "    return a + b" }, "󰚩 haiku-4-5")
  check("badge present when hint given", badge_present(buf, "haiku-4-5"))

  ghost.accept()
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  check("accept inserts completion", text:find("return a + b", 1, true) ~= nil)
  check("accept excludes badge text", text:find("haiku", 1, true) == nil)

  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  ghost.show({ "xyz" }) -- no hint → manual-lane behaviour
  check("no badge when hint omitted", not badge_present(buf, "haiku"))
  ghost.dismiss()
end

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qall!")
end
