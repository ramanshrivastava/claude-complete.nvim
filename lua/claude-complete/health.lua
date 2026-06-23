local config = require("claude-complete.config")

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
end

return M
