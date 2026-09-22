local config = require "checklist.config"
local persist = require "checklist.persist"
local state = require "checklist.state"

local real_path = persist.path

local function read_saved()
  local fd = assert(io.open(persist.path(), "rb"))
  local saved = vim.json.decode(fd:read "*a")
  fd:close()
  return saved
end

local function write_saved(saved)
  local fd = assert(io.open(persist.path(), "wb"))
  fd:write(vim.json.encode(saved))
  fd:close()
end

describe("persist", function()
  local tmp

  before_each(function()
    state.reset()
    persist.restored = false
    -- Never touch the real session state file from a test.
    tmp = vim.fn.tempname() .. ".json"
    persist.path = function() return tmp end
  end)

  after_each(function()
    os.remove(tmp)
    persist.path = real_path
  end)

  it("derives a path under stdpath('state') keyed on the repo", function()
    persist.path = real_path
    -- joinpath emits forward slashes, stdpath returns backslashes on Windows.
    local path = vim.fs.normalize(persist.path())
    assert.is_true(path:find(vim.fs.normalize(vim.fn.stdpath "state"), 1, true) == 1)
    assert.is_true(path:match "/checklist/[0-9a-f]+%.json$" ~= nil)
    persist.path = function() return tmp end
  end)

  it("round-trips items and order exactly (criterion 27)", function()
    state.apply_payload {
      ops = {
        { op = "set", id = "a", text = "A", group = "G", state = "done" },
        { op = "set", id = "b", text = "B", note = "n" },
      },
    }
    local items, order = vim.deepcopy(state.items), vim.deepcopy(state.order)

    assert.is_true(persist.save())
    state.reset()
    persist.restored = false
    assert.is_true(persist.restore())

    assert.are.same(items, state.items)
    assert.are.same(order, state.order)
  end)

  it("discards a file older than max_age (criterion 28)", function()
    state.apply_payload { ops = { { op = "set", id = "a", text = "A" } } }
    persist.save()

    local saved = read_saved()
    saved.ts = os.time() - (config.options.max_age + 60)
    write_saved(saved)

    state.reset()
    persist.restored = false
    assert.is_false(persist.restore())
    assert.are.same({}, state.order)
  end)

  it("keeps a stale file when max_age is 0", function()
    state.apply_payload { ops = { { op = "set", id = "a", text = "A" } } }
    persist.save()
    local saved = read_saved()
    saved.ts = 1
    write_saved(saved)

    local previous = config.options.max_age
    config.options.max_age = 0
    state.reset()
    persist.restored = false
    assert.is_true(persist.restore())
    assert.are.same({ "a" }, state.order)
    config.options.max_age = previous
  end)

  it("treats a corrupt file as no file, silently (criterion 29)", function()
    local fd = assert(io.open(persist.path(), "wb"))
    fd:write "{ not json at all"
    fd:close()

    assert.has_no.errors(function() persist.restore() end)
    assert.are.same({}, state.order)
    assert.are.same({}, state.items)
  end)

  it("discards a file whose schema version does not match", function()
    state.apply_payload { ops = { { op = "set", id = "a", text = "A" } } }
    persist.save()
    local saved = read_saved()
    saved.v = persist.VERSION + 1
    write_saved(saved)

    state.reset()
    persist.restored = false
    assert.is_false(persist.restore())
    assert.are.same({}, state.order)
  end)

  it("flushes a pending debounced save synchronously (criterion 30)", function()
    state.apply_payload { ops = { { op = "set", id = "a", text = "A" } } }
    persist.schedule_save()
    assert.is_nil(vim.uv.fs_stat(persist.path()), "debounce fired early")

    persist.flush()
    assert.is_not_nil(vim.uv.fs_stat(persist.path()), "flush did not write synchronously")

    state.reset()
    persist.restored = false
    persist.restore()
    assert.are.same({ "a" }, state.order)
  end)

  it("restores at most once", function()
    state.apply_payload { ops = { { op = "set", id = "a", text = "A" } } }
    persist.save()
    state.reset()
    persist.restored = false

    assert.is_true(persist.restore())
    state.reset()
    assert.is_false(persist.restore())
    assert.are.same({}, state.order)
  end)
end)
