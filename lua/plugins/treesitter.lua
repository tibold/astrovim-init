-- Customize Treesitter

---@type LazySpec
return {
  "nvim-treesitter/nvim-treesitter",
  opts = {
    ensure_installed = {
      "lua",
      "vim",
      -- add more arguments for adding more treesitter parsers
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
}
