-- lua/plugins/powershell.lua
--
-- astrocommunity.pack.ps1 installs powershell-editor-services through
-- mason-lspconfig, which enables `powershell_es` and supplies its `bundle_path`
-- from its own shim, while nvim-lspconfig's `lsp/powershell_es.lua` builds the
-- Start-EditorServices command. Only the formatting preference is left to state.
--
-- Registering the server from a plugin `init` instead, as this file used to, ran
-- before nvim-lspconfig was on the runtimepath. The base config carrying `cmd`
-- was therefore not found, and the server failed to start with
-- "cmd: expected function or table with executable command, got nil".
return {
  "AstroNvim/astrolsp",
  optional = true,
  ---@type AstroLSPOpts
  opts = {
    config = {
      powershell_es = {
        settings = {
          powershell = {
            codeFormatting = { preset = "OTBS" },
          },
        },
      },
    },
  },
}
