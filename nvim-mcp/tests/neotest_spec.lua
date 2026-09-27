local tests = require "nvim-mcp.neotest"

local ADAPTER = "neotest-rust:C:/src/demo"

--- A stand-in for the client neotest hands a consumer: listeners to fill in,
--- and positions to look up by id.
local function fake_client(positions)
  return {
    listeners = {},
    get_position = function(_, id)
      local data = positions[id]
      return data and {
        data = function() return data end,
      } or nil
    end,
  }
end

local function position(id, name, kind, line)
  return {
    id = id,
    name = name,
    type = kind or "test",
    path = "C:/src/demo/src/lib.rs",
    range = { line or 0, 0, 0, 0 },
  }
end

local POSITIONS = {
  ["C:/src/demo/src/lib.rs"] = position("C:/src/demo/src/lib.rs", "lib.rs", "file"),
  ["tests::adds"] = position("tests::adds", "adds", "test", 9),
  ["tests::parses"] = position("tests::parses", "parses", "test", 19),
  ["tests::skipped"] = position("tests::skipped", "skipped", "test", 29),
}

local IDS = { "C:/src/demo/src/lib.rs", "tests::adds", "tests::parses", "tests::skipped" }

local function consumer()
  tests.reset()
  local client = fake_client(POSITIONS)
  tests.consumer(client)
  return client
end

describe("neotest results", function()
  it("says when neotest is not reporting here", function()
    tests.reset()
    local ok, err = pcall(tests.read, {}, {})
    assert.is_false(ok)
    assert.matches("consumer", err.message)
  end)

  it("says when nothing has run yet", function()
    consumer()
    assert.are.same({ ran = false }, tests.read({}, {}))
  end)

  it("reports a run in progress, and what has finished so far", function()
    local client = consumer()
    client.listeners.run(ADAPTER, "C:/src/demo/src/lib.rs", IDS)
    client.listeners.results(ADAPTER, { ["tests::adds"] = { status = "passed" } }, true)
    local reply = tests.read({}, {})
    assert.is_true(reply.running)
    assert.are.same({ passed = 1, failed = 0, skipped = 0, pending = 2 }, reply.counts)
  end)

  it("reports the counts and each failure with where and why", function()
    local client = consumer()
    client.listeners.run(ADAPTER, "C:/src/demo/src/lib.rs", IDS)
    client.listeners.results(ADAPTER, {
      ["C:/src/demo/src/lib.rs"] = { status = "failed" },
      ["tests::adds"] = { status = "passed" },
      ["tests::parses"] = {
        status = "failed",
        short = "\27[31mthread 'tests::parses' panicked at src/lib.rs:21:9:\27[0m\nassertion failed",
        output = "C:/tmp/neotest-output",
        errors = { { message = "assertion failed", line = 20 } },
      },
      ["tests::skipped"] = { status = "skipped" },
    }, false)
    local reply = tests.read({}, {})
    assert.is_false(reply.running)
    assert.are.equal("neotest-rust", reply.adapter)
    assert.are.same({ passed = 1, failed = 1, skipped = 1, pending = 0 }, reply.counts)
    assert.are.equal(1, #reply.failures)
    local failure = reply.failures[1]
    assert.are.same(
      { "tests::parses", "parses", "C:/src/demo/src/lib.rs", 20 },
      { failure.id, failure.name, failure.file, failure.line }
    )
    assert.are.same({ { message = "assertion failed", line = 21 } }, failure.errors)
    assert.are.equal("thread 'tests::parses' panicked at src/lib.rs:21:9:\nassertion failed", failure.output)
    assert.are.equal("C:/tmp/neotest-output", failure.output_file)
  end)

  it("keeps only the end of long output unless asked for all of it", function()
    local client = consumer()
    local lines = {}
    for i = 1, 100 do
      lines[i] = "line " .. i
    end
    client.listeners.run(ADAPTER, "tests::parses", { "tests::parses" })
    client.listeners.results(ADAPTER, { ["tests::parses"] = { status = "failed", short = table.concat(lines, "\n") } })
    local summary = tests.read({}, {}).failures[1]
    assert.is_true(summary.output_truncated)
    assert.are.equal(tests.OUTPUT_LINES, #vim.split(summary.output, "\n"))
    assert.matches("line 100$", summary.output)
    local full = tests.read({}, { detail = "full" }).failures[1]
    assert.are.equal(100, #vim.split(full.output, "\n"))
    assert.is_nil(full.output_truncated)
  end)

  it("lists only the first failures in a summary", function()
    local client = consumer()
    local ids, results = {}, {}
    for i = 1, 15 do
      local id = "tests::t" .. i
      POSITIONS[id] = position(id, "t" .. i, "test", i)
      ids[i], results[id] = id, { status = "failed" }
    end
    client.listeners.run(ADAPTER, "C:/src/demo/src/lib.rs", ids)
    client.listeners.results(ADAPTER, results)
    local reply = tests.read({}, {})
    assert.are.equal(15, reply.counts.failed)
    assert.are.equal(tests.SHOWN, #reply.failures)
    assert.is_true(reply.truncated)
    assert.are.equal(15, #tests.read({}, { detail = "full" }).failures)
  end)

  it("starts afresh with each run", function()
    local client = consumer()
    client.listeners.run(ADAPTER, "tests::parses", { "tests::parses" })
    client.listeners.results(ADAPTER, { ["tests::parses"] = { status = "failed" } })
    client.listeners.run(ADAPTER, "tests::adds", { "tests::adds" })
    client.listeners.results(ADAPTER, { ["tests::adds"] = { status = "passed" } })
    local reply = tests.read({}, {})
    assert.are.same({ passed = 1, failed = 0, skipped = 0, pending = 0 }, reply.counts)
    assert.are.same({}, reply.failures)
  end)
end)

describe("running tests", function()
  local ran

  --- neotest and nio as far as run_tests uses them: nio.run runs at once, and
  --- run.run records what it was asked for.
  local function fakes(client)
    ran = {}
    package.loaded["nio"] = {
      run = function(fn) fn() end,
    }
    package.loaded["neotest"] = {
      run = {
        run = function(args) ran[#ran + 1] = args end,
        run_last = function(args) ran[#ran + 1] = { last = true, strategy = args and args.strategy } end,
      },
    }
    -- Every file is discovered unless a test says otherwise.
    client.get_position = function(_, id)
      local data = POSITIONS[id]
      return { data = function() return data or { id = id, type = "file" } end }
    end
    client.get_nearest = function(_, file, row)
      if row == 19 then return {
        data = function() return POSITIONS["tests::parses"] end,
      } end
    end
  end

  after_each(function()
    package.loaded["nio"], package.loaded["neotest"] = nil, nil
  end)

  it("runs the test at a line, and has the bridge wait for its results", function()
    local client = consumer()
    fakes(client)
    local path = vim.fn.tempname()
    vim.fn.writefile({ "x" }, path)
    local reply = tests.run_tests({ path = path, line = 20 }, {})
    assert.are.equal("tests::parses", ran[1][1])
    assert.are.same({ action = "tests", args = { after = tests.runs } }, reply.poll)
  end)

  it("runs a file, an id, the suite, or the last run, and debugs on request", function()
    local client = consumer()
    fakes(client)
    local path = vim.fn.tempname()
    vim.fn.writefile({ "x" }, path)
    tests.run_tests({ path = path }, {})
    tests.run_tests({ id = "tests::adds", debug = true }, {})
    tests.run_tests({ suite = true }, {})
    client.listeners.run(ADAPTER, "tests::adds", { "tests::adds" })
    tests.run_tests({ last = true }, {})
    assert.are.equal(vim.fs.normalize(vim.uv.fs_realpath(path)):lower(), vim.fs.normalize(ran[1][1]):lower())
    assert.are.same({ "tests::adds", strategy = "dap" }, ran[2])
    -- a debug run answers at once: the debug tool is needed while it runs
    assert.is_nil(tests.run_tests({ id = "tests::adds", debug = true }, {}).poll)
    assert.is_true(ran[3].suite)
    assert.is_true(ran[4].last)
  end)

  it("says when there is no test at the line, instead of waiting for a run", function()
    local client = consumer()
    fakes(client)
    local path = vim.fn.tempname()
    vim.fn.writefile({ "x" }, path)
    local ok, err = pcall(tests.run_tests, { path = path, line = 2 }, {})
    assert.is_false(ok)
    assert.matches("no test", err.message)
    assert.are.same({}, ran)
  end)

  it("is not ready while neotest is still discovering the file", function()
    local client = consumer()
    fakes(client)
    client.get_position = function() return nil end
    local path = vim.fn.tempname()
    vim.fn.writefile({ "x" }, path)
    local reply = tests.run_tests({ path = path }, {})
    assert.is_true(reply.not_ready)
    assert.matches("discovering", reply.status)
    assert.are.same({}, ran)
    local ok, err = pcall(tests.run_tests, { path = path }, { final = true })
    assert.is_false(ok)
    assert.matches("no tests", err.message)
  end)

  it("says when there is no last run to repeat", function()
    fakes(consumer())
    assert.has_error(function() tests.run_tests({ last = true }, {}) end)
  end)

  it("waits for a run newer than the one it started after, then for it to finish", function()
    local client = consumer()
    local after = tests.runs
    assert.are.same({ not_ready = true, status = "starting" }, tests.read({ after = after }, {}))
    client.listeners.run(ADAPTER, "tests::adds", { "tests::adds" })
    assert.is_true(tests.read({ after = after }, {}).not_ready)
    client.listeners.results(ADAPTER, { ["tests::adds"] = { status = "passed" } })
    local reply = tests.read({ after = after }, {})
    assert.is_nil(reply.not_ready)
    assert.are.equal(1, reply.counts.passed)
  end)

  it("never passes off the previous run as the answer when no new one started", function()
    local client = consumer()
    client.listeners.run(ADAPTER, "tests::adds", { "tests::adds" })
    client.listeners.results(ADAPTER, { ["tests::adds"] = { status = "passed" } })
    local after = tests.runs
    local reply = tests.read({ after = after }, { final = true })
    assert.is_true(reply.not_ready)
    assert.matches("no run started", reply.status)
  end)

  it("needs a target", function()
    fakes(consumer())
    assert.has_error(function() tests.run_tests({}, {}) end)
  end)
end)
