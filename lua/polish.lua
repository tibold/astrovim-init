-- This will run last in the setup process.
-- This is just pure lua so anything that doesn't
-- fit in the normal config locations above can go here

-- AstroNvim loads most plugins, the whole LSP stack among them, on its
-- AstroFile and AstroGitFile events, which it fires when the first real file
-- of a session opens. That made the first file wait ~150ms longer, with the
-- picker still on screen, whatever its type. Fired here instead, once the
-- editor is idle after startup; loading the LSP stack only registers the
-- servers, which still start when a buffer of theirs opens.
--
-- Skipped when a file is already open (`nvim foo.cs`): AstroNvim has run its
-- own pass then. AstroGitFile only inside a repository; AstroNvim still fires
-- it later for files in one elsewhere.
vim.api.nvim_create_autocmd("User", {
  pattern = "VeryLazy",
  once = true,
  callback = function()
    vim.defer_fn(function()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.b[buf].astrofile_checked then return end
      end
      vim.api.nvim_exec_autocmds("User", { pattern = "AstroFile", modeline = false })
      if vim.fs.root(vim.uv.cwd(), ".git") then
        vim.api.nvim_exec_autocmds("User", { pattern = "AstroGitFile", modeline = false })
      end
    end, 300)
  end,
})
