--- Choosing a server and asking it, synchronously.
---
--- A request itself is synchronous: the human's editor waits while it runs, so
--- every request carries a timeout and the notice says what is happening.
--- Waiting for a server to attach or finish loading is not done here: that can
--- take a minute, so it is raised as not_ready (see nvim-mcp.lsp.ready) and the
--- bridge polls, leaving the editor responsive.
local ready = require "nvim-mcp.lsp.ready"

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

--- Every client on the buffer, including those still initialising, which
--- get_clients leaves out by default.
local function attached(buffer) return vim.lsp.get_clients { bufnr = buffer, _uninitialized = true } end

--- Configs that serve the buffer's filetype, enabled or not. rustaceanvim
--- starts rust-analyzer itself rather than through vim.lsp.enable, but
--- nvim-lspconfig's rust_analyzer config still names the filetype, which is
--- enough to know a server is plausible here and a `.txt` file has none.
local function configured(buffer)
  return vim.tbl_map(
    function(config) return config.name end,
    vim.lsp.get_configs { filetype = vim.bo[buffer].filetype }
  )
end

--- The servers on `buffer` that answer `method`, once they are ready. A server
--- still starting or loading, or one expected to attach to a buffer an action
--- has just loaded, raises not_ready; the bridge's final attempt goes ahead
--- with whatever is there.
function M.clients(buffer, method, _)
  local present = attached(buffer)
  local found = vim.tbl_filter(
    function(client) return client.initialized and client:supports_method(method, buffer) end,
    present
  )
  if #found > 0 then
    for _, client in ipairs(found) do
      local busy = ready.busy(client)
      if busy then
        if not ready.final then ready.raise(client.name, busy) end
        ready.proceeded = ("%s was %s"):format(client.name, busy)
      end
    end
    return found
  end

  local starting = vim.tbl_filter(function(client) return not client.initialized end, present)
  if #starting > 0 then
    if not ready.final then ready.raise(names(starting), "starting") end
    error {
      code = -32603,
      message = ("%s is still starting. Retry with a longer timeout, or call diagnostics with wait_for first."):format(
        names(starting)
      ),
    }
  end
  if #present == 0 then
    local expected = configured(buffer)
    if #expected > 0 and ready.recently_loaded(buffer) and not ready.final then
      ready.raise(nil, "not attached yet")
    end
    local filetype = vim.bo[buffer].filetype
    local hint = #expected > 0 and (" %s is configured for it."):format(table.concat(expected, ", ")) or ""
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
    -- ContentModified: the server's state moved under the request, as it does
    -- right after loading. It asks to be retried, so it is not_ready.
    if type(response.err) == "table" and response.err.code == -32801 and not ready.final then
      ready.raise(client.name, "updating (content modified)")
    end
    local message = type(response.err) == "table" and response.err.message or tostring(response.err)
    error { code = -32603, message = ("%s: %s"):format(client.name, message) }
  end
  if response.result == vim.NIL then return nil, false end
  return response.result, false
end

return M
