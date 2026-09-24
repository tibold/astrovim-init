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

-- Polling for `wait_for`. The ceiling exists because an MCP client has its own
-- request timeout: waiting past it turns a provisional answer into no answer.
local POLL_MS = 250
local MAX_WAIT = 300

-- How long a single instance gets to answer during discovery, and this script's
-- own path so it can re-invoke itself as a probe. See instances().
local PROBE_MS = 2000
local SELF = _G.arg and _G.arg[0]

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

--- Probe mode: `nvim -u NONE -l server.lua <address>` writes that instance's
--- identify payload and exits. instances() spawns one child per candidate so a
--- wedged editor is killed by the child's timeout rather than blocking the
--- sweep. Checked before the JSON-RPC loop at the bottom, which reads stdin and
--- would otherwise wait forever for input that is never coming.
if _G.arg and _G.arg[1] then
  local info = editor(_G.arg[1], 'return require("nvim-mcp").invoke("identify", {})')
  if info and info.ok and info.content and info.content[1] then
    io.stdout:write(info.content[1].text)
    os.exit(0)
  end
  os.exit(1)
end

--- Every Neovim serving an RPC address on this machine. Only useful when
--- targeting a worktree other than the host, or when Claude was not started
--- from inside an editor at all.
local function instances()
  local paths = {}
  if vim.fn.has "win32" == 1 then
    -- Forward slashes, because the globber reads backslashes as escapes and
    -- the literal [[\\.\pipe\*]] therefore matches nothing at all -- which is
    -- what this action used to do on Windows.
    --
    -- Narrowed to `nvim.` rather than `nvim*` on purpose: the same namespace
    -- carries each editor's own terminal job pipes, named nvim-term-in-<pid>-<n>
    -- and nvim-term-out-<pid>-<n>. Those are live pipes that are not RPC
    -- servers, so connecting to one blocks rather than failing. Server sockets
    -- are always nvim.<pid>.<n>, and the dot is what separates them.
    --
    -- Entries come back in the \\.\pipe\ form, which is the same form $NVIM
    -- takes, so the `host` comparison below matches without normalising.
    paths = vim.fn.glob([[//./pipe/nvim.*]], true, true)
  else
    -- Built up rather than written as a literal: `ipairs {a, b}` stops at the
    -- first nil, so with XDG_RUNTIME_DIR unset -- the common case -- a literal
    -- would silently never reach /tmp, and discovery would always come back
    -- empty on Linux.
    local dirs = {}
    if vim.env.XDG_RUNTIME_DIR and vim.env.XDG_RUNTIME_DIR ~= "" then dirs[#dirs + 1] = vim.env.XDG_RUNTIME_DIR end
    dirs[#dirs + 1] = "/tmp"

    -- The layout differs by directory, which is the part that is easy to get
    -- wrong. $XDG_RUNTIME_DIR is already private to the user, so Neovim puts
    -- the socket straight into it; /tmp is world writable, so it first makes a
    -- private nvim.<user>/<random>/ to hold it. All three shapes verified
    -- against 0.11.7 in nvim-mcp/tests/integration.
    local candidates = {}
    for _, dir in ipairs(dirs) do
      vim.list_extend(candidates, vim.fn.glob(dir .. "/nvim.*", true, true)) -- flat, 0.10+
      vim.list_extend(candidates, vim.fn.glob(dir .. "/nvim*/*/nvim.*", true, true)) -- nested, 0.10+
      vim.list_extend(candidates, vim.fn.glob(dir .. "/nvim*/0", true, true)) -- pre-0.10
    end

    -- The flat pattern also matches the private directory itself, and one
    -- socket can match two patterns. Both are filtered here rather than paid
    -- for as a failed connection attempt each.
    local seen = {}
    for _, path in ipairs(candidates) do
      local stat = vim.uv.fs_stat(path)
      if stat and stat.type == "socket" and not seen[path] then
        seen[path] = true
        paths[#paths + 1] = path
      end
    end
  end

  -- Probing runs in child processes, not inline. An editor can hold its socket
  -- open while never servicing RPC -- a real state, hit on this machine -- and
  -- `vim.rpcrequest` has no timeout. A uv timer cannot rescue it either, since
  -- callbacks do not run while the main loop is blocked. One such editor would
  -- hang discovery for every other one, and the MCP call would never return.
  --
  -- They are started together and waited on afterwards, so the whole sweep
  -- costs one timeout rather than one per instance. Only Neovim with nvim-mcp
  -- loaded answers; anything else on the namespace exits non-zero and is
  -- skipped.
  if not SELF then return {} end

  local running = {}
  for _, address in ipairs(paths) do
    running[#running + 1] = {
      address = address,
      proc = vim.system({ "nvim", "-u", "NONE", "-l", SELF, address }, { text = true, timeout = PROBE_MS }),
    }
  end

  local found, headless = {}, 0
  for _, job in ipairs(running) do
    local result = job.proc:wait()
    local ok, decoded = pcall(vim.json.decode, result.stdout or "")
    if result.code == 0 and ok and type(decoded) == "table" then
      -- Only instances with a UI. A headless Neovim answers identify exactly
      -- like an editor but has no screen to put a file on, so offering it as a
      -- target is worse than omitting it. Test runners and leaked scripts are
      -- easily the majority on a development machine; they are counted rather
      -- than silently dropped so an instance going missing is explainable.
      if decoded.ui == false then
        headless = headless + 1
      else
        found[#found + 1] = {
          address = job.address,
          host = job.address == vim.env.NVIM,
          info = decoded,
        }
      end
    end
  end
  return { editors = found, headless_skipped = headless }
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
default, full when a summary elides what you need. `args.wait_for` holds until
a named language server has attached, which matters because one that has not
reports every file clean.

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

  -- Waiting belongs here rather than in the editor. A loop inside Neovim would
  -- block the very session whose language servers are being waited on, so the
  -- thing being waited for could never happen. Both keys are consumed here and
  -- not forwarded, because the editor-side action knows nothing about them.
  local wait_for = args.wait_for
  local timeout = math.min(tonumber(args.timeout) or 60, MAX_WAIT)
  args.wait_for, args.timeout = nil, nil

  local deadline = os.time() + timeout
  while true do
    local result, err = editor(address, 'return require("nvim-mcp").invoke(...)', { action, args, opts })
    if not result then return fail(id, -32603, err or "Neovim is not reachable") end
    if not result.ok then return fail(id, -32603, result.message or "Action failed") end

    local content = result.content or { { type = "text", text = "ok" } }
    if not wait_for then return reply(id, { content = content }) end

    -- An action's payload is JSON in its first text block. `clients` is what
    -- diagnostics reports as attached, and is the only thing worth waiting on:
    -- a server that has not attached reports every file clean, however broken.
    local decoded_ok, decoded = pcall(vim.json.decode, content[1] and content[1].text or "")
    local ready = decoded_ok and type(decoded) == "table" and vim.tbl_contains(decoded.clients or {}, wait_for)
    if ready then return reply(id, { content = content }) end

    if os.time() >= deadline then
      -- Answer anyway, marked provisional. Returning nothing would be worse
      -- than a clean-looking result the caller has been told to distrust.
      if decoded_ok and type(decoded) == "table" then
        decoded.timed_out = true
        decoded.waited_for = wait_for
        content = { { type = "text", text = vim.json.encode(decoded) } }
      end
      return reply(id, { content = content })
    end

    vim.uv.sleep(POLL_MS)
  end
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
