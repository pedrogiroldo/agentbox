-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Use the terminal's OSC 52 escape sequence as the clipboard provider whenever
-- we're inside an SSH session, so that yanks land in the local machine's
-- clipboard. Not gated on mobile mode -- it applies to any SSH session.
if vim.env.SSH_TTY then
  vim.g.clipboard = "osc52"
end

if require("config.mobile").enabled then
  local opt = vim.opt

  -- Reclaim horizontal space: no relative numbers, no sign column, no folds.
  opt.relativenumber = false
  opt.signcolumn = "no"
  opt.foldcolumn = "0"

  -- A narrow screen needs soft wrapping to stay readable.
  opt.wrap = true
  opt.linebreak = true
  opt.scrolloff = 2

  -- Give the last row back to the buffer.
  opt.laststatus = 0

  -- Termius forwards taps and drags as mouse events.
  opt.mouse = "a"

  -- Keep latency-sensitive timers short on a high-latency link.
  opt.ttimeoutlen = 10
  opt.updatetime = 500
end
