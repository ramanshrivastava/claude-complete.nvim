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
  "claude-complete.blink",
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
check("show_with_menu default true", a.show_with_menu == true)

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

-- error_max_turns is treated as an empty completion, not an error.
local result_maxturns = vim.json.encode({ type = "result", subtype = "error_max_turns", is_error = true })
local maxturns = run_turn({ init, assistant, result_maxturns })
check("error_max_turns → empty text", maxturns.called and maxturns.text == "")
check("error_max_turns → no err", maxturns.err == nil)

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

  -- Tab precedence: while ghost is shown, a buffer-local <Tab> maps to
  -- ghost.accept. Buffer-local + nowait wins over blink's global <Tab>.
  local m = vim.fn.maparg("<Tab>", "i", false, true)
  check("Tab is buffer-local while ghost shown", m.buffer == 1)
  check("Tab accepts the claude ghost", m.callback == ghost.accept)

  ghost.accept()
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  check("accept inserts completion", text:find("return a + b", 1, true) ~= nil)
  check("accept excludes badge text", text:find("haiku", 1, true) == nil)

  -- After accept/dismiss our <Tab> is removed, so blink's global map is live again.
  local m2 = vim.fn.maparg("<Tab>", "i", false, true)
  check("Tab mapping released after accept", vim.tbl_isempty(m2) or m2.buffer ~= 1)

  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  ghost.show({ "xyz" }) -- no hint → manual-lane behaviour
  check("no badge when hint omitted", not badge_present(buf, "haiku"))
  ghost.dismiss()
end

-- 9. Coexistence with the completion menu: a content change (e.g. accepting a
-- menu item — a programmatic edit with no InsertCharPre) must dismiss the ghost.
do
  local auto = require("claude-complete.auto")
  local ghost = require("claude-complete.ghost")
  config.setup({}) -- show_with_menu = true
  vim.cmd("enew!")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello" })
  vim.api.nvim_win_set_cursor(0, { 1, 5 })

  auto.enable()
  ghost.show({ "world" })
  check("ghost active before change", ghost.is_active())
  vim.api.nvim_exec_autocmds("TextChangedI", {}) -- simulate menu-accept / edit
  check("content change dismisses ghost", not ghost.is_active())
  auto.disable()
end

-- 10. Sanitizer strips in-band reasoning wrappers (MAX_THINKING_TOKENS=0 leak).
do
  local auto = require("claude-complete.auto")
  local san = auto._sanitize
  local function joined(t)
    return table.concat(t, "\n")
  end

  check("tag-only yields no ghost (repro)", #san("<thinking>") == 0)
  check("wrapped span removed", joined(san("<thinking>let me reason</thinking>\nreturn a + b")) == "return a + b")
  check("unterminated tag dropped to end", joined(san("return a + b\n<thinking>now I should")) == "return a + b")
  check("<think> variant removed", joined(san("<think>hmm</think>foo()")) == "foo()")
  check("stray closing tag removed", joined(san("bar</thinking>")) == "bar")
  check("multiline reasoning then code", joined(san("<thinking>\nline one\nline two\n</thinking>\nx = 1\ny = 2")) == "x = 1\ny = 2")
  check("reasoning-only yields no ghost", #san("<thinking>only thoughts, no code</thinking>") == 0)
  check("plain code untouched", joined(san("const x = 1")) == "const x = 1")
  check("fences still stripped", joined(san("```lua\nlocal x = 1\n```")) == "local x = 1")

  -- Fenced-code extraction + prose-preamble dropping.
  local preamble = "I need to complete this fibonacci function. Let me provide the code:\n"
    .. "```python\ndef fibonacci(n):\n    if n < 2:\n        return n\n```"
  check("fenced block after preamble → code only",
    joined(san(preamble)) == "def fibonacci(n):\n    if n < 2:\n        return n")
  check("multiple fences → first wins",
    joined(san("```\nfirst = 1\n```\nprose\n```\nsecond = 2\n```")) == "first = 1")
  check("fence with language tag",
    joined(san("```typescript\nconst y = 2;\n```")) == "const y = 2;")
  check("~~~ fences supported",
    joined(san("~~~\nx = 1\n~~~")) == "x = 1")
  check("no-fence passthrough", joined(san("return a + b")) == "return a + b")
  check("prose-only (colon) → empty", #san("Here is the completion:") == 0)
  check("prose-only (period) → empty", #san("I need more context to help.") == 0)
  -- Conservative: legit code that ends with ':' must NOT be treated as prose.
  check("code 'if n == 0:' kept", joined(san("if n == 0:\n    return 0")) == "if n == 0:\n    return 0")
  check("code 'class Foo:' kept (lowercase start)", joined(san("class Foo:\n    pass")) == "class Foo:\n    pass")
  check("code 'else:' kept (single word)", joined(san("else:\n    return 1")) == "else:\n    return 1")
end

-- 11. blink.cmp source: item shape, enabled() flag, cancellation drops stale.
do
  local Source = require("claude-complete.blink")
  local worker = require("claude-complete.worker")
  config.setup({})

  -- Item shape (via the internal seam, no blink runtime needed).
  local ctx = { cursor = { 5, 3 }, keyword = "ret" }
  local single = Source._make_item(ctx, "return a + b", {})
  check("label is first line", single.label == "return a + b")
  check("insertText is full text", single.insertText == "return a + b")
  check("kind_name is Haiku", single.kind_name == "Haiku")
  check("kind_icon set", single.kind_icon == "󰚩 ")
  check("textEdit anchored at cursor", single.textEdit.range.start.line == 4
    and single.textEdit.range.start.character == 3
    and single.textEdit.range["end"].character == 3)
  check("filterText is the keyword", single.filterText == "ret")

  local ml = Source._make_item(ctx, "if x then\n  return 1\nend", {})
  check("multiline label truncated with ellipsis", ml.label == "if x then…")
  check("multiline insert keeps all lines", ml.insertText == "if x then\n  return 1\nend")

  local long = string.rep("a", 80)
  local lt = Source._make_item(ctx, long, {})
  check("long label truncated to 60 + ellipsis", lt.label == string.rep("a", 60) .. "…")

  -- enabled() honours the advisory flag.
  local src = Source.new({})
  config.setup({ auto = { blink = { enabled = false } } })
  check("enabled() false when flag false", src:enabled() == false)
  config.setup({ auto = { blink = { enabled = true } } })
  check("enabled() true when flag true", src:enabled() == true)

  -- Cancellation: a cancelled context must not deliver its (late) response.
  config.setup({ auto = { debounce_ms = 5 } })
  vim.cmd("enew!")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "def f():", "    " })
  vim.api.nvim_win_set_cursor(0, { 2, 4 })

  local orig = worker.request
  local captured
  worker.request = function(_, on_done)
    captured = on_done
  end

  local fake_ctx = { cursor = { 2, 4 }, get_keyword = function() return "" end }

  -- Positive path first: fresh context delivers one item.
  local got_ok
  Source.new({}):get_completions(fake_ctx, function(resp) got_ok = resp end)
  vim.wait(300, function() return captured ~= nil end)
  check("worker fired after debounce", captured ~= nil)
  if captured then captured("return None", nil) end
  check("delivers exactly one item", got_ok ~= nil and #got_ok.items == 1)
  check("delivered item label", got_ok and got_ok.items[1].label == "return None")

  -- Cancellation path.
  captured = nil
  local got_cancel
  local cancel = Source.new({}):get_completions(fake_ctx, function(resp) got_cancel = resp end)
  vim.wait(300, function() return captured ~= nil end)
  cancel()
  if captured then captured("stale = true", nil) end
  check("cancelled response dropped", got_cancel == nil)

  worker.request = orig
  config.setup({})
end

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qall!")
end
