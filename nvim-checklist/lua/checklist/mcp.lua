--- Registers the checklist as a tool on the generic Neovim MCP server.
---
--- Claude reaches it as mcp__plugin_nvim_nvim__nvim (action checklist_update). That namespace matters:
--- Claude Code drops every mcp__ide__* tool that is not on a two-item
--- allowlist, so registering with claudecode.nvim -- the obvious-looking route
--- -- advertises a tool the model can never call.
local M = {}

--- One line. The full contract -- what the panel is for, why it is write-only,
--- what each op means -- lives in the `nvim` skill, which loads on demand
--- instead of costing permanent context in a tool description.
M.SUMMARY = "Mirror your working plan into the human's editor checklist panel. "
  .. "Write-only: never read it back. Batch a turn's changes into one call. "
  .. "Ops: set (upsert by id), drop, clear, sweep."

M.tool = {
  name = "checklist_update",
  description = M.SUMMARY,
  inputSchema = {
    type = "object",
    properties = {
      ops = {
        type = "array",
        description = "Operations to apply in order.",
        items = {
          type = "object",
          properties = {
            op = { type = "string", enum = { "set", "drop", "clear", "sweep" } },
            id = { type = "string" },
            text = { type = "string" },
            state = { type = "string", enum = { "todo", "done", "blocked" } },
            group = { type = "string" },
            note = { type = "string" },
          },
          required = { "op" },
        },
      },
    },
    required = { "ops" },
  },

  --- Required inside the handler, not at module scope: init.lua pulls this
  --- module in from setup(), so a top-level require would be circular.
  handler = function(args)
    if type(args) ~= "table" or type(args.ops) ~= "table" then
      error { code = -32602, message = "ops must be an array" }
    end

    local applied, reason = require("checklist").apply { ops = args.ops }
    if not applied then
      -- A shell wrapper stayed silent because failure meant "no editor". Over a
      -- live tool that cannot happen, so the only failure left is a malformed
      -- call, which the agent should learn about rather than repeat.
      error { code = -32602, message = "Checklist payload rejected: " .. tostring(reason) }
    end

    -- The shortest useful reply: anything longer is context spent on a panel
    -- the agent is not supposed to think about.
    return "ok"
  end,
}

--- Register with the Neovim MCP server if it is installed. Guarded so the
--- checklist works as a plain panel when nvim-mcp is absent.
function M.attach()
  local ok, mcp = pcall(require, "nvim-mcp")
  if not ok or type(mcp.register) ~= "function" then return false end
  return (mcp.register(M.tool))
end

return M
