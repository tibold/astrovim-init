--- MCP stdio bridge to a running Neovim. Spawned by Claude Code as:
---   nvim -u NONE -l server.lua
---
--- It holds no state and knows no actions. Everything is forwarded to
--- require("nvim-mcp") inside the editor, so an action registered at runtime is
--- reachable without restarting either side.
---
--- One tool is advertised, not one per action. A tool definition costs roughly
--- 600 tokens of permanent context; a dispatcher plus an on-demand `describe`
--- costs that once no matter how many actions exist, and the `nvim` skill
--- carries the knowledge that would otherwise bloat the descriptions.

local PROTOCOL_VERSION = "2024-11-05"

--- In `nvim -l`, print() goes to stderr. Every byte on stdout must be JSON-RPC
--- or the stream is corrupt, so writes go through here and nowhere else.
local function send(message)
  io.stdout:write(vim.json.encode(message) .. "\n")
  io.stdout:flush()
end

local function reply(id, result) send { jsonrpc = "2.0", id = id, result = result } end
local function fail(id, code, message) send { jsonrpc = "2.0", id = id, error = { code = code, message = message } } end

--- Connect and keep the channel per address: reconnecting per request would add
--- a socket round trip to every call.
local channels = {}
local function connect(address)
  if not address or address == "" then return nil end
  if channels[address] then return channels[address] end
  local ok, ch = pcall(vim.fn.sockconnect, "pipe", address, { rpc = true })
  if not ok or ch == 0 then return nil end
  channels[address] = ch
  return ch
end

--- Absent an explicit instance, talk to the editor hosting this session. Claude
--- Code spawns this process, so $NVIM is inherited from the Neovim that started
--- Claude -- which is why several instances each get a correctly bound bridge.
local function target(args) return (args and args.instance) or vim.env.NVIM end

local function editor(address, lua, call_args)
  local ch = connect(address)
  if not ch then return nil, "no Neovim at " .. tostring(address) end
  local ok, result = pcall(vim.rpcrequest, ch, "nvim_exec_lua", lua, call_args or {})
  if not ok then
    channels[address] = nil -- force a reconnect; the editor may have restarted
    return nil, "Neovim call failed"
  end
  return result
end

--- Every Neovim serving an RPC address on this machine. Only useful when
--- targeting a worktree other than the host, or when Claude was not started
--- from inside an editor at all.
local function instances()
  local paths = {}
  if vim.fn.has "win32" == 1 then
    paths = vim.fn.glob([[\\.\pipe\*]], true, true)
  else
    for _, dir in ipairs { vim.env.XDG_RUNTIME_DIR, "/tmp" } do
      if dir then vim.list_extend(paths, vim.fn.glob(dir .. "/nvim*/0", true, true)) end
    end
  end

  local found = {}
  for _, address in ipairs(paths) do
    -- Only Neovim answers nvim_exec_lua; anything else on the pipe namespace
    -- simply fails to connect or fails the call, and is skipped.
    local info = editor(address, 'return require("nvim-mcp").invoke("identify", {})')
    if info and info.ok and info.content then
      local ok, decoded = pcall(vim.json.decode, info.content[1].text)
      found[#found + 1] = {
        address = address,
        host = address == vim.env.NVIM,
        info = ok and decoded or nil,
      }
    end
  end
  return found
end

--- Actions the bridge answers itself, so they are listed even when the editor
--- is unreachable and its registry cannot be read.
local BRIDGE_ACTIONS = {
  { name = "instances", description = "Every Neovim on this machine, with its working directory." },
  {
    name = "describe",
    description = "Argument schema for one action, or a roster of all of them when name is omitted.",
  },
  { name = "search", description = "Find actions by name or description, with their schemas." },
}

local PREAMBLE = "Drive the human's running Neovim, and mirror your plan into its checklist panel."

local EPILOGUE = [[Add `instance` (an address from `instances`) to target a different editor; omit
it for the one hosting this session. `detail` shapes the reply: summary by
default, full when a summary elides what you need.

This list comes from the editor's live registry and shows the commonly used
actions only. Others exist and are callable but are not listed, because every
listed name costs context in every session. Use search to find them by what you
want to do ("open a file", "unsaved buffers"); it returns schemas, so a match
can be called straight away. describe with no name gives the full roster;
describe with a name gives one schema. The `nvim` skill explains when each of
the listed actions is worth using.]]

--- Built at tools/list time from whatever the editor has registered, rather than
--- hardcoded. A static list would go stale the moment a plugin registered an
--- action, which is the thing this server exists to allow.
local function tool_definition()
  -- listed(), not specs(): actions registered as hidden stay reachable through
  -- `search` without costing context in every session.
  local specs = editor(vim.env.NVIM, 'return require("nvim-mcp").listed()') or {}
  local all = vim.list_extend(vim.deepcopy(specs), BRIDGE_ACTIONS)

  -- Names only. A one-line blurb per action reads well but costs roughly 70
  -- characters each of permanent context and duplicates the `nvim` skill, which
  -- explains every action properly and loads only when relevant. `describe`
  -- supplies meaning and schema on demand for anything a name leaves unclear.
  local names = {}
  for _, action in ipairs(all) do
    names[#names + 1] = action.name
  end

  local description = table.concat({
    PREAMBLE,
    "",
    "actions: " .. table.concat(names, ", "),
    "",
    EPILOGUE,
  }, "\n")

  return {
    name = "drive",
    description = description,
    inputSchema = {
      type = "object",
      properties = {
        action = { type = "string", description = "One of the actions listed above." },
        args = { type = "object", description = "Arguments for that action." },
        detail = {
          type = "string",
          enum = { "summary", "full" },
          description = "Response size. Defaults to summary; use full when a summary elides what you need.",
        },
      },
      required = { "action" },
    },
  }
end

local TOOL_NAME = "drive"

local handlers = {}

handlers["initialize"] = function(id)
  reply(id, {
    protocolVersion = PROTOCOL_VERSION,
    capabilities = { tools = vim.empty_dict() },
    serverInfo = { name = "editor", version = "0.1.0" },
  })
end

handlers["tools/list"] = function(id) reply(id, { tools = { tool_definition() } }) end

handlers["ping"] = function(id) reply(id, vim.empty_dict()) end

handlers["tools/call"] = function(id, params)
  params = params or {}
  if params.name ~= TOOL_NAME then return fail(id, -32602, "Unknown tool: " .. tostring(params.name)) end

  local input = params.arguments or {}
  local action, args = input.action, input.args or {}
  local opts = { detail = input.detail or "summary" }
  if type(action) ~= "string" then return fail(id, -32602, "Missing `action`") end

  local function text(value)
    reply(id, { content = { { type = "text", text = type(value) == "string" and value or vim.json.encode(value) } } })
  end

  if action == "instances" then return text(instances()) end

  local address = target(args)
  if action == "search" then
    local found, err = editor(address, 'return require("nvim-mcp").search(...)', { args.query, args.limit })
    if not found then return fail(id, -32603, err or "search failed") end
    return text(found)
  end

  if action == "describe" then
    local spec, err = editor(address, 'return require("nvim-mcp").describe(...)', { args.name })
    if not spec then return fail(id, -32603, err or "describe failed") end
    return text(spec)
  end

  local result, err = editor(address, 'return require("nvim-mcp").invoke(...)', { action, args, opts })
  if not result then return fail(id, -32603, err or "Neovim is not reachable") end
  if not result.ok then return fail(id, -32603, result.message or "Action failed") end
  reply(id, { content = result.content or { { type = "text", text = "ok" } } })
end

for line in io.lines() do
  if line ~= "" then
    local decoded, message = pcall(vim.json.decode, line)
    if decoded and type(message) == "table" and message.method then
      local handler = handlers[message.method]
      if handler then
        -- A malformed request must not kill the loop; the client would see the
        -- pipe close and report a crashed server.
        pcall(handler, message.id, message.params)
      elseif message.id ~= nil then
        -- Notifications carry no id and expect no reply; requests do.
        fail(message.id, -32601, "Method not found: " .. tostring(message.method))
      end
    end
  end
end
