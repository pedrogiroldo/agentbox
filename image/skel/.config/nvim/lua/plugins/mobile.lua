-- Plugin overrides for mobile mode.
--
-- Returns an empty spec when the flag is off, so a desktop session resolves to
-- exactly the same plugin set it had before this file existed.
--
-- Note on names: this LazyVim install has no telescope, no mini.animate, no
-- mini.indentscope and no alpha.nvim. Scroll animation, indent guides, the
-- dashboard and the picker all live inside snacks.nvim, so they are turned off
-- through snacks opts rather than by disabling separate plugins.
if not require("config.mobile").enabled then
  return {}
end

return {
  {
    "folke/snacks.nvim",
    opts = {
      -- Each of these repaints a lot of cells per keystroke; over a phone link
      -- that is the dominant cost.
      scroll = { enabled = false },
      indent = { enabled = false },
      dashboard = { enabled = false },
      -- snacks.picker is the active picker here. Its default preset chooses by
      -- width at open time; pin it to vertical so the preview stacks instead of
      -- fighting for columns.
      picker = {
        layout = { preset = "vertical" },
        sources = {
          -- snacks.explorer is the file tree (no neo-tree in this install).
          -- Its default is a 40-column sidebar with `min_width = 40`, which on a
          -- phone leaves almost no buffer and cannot shrink. Give it the whole
          -- screen instead: `width = 0` means "full parent size" in snacks.win.
          -- The worktree switcher (lua/plugins/worktree.lua). Its `select`
          -- preset already clamps to the screen width, but the border and the
          -- centered box waste rows; make it a plain full-width list.
          git_worktrees = {
            layout = {
              preset = "select",
              -- max_width must not be 0: snacks reads it as a literal clamp
              -- (`math.min(width, max_width)`), which would shrink the window
              -- to 1 column. 0 means "full size" for width/height only.
              layout = { width = 0, min_width = 0, max_width = 9999, height = 0.5, border = "none" },
            },
          },
          explorer = {
            layout = {
              preset = "sidebar",
              preview = false, -- no room for a preview pane, and it costs redraws
              -- `position = "left"` would make this a real vertical split, and the
              -- main window next to it keeps `winminwidth` (LazyVim sets 5) plus a
              -- separator column -- 6 columns lost. A float takes the whole screen.
              layout = {
                position = "float",
                width = 0,
                min_width = 0,
                height = 0,
                min_height = 0,
                border = "none",
              },
            },
            -- A sidebar is meant to stay open; a full-screen tree is not -- it
            -- would sit on top of the file you just opened. Both default to false.
            auto_close = true,
            jump = { close = true },
          },
        },
      },
    },
  },

  -- Both redraw on nearly every event and cost a full row each.
  { "folke/noice.nvim", enabled = false },
  { "akinsho/bufferline.nvim", enabled = false },

  {
    "neovim/nvim-lspconfig",
    opts = {
      -- Virtual text that reflows wrapped lines on a narrow screen.
      inlay_hints = { enabled = false },
      codelens = { enabled = false },
    },
  },

  {
    "nvim-lualine/lualine.nvim",
    -- LazyVim builds its opts in a function, so take the built table and replace
    -- the sections wholesale -- merging would keep the default components.
    opts = function(_, opts)
      local filename = { "filename", path = 0, symbols = { modified = " ●", readonly = " ", unnamed = "" } }

      opts.sections = {
        lualine_a = { "mode" },
        lualine_b = {},
        lualine_c = { filename },
        lualine_x = {},
        lualine_y = {},
        lualine_z = {},
      }
      opts.inactive_sections = {
        lualine_a = {},
        lualine_b = {},
        lualine_c = { filename },
        lualine_x = {},
        lualine_y = {},
        lualine_z = {},
      }
      opts.extensions = {}

      return opts
    end,
    -- lualine's setup() unconditionally forces `laststatus` back to 2 (or 3 with
    -- globalstatus), which would undo the `laststatus = 0` set in options.lua.
    -- LazyVim defines no config for lualine, so wrapping the default one is safe.
    config = function(_, opts)
      require("lualine").setup(opts)
      vim.o.laststatus = 0
    end,
  },
}
