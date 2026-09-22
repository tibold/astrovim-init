local config = require "checklist.config"
local persist = require "checklist.persist"
local state = require "checklist.state"
local window = require "checklist.window"
local checklist = require "checklist"

local function write(json)
  local path = vim.fn.tempname()
  local fd = assert(io.open(path, "wb"))
  fd:write(json)
  fd:close()
  return path
end

describe("load", function()
  local tmp_state

  before_each(function()
    state.reset()
    -- Keep the suite off the real session state file.
    tmp_state = vim.fn.tempname() .. ".json"
    persist.path = function() return tmp_state end
    persist.restored = true -- suppress restore; it has its own spec
  end)

  after_each(function()
    os.remove(tmp_state)
    if window.is_open() then window.close() end
    config.options.auto_open = true
  end)

  it("returns 1 and applies every op for valid JSON (criterion 1)", function()
    local path = write [[{"ops":[
      {"op":"set","id":"nodes","group":"RKE2","text":"Provision nodes","state":"done"},
      {"op":"set","id":"dns","group":"RKE2","text":"DNS cutover","state":"blocked","note":"vendor TTL"}
    ]}]]
    assert.are.equal(1, checklist.load(path))
    assert.are.same({ "nodes", "dns" }, state.order)
    assert.are.equal("vendor TTL", state.items.dns.note)
    os.remove(path)
  end)

  it("returns 0 and changes nothing for malformed JSON (criterion 2)", function()
    checklist.load(write [[{"ops":[{"op":"set","id":"keep","text":"Keep"}]}]])
    local items, order = vim.deepcopy(state.items), vim.deepcopy(state.order)

    assert.are.equal(0, checklist.load(write "{ this is not json"))
    assert.are.equal(0, checklist.load(write [[{"ops":"nope"}]]))
    assert.are.equal(0, checklist.load(write [[{"ops":[{"op":"bogus"}]}]]))
    assert.are.same(items, state.items)
    assert.are.same(order, state.order)
  end)

  it(
    "returns 0 for a missing file and does not throw",
    function() assert.are.equal(0, checklist.load "Z:/definitely/not/here.json") end
  )

  it("survives quotes, dollars and backticks intact (criterion 24)", function()
    local nasty = [[it's "quoted" $HOME `tick` \n backslash-n]]
    local path = write(vim.json.encode { ops = { { op = "set", id = "q", text = nasty } } })
    assert.are.equal(1, checklist.load(path))
    assert.are.equal(nasty, state.items.q.text)
    os.remove(path)
  end)

  -- A buffer line cannot hold a newline, so an item carrying one is collapsed
  -- to a single line rather than rejected or allowed to abort the render.
  it("collapses a real newline instead of failing the render (criterion 24)", function()
    local path = write(vim.json.encode { ops = { { op = "set", id = "q", text = "first\nsecond\ttabbed" } } })
    assert.are.equal(1, checklist.load(path))
    assert.are.equal("first second tabbed", state.items.q.text)
    local render = require "checklist.render"
    assert.are.equal(1, #vim.api.nvim_buf_get_lines(render.ensure_buf(), 0, -1, false))
    os.remove(path)
  end)

  it("never throws, whatever it is handed", function()
    assert.has_no.errors(function()
      checklist.load(nil)
      checklist.load(42)
      checklist.load ""
    end)
  end)

  it("surfaces the panel when an update arrives and it is closed", function()
    assert.is_false(window.is_open())
    checklist.load(write [[{"ops":[{"op":"set","id":"a","text":"Surfaced"}]}]])
    assert.is_true(window.is_open())
  end)

  it("does not take the cursor when it surfaces the panel", function()
    local origin = vim.api.nvim_get_current_win()
    checklist.load(write [[{"ops":[{"op":"set","id":"a","text":"Surfaced"}]}]])
    assert.is_true(window.is_open())
    assert.are.equal(origin, vim.api.nvim_get_current_win())
  end)

  it("opens no second window when an update arrives and it is already open", function()
    checklist.load(write [[{"ops":[{"op":"set","id":"a","text":"One"}]}]])
    local count = #vim.api.nvim_tabpage_list_wins(0)
    checklist.load(write [[{"ops":[{"op":"set","id":"b","text":"Two"}]}]])
    assert.are.equal(count, #vim.api.nvim_tabpage_list_wins(0))
  end)

  it("stays closed when auto_open is off", function()
    config.options.auto_open = false
    checklist.load(write [[{"ops":[{"op":"set","id":"a","text":"Quiet"}]}]])
    assert.is_false(window.is_open())
  end)

  it("does not surface an empty checklist", function()
    checklist.load(write [[{"ops":[{"op":"clear"}]}]])
    assert.is_false(window.is_open())
  end)

  it("reports a reason instead of 0 under NVIM_CHECKLIST_DEBUG", function()
    vim.env.NVIM_CHECKLIST_DEBUG = "1"
    local reason = checklist.load(write "{ nope")
    vim.env.NVIM_CHECKLIST_DEBUG = nil
    assert.are.equal("undecodable JSON", reason)
  end)
end)
