-- Registers the git worktree switcher as a snacks.picker source plus its keymap.
-- Not gated on mobile mode -- it is just as useful on the desktop. Mobile mode
-- only changes how the picker is laid out (see lua/plugins/mobile.lua).
--
-- This is a plain table opts, not `opts = function(_, opts)`: a function opts
-- runs after the table ones are merged and would replace `sources.git_worktrees`
-- wholesale, throwing away the layout that mobile.lua sets for this same source.
return {
  {
    "folke/snacks.nvim",
    opts = {
      picker = {
        sources = {
          git_worktrees = require("config.worktree").source(),
        },
      },
    },
    -- stylua: ignore
    keys = {
      { "<leader>gw", function() require("config.worktree").pick() end, desc = "Worktrees" },
    },
  },
}
