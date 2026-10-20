--- Registers the checklist as a tool on the generic Neovim MCP server.
---
--- Claude reaches it as mcp__plugin_nvim_editor__drive (action checklist_update). That namespace matters:
--- Claude Code drops every mcp__ide__* tool that is not on a two-item
--- allowlist, so registering with claudecode.nvim -- the obvious-looking route
--- -- advertises a tool the model can never call.
local M = {}

--- One line. The full contract -- what the panel is for, when to read it back,
--- what each op means -- lives in the `checklist` skill, which loads on demand
--- instead of costing permanent context in a tool description.
M.SUMMARY = "Mirror your working plan into the human's editor checklist panel. "
  .. "Batch a turn's changes into one call. Group items by workstream. "
  .. "Ops: set (upsert by id), drop, clear, sweep. Read it back (`checklist`) only to tidy it."

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
            state = { type = "string", enum = { "todo", "inprogress", "done", "blocked" } },
            group = { type = "string", description = "Workstream heading. Expected on all but one-off items." },
            note = { type = "string" },
            index = {
              type = "integer",
              minimum = 1,
              description = "1-based position. Places a new item, moves an existing one. Omit to append or leave in place.",
            },
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

--- The panel read back, ids and all. Items arrive one at a time over a long
--- session, so the panel drifts -- duplicates, stale `inprogress`, finished
--- work piling up -- and tidying it means dropping and moving items by id.
--- Not for reporting it: the human is looking at it.
M.read_tool = {
  name = "checklist",
  description = "The checklist panel as markdown, each item with its id. Only to tidy it now and then "
    .. "(duplicates, stale items, finished work piling up), never to report it back to the human.",
  inputSchema = { type = "object", properties = vim.empty_dict() },
  handler = function()
    local markdown = require("checklist").read()
    if markdown == "" then return "The checklist is empty." end
    return markdown
  end,
}

--- Register with the Neovim MCP server if it is installed. Guarded so the
--- checklist works as a plain panel when nvim-mcp is absent.
function M.attach()
  local ok, mcp = pcall(require, "nvim-mcp")
  if not ok or type(mcp.register) ~= "function" then return false end
  return (mcp.register(M.tool)) and (mcp.register(M.read_tool))
end

return M
