-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

if require("config.mobile").enabled then
  -- `jk` beats reaching for <Esc> on the iPhone software keyboard.
  vim.keymap.set("i", "jk", "<Esc>", { desc = "Exit Insert Mode" })
  vim.keymap.set("t", "jk", "<C-\\><C-n>", { desc = "Exit Terminal Mode" })
end
