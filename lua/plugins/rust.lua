-- lua/plugins/rust.lua
--
-- Local additions on top of `astrocommunity.pack.rust` (imported in
-- community.lua).
--
-- Building: nvim's own rust ftplugin already runs `:compiler cargo` when the
-- cwd sits under a Cargo.toml; the keymaps below force it per buffer, so
-- `:make build`, `:make clippy` and friends parse rustc output straight into
-- the quickfix list. That covers building without adding a task runner.

-- neotest's client, handed over by the consumer registered below.
local neotest_client
-- rust-analyzer clients that have finished loading their workspace.
local loaded = {}

--- Ask again, for one Rust buffer, what was asked of rust-analyzer before it
--- could answer. neotest discovers a file's tests the moment it is loaded,
--- when rust-analyzer has not attached, let alone indexed: rustaceanvim gets no
--- runnables, neotest's tree building fails on the empty list, and the file
--- shows no tests until it is next saved. rustaceanvim loads the cargo debug
--- configurations when rust-analyzer turns quiescent, but for the *current*
--- buffer, which is as often the terminal Claude runs in, so none are added.
local function refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "rust" then return end
  if neotest_client then
    local file = vim.api.nvim_buf_get_name(bufnr)
    -- Private, but it is what neotest itself calls on BufWritePost; there is
    -- no public way to have it discover a file again.
    require("nio").run(function() neotest_client:_update_positions(file) end)
  end
  vim.api.nvim_buf_call(bufnr, function() require("rustaceanvim.commands.debuggables").add_dap_debuggables() end)
end

return {
  {
    "mrcjkb/rustaceanvim",
    opts = function(_, opts)
      -- Called once rust-analyzer is quiescent: refresh what it serves so far.
      -- Buffers attached later are refreshed on attach (rust_ready below).
      local on_initialized = opts.tools.on_initialized
      opts.tools.on_initialized = function(health, client_id)
        if on_initialized then on_initialized(health, client_id) end
        loaded[client_id] = true
        local client = vim.lsp.get_client_by_id(client_id)
        for bufnr in pairs(client and client.attached_buffers or {}) do
          refresh(bufnr)
        end
      end

      -- The pack hands rustaceanvim `exepath("codelldb")`, which on Windows is
      -- Mason's `codelldb.cmd` shim, and a guessed `share/lldb/bin/lldb.dll`.
      -- rustaceanvim spawns the adapter directly, which cannot run a .cmd, so
      -- point it at the real binaries inside the Mason package instead.
      if vim.fn.has "win32" == 1 then
        -- rustaceanvim's terminal executor turns a runnable into a shell line,
        -- and on Windows it chains `cd` onto the command with a pipe
        -- (`cd 'dir' | cargo run`). The program's stdin is then the empty
        -- output of `cd`, so anything that reads input gets EOF at once. Start
        -- cargo directly in a terminal instead, with no shell and no pipe.
        local term_buf
        local executor = {
          execute_command = function(command, args, cwd, exec_opts)
            if term_buf and vim.api.nvim_buf_is_valid(term_buf) then
              vim.api.nvim_buf_delete(term_buf, { force = true })
            end
            term_buf = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_open_win(term_buf, true, { split = "below", height = 15 })
            vim.fn.jobstart(vim.list_extend({ command }, args), {
              term = true,
              cwd = cwd,
              env = exec_opts and exec_opts.env,
            })
            vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = term_buf, desc = "Close run output" })
            vim.cmd.startinsert()
          end,
        }
        opts.tools.executor = executor
        opts.tools.crate_test_executor = executor

        local ext = vim.fn.expand "$MASON/packages/codelldb/extension"
        local codelldb = ext .. "\\adapter\\codelldb.exe"
        local liblldb = ext .. "\\lldb\\bin\\liblldb.dll"
        if vim.uv.fs_stat(codelldb) and vim.uv.fs_stat(liblldb) then
          opts.dap.adapter = require("rustaceanvim.config").get_codelldb_adapter(codelldb, liblldb)
        end
      end
      return opts
    end,
  },
  {
    "nvim-neotest/neotest",
    optional = true,
    opts = function(_, opts)
      opts.consumers = vim.tbl_extend("force", opts.consumers or {}, {
        rust_rediscover = function(client)
          neotest_client = client
          return {}
        end,
      })
    end,
  },
  {
    "AstroNvim/astrocore",
    ---@type AstroCoreOpts
    opts = {
      autocmds = {
        rust_ready = {
          {
            event = "LspAttach",
            desc = "Refresh tests and debug configurations for a Rust file opened after rust-analyzer loaded",
            callback = function(args)
              if loaded[args.data.client_id] then vim.schedule(function() refresh(args.buf) end) end
            end,
          },
        },
        rust_keymaps = {
          {
            event = "LspAttach",
            desc = "Rust keymaps for rust-analyzer buffers",
            callback = function(args)
              local client = vim.lsp.get_client_by_id(args.data.client_id)
              if not client or client.name ~= "rust-analyzer" then return end

              local function map(lhs, rhs, desc)
                vim.keymap.set("n", lhs, rhs, { buffer = args.buf, desc = desc })
              end
              local function rust_lsp(cmd)
                return function() vim.cmd.RustLsp(cmd) end
              end

              -- Hover with runnable/debuggable actions, and grouped code actions
              map("K", function() vim.cmd.RustLsp { "hover", "actions" } end, "Rust hover actions")
              map("<Leader>la", rust_lsp "codeAction", "Rust code action")

              -- The ftplugin picks `cargo` vs `rustc` by looking for Cargo.toml
              -- above the cwd, not above the file, so state it here, and pass
              -- the manifest so :make works whatever the cwd is.
              vim.api.nvim_buf_call(args.buf, function() vim.cmd.compiler "cargo" end)
              local function cargo(sub)
                return function()
                  local manifest = client.root_dir and vim.fs.joinpath(client.root_dir, "Cargo.toml")
                  local target = manifest and vim.uv.fs_stat(manifest) and (" --manifest-path " .. vim.fn.fnameescape(manifest))
                    or ""
                  vim.cmd("make " .. sub .. target)
                end
              end

              map("<Leader>r", "", "󱘗 Rust")
              -- Build and check: results land in quickfix
              map("<Leader>rb", cargo "build", "cargo build")
              map("<Leader>rB", cargo "build --release", "cargo build --release")
              map("<Leader>rk", cargo "clippy", "cargo clippy")
              map("<Leader>rf", function() vim.cmd.RustLsp { "flyCheck", "run" } end, "Re-run check (flycheck)")
              -- Run, debug, test the target under the cursor or pick one
              map("<Leader>rr", rust_lsp "runnables", "Runnables")
              map("<Leader>rR", function() vim.cmd.RustLsp { "runnables", bang = true } end, "Rerun last runnable")
              map("<Leader>rd", rust_lsp "debuggables", "Debuggables")
              map("<Leader>rD", function() vim.cmd.RustLsp { "debuggables", bang = true } end, "Rerun last debuggable")
              map("<Leader>rt", rust_lsp "testables", "Testables")
              -- Navigation and inspection
              map("<Leader>re", rust_lsp "expandMacro", "Expand macro")
              map("<Leader>rx", rust_lsp "explainError", "Explain error")
              map("<Leader>rg", rust_lsp "renderDiagnostic", "Render diagnostic")
              map("<Leader>rc", rust_lsp "openCargo", "Open Cargo.toml")
              map("<Leader>rp", rust_lsp "parentModule", "Parent module")
              map("<Leader>rs", rust_lsp "ssr", "Structural search & replace")
              map("<Leader>rm", rust_lsp "rebuildProcMacros", "Rebuild proc macros")
              map("<Leader>ro", rust_lsp "openDocs", "Open docs.rs")
            end,
          },
        },
      },
    },
  },
}
