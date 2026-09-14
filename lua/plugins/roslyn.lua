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
  -- References code lens costs a solution-wide find-all-refs on every attach
  { "AstroNvim/astrolsp", opts = { features = { codelens = false } } },
  {
    "seblyng/roslyn.nvim",
    ft = { "cs", "razor" },
    opts = {
      filewatching = "roslyn",
    },
    config = function(_, opts)
      require("roslyn").setup(opts)

      vim.lsp.config("roslyn", {
        cmd = {
          vim.fn.stdpath "data" .. "/mason/bin/roslyn-language-server",
          "--stdio",
          "--logLevel",
          "Warning",
          -- Automatic re-runs the Razor generator on every edit
          "--sourceGeneratorExecutionPreference",
          "Balanced",
        },
        settings = {
          ["csharp|background_analysis"] = {
            dotnet_analyzer_diagnostics_scope = "openFiles",
            dotnet_compiler_diagnostics_scope = "openFiles",
          },
          ["csharp|completion"] = {
            dotnet_show_completion_items_from_unimported_namespaces = false,
          },
          ["csharp|code_lens"] = {
            dotnet_enable_references_code_lens = false,
            dotnet_enable_tests_code_lens = false,
          },
          ["csharp|symbol_search"] = {
            dotnet_search_reference_assemblies = false,
          },
          ["csharp|navigation"] = {
            -- On-demand cost only, and it is what makes go-to-definition
            -- land in readable source for framework and NuGet types
            dotnet_navigate_to_decompiled_sources = true,
          },
          -- The repo restores through Prepare-Workspace.ps1
          ["csharp|projects"] = {
            dotnet_enable_automatic_restore = false,
          },
        },
      })
    end,
  },
}
