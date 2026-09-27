--- Run Lua in the editor, for looking at state no dedicated action reports:
--- a plugin's internals while working out why it misbehaves.
---
--- It is on a tool of its own, `lua`, so Claude Code asks before each use
--- unless the human allows it, and denying it leaves every other tool working.
--- It adds convenience rather than reach: Claude already has a shell with the
--- human's permissions.
local mcp = require "nvim-mcp"

local M = {}

local function fail(message) error { code = -32603, message = message } end

--- A value as JSON can carry it, or its vim.inspect text when it cannot:
--- functions, userdata, and tables holding them.
local function portable(value)
  if value == nil then return nil end
  local ok = pcall(vim.json.encode, value)
  if ok then return value end
  return vim.inspect(value)
end

function M.run(args)
  args = args or {}
  if type(args.code) ~= "string" or args.code == "" then error { code = -32602, message = "eval needs code" } end
  local chunk, syntax = loadstring(args.code, "=eval")
  if not chunk then fail(syntax) end

  local printed = {}
  local original = print
  _G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
      parts[#parts + 1] = tostring((select(i, ...)))
    end
    printed[#printed + 1] = table.concat(parts, "\t")
  end
  local ok, result = pcall(chunk)
  _G.print = original

  if not ok then fail(tostring(result)) end
  return { result = portable(result), printed = #printed > 0 and printed or nil }
end

function M.setup()
  mcp.register {
    name = "eval",
    tool = "lua",
    description = "Run a Lua chunk in the editor; `return` gives the result, print output comes back too.",
    inputSchema = {
      type = "object",
      properties = { code = { type = "string", description = "A Lua chunk; use `return` for a result." } },
      required = { "code" },
    },
    handler = M.run,
  }
end

return M
