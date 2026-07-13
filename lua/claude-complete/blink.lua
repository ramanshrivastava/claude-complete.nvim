local config = require("claude-complete.config")
local worker = require("claude-complete.worker")
local auto = require("claude-complete.auto")

--- A blink.cmp completion source that surfaces a Haiku continuation as a single
--- row inside the completion menu (instead of, or alongside, the ghost-text auto
--- lane). It reuses the SAME persistent worker, light FIM context, and output
--- sanitizer (thinking tags + fences stripped) as the auto lane.
---
--- Register it via blink's `sources.providers` (see the README). Independent of
--- the ghost lane — both can be enabled; the flag `auto.blink.enabled` is only
--- advisory input to `enabled()` (a user who wires the provider has opted in).
---
--- Protocol (blink.cmp v1.x): implements new/get_completions/enabled. Items use
--- a cursor-anchored `textEdit` so the full (multi-line) completion is inserted
--- at the caret without clobbering the typed keyword; `filterText` is set to the
--- current keyword so the row is not fuzzy-filtered away (AI continuations do not
--- necessarily begin with what was typed).
---@class ClaudeCompleteBlinkSource
---@field opts table
local Source = {}

local KIND_TEXT = vim.lsp.protocol.CompletionItemKind.Text
local FMT_PLAIN = vim.lsp.protocol.InsertTextFormat.PlainText
local LABEL_MAX = 60

--- Build the single completion item for `completion` at `context`'s cursor.
--- `context.cursor` is {row (1-based), col (0-based)} like nvim_win_get_cursor.
---@param context table
---@param completion string
---@param opts table
---@return table
local function make_item(context, completion, opts)
  local first = vim.split(completion, "\n", { trimempty = false })[1] or ""
  local multiline = completion:find("\n") ~= nil
  local label = first
  local truncated = #first > LABEL_MAX
  if truncated then
    label = first:sub(1, LABEL_MAX)
  end
  if truncated or multiline then
    label = label .. "…"
  end

  local row0 = (context.cursor[1] or 1) - 1
  local col0 = context.cursor[2] or 0

  return {
    label = label,
    kind = KIND_TEXT,
    kind_name = "Haiku",
    kind_icon = "󰚩 ",
    insertText = completion,
    insertTextFormat = FMT_PLAIN,
    -- Keep the row visible regardless of the typed prefix.
    filterText = (context.keyword ~= nil and context.keyword ~= "") and context.keyword or nil,
    -- Insert-at-caret (empty range), so nothing typed is replaced.
    textEdit = {
      newText = completion,
      range = {
        start = { line = row0, character = col0 },
        ["end"] = { line = row0, character = col0 },
      },
    },
    score_offset = opts.score_offset,
    documentation = {
      kind = "markdown",
      value = "```\n" .. completion .. "\n```",
    },
  }
end

---@param opts table|nil  provider `opts` (e.g. { score_offset = -1 })
---@return ClaudeCompleteBlinkSource
function Source.new(opts)
  return setmetatable({ opts = opts or {} }, { __index = Source })
end

--- Advisory: honour the `auto.blink.enabled` flag if present. A user who wired
--- the provider has effectively opted in, so default to enabled when unset.
---@return boolean
function Source:enabled()
  local b = config.options.auto.blink
  if b and b.enabled ~= nil then
    return b.enabled ~= false
  end
  return true
end

--- No trigger characters — behaves like a keyword/manual source (blink asks us
--- as the user types); the source-side debounce throttles worker requests.
---@return string[]
function Source:get_trigger_characters()
  return {}
end

--- blink calls this as the user types. We debounce, fire ONE worker request for
--- the current cursor context, and deliver a single item when it arrives.
---@param context table  blink.cmp.Context
---@param callback fun(response: table)
---@return fun()  cancel
function Source:get_completions(context, callback)
  local cancelled = false

  -- Snapshot what make_item needs now; the cursor may move before we render.
  local snapshot = {
    cursor = { context.cursor[1], context.cursor[2] },
    keyword = (type(context.get_keyword) == "function") and context:get_keyword() or nil,
  }

  local function deliver(items)
    callback({ is_incomplete_forward = true, is_incomplete_backward = true, items = items or {} })
  end

  self._timer = self._timer or vim.uv.new_timer()
  self._timer:stop()
  self._timer:start(
    config.options.auto.debounce_ms,
    0,
    vim.schedule_wrap(function()
      if cancelled then
        return
      end
      worker.request(auto._build_prompt(), function(text, err)
        if cancelled then
          return -- blink cancelled this context (a newer one superseded it)
        end
        if err or not text then
          deliver({})
          return
        end
        local lines = auto._sanitize(text)
        if #lines == 0 then
          deliver({})
          return
        end
        deliver({ make_item(snapshot, table.concat(lines, "\n"), self.opts) })
      end)
    end)
  )

  return function()
    cancelled = true
    if self._timer then
      self._timer:stop()
    end
  end
end

-- Internal seam for headless tests. Not part of the blink protocol.
Source._make_item = make_item

return Source
