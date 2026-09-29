-- lua/plugins/dotnet.lua
--
-- .NET through easy-dotnet.nvim: it runs Roslyn itself (with Razor and
-- CSHTML), the test runner, the debugger (netcoredbg), and the project, NuGet
-- and scaffolding commands under :Dotnet. It replaces roslyn.nvim, which must
-- not run beside it: two Roslyns would fight over every C# buffer.
--
-- Installed the way easy-dotnet expects, and nothing else: the EasyDotnet
-- global tool (`dotnet tool install -g EasyDotnet`), and Roslyn as the
-- `roslyn-language-server` global tool, which easy-dotnet installs itself on
-- first use (update with `dotnet-easydotnet roslyn update`). netcoredbg comes
-- bundled with EasyDotnet. No Mason packages for .NET: a Mason Roslyn on the
-- PATH is used only when the global tool is missing, which makes the build in
-- use depend on what happens to be installed.

--- easy-dotnet's neotest adapter, made to work on Windows and from a cold start.
---
--- - The test runner reports files with forward slashes and neotest asks with
---   backslashes; the adapter compares them as strings, so on Windows no .NET
---   file was ever a test file. It is asked with forward slashes, and the tree
---   it returns is handed back with the platform's own, since neotest merges
---   trees by path prefix and a forward-slash file under a backslash directory
---   crashed that before.
--- - Tests are found by the runner's quick_discover, which only easy-dotnet's
---   startup runs, and only when a solution is already selected for the
---   editor's directory at that moment. The adapter itself only initialises
---   the runner, which knows the solution and nothing under it. Discovery now
---   runs, once, the first time the adapter finds no projects.
--- - A run for a node the runner does not know never completes, and runs are
---   queued, so one such run blocks every later .NET run until a restart.
---   Discovering first is what keeps runs from starting that early.
local function windows_ready(adapter)
  if adapter.__windows_ready then return adapter end
  local is_test_file, discover = adapter.is_test_file, adapter.discover_positions
  local function forward(path) return (path:gsub("\\", "/")) end

  local discovering
  local function ensure_discovered()
    local state = require "easy-dotnet.test-runner.state"
    for _, node in pairs(state.nodes or {}) do
      if node.type and node.type.type == "Project" then return end
    end
    local nio = require "nio"
    if not discovering then
      discovering = nio.control.future()
      local solution = require("easy-dotnet.current_solution").try_get_selected_solution()
      local client = require("easy-dotnet.rpc.rpc").global_rpc_client
      if not solution then
        discovering.set()
      else
        client:initialize(function()
          client.testrunner:quick_discover(solution, function() discovering.set() end)
        end)
        -- quick_discover does not always call back; its nodes arrive anyway
        vim.defer_fn(function()
          if not discovering.is_set() then discovering.set() end
        end, 30000)
      end
    end
    discovering.wait()
  end

  --- Put the file's own spelling back on the positions naming it.
  local function native(list, from, to)
    local out = {}
    for i, item in ipairs(list) do
      if i == 1 and not vim.islist(item) then
        local data = vim.deepcopy(item)
        if data.path == from then data.path = to end
        if data.id == from then data.id = to end
        out[1] = data
      else
        out[i] = native(item, from, to)
      end
    end
    return out
  end

  adapter.is_test_file = function(path)
    if not vim.endswith(path, ".cs") then return false end
    if is_test_file(forward(path)) then return true end
    ensure_discovered()
    return is_test_file(forward(path))
  end

  adapter.discover_positions = function(path)
    ensure_discovered()
    local tree = discover(forward(path))
    if not tree then return nil end
    return require("neotest.types").Tree.from_list(
      native(tree:to_list(), forward(path), path),
      function(position) return position.id end
    )
  end

  adapter.__windows_ready = true
  return adapter
end

return {
  {
    "GustavEikaas/easy-dotnet.nvim",
    dependencies = { "nvim-lua/plenary.nvim", "folke/snacks.nvim" },
    ft = { "cs", "razor", "fsharp" },
    cmd = "Dotnet",
    opts = function()
      return {
        picker = "snacks",
        lsp = {
          enabled = true,
          config = {
            settings = {
              ["csharp|background_analysis"] = {
                dotnet_analyzer_diagnostics_scope = "openFiles",
                dotnet_compiler_diagnostics_scope = "openFiles",
              },
              ["csharp|completion"] = {
                dotnet_show_completion_items_from_unimported_namespaces = false,
              },
              ["csharp|code_lens"] = {
                -- Each "N references" is a solution-wide count, but Neovim 0.12
                -- only resolves the lenses on screen, in the background. If
                -- Roslyn's CPU use shows on the work solution, turn this off.
                dotnet_enable_references_code_lens = true,
                -- Its Run/Debug commands are VS Code's; tests go through neotest
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
              -- Restore what is missing as projects load. Prepare-Workspace.ps1
              -- in the work repo does a full restore too, but also regenerates
              -- the solution filters and builds the Tooling projects; without
              -- this, a project it had not restored left Roslyn unable to
              -- resolve its packages and references.
              ["csharp|projects"] = {
                dotnet_enable_automatic_restore = true,
              },
            },
          },
        },

        -- Tests go through neotest like every other language, so <Leader>T
        -- and Claude's tests/run_tests cover .NET too.
        test_runner = { neotest_integration = true },
      }
    end,
  },
  {
    "nvim-neotest/neotest",
    optional = true,
    opts = function(_, opts)
      opts.adapters = opts.adapters or {}
      table.insert(opts.adapters, windows_ready(require "easy-dotnet.neotest"))
    end,
  },
}
