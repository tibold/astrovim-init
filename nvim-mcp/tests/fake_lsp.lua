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

--- Capabilities that make Neovim send whole documents, which `documents`
--- below can follow without applying incremental changes.
M.FULL_SYNC = { openClose = true, change = 1 }

--- Keep `documents` (uri -> text) as a server would: from what it was sent.
local function follow(documents, method, params)
  if method == "textDocument/didOpen" then
    documents[params.textDocument.uri] = params.textDocument.text
  elseif method == "textDocument/didChange" then
    documents[params.textDocument.uri] = params.contentChanges[#params.contentChanges].text
  elseif method == "textDocument/didClose" then
    documents[params.textDocument.uri] = nil
  end
end

local function is_word(char) return char ~= "" and char:match "[%w_]" ~= nil end

--- A rename handler computed the way a real server computes one: from the
--- text it was sent, not from disk. It renames the word at the position in
--- every open document. Needs `documents` given to cmd/start, and FULL_SYNC.
function M.word_rename(documents)
  return function(params)
    local text = documents[params.textDocument.uri]
    if not text then return vim.NIL end
    local line = (vim.split(text, "\n", { plain = true })[params.position.line + 1] or ""):gsub("\r$", "")
    local first, last = params.position.character + 1, params.position.character + 1
    while is_word(line:sub(first - 1, first - 1)) do
      first = first - 1
    end
    while is_word(line:sub(last, last)) do
      last = last + 1
    end
    local word = line:sub(first, last - 1)
    if word == "" then return vim.NIL end

    local changes = {}
    for uri, document in pairs(documents) do
      local edits = {}
      for index, text_line in ipairs(vim.split(document, "\n", { plain = true })) do
        text_line = text_line:gsub("\r$", "")
        local from = 1
        while true do
          local a, b = text_line:find(word, from, true)
          if not a then break end
          if not is_word(text_line:sub(a - 1, a - 1)) and not is_word(text_line:sub(b + 1, b + 1)) then
            edits[#edits + 1] = { range = M.range(index - 1, a - 1, b), newText = params.newName }
          end
          from = b + 1
        end
      end
      if #edits > 0 then changes[uri] = edits end
    end
    return { changes = changes }
  end
end

--- The `cmd` function of a fake server, for vim.lsp.start or vim.lsp.config.
--- Every request it receives is appended to `requests`. With `opts.documents`,
--- it keeps the text of every open document there, from its notifications.
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
      notify = function(method, params)
        if opts.documents then follow(opts.documents, method, params) end
        return true
      end,
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
