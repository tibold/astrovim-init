--- Choosing a server and asking it, synchronously.
---
--- Synchronous on purpose: one tool call per request, nothing to poll. The cost
--- is that the human's editor waits while a request runs, so every request
--- carries a timeout and the notice says what is happening. If the wait ever
--- becomes a problem, the fix is bridge-side polling, as `wait_for` does -- not
--- making calls less efficient.
local notice = require "nvim-mcp.lsp.notice"

local M = {}

M.DEFAULT_TIMEOUT = 5
M.MAX_TIMEOUT = 30

function M.timeout_ms(args)
  local seconds = tonumber(args and args.timeout) or M.DEFAULT_TIMEOUT
  seconds = math.max(0.1, math.min(seconds, M.MAX_TIMEOUT))
  return math.floor(seconds * 1000)
end

local function names(clients)
  return table.concat(vim.tbl_map(function(client) return client.name end, clients), ", ")
end

--- How long a server that is configured for the filetype but has not attached
--- is given to turn up. Some decide their root asynchronously (lua_ls does),
--- so right after a buffer loads nothing is attached although one is coming --
--- within moments. One that is not coming (no root here, a missing binary)
--- must not hold the editor for the whole timeout.
M.GRACE_MS = 2000

--- Every client on the buffer, including those still initialising, which
--- get_clients leaves out by default.
local function attached(buffer) return vim.lsp.get_clients { bufnr = buffer, _uninitialized = true } end

--- Configs enabled for the buffer's filetype with no client attached yet.
local function pending(buffer)
  local present = {}
  for _, client in ipairs(attached(buffer)) do
    present[client.name] = true
  end
  local out = {}
  for _, config in ipairs(vim.lsp.get_configs { enabled = true, filetype = vim.bo[buffer].filetype }) do
    if not present[config.name] then out[#out + 1] = config.name end
  end
  return out
end

--- The servers on `buffer` that answer `method`. A server still initialising
--- is waited for up to `ms`; one configured but not yet attached for
--- GRACE_MS; nothing configured fails at once. Any wait shows the notice.
function M.clients(buffer, method, ms)
  local function supporting()
    return vim.tbl_filter(
      function(client) return client.initialized and client:supports_method(method, buffer) end,
      attached(buffer)
    )
  end

  local found = supporting()
  if #found == 0 then
    local started = vim.uv.now()
    local function worth_waiting()
      local starting = vim.iter(attached(buffer)):any(function(client) return not client.initialized end)
      return starting or (#pending(buffer) > 0 and vim.uv.now() - started < M.GRACE_MS)
    end
    if worth_waiting() then
      local name = vim.fs.basename(vim.api.nvim_buf_get_name(buffer))
      -- The same 300 ms as lookups: a server that turns up at once is no news.
      notice.during(("Claude · LSP waiting for a language server on %s…"):format(name), 300, function()
        vim.wait(ms, function()
          found = supporting()
          return #found > 0 or not worth_waiting()
        end, 20)
      end)
    end
  end
  if #found > 0 then return found end

  local present = attached(buffer)
  local starting = vim.tbl_filter(function(client) return not client.initialized end, present)
  if #starting > 0 then
    error {
      code = -32603,
      message = ("%s is still starting. Retry with a longer timeout, or call diagnostics with wait_for first."):format(
        names(starting)
      ),
    }
  end
  if #present == 0 then
    local filetype = vim.bo[buffer].filetype
    local configured = vim.tbl_map(
      function(config) return config.name end,
      vim.lsp.get_configs { enabled = true, filetype = filetype }
    )
    local hint = #configured > 0 and (" %s is configured for it."):format(table.concat(configured, ", ")) or ""
    error {
      code = -32603,
      message = ("No language server is attached to %s (filetype %q).%s If one is still starting, call diagnostics with wait_for, then retry."):format(
        vim.api.nvim_buf_get_name(buffer),
        filetype,
        hint
      ),
    }
  end
  error { code = -32603, message = ("%s: no server here supports %s"):format(names(present), method) }
end

function M.client(buffer, method, ms) return M.clients(buffer, method, ms)[1] end

--- One request. Returns the result (nil for a null one) and whether it timed
--- out; a timed-out request is cancelled by request_sync itself.
function M.send(client, method, params, buffer, ms)
  local response, reason = client:request_sync(method, params, ms, buffer)
  if not response then
    if reason == "timeout" then return nil, true end
    error { code = -32603, message = ("%s: %s failed (%s)"):format(client.name, method, reason or "request refused") }
  end
  if response.err then
    local message = type(response.err) == "table" and response.err.message or tostring(response.err)
    error { code = -32603, message = ("%s: %s"):format(client.name, message) }
  end
  if response.result == vim.NIL then return nil, false end
  return response.result, false
end

return M
