local debug = require "nvim-mcp.debug"
local dap = require "dap"
local breakpoints = require "dap.breakpoints"

local function file(lines)
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/main.rs"
  vim.fn.writefile(lines or { "fn main() {", "    let total = add(1, 2);", '    println!("{total}");', "}" }, path)
  return path
end

--- A stopped session answering DAP requests from `answers`, keyed by command.
--- Each answer is a table, or a function of the request's arguments.
local function fake_session(path, answers, requests)
  requests = requests or {}
  local frame = { id = 11, name = "demo::main", line = 2, column = 17, source = { path = path } }
  local session = {
    config = { name = "Debug demo", type = "codelldb", request = "launch" },
    stopped_thread_id = 1,
    current_frame = frame,
    threads = {
      [1] = {
        id = 1,
        name = "main",
        frames = {
          frame,
          { id = 12, name = "std::rt::lang_start", line = 199, source = { path = "C:/rust/rt.rs" } },
        },
      },
    },
    children = {},
  }
  function session:request(command, arguments, callback)
    requests[#requests + 1] = { command = command, arguments = arguments }
    local answer = answers[command]
    if type(answer) == "function" then answer = answer(arguments) end
    vim.schedule(function()
      if answer == nil then return callback({ message = "unsupported: " .. command }, nil) end
      callback(nil, answer)
    end)
  end
  function session:set_breakpoints(bps) self.sent = bps end
  return session, requests
end

local LOCALS = {
  scopes = {
    scopes = {
      { name = "Local", variablesReference = 100 },
      { name = "Static", variablesReference = 200, expensive = true },
    },
  },
  variables = function(arguments)
    if arguments.variablesReference == 100 then
      return {
        variables = {
          { name = "total", value = "3", type = "i32", variablesReference = 0 },
          { name = "names", value = "size=2", type = "Vec<String>", variablesReference = 101 },
        },
      }
    end
    if arguments.variablesReference == 101 then
      return {
        variables = {
          { name = "[0]", value = '"ann"', type = "String", variablesReference = 0 },
          { name = "[1]", value = '"bob"', type = "String", variablesReference = 0 },
        },
      }
    end
  end,
  evaluate = function(arguments)
    if arguments.expression == "total * 2" then return { result = "6", type = "i32", variablesReference = 0 } end
    if arguments.expression == "names" then
      return { result = "size=2", type = "Vec<String>", variablesReference = 101 }
    end
  end,
}

describe("debug", function()
  local original = {}

  before_each(function()
    debug.reset()
    debug.hook(dap)
    for _, name in ipairs {
      "session",
      "sessions",
      "continue",
      "step_over",
      "step_into",
      "step_out",
      "pause",
      "terminate",
      "run",
    } do
      original[name] = dap[name]
    end
    breakpoints.clear()
  end)

  after_each(function()
    for name, fn in pairs(original) do
      dap[name] = fn
    end
  end)

  local function with_session(session)
    dap.session = function() return session end
    dap.sessions = function() return { [1] = session } end
  end

  describe("state", function()
    it("says when there is no session, and what could be started", function()
      with_session(nil)
      dap.configurations.rust = { { name = "Debug demo", type = "codelldb", request = "launch" } }
      local reply = debug.state({}, {})
      assert.is_false(reply.session)
      assert.are.same({ rust = { "Debug demo" } }, reply.configurations)
      dap.configurations.rust = nil
    end)

    it("reports where it stopped, why, the stack and the current frame's locals", function()
      local path = file()
      with_session(fake_session(path, LOCALS))
      dap.listeners.after.event_stopped["nvim-mcp"](dap.session(), { reason = "breakpoint", threadId = 1 })
      local reply = debug.state({}, {})
      assert.are.equal("Debug demo", reply.session.name)
      assert.are.same({ reason = "breakpoint", thread = "main" }, reply.stopped)
      assert.are.same(
        { file = vim.fs.normalize(path), line = 2, column = 17, text = "    let total = add(1, 2);" },
        reply.location
      )
      assert.are.same({ index = 1, name = "demo::main", file = vim.fs.normalize(path), line = 2 }, reply.stack[1])
      assert.are.equal(2, #reply.stack)
      local locals = reply.scopes[1]
      assert.are.equal("Local", locals.name)
      assert.are.same({ name = "total", value = "3", type = "i32" }, locals.variables[1])
      assert.are.same({ name = "names", value = "size=2", type = "Vec<String>", ref = 101 }, locals.variables[2])
      -- expensive scopes are named, not fetched
      assert.are.same({ name = "Static", ref = 200, expensive = true }, reply.scopes[2])
    end)

    it("expands only the locals scope, naming the others with their ref", function()
      -- codelldb puts the C runtime's statics beside the locals without
      -- marking them expensive: fifty lines of noise on every stop.
      local path = file()
      with_session(fake_session(path, {
        scopes = {
          scopes = {
            { name = "Static", variablesReference = 200 },
            { name = "Local", variablesReference = 100 },
          },
        },
        variables = LOCALS.variables,
      }))
      local reply = debug.state({}, {})
      assert.are.same({ name = "Static", ref = 200 }, reply.scopes[1])
      assert.are.equal("Local", reply.scopes[2].name)
      assert.are.equal(2, #reply.scopes[2].variables)
    end)

    it("expands js-debug's Block scopes with the locals", function()
      local path = file()
      with_session(fake_session(path, {
        scopes = {
          scopes = {
            { name = "Block: main", variablesReference = 101 },
            { name = "Local: main", variablesReference = 100 },
            { name = "Closure", variablesReference = 300 },
          },
        },
        variables = LOCALS.variables,
      }))
      local reply = debug.state({}, {})
      assert.is_truthy(reply.scopes[1].variables, "Block expanded")
      assert.is_truthy(reply.scopes[2].variables, "Local expanded")
      assert.are.same({ name = "Closure", ref = 300 }, reply.scopes[3])
    end)

    it("cuts long values short", function()
      local path = file()
      local long = string.rep("x", 500)
      with_session(fake_session(path, {
        scopes = { scopes = { { name = "Local", variablesReference = 100 } } },
        variables = { variables = { { name = "blob", value = long, variablesReference = 0 } } },
      }))
      local variable = debug.state({}, {}).scopes[1].variables[1]
      assert.are.equal(debug.VALUE_CHARS + #"…", #variable.value)
      assert.is_true(variable.cut)
    end)

    it("says the program is running when nothing is stopped", function()
      local session = fake_session(file(), LOCALS)
      session.stopped_thread_id = nil
      with_session(session)
      local reply = debug.state({}, {})
      assert.is_true(reply.running)
      assert.is_nil(reply.location)
    end)

    it("is not ready while waiting for the next stop, and ready once it comes", function()
      local session = fake_session(file(), LOCALS)
      session.stopped_thread_id = nil
      with_session(session)
      local after = debug.stops
      assert.is_true(debug.state({ after = after }, {}).not_ready)
      session.stopped_thread_id = 1
      dap.listeners.after.event_stopped["nvim-mcp"](session, { reason = "step", threadId = 1 })
      local reply = debug.state({ after = after }, {})
      assert.is_nil(reply.not_ready)
      assert.are.equal("step", reply.stopped.reason)
    end)

    it("waits on request for a running program's next stop", function()
      local session = fake_session(file(), LOCALS)
      session.stopped_thread_id = nil
      with_session(session)
      assert.is_true(debug.state({ wait = true }, {}).not_ready)
      session.stopped_thread_id = 1
      assert.is_nil(debug.state({ wait = true }, {}).not_ready, "already stopped: nothing to wait for")
    end)

    it("waits on request for a session that has not started yet", function()
      -- Debugging a test builds it first: run_tests answers at once, and the
      -- session turns up seconds later.
      with_session(nil)
      assert.is_true(debug.state({ wait = true }, {}).not_ready)
    end)

    it("says a session ended even when the adapter gave no exit code", function()
      -- js-debug ends a Node session with no exitCode; an empty table would
      -- encode as [] rather than an object.
      local session = fake_session(file(), LOCALS)
      with_session(session)
      dap.listeners.after.event_terminated["nvim-mcp"](session, {})
      with_session(nil)
      local encoded = vim.json.encode(debug.state({}, {}).ended)
      assert.are.equal('{"exit_code":null}', encoded)
    end)

    it("waits for a session that is still starting", function()
      with_session(nil)
      local after = debug.stops
      assert.are.same({ not_ready = true, status = "starting" }, debug.state({ after = after }, {}))
    end)

    it("stops waiting when the program ends, and says how", function()
      local session = fake_session(file(), LOCALS)
      session.stopped_thread_id = nil
      with_session(session)
      local after = debug.stops
      dap.listeners.after.event_exited["nvim-mcp"](session, { exitCode = 101 })
      with_session(nil)
      local reply = debug.state({ after = after }, {})
      assert.is_false(reply.session)
      assert.are.same({ exit_code = 101 }, reply.ended)
    end)

    it("includes the dap-ui watches, evaluated in the current frame", function()
      local path = file()
      with_session(fake_session(path, LOCALS))
      package.loaded["dapui"] = {
        elements = {
          watches = {
            get = function() return { { expression = "total * 2" }, { expression = "nope" } } end,
          },
        },
      }
      local reply = debug.state({}, {})
      package.loaded["dapui"] = nil
      assert.are.same({ expression = "total * 2", value = "6", type = "i32" }, reply.watches[1])
      assert.are.equal("nope", reply.watches[2].expression)
      assert.is_truthy(reply.watches[2].error)
    end)
  end)

  describe("inspect", function()
    it("evaluates an expression in the current frame, expanding one level", function()
      local session, requests = fake_session(file(), LOCALS)
      with_session(session)
      local reply = debug.inspect({ expression = "names" }, {})
      assert.are.equal("size=2", reply.value)
      assert.are.same({ '"ann"', '"bob"' }, vim.tbl_map(function(v) return v.value end, reply.children))
      local evaluate = vim.iter(requests):find(function(r) return r.command == "evaluate" end)
      assert.are.equal(11, evaluate.arguments.frameId)
    end)

    it("expands a variable by its ref", function()
      with_session(fake_session(file(), LOCALS))
      local reply = debug.inspect({ ref = 101 }, {})
      assert.are.equal(2, #reply.children)
    end)

    it("reads another frame's locals by its index in the stack", function()
      local session, requests = fake_session(file(), LOCALS)
      with_session(session)
      debug.inspect({ frame = 2 }, {})
      local scopes = vim.iter(requests):find(function(r) return r.command == "scopes" end)
      assert.are.equal(12, scopes.arguments.frameId)
    end)

    it("needs a stopped program", function()
      local session = fake_session(file(), LOCALS)
      session.stopped_thread_id = nil
      with_session(session)
      assert.has_error(function() debug.inspect({ expression = "x" }, {}) end)
    end)
  end)

  describe("controls", function()
    it("steps, then has the bridge wait for the next stop", function()
      local stepped = false
      with_session(fake_session(file(), LOCALS))
      dap.step_over = function() stepped = true end
      local reply = debug.control "step_over"({}, {})
      assert.is_true(stepped)
      assert.are.same({ action = "state", args = { after = debug.stops } }, reply.poll)
    end)

    it("refuses without a session rather than open a picker", function()
      with_session(nil)
      dap.continue = function() error "would open the configuration picker" end
      assert.has_error(function() debug.control "continue"({}, {}) end)
    end)
  end)

  describe("sessions", function()
    it("starts a configuration by name and waits for the first stop", function()
      with_session(nil)
      local started
      dap.run = function(config) started = config end
      dap.configurations.rust = { { name = "Debug demo", type = "codelldb", request = "launch" } }
      local reply = debug.start({ name = "Debug demo" }, {})
      dap.configurations.rust = nil
      assert.are.equal("Debug demo", started.name)
      assert.are.equal("state", reply.poll.action)
    end)

    it("refuses a configuration that would ask the human for input", function()
      with_session(nil)
      dap.run = function() error "would prompt in the human's editor" end
      dap.configurations.rust = {
        {
          name = "LLDB: Launch",
          type = "codelldb",
          program = function() return vim.fn.input "Path: " end,
        },
      }
      local listed = debug.state({}, {})
      local ok, err = pcall(debug.start, { name = "LLDB: Launch" }, {})
      dap.configurations.rust = nil
      assert.are.same({ rust = { "LLDB: Launch" } }, listed.computed)
      assert.is_nil(listed.configurations.rust)
      assert.is_false(ok)
      assert.matches("asks", err.message)
    end)

    it("starts one whose functions only compute, resolved, without prompting", function()
      -- nvim-dap-python finds the virtualenv with a function; that is not a prompt.
      with_session(nil)
      local started
      dap.run = function(config) started = config end
      dap.configurations.python = {
        {
          name = "file",
          type = "python",
          program = "${file}",
          pythonPath = function() return "C:/venv/python.exe" end,
        },
      }
      local listed = debug.state({}, {})
      debug.start({ name = "file", file = "C:/src/app/main.py" }, {})
      dap.configurations.python = nil
      assert.are.same({ "file" }, listed.computed.python)
      assert.are.equal("C:/venv/python.exe", started.pythonPath)
      assert.are.equal("C:/src/app/main.py", started.program)
    end)

    it("fills the file variables from the file it is given", function()
      with_session(nil)
      local started
      dap.run = function(config) started = config end
      dap.configurations.javascript = {
        {
          name = "Launch",
          type = "pwa-node",
          program = "${file}",
          cwd = "${fileDirname}",
          args = { "${fileBasename}" },
        },
      }
      debug.start({ name = "Launch", file = "C:/src/app/index.js" }, {})
      dap.configurations.javascript = nil
      assert.are.same(
        { "C:/src/app/index.js", "C:/src/app", { "index.js" } },
        { started.program, started.cwd, started.args }
      )
    end)

    it("fills workspaceFolder from the project tab the file is in", function()
      with_session(nil)
      local started
      dap.run = function(config) started = config end
      local project = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(project .. "/src", "p")
      vim.fn.writefile({ "x" }, project .. "/src/main.py")
      require("nvim-mcp.actions").project({ path = project }, {})
      dap.configurations.python = { { name = "file", program = "${file}", cwd = "${workspaceFolder}" } }
      debug.start({ name = "file", file = project .. "/src/main.py" }, {})
      dap.configurations.python = nil
      vim.cmd "tablast | tabclose!"
      assert.are.equal(project:lower(), vim.fs.normalize(started.cwd):lower())
    end)

    it("takes the file in the human's window when none is given", function()
      with_session(nil)
      local started
      dap.run = function(config) started = config end
      local path = file()
      vim.cmd.edit(path)
      dap.configurations.python = { { name = "file", program = "${file}" } }
      debug.start({ name = "file" }, {})
      dap.configurations.python = nil
      assert.are.equal(vim.fs.normalize(path):lower(), vim.fs.normalize(started.program):lower())
    end)

    it("treats a picker as a prompt too, and leaves input() working afterwards", function()
      with_session(nil)
      dap.configurations.python = {
        {
          name = "attach",
          processId = function()
            vim.ui.select({ 1, 2 }, {}, function() end)
          end,
        },
      }
      local ok, err = pcall(debug.start, { name = "attach" }, {})
      dap.configurations.python = nil
      assert.is_false(ok)
      assert.matches("asks", err.message)
      assert.are_not.equal(nil, vim.fn.input)
      assert.is_true(pcall(vim.fn.exists, "*input"))
    end)

    it("lists configurations without running any of their code", function()
      with_session(nil)
      local ran = false
      dap.configurations.cs = { { name = "picky", port = function() ran = true end } }
      local listed = debug.state({}, {})
      dap.configurations.cs = nil
      assert.is_false(ran)
      assert.are.same({ cs = { "picky" } }, listed.computed)
    end)

    it("refuses one that schedules work, returns a coroutine or aborts, without running the work", function()
      with_session(nil)
      dap.run = function() error "must not start" end
      local scheduled = false
      dap.configurations.cs = {
        {
          name = "schedules",
          type = "coreclr",
          port = function()
            vim.schedule(function() scheduled = true end)
          end,
        },
        {
          name = "coroutine",
          type = "coreclr",
          program = function()
            return coroutine.create(function() end)
          end,
        },
        { name = "aborts", type = "coreclr", port = function() return dap.ABORT end },
      }
      for _, name in ipairs { "schedules", "coroutine", "aborts" } do
        local ok, err = pcall(debug.start, { name = name }, {})
        assert.is_false(ok, name)
        assert.matches("asks", err.message)
      end
      dap.configurations.cs = nil
      vim.wait(100)
      assert.is_false(scheduled, "the scheduled work ran")
    end)

    it("starts a configuration given in full", function()
      with_session(nil)
      local started
      dap.run = function(config) started = config end
      dap.adapters.coreclr = dap.adapters.coreclr or { type = "executable", command = "netcoredbg" }
      debug.start({ config = { type = "coreclr", program = "C:/src/app/bin/app.dll", cwd = "C:/src/app" } }, {})
      assert.are.same(
        { "coreclr", "launch", "C:/src/app/bin/app.dll" },
        { started.type, started.request, started.program }
      )
      assert.has_error(function() debug.start({ config = { type = "nope" } }, {}) end)
    end)

    it("names the configurations there are when the name matches none", function()
      dap.configurations.rust = { { name = "Debug demo" } }
      local ok, err = pcall(debug.start, { name = "nope" }, {})
      dap.configurations.rust = nil
      assert.is_false(ok)
      assert.matches("Debug demo", err.message)
    end)

    it("stops the session", function()
      local terminated = false
      with_session(fake_session(file(), LOCALS))
      dap.terminate = function() terminated = true end
      debug.stop({}, {})
      assert.is_true(terminated)
    end)
  end)

  describe("breakpoints", function()
    it("sets one at a line, with a condition, sends it to the session, and marks it Claude's", function()
      local path = file()
      local session = fake_session(path, LOCALS)
      with_session(session)
      local reply = debug.breakpoint({ path = path, line = 3, condition = "total == 3" }, {})
      local set = reply.breakpoints[1]
      assert.are.same(
        { vim.fs.normalize(path), 3, "total == 3", true },
        { set.file, set.line, set.condition, set.by_claude }
      )
      local buffer = vim.fn.bufnr(path)
      assert.are.equal(3, session.sent[buffer][1].line)
    end)

    it("clears one, and leaves the human's alone", function()
      local path = file()
      with_session(nil)
      local buffer = vim.fn.bufadd(path)
      vim.fn.bufload(buffer)
      breakpoints.set({}, buffer, 1)
      debug.breakpoint({ path = path, line = 3 }, {})
      local reply = debug.breakpoint({ path = path, line = 3, clear = true }, {})
      assert.are.equal(1, #reply.breakpoints)
      assert.are.equal(1, reply.breakpoints[1].line)
      assert.is_nil(reply.breakpoints[1].by_claude)
    end)
  end)
end)
