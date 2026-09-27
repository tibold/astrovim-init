--- The human's last test run, as neotest saw it.
---
--- neotest has no public way to read results, but it hands a client to every
--- consumer in its config. `consumer` is one: add it to neotest's `consumers`
--- and it records each run as it streams in. It does the lookups inside
--- neotest's own listeners, which run in its async context, so the `tests`
--- action only ever reads a plain snapshot and never calls into neotest.
local mcp = require "nvim-mcp"

local M = {}

--- Failures listed in a summary, and the lines of output kept for each.
M.SHOWN = 10
M.OUTPUT_LINES = 30

--- The client neotest gave the consumer; nil until neotest has set up.
M.client = nil
--- { adapter, started, tests = { [id] = { name, file, line } }, results = { [id] = snapshot } }
M.run = nil
--- Runs seen, so `tests { after = n }` can wait for one started after n.
M.runs = 0

function M.reset()
  M.client, M.run, M.runs = nil, nil, 0
end

--- Colour codes: adapters pass test output through as the terminal got it.
local function plain(text) return (text:gsub("\27%[[%d;]*[A-Za-z]", "")) end

local function describe_position(client, id, adapter)
  local ok, tree = pcall(client.get_position, client, id, { adapter = adapter })
  local data = ok and tree and tree:data()
  if not data then return nil end
  return {
    type = data.type,
    name = data.name,
    file = data.path and vim.fs.normalize(data.path),
    line = data.range and data.range[1] + 1,
  }
end

--- Register as a neotest consumer: `consumers = { nvim_mcp = <this> }`.
function M.consumer(client)
  M.client = client

  client.listeners.run = function(adapter_id, _, position_ids)
    local run = { adapter = adapter_id, started = os.time(), tests = {}, results = {} }
    for _, id in ipairs(position_ids or {}) do
      local position = describe_position(client, id, adapter_id)
      -- Files and namespaces carry results too, aggregated from their tests;
      -- counting them as well would count each failure twice.
      if position and position.type == "test" then run.tests[id] = position end
    end
    M.run = run
    M.runs = M.runs + 1
  end

  client.listeners.results = function(adapter_id, results)
    local run = M.run
    if not run or run.adapter ~= adapter_id then return end
    for id, result in pairs(results or {}) do
      if run.tests[id] then
        local errors = {}
        for _, err in ipairs(result.errors or {}) do
          errors[#errors + 1] = { message = err.message, line = err.line and err.line + 1 }
        end
        run.results[id] = {
          status = result.status,
          errors = errors,
          output = result.short and plain(result.short),
          output_file = result.output,
        }
      end
    end
  end

  return {}
end

--- A failure as the action reports it.
local function failure(id, test, result, full)
  local out = {
    id = id,
    name = test.name,
    file = test.file,
    line = test.line,
    errors = #result.errors > 0 and result.errors or nil,
    output_file = result.output_file,
  }
  local output = result.output and vim.trim(result.output)
  if output and output ~= "" then
    local lines = vim.split(output, "\n")
    if not full and #lines > M.OUTPUT_LINES then
      -- The end, not the start: a panic, an assertion and its values come last.
      output = table.concat(vim.list_slice(lines, #lines - M.OUTPUT_LINES + 1, #lines), "\n")
      out.output_truncated = true
    end
    out.output = output
  end
  return out
end

--- The last run: counts, and each failure with where and why. `after` waits
--- (as not_ready, which the bridge polls) for a run newer than that count to
--- start and finish.
function M.read(args, opts)
  args, opts = args or {}, opts or {}
  if not M.client then
    error {
      code = -32603,
      message = 'neotest is not reporting to nvim-mcp. Add require("nvim-mcp.neotest").consumer to its consumers, or neotest has not loaded yet.',
    }
  end
  local run = M.run
  local after = tonumber(args.after)
  if after and M.runs <= after then
    -- On the last attempt too: the run before is not an answer to this one.
    -- neotest found nothing to run, most often, and says so only in a
    -- notification the bridge cannot see.
    if opts.final then
      return {
        not_ready = true,
        status = "no run started: neotest found no tests there (is the file inside the project neotest knows?)",
      }
    end
    return { not_ready = true, status = "starting" }
  end
  if not run then return { ran = false } end

  local full = (opts and opts.detail) == "full"
  local counts = { passed = 0, failed = 0, skipped = 0, pending = 0 }
  local failures = {}
  local ids = vim.tbl_keys(run.tests)
  -- Stable, and in source order within a file.
  table.sort(ids, function(a, b)
    local x, y = run.tests[a], run.tests[b]
    if x.file ~= y.file then return (x.file or "") < (y.file or "") end
    return (x.line or 0) < (y.line or 0)
  end)
  for _, id in ipairs(ids) do
    local result = run.results[id]
    if not result then
      counts.pending = counts.pending + 1
    elseif counts[result.status] then
      counts[result.status] = counts[result.status] + 1
      if result.status == "failed" then failures[#failures + 1] = failure(id, run.tests[id], result, full) end
    end
  end

  if after and not opts.final and counts.pending > 0 then
    return { not_ready = true, status = ("running, %d to go"):format(counts.pending) }
  end

  return {
    adapter = run.adapter:match "^[^:]+" or run.adapter,
    started = os.date("%Y-%m-%d %H:%M:%S", run.started),
    running = counts.pending > 0,
    counts = counts,
    failures = full and failures or vim.list_slice(failures, 1, math.min(M.SHOWN, #failures)),
    truncated = not full and #failures > M.SHOWN,
  }
end

local function fail(message) error { code = -32603, message = message } end

--- Start a run in the human's neotest, and have the bridge wait for its
--- results: the file or directory at `path`, the test at `path` and `line`, a
--- test by `id` (as `tests` reports it), the whole `suite`, or the `last` run.
--- `debug` runs it under nvim-dap, where the debug tool takes over.
--- Whether neotest has discovered `id` yet, looked up in its async context.
local function discovered(id)
  local found
  require("nio").run(function() found = M.client:get_position(id) ~= nil end)
  vim.wait(2000, function() return found ~= nil end, 10)
  return found == true
end

function M.run_tests(args, opts)
  args, opts = args or {}, opts or {}
  if not M.client then
    pcall(require, "neotest") -- loading it is what registers the consumer
    if not M.client then fail "neotest is not reporting to nvim-mcp; see the tests action" end
  end
  local neotest = require "neotest"
  local strategy = args.debug and "dap" or nil
  -- Under the debugger the run stops at breakpoints, and Claude makes one call
  -- at a time: waiting here for results would hold off the debug tool it needs
  -- to move the run on. So a debug run answers at once.
  local reply = args.debug
      and { started = true, debug = true, next = "debug state with wait: true, then tests once it ends" }
    or { poll = { action = "tests", args = { after = M.runs } } }

  if args.last then
    if not M.run then fail "nothing has run yet, so there is no last run to repeat" end
    neotest.run.run_last { strategy = strategy }
    return reply
  end
  if args.suite then
    neotest.run.run { suite = true, strategy = strategy }
    return reply
  end

  local id = args.id
  if not id and type(args.path) == "string" and args.path ~= "" then
    local path = vim.uv.fs_realpath(args.path)
    if not path then fail("no such file or directory: " .. args.path) end
    -- neotest discovers a file's tests in the background, parsing it in a
    -- child process; right after the file opens there is nothing to run yet,
    -- and run.run would start nothing. Not ready, so the bridge asks again.
    if not discovered(path) then
      if opts.final then fail(("neotest found no tests in %s"):format(args.path)) end
      return { not_ready = true, status = ("neotest is still discovering tests in %s"):format(args.path) }
    end
    if args.line then
      -- Claude has no cursor for run.run to use, so find the nearest test
      -- itself. get_nearest is async; nio.run starts it in neotest's context,
      -- and with the state already built it finishes before this returns.
      local found
      require("nio").run(function()
        local tree = M.client:get_nearest(path, tonumber(args.line) - 1, {})
        local data = tree and tree:data()
        found = data and data.type == "test" and data.id or false
      end)
      vim.wait(2000, function() return found ~= nil end, 10)
      if not found then fail(("no test at %s:%s"):format(args.path, args.line)) end
      id = found
    else
      id = path
    end
  end
  if not id then fail "run_tests needs a path (and line), an id, suite or last" end
  neotest.run.run { id, strategy = strategy }
  return reply
end

function M.setup()
  mcp.register {
    name = "tests",
    description = "The human's last neotest run: counts, and each failure with file, line, errors and output.",
    inputSchema = {
      type = "object",
      properties = {
        after = { type = "integer", description = "Wait for a run later than this count (set by run_tests)." },
      },
    },
    handler = M.read,
  }
  mcp.register {
    name = "run_tests",
    description = "Run tests in the human's neotest (file, test at a line, id, suite or last) and wait for results.",
    inputSchema = {
      type = "object",
      properties = {
        path = { type = "string", description = "A test file or directory." },
        line = { type = "integer", minimum = 1, description = "With path: the test at this line." },
        id = { type = "string", description = "A test id, as tests reports it." },
        suite = { type = "boolean" },
        last = { type = "boolean", description = "Repeat the last run." },
        debug = { type = "boolean", description = "Run under the debugger; the debug tool takes over." },
      },
    },
    handler = M.run_tests,
  }
end

return M
