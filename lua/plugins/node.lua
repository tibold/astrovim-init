-- lua/plugins/node.lua
--
-- Debugging and tests for JavaScript and TypeScript, on top of the typescript
-- pack.

--- The package a path belongs to: the nearest directory with a package.json.
local function package_root(path) return vim.fs.root(path, "package.json") end

--- neotest-jest's own path helpers split on "/" only, so on Windows its search
--- for node_modules/.bin/jest never gets anywhere and it falls back to a bare
--- `jest`, which is not on PATH. And the test file pattern it appends is the
--- absolute path escaped as a regex, which jest never matches on Windows (the
--- drive letter defeats it), so nothing ran. The command is where the path is
--- available, so it finds jest itself and adds a pattern jest does match: the
--- file relative to the package, with forward slashes. Jest ORs the patterns,
--- so the broken one appended after it does no harm.
local function jest_command(path)
  local root = package_root(path)
  local bin = root and vim.fs.joinpath(root, "node_modules", ".bin", vim.fn.has "win32" == 1 and "jest.cmd" or "jest")
  if not bin or not vim.uv.fs_stat(bin) then return "npx jest" end
  -- neotest-jest splits the command on whitespace, so a path with a space
  -- would be cut in two; npx finds the same local jest from the package.
  if bin:find "%s" then return "npx jest" end
  local relative = vim.fs.relpath(root, path)
  if not relative or relative == "." then return bin end
  local pattern = relative:gsub("\\", "/"):gsub("([%.%+%*%?%^%$%(%)%[%]])", "\\%1")
  return bin .. " " .. pattern
end

-- Launch configurations for JavaScript and TypeScript. The typescript pack
-- installs js-debug-adapter and mason-nvim-dap registers it as `pwa-node`, but
-- nothing defined configurations, so debugging a .js or .ts file had nothing
-- to offer. Node 24 runs TypeScript without a build step, so one launch
-- configuration serves both. Tests are debugged through neotest-jest instead,
-- which brings its own configuration.
return {
  {
    "mfussenegger/nvim-dap",
    optional = true,
    -- AstroNvim's spec for nvim-dap has no config of its own to replace.
    config = function()
      local dap = require "dap"

      -- js-debug's debug server, from Mason. deno-nvim (in the typescript
      -- all-in-one pack) installs a placeholder `pwa-node` -- `node` with no
      -- arguments, to be filled in by hand -- whenever none exists yet, and it
      -- got there before mason-nvim-dap: every Node session started a bare
      -- node that exited at once. Defined here, as nvim-dap loads, it is there
      -- first, and deno-nvim leaves an existing adapter alone.
      local server = vim.fn.expand "$MASON/packages/js-debug-adapter/js-debug/src/dapDebugServer.js"
      if vim.uv.fs_stat(server) then
        dap.adapters["pwa-node"] = {
          type = "server",
          host = "localhost",
          port = "${port}",
          executable = { command = "node", args = { server, "${port}" } },
        }
      end

      local configurations = {
        {
          type = "pwa-node",
          request = "launch",
          name = "Node: launch file",
          program = "${file}",
          cwd = "${workspaceFolder}",
          skipFiles = { "<node_internals>/**" },
        },
        {
          type = "pwa-node",
          request = "attach",
          name = "Node: attach to process",
          processId = function() return require("dap.utils").pick_process() end,
          cwd = "${workspaceFolder}",
          skipFiles = { "<node_internals>/**" },
        },
      }
      for _, filetype in ipairs { "javascript", "typescript", "javascriptreact", "typescriptreact" } do
        dap.configurations[filetype] = dap.configurations[filetype] or configurations
      end
    end,
  },
  {
    "nvim-neotest/neotest-jest",
    optional = true,
    opts = {
      jestCommand = jest_command,
      -- Run jest from the package, not whatever the editor's directory is.
      cwd = package_root,
    },
  },
}
