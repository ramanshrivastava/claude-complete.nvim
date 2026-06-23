-- Minimal, ISOLATED config for the README demo (vhs). Does not touch your real
-- Neovim: it pins XDG dirs to ./.demo so lazy installs there.
local root = vim.fn.fnamemodify(vim.fn.getcwd() .. "/.demo", ":p")
for _, n in ipairs({ "DATA", "STATE", "CACHE" }) do
  vim.env["XDG_" .. n .. "_HOME"] = root .. "/" .. n:lower()
end

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  vim.fn.system({ "git", "clone", "--filter=blob:none", "https://github.com/folke/lazy.nvim.git", lazypath })
end
vim.opt.rtp:prepend(lazypath)
vim.g.mapleader = " "
vim.opt.number = true
vim.opt.signcolumn = "yes"
vim.opt.swapfile = false

require("lazy").setup({
  {
    "catppuccin/nvim",
    name = "catppuccin",
    priority = 1000,
    config = function()
      vim.cmd.colorscheme("catppuccin-mocha")
    end,
  },
  { "folke/snacks.nvim", opts = { notifier = { enabled = true } } },
  {
    dir = vim.fn.fnamemodify(vim.fn.getcwd(), ":p"),
    main = "claude-complete",
    lazy = false,
    opts = {
      ui = { rich = true, context_line = true },
      highlights = { ghost = { fg = "#b4befe", bg = "#1e1e2e", italic = true } },
    },
  },
})
