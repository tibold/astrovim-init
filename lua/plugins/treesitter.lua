-- Parser list for treesitter.
--
-- AstroNvim 6 moved nvim-treesitter to its `main` branch, where `ensure_installed`
-- is no longer a setup option -- the configuration lives under astrocore's
-- `treesitter` key instead, and astrocore declares
-- `opts_extend = { "treesitter.ensure_installed" }` so this list is appended to
-- AstroNvim's own rather than replacing it.
--
-- Setting it on the nvim-treesitter spec, as this file used to, now does nothing
-- at all. It fails quietly rather than loudly, because v6 also sets
-- `auto_install = true` and the parsers turn up on demand anyway.

--- Drop an injection that lies wholly outside its parent's ranges. Neovim
--- narrows each injection to the ranges its parent tree was given, after its
--- check for an empty range list, and an empty list makes the injected parser
--- read the whole buffer: one stray `style="…"` in a Razor file had CSS
--- colouring every tag. See treesitter.md. Leaves Neovim alone if
--- add_injection or clip_regions is no longer where this expects it.
local function drop_injections_outside_parent()
  local function upvalue(fn, wanted)
    for i = 1, math.huge do
      local name, value = debug.getupvalue(fn, i)
      if not name then return end
      if name == wanted then return i, value end
    end
  end

  local get_injections = require("vim.treesitter.languagetree")._get_injections
  local index, add_injection = upvalue(get_injections, "add_injection")
  if not add_injection then return end
  local _, clip_regions = upvalue(add_injection, "clip_regions")
  if not clip_regions then return end

  debug.setupvalue(get_injections, index, function(t, pattern, lang, combined, ranges, parent_ranges, result)
    if #ranges > 0 and parent_ranges and #clip_regions(ranges, parent_ranges) == 0 then return end
    return add_injection(t, pattern, lang, combined, ranges, parent_ranges, result)
  end)
end

drop_injections_outside_parent()

return {
  "AstroNvim/astrocore",
  opts = {
    treesitter = {
      ensure_installed = {
        "lua",
        "vim",
        "bash",
        "json",
        "yaml",
        "toml",
        "markdown",
        "python",
        "dockerfile",
        "ini",
        "regex",
        "ssh_config",
        "git_config",
        "gitignore",
      },
    },
  },
}
