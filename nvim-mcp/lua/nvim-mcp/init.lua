--- A generic MCP surface for this Neovim instance.
---
--- Two processes are involved. `bin/server.lua` is spawned by Claude Code and
--- speaks MCP on stdin/stdout; it holds no state and knows nothing about tools.
--- This module lives in the *editor* and owns the registry, so any plugin can
--- register a tool at runtime and it appears without restarting either side.
local M = {}

--- "<tool>.<name>" -> { name, description, inputSchema, handler, tool, hidden }.
--- Keyed by tool as well as name: `state` means the editor on `drive` and the
--- debug session on `debug`, and with names alone one replaced the other.
M.tools = {}
--- Registration order of those keys, so the tool list is stable rather than
--- hash-ordered.
M.order = {}

local NAME = "^[a-zA-Z][a-zA-Z0-9_]*$"

--- The MCP tool an action is reached through when it names none. Which tools
--- exist is the bridge's business (claude/server.lua), because a tool is what
--- a Claude Code permission rule names; an action only says which one it is on.
M.DEFAULT_TOOL = "drive"

local function key(name, tool) return (tool or M.DEFAULT_TOOL) .. "." .. name end

--- JSON objects with no members must encode as {} rather than []. Lua cannot
--- tell the two apart, so anything meant to be an object is marked explicitly.
local function as_object(value)
  if type(value) ~= "table" then return value end
  if next(value) == nil then return vim.empty_dict() end
  return value
end

--- Register a tool. Returns true, or false plus a reason.
--- Re-registering a name replaces it, so reloading a plugin does not duplicate.
function M.register(tool)
  if type(tool) ~= "table" then return false, "tool must be a table" end
  if type(tool.name) ~= "string" or not tool.name:match(NAME) then return false, "tool.name must match " .. NAME end
  if type(tool.description) ~= "string" or tool.description == "" then
    return false, ("tool %s needs a description"):format(tool.name)
  end
  if type(tool.handler) ~= "function" then return false, ("tool %s needs a handler"):format(tool.name) end
  if tool.tool ~= nil and (type(tool.tool) ~= "string" or not tool.tool:match(NAME)) then
    return false, ("tool %s has a tool that does not match %s"):format(tool.name, NAME)
  end

  local schema = tool.inputSchema or { type = "object", properties = {} }
  if type(schema) ~= "table" then return false, ("tool %s has a non-table inputSchema"):format(tool.name) end
  schema = vim.deepcopy(schema)
  schema.type = schema.type or "object"
  schema.properties = as_object(schema.properties or {})

  local k = key(tool.name, tool.tool)
  if not M.tools[k] then M.order[#M.order + 1] = k end
  M.tools[k] = {
    name = tool.name,
    description = tool.description,
    inputSchema = schema,
    handler = tool.handler,
    -- The MCP tool this action is called through. Actions that change files
    -- sit on their own tool so a permission rule can tell them apart from
    -- lookups; Claude Code matches MCP rules by tool name, never by argument.
    tool = tool.tool or M.DEFAULT_TOOL,
    -- Hidden actions are reachable but not advertised. Every listed name costs
    -- permanent context in the dispatcher's description, so something used once
    -- a month is better found through `search` than carried all year.
    hidden = tool.hidden == true,
  }
  return true
end

--- An action by name on a tool (drive when none is given).
function M.get(name, tool) return M.tools[key(name, tool)] end

--- An action by name on any tool, drive's first; nil when none has it.
local function any(name)
  if M.tools[key(name)] then return M.tools[key(name)] end
  for _, k in ipairs(M.order) do
    if M.tools[k].name == name then return M.tools[k] end
  end
end

function M.unregister(name, tool)
  local k = key(name, tool)
  if not M.tools[k] then return false end
  M.tools[k] = nil
  for i, n in ipairs(M.order) do
    if n == k then
      table.remove(M.order, i)
      break
    end
  end
  return true
end

--- The MCP `tools/list` payload, in registration order. Handlers are omitted:
--- this crosses an RPC boundary and functions do not serialise.
function M.specs()
  local out = {}
  for _, k in ipairs(M.order) do
    local tool = M.tools[k]
    out[#out + 1] =
      { name = tool.name, description = tool.description, tool = tool.tool, inputSchema = tool.inputSchema }
  end
  return out
end

--- Invoke a tool by name. Never throws: the bridge is a separate process and a
--- Lua error here would surface to it as an opaque RPC failure.
--- `opts` carries response shaping (currently `detail`), kept separate from the
--- action's own arguments because it belongs to the reply, not the request.
--- `via` is the MCP tool the call arrived through, and the action is looked up
--- on it. One found only on another tool is refused rather than run:
--- otherwise an edit could be reached through a tool whose permission rule only
--- meant to allow lookups. In-editor callers name no tool and get drive's
--- action, or any tool's when drive has none.
--- Returns { ok = true, content = {...} } or { ok = false, message = "..." }.
function M.invoke(name, args, opts, via)
  local tool
  if via then
    tool = M.get(name, via)
  else
    tool = any(name)
  end
  if not tool then
    local elsewhere = any(name)
    if elsewhere then
      return { ok = false, message = ("`%s` is on the `%s` tool, not `%s`"):format(name, elsewhere.tool, via) }
    end
    return { ok = false, message = "Unknown tool: " .. tostring(name) }
  end

  local ok, result = pcall(tool.handler, args or {}, opts or {})
  if not ok then
    local message = type(result) == "table" and result.message or tostring(result)
    return { ok = false, message = message }
  end

  -- A handler may return MCP content directly, a plain string for brevity, or a
  -- data table. The table case must be encoded rather than dropped: falling
  -- through to "ok" silently threw away everything an action reported.
  if type(result) == "string" then return { ok = true, content = { { type = "text", text = result } } } end
  if type(result) == "table" then
    if result.content then return { ok = true, content = result.content } end
    local encoded, json = pcall(vim.json.encode, result)
    if encoded then return { ok = true, content = { { type = "text", text = json } } } end
  end
  return { ok = true, content = { { type = "text", text = "ok" } } }
end

--- The names worth advertising: everything not registered as hidden, each with
--- the tool it is on so the bridge can list it under that tool.
function M.listed()
  local out = {}
  for _, k in ipairs(M.order) do
    local tool = M.tools[k]
    if not tool.hidden then out[#out + 1] = { name = tool.name, description = tool.description, tool = tool.tool } end
  end
  return out
end

--- Full schema for one action -- the given tool's, or any tool's when that one
--- has none by the name -- or a name-and-description roster of every action,
--- hidden ones included. The roster omits schemas: with a long tail, returning
--- them all would cost more than the question is worth.
function M.describe(name, on)
  if name then
    local tool = (on and M.get(name, on)) or any(name)
    if not tool then return nil end
    return { name = tool.name, description = tool.description, tool = tool.tool, inputSchema = tool.inputSchema }
  end
  local out = {}
  for _, key in ipairs(M.order) do
    local tool = M.tools[key]
    out[#out + 1] = { name = tool.name, description = tool.description, tool = tool.tool, hidden = tool.hidden or nil }
  end
  return out
end

--- Find actions by name or description, returning full schemas so a match can be
--- called immediately. This is how a rarely used action stays reachable without
--- occupying context between uses.
function M.search(query, limit)
  limit = tonumber(limit) or 5
  local needles = {}
  for word in tostring(query or ""):lower():gmatch "[%w_]+" do
    needles[#needles + 1] = word
  end

  local scored = {}
  for _, key in ipairs(M.order) do
    local tool = M.tools[key]
    local haystack = (tool.name .. " " .. tool.description):lower()
    local score = 0
    for _, needle in ipairs(needles) do
      if tool.name:lower():find(needle, 1, true) then
        score = score + 2 -- a name match beats a description match
      elseif haystack:find(needle, 1, true) then
        score = score + 1
      end
    end
    if score > 0 or #needles == 0 then
      scored[#scored + 1] = {
        score = score,
        spec = {
          name = tool.name,
          description = tool.description,
          tool = tool.tool,
          inputSchema = tool.inputSchema,
        },
      }
    end
  end

  table.sort(scored, function(a, b) return a.score > b.score end)

  local out = {}
  for i = 1, math.min(limit, #scored) do
    out[i] = scored[i].spec
  end
  return out
end

function M.setup(opts)
  require("nvim-mcp.config").setup(opts)
  require("nvim-mcp.actions").setup()
  require("nvim-mcp.quickfix").setup()
  require("nvim-mcp.neotest").setup()
  require("nvim-mcp.debug").setup()
  require("nvim-mcp.eval").setup()
  require("nvim-mcp.announce").setup()
  require("nvim-mcp.lsp").setup()
end

return M
