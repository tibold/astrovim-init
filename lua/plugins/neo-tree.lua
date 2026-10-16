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
    -- The git tab asks for `--untracked-files=all --ignored=traditional`, and
    -- together those list every file inside an ignored folder: 86k files from
    -- bin/ and obj/ in a large .NET repo, ~3s parsed on the main thread, for entries the
    -- tab never shows. "matching" lists ignored folders as folders, the form
    -- the filesystem tab already gets, and neo-tree marks their contents from
    -- the folder. AstroNvim extends this list, so it adds to its handlers.
    event_handlers = {
      {
        event = "before_git_status",
        handler = function(args)
          local cmd = args.status_args
          if not vim.list_contains(cmd, "--untracked-files=all") then return end
          for i, arg in ipairs(cmd) do
            if arg == "--ignored=traditional" then cmd[i] = "--ignored=matching" end
          end
        end,
      },
    },
  },
}
