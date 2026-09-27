--- An in-process language server for tests: vim.lsp.start with a `cmd`
--- function, as Neovim's own LSP tests do. Handlers answer with fixed data, so
--- the actions can be tested without a real server installed.
local M = {}

--- Returned by a handler: never answer, so the request times out.
M.NEVER = setmetatable({}, { __name = "NEVER" })

--- Returned by a handler: answer with an LSP error instead of a result.
function M.failure(code, message) return { __failure = { code = code, message = message } } end

--- Write `lines` to a new file in a fresh temp directory.
function M.file(lines, name)
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/" .. (name or "a.txt")
  vim.fn.writefile(lines, path)
  return path, dir
end

--- A range on one line, 0-based as LSP has it.
function M.range(line, from, to)
  return { start = { line = line, character = from }, ["end"] = { line = line, character = to } }
end

--- The `cmd` function of a fake server, for vim.lsp.start or vim.lsp.config.
--- Every request it receives is appended to `requests`.
function M.cmd(opts, requests)
  opts = opts or {}
  requests = requests or {}
  return function(dispatchers)
    local count = 0
    return {
      request = function(method, params, callback)
        count = count + 1
        requests[#requests + 1] = { method = method, params = params }
        -- Answer on a later tick, as a real server would: the client is
        -- still inside request() at this point. `initialize_delay` makes a
        -- server that is slow to start, as a cold rust-analyzer is.
        local delay = method == "initialize" and opts.initialize_delay or 0
        vim.defer_fn(function()
          local result
          if method == "initialize" then
            result = { capabilities = opts.capabilities or {} }
          elseif method == "shutdown" then
            result = vim.NIL
          else
            local handler = (opts.handlers or {})[method]
            if handler then result = handler(params, dispatchers) end
          end
          if result == M.NEVER then return end
          if type(result) == "table" and result.__failure then return callback(result.__failure, nil) end
          if result == nil then result = vim.NIL end
          callback(nil, result)
        end, delay)
        return true, count
      end,
      notify = function() return true end,
      is_closing = function() return false end,
      terminate = function() end,
    }
  end
end

--- Start a fake server attached to `buffer`, which must already be loaded:
--- vim.lsp.start returns nil for an unloaded buffer.
--- Returns the initialised client and a log of every request it received.
function M.start(buffer, root, opts)
  opts = opts or {}
  local requests = {}
  local id = vim.lsp.start({
    name = opts.name or "fake",
    root_dir = root,
    cmd = M.cmd(opts, requests),
  }, { bufnr = buffer })
  assert(id, "vim.lsp.start refused: is the buffer loaded?")
  local client = vim.lsp.get_client_by_id(id)
  vim.wait(1000, function() return client.initialized end, 10)
  return client, requests
end

--- Stop every client, so one test's server cannot answer another's request.
function M.stop_all()
  for _, client in ipairs(vim.lsp.get_clients()) do
    client:stop(true)
  end
  vim.wait(1000, function() return #vim.lsp.get_clients() == 0 end, 10)
end

return M
