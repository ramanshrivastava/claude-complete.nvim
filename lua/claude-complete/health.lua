local config = require("claude-complete.config")
local worker = require("claude-complete.worker")

local M = {}

function M.check()
  local h = vim.health
  h.start("claude-complete")

  if vim.fn.has("nvim-0.10") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim >= 0.10 is required")
  end

  local cmd = config.options.command
  if vim.fn.executable(cmd) == 1 then
    local version = vim.fn.system(cmd .. " --version 2>/dev/null"):gsub("%s+$", "")
    h.ok(("`%s` found%s"):format(cmd, version ~= "" and (" (" .. version .. ")") or ""))
  else
    h.error(
      ("`%s` is not on your PATH"):format(cmd),
      { "Install the Claude Code CLI and run `" .. cmd .. "` once to authenticate." }
    )
  end

  if _G.Snacks and Snacks.notifier then
    h.ok("snacks.nvim present — rich progress panel enabled")
  else
    h.info("snacks.nvim not found — using the cmdline progress spinner")
  end

  local o = config.options
  if type(o.model) == "string" and o.model ~= "" then
    h.ok("model: " .. o.model)
  else
    h.warn("`model` is not set")
  end
  if type(o.timeout_ms) == "number" then
    h.ok(("timeout: %dms"):format(o.timeout_ms))
  else
    h.warn("`timeout_ms` is not a number")
  end

  h.start("claude-complete: auto lane")
  local a = o.auto
  if not a.enabled then
    h.info("auto lane disabled (set `auto.enabled = true` or run `:ClaudeCompleteAuto on`)")
  else
    h.ok(("auto lane enabled · model: %s · debounce: %dms"):format(a.model, a.debounce_ms))
  end
  local w = worker.status()
  if w.disabled then
    h.warn("worker disabled this session (repeated failures) — `:ClaudeCompleteAuto on` to retry")
  elseif w.running then
    local lat = w.last_latency_ms and (" · last latency: " .. w.last_latency_ms .. "ms") or ""
    h.ok(("worker running (%s)%s"):format(w.model or "?", lat))
  else
    h.info("worker not running (starts lazily on first completion)")
  end
end

return M
