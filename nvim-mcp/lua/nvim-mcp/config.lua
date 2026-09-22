--- Sideload fallback: generates an --mcp-config file and the command line that
--- loads it, for driving Neovim before the Claude Code plugin is installed.
---
--- The supported route is the plugin (`claude plugin marketplace add <repo>`),
--- which delivers this same server together with the `nvim` skill. Do not use
--- both at once: two registrations of the same server name collide.
local M = {}

M.defaults = {
  server_name = "nvim", -- tools reach Claude as mcp__plugin_nvim_editor__drive
  claude_cmd = "claude", -- the binary claudecode.nvim should launch
}

M.options = vim.deepcopy(M.defaults)

--- Absolute path to the bridge, derived from this file rather than configured,
--- so it cannot go stale. The bridge lives in the Claude Code plugin because
--- that directory is what gets copied on install; ${CLAUDE_PLUGIN_ROOT} then
--- resolves to it. This path is only used by the sideload fallback below.
function M.server_script()
  local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
  local repo = vim.fn.fnamemodify(here, ":h:h:h") -- lua/nvim-mcp -> nvim-mcp -> repo
  return vim.fs.normalize(repo .. "/claude/server.lua")
end

function M.config_path() return vim.fs.normalize(vim.fs.joinpath(vim.fn.stdpath "state", "nvim-mcp", "mcp.json")) end

--- The object Claude Code expects from --mcp-config. Note the mcpServers
--- wrapper: a plugin's own .mcp.json is a bare map, this form is not.
function M.payload()
  return {
    mcpServers = {
      [M.options.server_name] = {
        type = "stdio",
        command = "nvim",
        -- -u NONE keeps the bridge from loading the user's whole config on
        -- every spawn: it needs only core Lua, and must not let a plugin print
        -- to stdout, which would corrupt the JSON-RPC stream.
        args = { "-u", "NONE", "-l", M.server_script() },
      },
    },
  }
end

--- Write the config file. Returns the path, or nil plus a reason.
function M.write()
  local path = M.config_path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local ok, encoded = pcall(vim.json.encode, M.payload())
  if not ok then return nil, "could not encode config" end
  local fd = io.open(path, "wb")
  if not fd then return nil, "could not open " .. path end
  fd:write(encoded)
  fd:close()
  return path
end

--- The string to hand claudecode.nvim as `terminal_cmd`.
--- The `=` form is required: `--mcp-config` takes a variable number of paths,
--- so a space-separated value swallows whatever follows it on the line.
function M.claude_cmd()
  local path = M.write()
  if not path then return M.options.claude_cmd end
  return ("%s --mcp-config=%s"):format(M.options.claude_cmd, path)
end

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  pcall(M.write)
end

return M
