-- lua/mason-local/sqls.lua
--
-- sqls from its GitHub release instead of `go install`. Upstream mason builds
-- from source, and since sqls imports the Oracle driver godror unconditionally,
-- that build needs cgo: without a C compiler on PATH Go sets CGO_ENABLED=0,
-- drops godror's cgo files, and the install dies on `undefined: VersionInfo`.
-- The release binaries are built with cgo already, so nothing is compiled here.
--
-- Upstream only ships x86-64. macOS on Apple silicon runs it under Rosetta;
-- there is nothing for ARM Linux, where mason reports the platform unsupported.
--
-- The version follows the latest release (see github.lua); the one given here
-- is only used until the first lookup has succeeded. Asset names are built
-- from whichever version that is, so a new release needs no edit here unless
-- upstream renames its zips.
local version = require("mason-local.github").latest("sqls-server/sqls", "v0.2.48")

return {
  name = "sqls",
  description = "SQL language server written in Go. Installed from the prebuilt release.",
  homepage = "https://github.com/sqls-server/sqls",
  licenses = { "MIT" },
  languages = { "SQL" },
  categories = { "LSP" },
  source = {
    id = "pkg:github/sqls-server/sqls@" .. version,
    asset = {
      { target = "win_x64", file = "sqls-windows-{{ version | strip_prefix \"v\" }}.zip", bin = "sqls.exe" },
      { target = "linux_x64", file = "sqls-linux-{{ version | strip_prefix \"v\" }}.zip", bin = "sqls" },
      {
        target = { "darwin_x64", "darwin_arm64" },
        file = "sqls-darwin-{{ version | strip_prefix \"v\" }}.zip",
        bin = "sqls",
      },
    },
  },
  schemas = {
    lsp = "https://raw.githubusercontent.com/sqls-server/sqls/{{version}}/schema.json",
  },
  bin = {
    sqls = "{{source.asset.bin}}",
  },
  neovim = {
    lspconfig = "sqls",
  },
}
