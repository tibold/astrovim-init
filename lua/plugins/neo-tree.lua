---@type LazySpec
return {
  "nvim-neo-tree/neo-tree.nvim",
  opts = {
    filesystem = {
      -- AstroNvim defaults to "open_current", which opens the tree *inside* the
      -- window you launched from. `nvim .` then loses the tree the moment you
      -- pick a file, and it collides with the startup sidebar. "open_default"
      -- puts it in the normal left position instead, so there is exactly one
      -- tree and it survives opening files.
      hijack_netrw_behavior = "open_default",
    },
    window = {
      -- AstroNvim's 30 is cramped on a wide screen, and the checklist panel
      -- shares this column, so it pays the same cost. neo-tree accepts a
      -- function here, so scale with the screen and clamp at both ends: never
      -- so narrow that filenames truncate, never so wide it crowds the editor.
      -- The lower clamp is AstroNvim's original 30, so a narrow terminal is no
      -- worse off than before and only wide screens actually widen.
      width = function() return math.min(70, math.max(30, math.floor(vim.o.columns * 0.22))) end,
    },
  },
}
