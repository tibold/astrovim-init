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
