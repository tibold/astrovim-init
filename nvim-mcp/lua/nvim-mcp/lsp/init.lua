--- Language server actions: the servers this editor is already running,
--- reached through the `lsp` and `lsp_edit` tools. They are warm and configured the way the human
--- sees them, which Claude Code's own LSP tool -- a second set of servers --
--- cannot promise.
---
--- Navigation answers with locations. Edits are applied and saved, all or
--- nothing (see nvim-mcp.lsp.edit). Requests block the editor while they run;
--- the notice tells the human why.
local mcp = require "nvim-mcp"
local position = require "nvim-mcp.lsp.position"
local request = require "nvim-mcp.lsp.request"
local notice = require "nvim-mcp.lsp.notice"
local edit = require "nvim-mcp.lsp.edit"
local ready = require "nvim-mcp.lsp.ready"

local M = {}

--- Read-only requests usually answer in milliseconds; a notice flashing on
--- every hover would be noise, so it appears only once one has run this long.
M.QUIET_MS = 300
--- Locations kept in a summary.
M.SHOWN = 20

--- Everything a request at a position needs. The symbol is resolved before a
--- server is chosen, so a typo fails without waiting on anything.
function M.locate(args, method)
  local buffer = position.buffer(args.path)
  local line = tonumber(args.line)
  if not line then position.invalid "line is required" end
  local byte = position.byte_column(buffer, line, args.symbol, args.column)
  local ms = request.timeout_ms(args)
  local client = request.client(buffer, method, ms)
  return {
    buffer = buffer,
    client = client,
    ms = ms,
    line = line,
    byte = byte,
    params = position.params(buffer, line, byte, client.offset_encoding),
    what = args.symbol or ("%s:%d"):format(vim.fs.basename(vim.api.nvim_buf_get_name(buffer)), line),
  }
end

function M.label(verb, at) return ("Claude · LSP %s %s (%s)…"):format(verb, at.what, at.client.name) end

--- Locations (or LocationLinks) as { file, line, column, text }, 1-based
--- characters like everything else here.
function M.locations(result, encoding)
  if result == nil then return {} end
  if result.uri or result.targetUri then result = { result } end
  local out = {}
  for _, item in ipairs(vim.lsp.util.locations_to_items(result, encoding)) do
    local text = item.text or ""
    out[#out + 1] = {
      file = vim.fs.normalize(item.filename),
      line = item.lnum,
      column = position.byte_to_char(text, item.col),
      text = vim.trim(text),
    }
  end
  return out
end

--- A big codebase can return hundreds of references; a summary keeps the
--- count per file and the first few, as `diagnostics` does.
function M.summarise(locations, opts)
  if opts and opts.detail == "full" then return { count = #locations, locations = locations, detail = "full" } end
  local per_file, order = {}, {}
  for _, location in ipairs(locations) do
    if not per_file[location.file] then
      per_file[location.file] = 0
      order[#order + 1] = location.file
    end
    per_file[location.file] = per_file[location.file] + 1
  end
  return {
    count = #locations,
    by_file = vim.tbl_map(function(file) return { file = file, count = per_file[file] } end, order),
    locations = vim.list_slice(locations, 1, math.min(M.SHOWN, #locations)),
    truncated = #locations > M.SHOWN,
    detail = "summary",
  }
end

local function navigate(method, verb, extend)
  return function(args, opts)
    local at = M.locate(args, method)
    if extend then extend(at.params) end
    local result, timed_out = notice.during(M.label(verb, at), M.QUIET_MS, function()
      return request.send(at.client, method, at.params, at.buffer, at.ms)
    end)
    local reply = M.summarise(M.locations(result, at.client.offset_encoding), opts)
    reply.server = at.client.name
    reply.timed_out = timed_out or nil
    return reply
  end
end

M.definition = navigate("textDocument/definition", "definition of")
M.implementation = navigate("textDocument/implementation", "implementations of")
M.references = navigate(
  "textDocument/references",
  "references to",
  function(params) params.context = { includeDeclaration = true } end
)

function M.hover(args)
  local at = M.locate(args, "textDocument/hover")
  local result, timed_out = notice.during(M.label("hover", at), M.QUIET_MS, function()
    return request.send(at.client, "textDocument/hover", at.params, at.buffer, at.ms)
  end)
  local text = ""
  if result and result.contents then
    text = vim.trim(table.concat(vim.lsp.util.convert_input_to_markdown_lines(result.contents), "\n"))
  end
  return { server = at.client.name, text = text, timed_out = timed_out or nil }
end

M.SYMBOLS_SHOWN = 50

local function symbol_reply(items, server, timed_out, opts)
  local symbols = vim.tbl_map(
    function(item) return { name = item.text, file = vim.fs.normalize(item.filename or ""), line = item.lnum } end,
    items
  )
  local limit = (opts and opts.detail == "full") and #symbols or M.SYMBOLS_SHOWN
  return {
    server = server,
    count = #symbols,
    symbols = vim.list_slice(symbols, 1, math.min(limit, #symbols)),
    truncated = #symbols > limit or nil,
    timed_out = timed_out or nil,
  }
end

--- A file's outline with `path`, or a workspace-wide search with `query`. A
--- search asks every server that can answer, since a workspace may hold more
--- than one language; they share one time budget.
function M.symbols(args, opts)
  local ms = request.timeout_ms(args)
  if type(args.path) == "string" and args.path ~= "" then
    local buffer = position.buffer(args.path)
    local method = "textDocument/documentSymbol"
    local client = request.client(buffer, method, ms)
    local what = vim.fs.basename(vim.api.nvim_buf_get_name(buffer))
    local result, timed_out = notice.during(
      ("Claude · LSP symbols in %s (%s)…"):format(what, client.name),
      M.QUIET_MS,
      function() return request.send(client, method, { textDocument = { uri = vim.uri_from_bufnr(buffer) } }, buffer, ms) end
    )
    return symbol_reply(vim.lsp.util.symbols_to_items(result or {}, buffer, client.offset_encoding), client.name, timed_out, opts)
  end

  if type(args.query) ~= "string" or args.query == "" then
    position.invalid "symbols needs a path (a file's outline) or a query (a workspace search)"
  end
  local clients = vim.tbl_filter(
    function(client) return client.initialized and client:supports_method "workspace/symbol" end,
    vim.lsp.get_clients()
  )
  if #clients == 0 then error { code = -32603, message = "No running language server supports workspace symbol search" } end
  -- A server still indexing finds nothing, which would read as "no match".
  for _, client in ipairs(clients) do
    local busy = ready.busy(client)
    if busy then
      if not ready.final then ready.raise(client.name, busy) end
      ready.proceeded = ("%s was %s"):format(client.name, busy)
    end
  end

  local items, servers, timed_out = {}, {}, false
  notice.during(("Claude · LSP symbols matching %q…"):format(args.query), M.QUIET_MS, function()
    local started = vim.uv.now()
    for _, client in ipairs(clients) do
      local left = ms - (vim.uv.now() - started)
      if left <= 0 then
        timed_out = true
        break
      end
      local result, late = request.send(client, "workspace/symbol", { query = args.query }, nil, left)
      timed_out = timed_out or late
      vim.list_extend(items, vim.lsp.util.symbols_to_items(result or {}, nil, client.offset_encoding))
      servers[#servers + 1] = client.name
    end
  end)
  return symbol_reply(items, table.concat(servers, ", "), timed_out, opts)
end

--- One level of the call hierarchy: who calls the symbol, or what it calls.
function M.calls(args)
  local direction = args.direction or "incoming"
  if direction ~= "incoming" and direction ~= "outgoing" then
    position.invalid 'direction must be "incoming" or "outgoing"'
  end
  local at = M.locate(args, "textDocument/prepareCallHierarchy")
  local method = ("callHierarchy/%sCalls"):format(direction)

  local found, timed_out = notice.during(M.label(direction .. " calls of", at), M.QUIET_MS, function()
    local started = vim.uv.now()
    local items, late = request.send(at.client, "textDocument/prepareCallHierarchy", at.params, at.buffer, at.ms)
    if late or not items or #items == 0 then return {}, late end
    local left = math.max(1, at.ms - (vim.uv.now() - started))
    return request.send(at.client, method, { item = items[1] }, at.buffer, left)
  end)

  local calls = {}
  for _, call in ipairs(found or {}) do
    local target = call.from or call.to
    calls[#calls + 1] = {
      name = target.name,
      file = vim.fs.normalize(vim.uri_to_fname(target.uri)),
      line = target.selectionRange.start.line + 1,
      sites = #(call.fromRanges or {}),
    }
  end
  return { server = at.client.name, direction = direction, count = #calls, calls = calls, timed_out = timed_out or nil }
end

--- Edits leave a line in the message history as well as the reply, so the
--- human can see what changed even if they were not watching the notice.
local function announce(reply, message)
  if reply.applied and reply.changed and #reply.changed > 0 then vim.notify(message, vim.log.levels.INFO) end
  return reply
end

local function files_phrase(count) return ("%d file%s"):format(count, count == 1 and "" or "s") end

function M.rename(args)
  if type(args.new_name) ~= "string" or args.new_name == "" then position.invalid "rename needs new_name" end
  local at = M.locate(args, "textDocument/rename")
  at.params.newName = args.new_name

  local reply = notice.during(
    ("Claude · LSP rename %s → %s (%s)…"):format(at.what, args.new_name, at.client.name),
    0,
    function()
      local result, timed_out = request.send(at.client, "textDocument/rename", at.params, at.buffer, at.ms)
      if timed_out then return { applied = false, timed_out = true } end
      if not result then return { applied = false, reason = "no edit", message = "The server returned no rename edit here." } end
      return edit.apply(result, at.client.offset_encoding)
    end
  )
  reply.server = at.client.name
  return announce(
    reply,
    ("Claude renamed %s → %s in %s"):format(at.what, args.new_name, files_phrase(reply.changed and #reply.changed or 0))
  )
end

--- Format a file, or whole lines `line`..`end_line`.
function M.format(args)
  local buffer = position.buffer(args.path)
  local ms = request.timeout_ms(args)
  local ranged = args.line ~= nil
  local method = ranged and "textDocument/rangeFormatting" or "textDocument/formatting"
  local client = request.client(buffer, method, ms)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(buffer) },
    options = { tabSize = vim.lsp.util.get_effective_tabstop(buffer), insertSpaces = vim.bo[buffer].expandtab },
  }
  if ranged then params.range = position.line_range(buffer, args.line, args.end_line or args.line, client.offset_encoding) end

  local name = vim.fs.basename(vim.api.nvim_buf_get_name(buffer))
  local reply = notice.during(("Claude · LSP format %s (%s)…"):format(name, client.name), 0, function()
    local result, timed_out = request.send(client, method, params, buffer, ms)
    if timed_out then return { applied = false, timed_out = true } end
    if not result or #result == 0 then return { applied = true, changed = {}, note = "Already formatted." } end
    return edit.apply({ changes = { [vim.uri_from_bufnr(buffer)] = result } }, client.offset_encoding)
  end)
  reply.server = client.name
  return announce(reply, ("Claude formatted %s"):format(name))
end

--- The diagnostics on lines first..last in the shape a server expects back:
--- quick fixes are keyed to them.
local function context_diagnostics(buffer, first, last)
  local out = {}
  for _, diagnostic in ipairs(vim.diagnostic.get(buffer)) do
    local lsp_form = diagnostic.user_data and diagnostic.user_data.lsp
    if lsp_form and diagnostic.lnum >= first - 1 and diagnostic.lnum <= last - 1 then out[#out + 1] = lsp_form end
  end
  return out
end

--- Every server's code actions over whole lines, in one list. Asked fresh
--- each time: a list kept from an earlier call goes stale with the first edit.
local function gather(args)
  local buffer = position.buffer(args.path)
  local first = tonumber(args.line)
  if not first then position.invalid "line is required" end
  local last = tonumber(args.end_line) or first
  local ms = request.timeout_ms(args)
  local clients = request.clients(buffer, "textDocument/codeAction", ms)

  local found, timed_out, started = {}, false, vim.uv.now()
  for _, client in ipairs(clients) do
    local left = ms - (vim.uv.now() - started)
    if left <= 0 then
      timed_out = true
      break
    end
    local params = {
      textDocument = { uri = vim.uri_from_bufnr(buffer) },
      range = position.line_range(buffer, first, last, client.offset_encoding),
      context = { diagnostics = context_diagnostics(buffer, first, last), triggerKind = 1 },
    }
    local result, late = request.send(client, "textDocument/codeAction", params, buffer, left)
    timed_out = timed_out or late
    for _, action in ipairs(result or {}) do
      found[#found + 1] = { action = action, client = client }
    end
  end
  return { buffer = buffer, ms = ms, actions = found, timed_out = timed_out }
end

function M.code_actions(args)
  local where = ("%s:%s"):format(vim.fs.basename(tostring(args.path or "")), tostring(args.line))
  local found = notice.during(("Claude · LSP code actions at %s…"):format(where), M.QUIET_MS, function() return gather(args) end)
  local list = {}
  for index, entry in ipairs(found.actions) do
    list[#list + 1] = {
      index = index,
      title = entry.action.title,
      kind = entry.action.kind,
      server = entry.client.name,
      disabled = entry.action.disabled and entry.action.disabled.reason or nil,
    }
  end
  return { count = #list, actions = list, timed_out = found.timed_out or nil }
end

local function message_of(err) return type(err) == "table" and err.message or tostring(err) end

--- A command Neovim or the client handles itself runs inside the editor --
--- roslyn.nvim's "Fix all" opens a picker and applies the choice unsaved --
--- so nothing honest could be reported about it. It is refused instead.
local function client_side(command, client)
  if not (client.commands[command.command] or vim.lsp.commands[command.command]) then return nil end
  return {
    applied = false,
    reason = "client command",
    message = ("%q runs inside the editor and may ask for a choice; ask the human to apply it."):format(
      command.title or command.command
    ),
  }
end

--- Run a Command on the server. An edit it sends back goes through
--- edit.apply; if the server then fails the command, what did or did not land
--- is still reported, with the server's error alongside.
function M.run_command(command, client, buffer, ms)
  local refused = client_side(command, client)
  if refused then return refused end

  local reply, failure = { applied = true, changed = {} }, nil
  local _, results = edit.capturing(client.offset_encoding, function()
    local ok, value, late = pcall(
      request.send,
      client,
      "workspace/executeCommand",
      { command = command.command, arguments = command.arguments },
      buffer,
      ms
    )
    if ok then
      reply.timed_out = late or nil
    else
      failure = message_of(value)
    end
  end)
  for _, result in ipairs(results) do
    if result.applied ~= true then
      result.server_error = failure
      return result
    end
    vim.list_extend(reply.changed, result.changed)
  end
  if failure then
    if #reply.changed == 0 then error { code = -32603, message = failure } end
    reply.server_error = failure
  end
  return reply
end

--- Apply one code action: resolve it if it came without its edit, apply the
--- edit, then run its command -- the order the protocol prescribes.
function M.run_action(action, client, buffer, ms)
  -- A bare Command in the list rather than a CodeAction.
  if type(action.command) == "string" then return M.run_command(action, client, buffer, ms) end
  if action.disabled then return { applied = false, reason = "disabled", message = action.disabled.reason } end

  if not action.edit and not action.command and client:supports_method("codeAction/resolve", buffer) then
    local resolved, late = request.send(client, "codeAction/resolve", action, buffer, ms)
    if late then return { applied = false, timed_out = true } end
    action = resolved or action
  end

  -- Refused before the edit, so the action is not left half applied.
  local refused = action.command and client_side(action.command, client)
  if refused then return refused end

  local reply = { applied = true, changed = {} }
  if action.edit then
    reply = edit.apply(action.edit, client.offset_encoding)
    if reply.applied ~= true then return reply end
  end
  if action.command then
    local ok, ran = pcall(M.run_command, action.command, client, buffer, ms)
    if not ok then
      -- The action's own edit landed and was saved; say so, with the error.
      if #reply.changed == 0 then error(ran, 0) end
      reply.server_error = message_of(ran)
      return reply
    end
    if ran.applied ~= true then
      ran.changed = reply.changed -- the action's own edit did land
      return ran
    end
    vim.list_extend(reply.changed, ran.changed)
    reply.timed_out = ran.timed_out
    reply.server_error = ran.server_error
  end
  return reply
end

function M.code_action(args)
  if type(args.title) ~= "string" or args.title == "" then
    position.invalid "code_action needs the exact title from code_actions"
  end
  local reply, server = notice.during(("Claude · LSP code action %q…"):format(args.title), 0, function()
    local found = gather(args)
    local chosen
    local index = tonumber(args.index)
    -- An index only picks among duplicates of the same title: a list that
    -- shifted since code_actions must not apply the wrong fix.
    if index and found.actions[index] and found.actions[index].action.title == args.title then chosen = found.actions[index] end
    if not chosen then
      for _, entry in ipairs(found.actions) do
        if entry.action.title == args.title then
          chosen = entry
          break
        end
      end
    end
    if not chosen then
      local titles = vim.tbl_map(function(entry) return entry.action.title end, found.actions)
      error {
        code = -32602,
        message = ("No code action titled %q here. Available: %s"):format(
          args.title,
          #titles > 0 and table.concat(titles, " | ") or "none"
        ),
      }
    end
    return M.run_action(chosen.action, chosen.client, found.buffer, found.ms), chosen.client.name
  end)

  reply.server, reply.title = server, args.title
  if reply.applied and #(reply.changed or {}) == 0 and not reply.timed_out then
    reply.note = "The action ran but changed no files."
  end
  return announce(reply, ("Claude applied %q in %s"):format(args.title, files_phrase(#(reply.changed or {}))))
end

local POSITION = {
  path = { type = "string", description = "The file to ask about." },
  line = { type = "integer", minimum = 1, description = "1-based line." },
  symbol = { type = "string", description = "The word at that spot on the line. Preferred over column." },
  column = { type = "integer", minimum = 1, description = "1-based character column; picks among repeats of symbol." },
  timeout = { type = "number", description = "Seconds to wait. Default 5, capped at 30." },
}

function M.positioned(extra, required)
  return {
    type = "object",
    properties = vim.tbl_extend("force", POSITION, extra or {}),
    required = vim.list_extend({ "path", "line" }, required or {}),
  }
end

--- Lookups go on the `lsp` tool and edits on `lsp_edit`, so a permission rule
--- can allow one and still ask for the other. Each tool lists all of its
--- actions: there are few enough that none needs hiding.
function M.setup()
  ready.setup()
  -- Every action can find its server still loading; see nvim-mcp.lsp.ready.
  local function register(spec)
    spec.handler = ready.guard(spec.handler, spec.tool == "lsp_edit")
    mcp.register(spec)
  end

  register {
    name = "definition",
    tool = "lsp",
    description = "Where the symbol at a file and line is defined, from the editor's language server.",
    inputSchema = M.positioned(),
    handler = M.definition,
  }
  register {
    name = "references",
    tool = "lsp",
    description = "Every reference to the symbol at a file and line, grouped by file.",
    inputSchema = M.positioned(),
    handler = M.references,
  }
  register {
    name = "hover",
    tool = "lsp",
    description = "Type and documentation for the symbol at a file and line.",
    inputSchema = M.positioned(),
    handler = M.hover,
  }
  register {
    name = "implementation",
    tool = "lsp",
    description = "Implementations of the interface or abstract member at a file and line.",
    inputSchema = M.positioned(),
    handler = M.implementation,
  }
  register {
    name = "symbols",
    tool = "lsp",
    description = "A file's symbol outline (path), or a workspace-wide symbol search (query).",
    inputSchema = {
      type = "object",
      properties = {
        path = { type = "string", description = "Outline this file." },
        query = { type = "string", description = "Search the workspace for symbols matching this." },
        timeout = { type = "number", description = "Seconds to wait. Default 5, capped at 30." },
      },
    },
    handler = M.symbols,
  }
  register {
    name = "calls",
    tool = "lsp",
    description = "Who calls the function at a file and line (incoming), or what it calls (outgoing).",
    inputSchema = M.positioned { direction = { type = "string", enum = { "incoming", "outgoing" } } },
    handler = M.calls,
  }
  register {
    name = "rename",
    tool = "lsp_edit",
    description = "Rename the symbol at a file and line across the workspace; applied and saved.",
    inputSchema = M.positioned({ new_name = { type = "string" } }, { "new_name" }),
    handler = M.rename,
  }
  register {
    name = "format",
    tool = "lsp_edit",
    description = "Format a file, or lines line..end_line, with its language server; applied and saved.",
    inputSchema = {
      type = "object",
      properties = {
        path = { type = "string" },
        line = { type = "integer", minimum = 1 },
        end_line = { type = "integer", minimum = 1 },
        timeout = { type = "number", description = "Seconds to wait. Default 5, capped at 30." },
      },
      required = { "path" },
    },
    handler = M.format,
  }
  register {
    name = "code_actions",
    tool = "lsp",
    description = "List the fixes and refactors language servers offer on lines line..end_line; changes nothing.",
    inputSchema = {
      type = "object",
      properties = {
        path = { type = "string" },
        line = { type = "integer", minimum = 1 },
        end_line = { type = "integer", minimum = 1 },
        timeout = { type = "number", description = "Seconds to wait. Default 5, capped at 30." },
      },
      required = { "path", "line" },
    },
    handler = M.code_actions,
  }
  register {
    name = "code_action",
    tool = "lsp_edit",
    description = "Apply one code action by its exact title from code_actions; applied and saved.",
    inputSchema = {
      type = "object",
      properties = {
        path = { type = "string" },
        line = { type = "integer", minimum = 1 },
        end_line = { type = "integer", minimum = 1 },
        title = { type = "string", description = "Exact title from code_actions." },
        index = { type = "integer", minimum = 1, description = "Picks among duplicate titles; ignored if its title differs." },
        timeout = { type = "number", description = "Seconds to wait. Default 5, capped at 30." },
      },
      required = { "path", "line", "title" },
    },
    handler = M.code_action,
  }
end

return M
