-- lua/plugins/powershell.lua
--
-- nvim-lspconfig now ships lsp/powershell_es.lua, which builds the
-- Start-EditorServices command itself and reads `bundle_path` off the config. So
-- all that is left to supply is where the bundle lives -- Mason's package
-- directory -- and the formatting preference. The hand-built `cmd`, `filetypes`
-- and `root_markers` this file used to carry are all upstream now.
--
-- `version = false` is what makes that config reachable at all: AstroNvim pins
-- every plugin while `version` is tracked in lazy_setup.lua, so nvim-lspconfig
-- stays at the release AstroNvim was tested against, which is older than the
-- fix. Unpinned here for this one plugin rather than globally with
-- `pin_plugins = false`, which would unpin everything at once.
--
-- Once AstroNvim's pin moves past the fix, the `version = false` above can go.
-- The rest stays: astrocommunity.pack.ps1 adds powershell_es to
-- mason-lspconfig's ensure_installed, and that installs the package and nothing
-- more. Measured -- on a ps1 buffer, vim.lsp.is_enabled("powershell_es") was
-- false and no client attached -- so the enable below is not legacy, and
-- dropping it leaves the server installed and never started.
return {
  { "neovim/nvim-lspconfig", version = false },
  {
    "AstroNvim/astrolsp",
    optional = true,
    -- init rather than opts: nothing here needs astrolsp loaded, and opts runs
    -- only once it does, which can be after the FileType event of a file opened
    -- on the command line -- by which point the server config is wanted.
    init = function()
      vim.lsp.config("powershell_es", {
        bundle_path = vim.fn.stdpath "data" .. "/mason/packages/powershell-editor-services",
        settings = {
          powershell = {
            codeFormatting = { preset = "OTBS" },
          },
        },
      })

      vim.lsp.enable "powershell_es"
    end,
  },
}
