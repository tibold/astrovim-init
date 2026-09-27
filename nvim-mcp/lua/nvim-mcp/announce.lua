--- Editors announce themselves, so `instances` can find one even while it is too
--- busy to answer.
---
--- Discovery used to rest on probing every Neovim pipe. A probe cannot tell an
--- editor that is busy -- Roslyn loading a large solution holds the main loop
--- for seconds -- from a Neovim that will never answer, such as Claude's own
--- bridge processes blocked on stdin. So each editor with a UI writes a small
--- record, and the bridge probes those: one that does not answer is busy, and
--- its record still says where it is working.
local M = {}

--- Where the records live; NVIM_MCP_INSTANCES overrides it for tests.
function M.dir() return vim.env.NVIM_MCP_INSTANCES or vim.fs.joinpath(vim.fn.stdpath "state", "nvim-mcp", "instances") end

function M.path(pid) return vim.fs.joinpath(M.dir(), tostring(pid) .. ".json") end

--- Write this editor's record: its RPC address, process id and directory.
function M.write()
  local address = vim.v.servername
  if not address or address == "" then return end
  vim.fn.mkdir(M.dir(), "p")
  local record = { address = address, pid = vim.fn.getpid(), cwd = vim.fn.getcwd() }
  pcall(vim.fn.writefile, { vim.json.encode(record) }, M.path(record.pid))
end

function M.remove() os.remove(M.path(vim.fn.getpid())) end

function M.setup()
  local group = vim.api.nvim_create_augroup("nvim_mcp_announce", { clear = true })
  -- Only editors with a UI announce: test runners and scripts load this config
  -- headless, and offering them as places to show a file is worse than useless.
  vim.api.nvim_create_autocmd({ "UIEnter", "DirChanged" }, {
    group = group,
    callback = function()
      if #vim.api.nvim_list_uis() > 0 then M.write() end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.remove })
  if vim.v.vim_did_enter == 1 and #vim.api.nvim_list_uis() > 0 then M.write() end
end

return M
