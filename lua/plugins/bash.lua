-- lua/plugins/bash.lua
--
-- bash-language-server looks for `shellcheck` on PATH, but mason only puts a
-- `shellcheck.cmd` shim there, which Node cannot spawn without a shell. The
-- server then logs "disabling linting as no executable was found" and shell
-- scripts get no ShellCheck diagnostics. Pointing it at the real executable in
-- mason's package directory avoids the shim.
local shellcheck = vim.fn.stdpath "data" .. "/mason/packages/shellcheck/shellcheck.exe"

return {
  "AstroNvim/astrolsp",
  optional = true,
  ---@type AstroLSPOpts
  opts = {
    config = {
      bashls = vim.fn.executable(shellcheck) == 1 and {
        settings = {
          bashIde = { shellcheckPath = shellcheck },
        },
      } or nil,
    },
  },
}
