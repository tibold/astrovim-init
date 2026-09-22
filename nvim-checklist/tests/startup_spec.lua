local config = require "checklist.config"
local persist = require "checklist.persist"
local render = require "checklist.render"
local state = require "checklist.state"
local window = require "checklist.window"
local checklist = require "checklist"

--- setup() fires open_restored from VimEnter, which has already passed inside
--- the test harness, so these drive the routine directly. The wiring itself is
--- verified against a real nvim startup.

describe("startup", function()
  local tmp

  before_each(function()
    state.reset()
    if window.is_open() then window.close() end
    tmp = vim.fn.tempname() .. ".json"
    persist.path = function() return tmp end
    persist.restored = false
    config.options.open_on_startup = true
  end)

  after_each(function()
    os.remove(tmp)
    if window.is_open() then window.close() end
    config.options.open_on_startup = true
  end)

  local function save_a_checklist()
    state.apply_payload { ops = { { op = "set", id = "a", text = "Left over from last session" } } }
    persist.save()
    state.reset()
    persist.restored = false
  end

  it("restores and opens a checklist left from the last session", function()
    save_a_checklist()
    checklist.setup {}
    checklist.open_restored()
    assert.are.same({ "a" }, state.order)
    assert.is_true(window.is_open())
  end)

  it("opens nothing when there is no saved checklist", function()
    checklist.setup {}
    checklist.open_restored()
    assert.are.same({}, state.order)
    assert.is_false(window.is_open())
  end)

  it("opens nothing when the saved checklist is empty", function()
    persist.save() -- state is empty
    persist.restored = false
    checklist.setup {}
    checklist.open_restored()
    assert.is_false(window.is_open())
  end)

  it("stays closed when open_on_startup is off", function()
    save_a_checklist()
    config.options.open_on_startup = false
    checklist.setup { open_on_startup = false }
    checklist.open_restored()
    assert.is_false(window.is_open())
  end)

  it("does not resurrect a cleared list via a later restore", function()
    save_a_checklist()
    checklist.setup {}
    checklist.clear() -- before anything has restored
    persist.flush()
    checklist.set("fresh", { text = "Fresh item" })
    assert.are.same({ "fresh" }, state.order)
  end)

  it("registers the user commands", function()
    checklist.setup {}
    local commands = vim.api.nvim_get_commands {}
    assert.is_truthy(commands.ChecklistToggle)
    assert.is_truthy(commands.ChecklistClear)
    assert.is_truthy(commands.ChecklistSweep)
  end)

  it("clearing leaves nothing for the next startup to restore", function()
    save_a_checklist()
    checklist.setup {}
    checklist.open_restored()
    assert.is_true(window.is_open())

    checklist.clear()
    persist.flush()
    assert.is_false(window.is_open())

    -- A fresh start reads the file back and finds it empty.
    state.reset()
    persist.restored = false
    persist.restore()
    assert.are.same({}, state.order)
  end)
end)
