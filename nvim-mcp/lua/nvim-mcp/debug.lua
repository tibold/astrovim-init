--- The human's debug session, through nvim-dap: what it stopped on, the stack,
--- the current frame's locals and the dap-ui watches; inspecting further;
--- stepping; starting and stopping sessions; and breakpoints.
---
--- Controls do not wait in here. They return `{ poll = { action = "state",
--- args = { after = <stops> } } }`, and the bridge polls `state`, which says
--- not_ready until the program stops again or ends. The editor stays usable
--- while the program runs, as it does while a language server indexes.
local mcp = require "nvim-mcp"

local M = {}

--- Frames listed, children per variable, and characters per value.
M.STACK = 10
M.CHILDREN = 50
M.VALUE_CHARS = 200
--- A single DAP request; they answer in milliseconds unless something is wrong.
M.REQUEST_MS = 3000
M.MAX_DEPTH = 3

--- Counts stops and ends, so `state { after = n }` can tell a new stop from
--- the one before a control was sent.
M.stops = 0
--- The last stopped event's body, and how the last session ended.
M.last_stop = nil
M.ended = nil
--- Breakpoints Claude set, as "<file>:<line>", so the human can tell them apart.
M.added = {}

function M.reset()
  M.stops, M.last_stop, M.ended, M.added = 0, nil, nil, {}
end

local function fail(message) error { code = -32603, message = message } end
local function invalid(message) error { code = -32602, message = message } end

local function get_dap()
  local ok, dap = pcall(require, "dap")
  if not ok then fail "nvim-dap is not installed" end
  return dap
end

--- Listen for stops and ends. Called when nvim-dap loads; it is lazy, and
--- requiring it at startup just to listen would load it for every session.
function M.hook(dap)
  dap.listeners.after.event_stopped["nvim-mcp"] = function(_, body)
    M.stops = M.stops + 1
    M.last_stop = body
  end
  local function ended(_, body)
    M.stops = M.stops + 1
    -- vim.NIL, not nil: js-debug ends a session without an exit code, and an
    -- empty table encodes as [] rather than as an object.
    M.ended = { exit_code = body and body.exitCode or vim.NIL }
  end
  dap.listeners.after.event_exited["nvim-mcp"] = ended
  dap.listeners.after.event_terminated["nvim-mcp"] = function(session, body)
    -- exited carries the code and usually comes first; keep it
    if not M.ended then
      ended(session, body)
    else
      M.stops = M.stops + 1
    end
  end
  dap.listeners.after.launch["nvim-mcp"] = function() M.ended = nil end
  dap.listeners.after.attach["nvim-mcp"] = function() M.ended = nil end
end

--- A DAP request, answered synchronously. vim.wait keeps the event loop
--- turning, so the reply is read as it arrives.
local function request(session, command, arguments)
  local done, err, result = false, nil, nil
  session:request(command, arguments, function(e, r)
    done, err, result = true, e, r
  end)
  vim.wait(M.REQUEST_MS, function() return done end, 5)
  if not done then fail(("%s timed out"):format(command)) end
  if err then fail(("%s: %s"):format(command, type(err) == "table" and err.message or tostring(err))) end
  return result or {}
end

local function short(text)
  text = tostring(text or "")
  if #text > M.VALUE_CHARS then return text:sub(1, M.VALUE_CHARS) .. "…", true end
  return text, nil
end

--- Variables under a reference, `depth` levels deep. A variable with children
--- carries `ref`, which `inspect` expands later.
local function variables(session, ref, depth)
  local found = request(session, "variables", { variablesReference = ref }).variables or {}
  local out = {}
  for index, variable in ipairs(found) do
    if index > M.CHILDREN then break end
    local value, cut = short(variable.value)
    local entry = { name = variable.name, value = value, type = variable.type, cut = cut }
    if (variable.variablesReference or 0) > 0 then
      entry.ref = variable.variablesReference
      if depth > 1 then
        entry.children, entry.more = variables(session, entry.ref, depth - 1)
      end
    end
    out[#out + 1] = entry
  end
  return out, #found > M.CHILDREN and #found - M.CHILDREN or nil
end

local function frame_file(frame) return frame.source and frame.source.path and vim.fs.normalize(frame.source.path) end

--- A frame's scopes, with only the locals expanded: the scope named like
--- "Local(s)", or the first when none is. The rest are named with their ref for
--- inspect. Adapters differ on what they mark expensive -- codelldb lists the C
--- runtime's statics beside the locals without the flag -- so the flag alone
--- does not keep a stop's reply small.
local function scopes(session, frame)
  local list = request(session, "scopes", { frameId = frame.id }).scopes or {}
  -- js-debug keeps a loop's variables in "Block" scopes beside "Local", so
  -- both count as the frame's locals.
  local expand = {}
  for index, scope in ipairs(list) do
    local name = tostring(scope.name):lower()
    if not scope.expensive and (name:match "^local" or name:match "^block") then expand[index] = true end
  end
  if next(expand) == nil and list[1] and not list[1].expensive then expand[1] = true end

  local out = {}
  for index, scope in ipairs(list) do
    if not expand[index] then
      out[#out + 1] = { name = scope.name, ref = scope.variablesReference, expensive = scope.expensive or nil }
    else
      local vars, more = variables(session, scope.variablesReference, 1)
      out[#out + 1] = { name = scope.name, variables = vars, more = more }
    end
  end
  return out
end

--- In the "watch" context: "repl" means debugger commands to some adapters
--- (codelldb reads `total` as an LLDB command there), while every adapter
--- evaluates an expression in "watch". Side effects still happen, by agreement.
local function evaluate(session, expression, frame)
  local result =
    request(session, "evaluate", { expression = expression, frameId = frame and frame.id, context = "watch" })
  local value, cut = short(result.result)
  return {
    value = value,
    cut = cut,
    type = result.type,
    ref = (result.variablesReference or 0) > 0 and result.variablesReference or nil,
  }
end

local function stopped_thread(session)
  local thread = session.stopped_thread_id and session.threads and session.threads[session.stopped_thread_id]
  return thread
end

local function breakpoint_list()
  local ok, breakpoints = pcall(require, "dap.breakpoints")
  if not ok then return {} end
  local out = {}
  for buffer, list in pairs(breakpoints.get()) do
    local file = vim.fs.normalize(vim.api.nvim_buf_get_name(buffer))
    for _, bp in ipairs(list) do
      out[#out + 1] = {
        file = file,
        line = bp.line,
        condition = bp.condition,
        hit_condition = bp.hitCondition,
        log_message = bp.logMessage,
        verified = bp.state and bp.state.verified,
        by_claude = M.added[file:lower() .. ":" .. bp.line] or nil,
      }
    end
  end
  table.sort(out, function(a, b) return a.file == b.file and a.line < b.line or a.file < b.file end)
  return out
end

--- Raised by the stand-in prompts while a configuration is resolved.
local PROMPT = setmetatable({}, {
  __tostring = function() return "prompts for input" end,
})

--- A configuration's function fields evaluated, with every way of asking the
--- human replaced by one that raises PROMPT. A function that only computes --
--- nvim-dap-python finding the virtualenv's python -- resolves to its value;
--- one that asks -- mason-nvim-dap's "LLDB: Launch" calling input() for the
--- program, a process picker -- would leave the human facing a prompt they did
--- not ask for while the bridge waits, so the configuration is interactive.
--- Returns the resolved copy, or nil and the field that asks (or failed).
---
--- Work deferred to the editor counts as asking too: easy-dotnet's
--- configuration schedules `:Dotnet debug profile`, a picker, and aborts. So
--- do a returned coroutine (mason-nvim-dap's NetCoreDbg program, which nvim-dap
--- runs later to pick a DLL) and nvim-dap's ABORT. Deferred work is swallowed,
--- not run.
local function resolve(config)
  local saved = {
    input = rawget(vim.fn, "input"),
    inputlist = rawget(vim.fn, "inputlist"),
    select = vim.ui.select,
    ui_input = vim.ui.input,
    schedule = vim.schedule,
    defer_fn = vim.defer_fn,
  }
  local deferred = false
  local function refuse() error(PROMPT, 0) end
  local function defer() deferred = true end
  vim.fn.input, vim.fn.inputlist, vim.ui.select, vim.ui.input = refuse, refuse, refuse, refuse
  vim.schedule, vim.defer_fn = defer, defer
  local abort = package.loaded["dap"] and package.loaded["dap"].ABORT

  local resolved, blocked = {}, nil
  for key, value in pairs(config) do
    if type(value) == "function" then
      local ok, result = pcall(value)
      if not ok or deferred or type(result) == "thread" or (abort ~= nil and result == abort) then
        blocked = key
        break
      end
      resolved[key] = result
    else
      resolved[key] = value
    end
  end

  -- rawget gave nil for the usual lazily looked-up vim.fn entries, and
  -- assigning nil back restores that lookup.
  vim.fn.input, vim.fn.inputlist, vim.ui.select, vim.ui.input =
    saved.input, saved.inputlist, saved.select, saved.ui_input
  vim.schedule, vim.defer_fn = saved.schedule, saved.defer_fn
  if blocked then return nil, blocked end
  return resolved
end

--- Whether a configuration computes any field when it starts. Only `start`
--- finds out whether that means asking the human: listing must never run
--- configuration code, since some of it opens pickers.
local function computed(config)
  for _, value in pairs(config) do
    if type(value) == "function" then return true end
  end
  return false
end

--- ${file} and its relatives, which nvim-dap would take from the current
--- buffer: when Claude starts a session, that is Claude's own terminal.
local function fill_file(value, file)
  if type(value) == "table" then
    local out = {}
    for key, inner in pairs(value) do
      out[key] = fill_file(inner, file)
    end
    return out
  end
  if type(value) ~= "string" or not value:find("${", 1, true) then return value end
  local cwd = vim.fn.getcwd()
  local relative = vim.fs.relpath and vim.fs.relpath(cwd, file) or file
  local variables = {
    file = file,
    fileBasename = vim.fs.basename(file),
    fileBasenameNoExtension = vim.fn.fnamemodify(file, ":t:r"),
    fileDirname = vim.fs.dirname(file),
    fileExtname = vim.fn.fnamemodify(file, ":e") ~= "" and "." .. vim.fn.fnamemodify(file, ":e") or "",
    relativeFile = relative,
    relativeFileDirname = vim.fs.dirname(relative),
  }
  -- nvim-dap would take the current window's directory: Claude's tab, not the
  -- project tab the file belongs to.
  local root = require("nvim-mcp.actions").project_root(file)
  if root then
    variables.workspaceFolder = root
    variables.workspaceFolderBasename = vim.fs.basename(root)
  end
  return (value:gsub("%${(%w+)}", function(name) return variables[name] end))
end

local function uses_file(value)
  if type(value) == "table" then
    for _, inner in pairs(value) do
      if uses_file(inner) then return true end
    end
    return false
  end
  if type(value) ~= "string" then return false end
  for _, variable in ipairs { "${file", "${relativeFile", "${workspaceFolder" } do
    if value:find(variable, 1, true) then return true end
  end
  return false
end

--- Configuration names by filetype: plain ones, and ones that compute fields
--- when they start (which `start` refuses if that computing asks the human).
local function configurations(dap)
  local plain, computing = {}, {}
  for filetype, list in pairs(dap.configurations or {}) do
    for _, config in ipairs(list) do
      if config.name then
        local into = computed(config) and computing or plain
        into[filetype] = into[filetype] or {}
        table.insert(into[filetype], config.name)
      end
    end
  end
  return plain, computing
end

local function watches(session, frame)
  local dapui = package.loaded["dapui"]
  local element = dapui and dapui.elements and dapui.elements.watches
  if not element then return nil end
  local out = {}
  for _, watch in ipairs(element.get() or {}) do
    local ok, result = pcall(evaluate, session, watch.expression, frame)
    if ok then
      out[#out + 1] = vim.tbl_extend("force", { expression = watch.expression }, result)
    else
      out[#out + 1] = {
        expression = watch.expression,
        error = type(result) == "table" and result.message or tostring(result),
      }
    end
  end
  return #out > 0 and out or nil
end

--- Where the session is: stopped (where, why, stack, locals, watches), running,
--- or not there at all. `after` waits for a stop or end later than that count.
function M.state(args, opts)
  args, opts = args or {}, opts or {}
  local dap = get_dap()
  local session = dap.session()
  local after = tonumber(args.after)
  -- `wait` is `after` for a caller that does not know the count: wait for the
  -- next stop or end of a program that is running now.
  -- With no session yet it waits for one to start and stop: debugging a test
  -- builds it first, and run_tests answers before the session exists.
  if args.wait and not after and not (session and stopped_thread(session)) then after = M.stops end
  local waiting = after ~= nil and M.stops <= after

  if not session then
    -- Right after start there is no session yet: the adapter is launching,
    -- and codelldb builds first. An end would have moved the count on.
    if waiting and not opts.final then return { not_ready = true, status = "starting" } end
    local plain, computing = configurations(dap)
    return {
      session = false,
      ended = M.ended,
      configurations = plain,
      computed = next(computing) and computing or nil,
      breakpoints = breakpoint_list(),
    }
  end

  local base =
    { session = { name = session.config.name, type = session.config.type, request = session.config.request } }
  local thread = stopped_thread(session)
  if not thread or not session.current_frame then
    if waiting and not opts.final then return { not_ready = true, status = "running" } end
    base.running = true
    base.breakpoints = breakpoint_list()
    return base
  end
  if waiting and not opts.final then return { not_ready = true, status = "running" } end

  local frame = session.current_frame
  local stop = M.last_stop or {}
  base.stopped = { reason = stop.reason, description = stop.description, text = stop.text, thread = thread.name }

  local file = frame_file(frame)
  local text
  if file and vim.uv.fs_stat(file) then
    local ok, lines = pcall(vim.fn.readfile, file, "", frame.line)
    text = ok and lines[frame.line] or nil
  end
  base.location = { file = file, line = frame.line, column = frame.column, text = text }

  local stack = {}
  for index, entry in ipairs(thread.frames or {}) do
    if index > M.STACK then break end
    stack[#stack + 1] = { index = index, name = entry.name, file = frame_file(entry), line = entry.line }
  end
  base.stack = stack
  base.stack_more = thread.frames and #thread.frames > M.STACK and #thread.frames - M.STACK or nil

  base.scopes = scopes(session, frame)
  base.watches = watches(session, frame)
  base.breakpoints = breakpoint_list()
  return base
end

--- Look further: an expression, a variable's children by `ref`, or another
--- frame's locals by its `frame` index in the stack.
function M.inspect(args)
  args = args or {}
  local session = get_dap().session()
  local thread = session and stopped_thread(session)
  if not thread then fail "the program is not stopped; inspect needs a stopped thread" end

  local frame = session.current_frame
  if args.frame then
    frame = (thread.frames or {})[tonumber(args.frame)]
    if not frame then invalid(("there is no frame %s; the stack has %d"):format(args.frame, #(thread.frames or {}))) end
  end
  local depth = math.max(1, math.min(tonumber(args.depth) or 1, M.MAX_DEPTH))

  if args.expression then
    local out = evaluate(session, args.expression, frame)
    if out.ref then
      out.children, out.more = variables(session, out.ref, depth)
    end
    return out
  end
  if args.ref then
    local children, more = variables(session, tonumber(args.ref), depth)
    return { children = children, more = more }
  end
  if args.frame then
    return {
      frame = { index = tonumber(args.frame), name = frame.name, file = frame_file(frame), line = frame.line },
      scopes = scopes(session, frame),
    }
  end
  invalid "inspect needs an expression, a ref or a frame"
end

--- Ask the bridge to wait, polling state, for the next stop or end.
local function wait_for_stop() return { poll = { action = "state", args = { after = M.stops } } } end

--- A control, by nvim-dap's function name. Refuses without a session: with
--- none, dap.continue opens the configuration picker in the human's editor.
function M.control(name)
  return function()
    local dap = get_dap()
    if not dap.session() then fail "there is no debug session; start one with start" end
    local reply = wait_for_stop()
    dap[name]()
    return reply
  end
end

--- Start a configuration by name, from dap.configurations.
--- Launch a configuration: resolve what it computes (refusing one that would
--- ask the human), fill the file variables, and wait for the first stop.
local function launch(dap, config, args, opts)
  local label = config.name or config.type or "the configuration"
  local resolved, field = resolve(config)
  if not resolved then
    fail(
      ("%q asks the human for input when it starts (its %s); ask them to start it, then drive it"):format(label, field)
    )
  end
  if uses_file(resolved) then
    local file = args.file or require("nvim-mcp.actions").state().file
    if args.file and vim.fn.isabsolutepath(file) == 0 then file = vim.fs.joinpath(opts.cwd or vim.fn.getcwd(), file) end
    if not file or file == "" then invalid(("%q debugs a file: pass file, or have one open"):format(label)) end
    resolved = fill_file(resolved, vim.fs.normalize(file))
  end
  M.ended = nil
  local reply = wait_for_stop()
  dap.run(resolved)
  return reply
end

--- Start a configuration by name, from dap.configurations, or one given in
--- full as `config` -- for a launch no listed configuration covers, such as
--- netcoredbg on a DLL that was just built.
function M.start(args, opts)
  args, opts = args or {}, opts or {}
  local dap = get_dap()
  if type(args.config) == "table" then
    if type(args.config.type) ~= "string" or not dap.adapters[args.config.type] then
      invalid(
        ("config.type must name a debug adapter; there are: %s"):format(table.concat(vim.tbl_keys(dap.adapters), ", "))
      )
    end
    local config = vim.tbl_extend("keep", args.config, { request = "launch", name = "Claude: " .. args.config.type })
    return launch(dap, config, args, opts)
  end
  if type(args.name) ~= "string" or args.name == "" then invalid "start needs a configuration name, or a config" end
  for _, list in pairs(dap.configurations or {}) do
    for _, config in ipairs(list) do
      if config.name == args.name then return launch(dap, config, args, opts) end
    end
  end
  local names = {}
  local plain, computing = configurations(dap)
  for _, group in ipairs { plain, computing } do
    for filetype, list in pairs(group) do
      names[#names + 1] = ("%s: %s"):format(filetype, table.concat(list, ", "))
    end
  end
  invalid(
    ("no configuration named %q. There are: %s"):format(args.name, #names > 0 and table.concat(names, "; ") or "none")
  )
end

function M.stop()
  local dap = get_dap()
  if not dap.session() then return { stopped = false, reason = "no session" } end
  local reply = wait_for_stop()
  dap.terminate()
  return reply
end

--- Set or clear a breakpoint, and send the file's breakpoints to every session.
function M.breakpoint(args)
  args = args or {}
  local dap = get_dap()
  local breakpoints = require "dap.breakpoints"
  if type(args.path) ~= "string" or args.path == "" then invalid "breakpoint needs a path" end
  local line = tonumber(args.line)
  if not line or line < 1 then invalid "breakpoint needs a 1-based line" end

  local buffer = require("nvim-mcp.lsp.position").buffer(args.path)
  local file = vim.fs.normalize(vim.api.nvim_buf_get_name(buffer))
  local key = file:lower() .. ":" .. line
  if args.clear then
    breakpoints.remove(buffer, line)
    M.added[key] = nil
  else
    breakpoints.set({
      condition = args.condition,
      hit_condition = args.hit_condition,
      log_message = args.log_message,
    }, buffer, line)
    M.added[key] = true
  end

  local current = breakpoints.get(buffer)
  local function send(sessions)
    for _, session in pairs(sessions or {}) do
      session:set_breakpoints(current)
      send(session.children)
    end
  end
  send(dap.sessions())
  return { breakpoints = breakpoint_list() }
end

function M.setup()
  if package.loaded["dap"] then
    M.hook(package.loaded["dap"])
  else
    vim.api.nvim_create_autocmd("User", {
      pattern = "LazyLoad",
      group = vim.api.nvim_create_augroup("nvim_mcp_debug", { clear = true }),
      callback = function(event)
        if event.data == "nvim-dap" then
          M.hook(require "dap")
          return true
        end
      end,
    })
  end

  local function register(spec)
    spec.tool = "debug"
    mcp.register(spec)
  end
  local nothing = { type = "object", properties = vim.empty_dict() }

  register {
    name = "state",
    description = "Where the debug session is: why it stopped, the line, the stack, the frame's locals and watches.",
    inputSchema = {
      type = "object",
      properties = {
        wait = { type = "boolean", description = "If the program is running, wait for its next stop or end." },
        after = {
          type = "integer",
          description = "Wait for a stop later than this count (set by the controls).",
        },
      },
    },
    handler = M.state,
  }
  register {
    name = "inspect",
    description = "Evaluate an expression, expand a variable by ref, or read another frame's locals.",
    inputSchema = {
      type = "object",
      properties = {
        expression = { type = "string" },
        ref = { type = "integer", description = "A variable's ref, from state or an earlier inspect." },
        frame = {
          type = "integer",
          minimum = 1,
          description = "Index in the stack; default the current frame.",
        },
        depth = { type = "integer", minimum = 1, maximum = M.MAX_DEPTH },
      },
    },
    handler = M.inspect,
  }
  for _, control in ipairs { "continue", "step_over", "step_into", "step_out", "pause" } do
    register {
      name = control,
      description = ("%s, then wait for the next stop."):format((control:gsub("_", " "):gsub("^%l", string.upper))),
      inputSchema = nothing,
      handler = M.control(control),
    }
  end
  register {
    name = "start",
    description = "Start a debug configuration by name and wait for the first stop.",
    inputSchema = {
      type = "object",
      properties = {
        name = { type = "string", description = "A configuration as state lists it." },
        config = {
          type = "object",
          description = "A full DAP configuration instead of a name: type (an adapter), request, program, args, cwd, env.",
        },
        file = { type = "string", description = "For ${file} in the configuration; default the human's file." },
      },
    },
    handler = M.start,
  }
  register {
    name = "stop",
    description = "End the debug session.",
    inputSchema = nothing,
    handler = M.stop,
  }
  register {
    name = "breakpoint",
    description = "Set a breakpoint at a file and line, optionally conditional, or clear one.",
    inputSchema = {
      type = "object",
      properties = {
        path = { type = "string" },
        line = { type = "integer", minimum = 1 },
        condition = { type = "string", description = "Stop only when this is true." },
        hit_condition = { type = "string", description = "Stop on this hit count, e.g. '5' or '>= 3'." },
        log_message = { type = "string", description = "Log this instead of stopping; {expr} interpolates." },
        clear = { type = "boolean" },
      },
      required = { "path", "line" },
    },
    handler = M.breakpoint,
  }
end

return M
