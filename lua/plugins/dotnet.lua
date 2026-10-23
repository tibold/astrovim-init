-- lua/plugins/dotnet.lua
--
-- .NET: Roslyn for C#, and for Razor and CSHTML through Roslyn's own
-- co-hosting (no rzls), through nvim-dotnet or roslyn.nvim. Tests, debugging
-- and project commands are not set up here.
--
-- Roslyn is the `roslyn-language-server` global tool from the Azure DevOps
-- feed, at an explicit version (see dotnet.md for how to update it). No Mason
-- package: both plugins prefer Mason's Roslyn when there is one, which makes
-- the build in use depend on what happens to be installed.

--- true: nvim-dotnet; false: roslyn.nvim. Both stay installed (lazy's
--- `cond`), so switching back is this line and a restart.
local use_nvim_dotnet = true

--- nvim-dotnet runs from this clone, and so does its project-system service,
--- which is not on nuget.org yet (see dotnet.md for rebuilding it)
local nvim_dotnet_clone = "D:/source/github/ArchPillar/nvim-dotnet"

--- The service built in the clone when there is one; else dev mode, which
--- builds it there (its first client meanwhile uses Roslyn's own loader), so
--- the next session finds it
local function nvim_dotnet_server()
  local dll = vim.fs.joinpath(
    nvim_dotnet_clone,
    "server/src/ArchPillar.Nvim.Dotnet.Service/bin/Debug/net10.0/ArchPillar.Nvim.Dotnet.Service.dll"
  )
  if vim.uv.fs_stat(dll) then return { path = dll } end
  return { dev_source = vim.fs.joinpath(nvim_dotnet_clone, "server") }
end

--- The global tool's launcher, by full path. roslyn.nvim names it bare, and
--- Neovim checks a bare name with a PATH search each time it considers
--- starting the server, ~15ms each on Windows. Global tools always land in
--- ~/.dotnet/tools (or under DOTNET_CLI_HOME).
local function roslyn_tool()
  local name = vim.fn.has "win32" == 1 and "roslyn-language-server.cmd" or "roslyn-language-server"
  local path = vim.fs.joinpath(vim.env.DOTNET_CLI_HOME or vim.uv.os_homedir(), ".dotnet", "tools", name)
  return vim.uv.fs_stat(path) and path or nil
end

--- Load the C# treesitter queries (~150ms, compiled once per session) while
--- the editor is idle after startup, rather than while the first C# file
--- waits. Only in a directory with a solution or project at the top or one
--- level down.
local function prewarm()
  local found = false
  for _, pattern in ipairs { "*.sln", "*.slnx", "*.csproj", "*/*.sln", "*/*.slnx", "*/*.csproj" } do
    if #vim.fn.glob(pattern, false, true) > 0 then
      found = true
      break
    end
  end
  if not found then return end

  -- One step per tick, so a keypress in between is not held up by all of them
  local steps = { function() pcall(vim.treesitter.language.add, "c_sharp") end }
  for _, query in ipairs { "highlights", "injections", "locals", "folds" } do
    table.insert(steps, function() pcall(vim.treesitter.query.get, "c_sharp", query) end)
  end
  local function run(i)
    if not steps[i] then return end
    steps[i]()
    vim.defer_fn(function() run(i + 1) end, 10)
  end
  run(1)
end

vim.api.nvim_create_autocmd("User", {
  pattern = "VeryLazy",
  once = true,
  callback = function() vim.defer_fn(prewarm, 100) end,
})

--- roslyn.nvim only. Roslyn asks the html server about a Razor file's markup
--- through Neovim, and roslyn.nvim waits for that server to attach to the
--- file's hidden HTML copy with vim.wait, which holds up typing: up to 5s per
--- question while the server starts (see dotnet.md). The questions are handled
--- in a coroutine, so wait there by yielding first; the plugin's own wait then
--- returns at once.
local function wait_for_html_without_blocking()
  local manager = require "roslyn.razor.documentManager"
  local types = require "roslyn.razor.types"
  local get_document = manager.getDocument

  manager.getDocument = function(self, uri, checksum)
    local co = coroutine.running()
    local path = uri:match(vim.pesc(types.virtualHtmlSuffix) .. "$") and uri or uri .. types.virtualHtmlSuffix
    local doc = co and manager.htmlDocuments[path]
    if doc then
      local function ready()
        if checksum and manager.pendingUpdates[doc.path] and doc:getChecksum() ~= checksum then return false end
        return vim.lsp.get_clients({ bufnr = doc.buf, name = types.html_lsp_name })[1] ~= nil
      end
      local deadline = vim.uv.now() + 5000
      while not ready() and vim.uv.now() < deadline do
        vim.defer_fn(function() coroutine.resume(co) end, 20)
        coroutine.yield()
      end
    end
    return get_document(self, uri, checksum)
  end
end

return {
  -- nvim-dotnet already does what roslyn.nvim needed help with below: Roslyn
  -- watches files itself, Razor's html questions wait without blocking, the
  -- server runs with --daemon-mode and DOTNET_GCConserveMemory=7, and it is
  -- looked up once per session (see dotnet.md)
  {
    "ArchPillar/nvim-dotnet",
    dir = vim.uv.fs_stat(nvim_dotnet_clone) and nvim_dotnet_clone or nil,
    cond = use_nvim_dotnet,
    main = "ap_dotnet",
    -- Its client's own filetypes: .cshtml is razor here (filetypes.lua), but
    -- the plugin sends a cshtml buffer to Roslyn as razor too
    ft = { "cs", "razor", "cshtml" },
    opts = function() return { server = nvim_dotnet_server() } end,
    init = function()
      vim.lsp.config("ap_dotnet", {
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
            -- Its Run/Debug commands are VS Code's
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
          -- The service restores what is missing as projects load, following
          -- this. Prepare-Workspace.ps1 in the work repo does a full restore
          -- too, but also regenerates the solution filters and builds the
          -- Tooling projects; without this, a project it had not restored
          -- left Roslyn unable to resolve its packages and references.
          ["csharp|projects"] = {
            dotnet_enable_automatic_restore = true,
          },
        },
        -- A pipe of its own: a daemon roslyn.nvim started (another editor
        -- still on it, or one in its 15 minutes of keepalive) has no
        -- broker-reset extension, and on its pipe every target would restart
        -- without the daemon
        cmd_env = { ROSLYN_LANGUAGE_SERVER_DAEMON_PIPE_NAME = "nvim-dotnet" },
      })
    end,
  },
  {
    "seblyng/roslyn.nvim",
    cond = not use_nvim_dotnet,
    ft = { "cs", "razor" },
    opts = {
      -- Roslyn watches the files itself: Neovim's watchers froze the editor
      -- on builds and checkouts (see dotnet.md)
      filewatching = "roslyn",
    },
    -- In init, not config: loading roslyn.nvim enables the server, which
    -- starts at once for the C# buffer that loaded it, before config runs.
    -- vim.lsp.config() wins over the plugin's lsp/roslyn.lua in any order.
    init = function()
      local config = {
        -- What filewatching = "roslyn" sets, which is also only set in setup
        capabilities = {
          workspace = { didChangeWatchedFiles = { dynamicRegistration = false } },
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
            -- Each "N references" is a solution-wide count, but Neovim 0.12
            -- only resolves the lenses on screen, in the background. If
            -- Roslyn's CPU use shows on the work solution, turn this off.
            dotnet_enable_references_code_lens = true,
            -- Its Run/Debug commands are VS Code's
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
      }

      -- roslyn.nvim's own arguments (its lsp/roslyn.lua), which cannot be read
      -- before it loads, with the launcher by full path
      local tool = roslyn_tool()
      if tool then
        config.cmd = { tool, "--stdio", "--daemon-mode", "--clientProcessId", tostring(vim.uv.os_getpid()) }
      end
      -- On a large solution the server idled at 10 GB with under 5 GB live:
      -- its Server GC left dead gen2 objects and freed memory committed. This
      -- lets fragmentation trigger compacting GCs that hand memory back, and
      -- above 5 also shrinks the allocation budget DATAS keeps per GC. The
      -- daemon inherits it, so an already running one keeps the old setting
      config.cmd_env = { DOTNET_GCConserveMemory = "7" }
      vim.lsp.config("roslyn", config)
    end,
    config = function(_, opts)
      require("roslyn").setup(opts)
      wait_for_html_without_blocking()
    end,
  },
}
