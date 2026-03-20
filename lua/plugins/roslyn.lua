-- lua/plugins/roslyn.lua
return {
  {
    "mason-org/mason.nvim",
    opts = {
      registries = {
        "github:mason-org/mason-registry",
        "github:Crashdummyy/mason-registry",
      },
    },
  },
  {
    "seblyng/roslyn.nvim",
    ft = { "cs", "razor" },
    opts = {
      filewatching = "roslyn",
    },
  },
}
