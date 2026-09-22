local state = require "checklist.state"
local render = require "checklist.render"
local window = require "checklist.window"

describe("window", function()
  before_each(function()
    state.reset()
    if window.is_open() then window.close() end
    state.apply_payload { ops = { { op = "set", id = "a", text = "A task" } } }
    render.render()
  end)

  after_each(function()
    if window.is_open() then window.close() end
  end)

  it("returns to the starting state after two toggles (criterion 18)", function()
    local before = #vim.api.nvim_tabpage_list_wins(0)
    window.toggle()
    assert.is_true(window.is_open())
    window.toggle()
    assert.is_false(window.is_open())
    assert.are.equal(before, #vim.api.nvim_tabpage_list_wins(0))
  end)

  it("never opens a second window for the same buffer (criterion 19)", function()
    window.toggle()
    window.open()
    window.open()
    local buf = render.ensure_buf()
    local showing = 0
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(win) == buf then showing = showing + 1 end
    end
    assert.are.equal(1, showing)
  end)

  it("leaves the cursor in the originating window (criterion 21)", function()
    local origin = vim.api.nvim_get_current_win()
    window.open()
    assert.are.equal(origin, vim.api.nvim_get_current_win())
  end)

  it("moves the cursor into the panel when focus_on_open is set", function()
    local config = require "checklist.config"
    config.options.focus_on_open = true
    window.open()
    assert.are.equal(render.ensure_buf(), vim.api.nvim_win_get_buf(0))
    config.options.focus_on_open = false
  end)

  it("toggles the item under the cursor between todo and done", function()
    window.open()
    vim.api.nvim_win_set_cursor(window.win, { 1, 0 })
    window.toggle_item_under_cursor()
    assert.are.equal("done", state.items.a.state)
    window.toggle_item_under_cursor()
    assert.are.equal("todo", state.items.a.state)
  end)

  it("drops the item under the cursor", function()
    window.open()
    vim.api.nvim_win_set_cursor(window.win, { 1, 0 })
    window.drop_item_under_cursor()
    assert.is_nil(state.items.a)
    assert.are.same({}, state.order)
  end)

  it("does nothing when the cursor is on a heading line", function()
    state.reset()
    state.apply_payload { ops = { { op = "set", id = "a", text = "A", group = "G" } } }
    render.render()
    window.open()
    vim.api.nvim_win_set_cursor(window.win, { 1, 0 }) -- the heading
    window.toggle_item_under_cursor()
    assert.are.equal("todo", state.items.a.state)
  end)

  it("reads a size of 1 or less as a fraction of the available space", function()
    assert.are.equal(24, window.resolve_size(0.3, 80, 5))
    assert.are.equal(15, window.resolve_size(0.5, 30, 5))
    assert.are.equal(40, window.resolve_size(1, 40, 5)) -- exactly 1 is still a fraction
  end)

  it("reads a size above 1 as an absolute count", function()
    assert.are.equal(15, window.resolve_size(15, 80, 5))
    assert.are.equal(50, window.resolve_size(50, 200, 20))
  end)

  it("never resolves below the minimum", function()
    assert.are.equal(5, window.resolve_size(0.01, 80, 5)) -- would be 0
    assert.are.equal(5, window.resolve_size(2, 80, 5))
  end)

  it("takes its height from the fraction when it splits below neo-tree", function()
    local config = require "checklist.config"
    -- Stand in for neo-tree: placement keys off the filetype, nothing more.
    vim.cmd "topleft vsplit"
    local fake = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "neo-tree"
    vim.api.nvim_win_set_buf(fake, buf)

    local previous = config.options.height
    config.options.height = 0.3
    window.open()

    assert.is_false(window.vertical)
    assert.are.equal(window.resolve_size(0.3, vim.o.lines, 5), vim.api.nvim_win_get_height(window.win))

    config.options.height = previous
    window.close()
    if vim.api.nvim_win_is_valid(fake) then vim.api.nvim_win_close(fake, true) end
  end)

  it("takes its width from config when no neo-tree is present", function()
    local config = require "checklist.config"
    local previous = config.options.width
    config.options.width = 40
    window.open()
    assert.is_true(window.vertical)
    assert.are.equal(40, vim.api.nvim_win_get_width(window.win))
    config.options.width = previous
  end)

  it("reapplies the configured size on resize", function()
    local config = require "checklist.config"
    local previous = config.options.width
    config.options.width = 40
    window.open()
    vim.api.nvim_win_set_width(window.win, 25)
    config.options.width = 38
    window.resize()
    assert.are.equal(38, vim.api.nvim_win_get_width(window.win))
    config.options.width = previous
  end)

  it("drops the panel once the last item is gone", function()
    window.open()
    assert.is_true(window.is_open())
    state.drop "a"
    window.after_mutation()
    assert.is_false(window.is_open())
  end)

  it("drops the panel when the checklist is cleared", function()
    window.open()
    assert.is_true(window.is_open())
    state.clear()
    window.after_mutation()
    assert.is_false(window.is_open())
    assert.are.same({}, state.order)
  end)

  it("yanks the checklist as markdown", function()
    state.reset()
    state.apply_payload {
      ops = {
        { op = "set", id = "a", text = "Done thing", state = "done" },
        { op = "set", id = "b", text = "Open thing", group = "G" },
      },
    }
    render.render()
    window.yank_markdown()
    local yanked = vim.fn.getreg "+"
    assert.is_true(yanked:find("- [x] Done thing", 1, true) ~= nil)
    assert.is_true(yanked:find("## G", 1, true) ~= nil)
    assert.is_true(yanked:find("- [ ] Open thing", 1, true) ~= nil)
  end)
end)
