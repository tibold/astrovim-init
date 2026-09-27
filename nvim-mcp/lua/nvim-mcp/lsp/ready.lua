--- Whether a language server is ready to answer, and a way to say it is not.
---
--- A server that is attached but still loading its workspace answers lookups
--- with nothing: rust-analyzer returns no definitions and no references until
--- it has indexed, which reads exactly like "none found". So an action that
--- finds its server busy does not ask; it raises `not_ready`, which the action
--- wrapper turns into a `{ not_ready = true, ... }` reply. The bridge polls on
--- that, as it does for `wait_for`, so the editor stays responsive while a cold
--- server indexes instead of blocking inside a vim.wait.
---
--- The bridge's last attempt sets `final`: the request is then sent whatever
--- the state, and the reply carries `loading` so an answer from a server still
--- loading is not mistaken for a complete one.
local notice = require "nvim-mcp.lsp.notice"

local M = {}

--- After a server's last progress ends, how long it still counts as busy.
--- Loading comes in stages, each its own progress token, with short gaps
--- between them that are not the end of the work.
M.SETTLE_MS = 250
--- How long a server that has not yet reported any progress counts as busy
--- after it attaches. easy-dotnet's Roslyn attaches, then begins "Loading
--- <solution>" only once the solution is opened: a lookup in between got an
--- empty answer from a server that had not started loading. A server that
--- never reports progress waits this once, at most.
M.FIRST_PROGRESS_MS = 10000
--- How long after this module's actions load a buffer a server is expected to
--- attach to it. rustaceanvim attaches only once `cargo metadata` returns.
M.ATTACH_MS = 15000
--- How long the "waiting on" notice stays up after the last poll refreshed it.
M.NOTICE_MS = 1000

--- client id -> { quiescent?, tokens = { [token] = text }, titles, last }.
--- Kept after a client stops: ids are never reused, and the entry is small.
M.status = {}
--- buffer -> when an action loaded it (vim.uv.now())
M.loaded = {}
--- Set for the bridge's last attempt; see the module comment.
M.final = false
--- What the request was sent through despite, when `final` let it proceed.
M.proceeded = nil

local function status(id)
  M.status[id] = M.status[id] or { tokens = {}, titles = {}, last = 0 }
  return M.status[id]
end

--- Why `client` cannot usefully answer yet, or nil when it can.
function M.busy(client)
  if not client.initialized then return "starting" end
  local state = M.status[client.id]
  if not state then return nil end
  local _, working = next(state.tokens)
  -- rust-analyzer says exactly when it is done loading. Its progress is not a
  -- good guide after that: flycheck runs `cargo clippy` under progress on
  -- every save, and lookups answer fine meanwhile.
  if state.quiescent ~= nil then
    if state.quiescent then return nil end
    return working or "loading the workspace"
  end
  if working then return working end
  if state.last == 0 and state.attached and vim.uv.now() - state.attached < M.FIRST_PROGRESS_MS then
    return "starting up (no progress reported yet)"
  end
  if vim.uv.now() - state.last < M.SETTLE_MS then return "loading" end
  return nil
end

--- Raise not_ready for `server` (a name, or nil when none is attached yet).
function M.raise(server, what)
  error {
    code = -32603,
    not_ready = true,
    server = server,
    status = what,
    message = ("%s is %s"):format(server or "The language server", what),
  }
end

--- The buffer was loaded by an action just now, so FileType has only just
--- fired and a server may be on its way.
function M.recently_loaded(buffer)
  local at = M.loaded[buffer]
  return at ~= nil and vim.uv.now() - at < M.ATTACH_MS
end

--- Run an action handler, turning not_ready into a reply the bridge polls on.
--- `strict` is for edits: they never go ahead against a server still loading,
--- final attempt or not, since a rename computed from half an index would
--- miss references and still be applied.
function M.guard(handler, strict)
  return function(args, opts)
    opts = opts or {}
    M.final, M.proceeded = opts.final == true and not strict, nil
    local ok, result = pcall(handler, args, opts)
    local proceeded = M.proceeded
    M.final, M.proceeded = false, nil

    if not ok then
      if type(result) == "table" and result.not_ready then
        local text = ("Claude · LSP waiting: %s"):format(result.message)
        notice.linger(text, M.NOTICE_MS)
        return { not_ready = true, server = result.server, status = result.status }
      end
      error(result, 0)
    end
    if proceeded and type(result) == "table" then result.loading = proceeded end
    return result
  end
end

local function track_status(client)
  local state = status(client.id)
  state.attached = state.attached or vim.uv.now()
  if state.wrapped then return end
  state.wrapped = true
  -- rustaceanvim installs its own handler on the client, which is consulted
  -- before vim.lsp.handlers, so wrap the client's rather than adding a global.
  local original = client.handlers["experimental/serverStatus"]
  client.handlers["experimental/serverStatus"] = function(err, result, ctx, config)
    if type(result) == "table" then state.quiescent = result.quiescent == true end
    if original then return original(err, result, ctx, config) end
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("nvim_mcp_lsp_ready", { clear = true })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(event)
      local client = vim.lsp.get_client_by_id(event.data.client_id)
      if client then track_status(client) end
    end,
  })
  vim.api.nvim_create_autocmd("LspProgress", {
    group = group,
    callback = function(event)
      local params = event.data.params or {}
      local value = params.value
      if type(value) ~= "table" or params.token == nil then return end
      local state = status(event.data.client_id)
      state.last = vim.uv.now()
      local token = params.token
      if value.kind == "end" then
        state.tokens[token], state.titles[token] = nil, nil
      else
        -- Only `begin` carries the title; reports carry the message.
        if value.title then state.titles[token] = value.title end
        local title = state.titles[token] or "working"
        state.tokens[token] = value.message and ("%s: %s"):format(title, value.message) or title
      end
    end,
  })
end

return M
