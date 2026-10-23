---@type LazySpec
return {
  "nvim-neo-tree/neo-tree.nvim",
  opts = {
    -- The solution explorer's tab is added in dotnet.lua, with nvim-dotnet
    filesystem = {
      -- AstroNvim defaults to "open_current", which opens the tree *inside* the
      -- window you launched from. `nvim .` then loses the tree the moment you
      -- pick a file, and it collides with the startup sidebar. "open_default"
      -- puts it in the normal left position instead, so there is exactly one
      -- tree and it survives opening files.
      hijack_netrw_behavior = "open_default",
    },
    buffers = {
      -- The buffers tab runs a blocking `git status` before every render, even
      -- with git_status_async on: ~1s in a large .NET repo, most of it git
      -- walking ignored bin/ and obj/ folders. That freezes the editor on every
      -- switch to the tab, and on every buffer opened, closed or written while
      -- it is showing. Setting before_render replaces that call, so this asks
      -- the way the filesystem tab does, in the background, and the
      -- git_status_changed handler below repaints once the answer lands.
      before_render = function(state)
        local config = require("neo-tree").ensure_config()
        require("neo-tree.git").status_async(state.path, state.git_base_by_worktree, config.git_status_async_options)
      end,
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
      -- Setting buffers.before_render (above) also drops the tab's own git
      -- listeners. These two put them back: repaint when the background status
      -- lands, and refresh after a commit or a Fugitive change.
      {
        event = "git_status_changed",
        handler = function(args) require("neo-tree.sources.manager").git_status_changed("buffers", args) end,
      },
      {
        event = "git_event",
        handler = function() require("neo-tree.sources.buffers").buffers_changed() end,
      },
    },
  },
}
