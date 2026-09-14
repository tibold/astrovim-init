-- lua/plugins/roslyn.lua
--
-- Razor and CSHTML are served by roslyn.nvim's own co-hosting support, which
-- supersedes rzls.nvim. Neither the `rzls` plugin nor the `rzls` Mason package
-- may be installed alongside it, and no razor specific command arguments are
-- needed. Co-hosting requires Neovim 0.12 and a roslyn language server from
-- 5.8.0-1.26262.10 onwards.
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
        -- Only the extra arguments are stated here. The executable itself comes
        -- from roslyn.nvim's own resolver, which appends the `.cmd` extension
        -- the Mason shim carries on Windows; a hand written path without it
        -- names a file that does not exist and the server never starts.
        cmd = {
          require("roslyn.utils").get_roslyn_lsp_path(),
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
