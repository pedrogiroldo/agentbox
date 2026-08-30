-- The Herdr UI runs the built-in "vesper" theme (~/.config/herdr/config.toml),
-- so the editor inside its panes uses the same palette -- the seam between the
-- pane chrome and the buffer should be invisible.
return {
  {
    "datsfilipe/vesper.nvim",
    lazy = false,
    priority = 1000, -- a colorscheme has to load before anything draws
    opts = {
      -- Paint our own background instead of letting the terminal show through:
      -- the phone client may not be running Vesper.
      transparent = false,
      -- Italics in a terminal font degrade to underline or reverse video on
      -- most mobile SSH clients, so keep them where they carry meaning.
      italics = {
        comments = true,
        keywords = false,
        functions = false,
        strings = false,
        variables = false,
      },
    },
  },

  { "LazyVim/LazyVim", opts = { colorscheme = "vesper" } },
}
