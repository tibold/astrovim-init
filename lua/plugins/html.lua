-- lua/plugins/html.lua
--
-- The html server lints <style> blocks with the settings it requests from the
-- client under `css`. It is written against VS Code, which always answers with
-- its defaults; Neovim answers only with what is configured, so with nothing
-- configured the answer is null. The css service then reads `null.lint`, every
-- validation throws "Cannot read properties of null (reading 'validProperties')",
-- and embedded CSS silently gets no diagnostics at all. Declaring the section is
-- enough: the service fills in its own defaults for everything left out.
return {
  "AstroNvim/astrolsp",
  optional = true,
  ---@type AstroLSPOpts
  opts = {
    config = {
      html = {
        settings = {
          css = { validate = true },
        },
      },
    },
  },
}
