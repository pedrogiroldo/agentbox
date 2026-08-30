-- Mobile mode flag.
--
-- Turned on by `NVIM_MOBILE=1` in the environment, or automatically when the
-- terminal is narrower than 90 columns (an iPhone over SSH/mosh). Everything
-- gated on this flag is inert on a normal desktop terminal.
--
-- The value is computed once, at require() time. Since `require` caches the
-- module, every consumer (options, keymaps, plugin specs) observes the same
-- value for the whole session, even if the window is resized later.
local M = {}

M.enabled = vim.env.NVIM_MOBILE == "1" or vim.o.columns < 90

return M
