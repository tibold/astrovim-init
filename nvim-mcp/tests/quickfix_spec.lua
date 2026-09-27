local quickfix = require "nvim-mcp.quickfix"

local function file(name, lines)
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/" .. name
  vim.fn.writefile(lines or { "one", "two", "three" }, path)
  return path, dir
end

local function reset()
  vim.fn.setqflist({}, "f")
  vim.cmd "silent! cclose"
end

describe("quickfix read", function()
  before_each(reset)

  it("returns the current list with its title and located entries", function()
    local path = file "a.rs"
    vim.fn.setqflist({}, " ", {
      title = ":make build",
      items = {
        { filename = path, lnum = 2, col = 5, type = "E", text = "mismatched types" },
        { filename = path, lnum = 3, col = 0, type = "W", text = "unused variable" },
      },
    })
    local reply = quickfix.read {}
    assert.are.equal(":make build", reply.title)
    assert.are.equal(2, reply.count)
    assert.are.same(
      { file = vim.fs.normalize(path), line = 2, column = 5, type = "error", text = "mismatched types" },
      reply.items[1]
    )
    assert.is_nil(reply.items[2].column, "col 0 means no column")
    assert.are.equal("warning", reply.items[2].type)
  end)

  it("folds the unlocated lines after an entry into its detail", function()
    -- rustc prints an error's notes on lines of their own, which :make turns
    -- into entries with no location. Alone they are noise; under their error
    -- they are the explanation.
    local path = file "a.rs"
    vim.fn.setqflist({}, " ", {
      title = ":make build",
      items = {
        { text = "   Compiling demo v0.1.0" },
        { filename = path, lnum = 2, col = 5, type = "E", text = "mismatched types" },
        { text = "  = note: expected `u32`, found `String`" },
        { text = "  = help: try `.len()`" },
      },
    })
    local reply = quickfix.read {}
    assert.are.equal(1, reply.count)
    assert.are.same({ "  = note: expected `u32`, found `String`", "  = help: try `.len()`" }, reply.items[1].detail)
    assert.are.same({ "   Compiling demo v0.1.0" }, reply.preamble)
  end)

  it("summarises a long list and gives it all when asked", function()
    local path = file "a.rs"
    local items = {}
    for i = 1, 30 do
      items[i] = { filename = path, lnum = 1, text = "hit " .. i, type = i % 2 == 0 and "W" or "E" }
    end
    vim.fn.setqflist({}, " ", { title = "grep", items = items })
    local summary = quickfix.read({}, { detail = "summary" })
    assert.are.equal(30, summary.count)
    assert.are.equal(quickfix.SHOWN, #summary.items)
    assert.is_true(summary.truncated)
    assert.are.same({ error = 15, warning = 15 }, summary.types)
    local full = quickfix.read({}, { detail = "full" })
    assert.are.equal(30, #full.items)
    assert.is_false(full.truncated)
  end)

  it("reads an older list by number, and says how many there are", function()
    local path = file "a.rs"
    vim.fn.setqflist({}, " ", { title = "first", items = { { filename = path, lnum = 1, text = "a" } } })
    vim.fn.setqflist({}, " ", { title = "second", items = { { filename = path, lnum = 2, text = "b" } } })
    local current = quickfix.read {}
    assert.are.equal("second", current.title)
    assert.are.equal(2, current.nr)
    assert.are.equal(2, current.lists)
    assert.are.equal("first", quickfix.read({ nr = 1 }).title)
  end)

  it("refuses a list number past the history", function()
    local path = file "a.rs"
    vim.fn.setqflist({}, " ", { title = "only", items = { { filename = path, lnum = 1, text = "a" } } })
    local ok, err = pcall(quickfix.read, { nr = 5 })
    assert.is_false(ok)
    assert.matches("no quickfix list 5", err.message)
  end)

  it("answers an empty list plainly", function()
    local reply = quickfix.read {}
    assert.are.equal(0, reply.count)
    assert.are.same({}, reply.items)
  end)
end)

describe("quickfix write", function()
  before_each(reset)

  it("adds a new titled list and keeps the human's one underneath", function()
    local path = file "a.rs"
    vim.fn.setqflist({}, " ", { title = ":make build", items = { { filename = path, lnum = 1, text = "theirs" } } })
    local reply = quickfix.write({
      title = "call sites of parse",
      items = { { path = path, line = 2, column = 3, text = "here" }, { path = path, line = 3 } },
      open = false,
    }, {})
    assert.are.equal("Claude: call sites of parse", reply.title)
    assert.are.equal(2, reply.count)
    assert.are.equal("Claude: call sites of parse", vim.fn.getqflist({ title = 1 }).title)
    local older = vim.fn.getqflist { nr = reply.nr - 1, title = 1 }
    assert.are.equal(":make build", older.title)
  end)

  it("resolves relative paths against the session's directory", function()
    local path, dir = file "b.rs"
    quickfix.write({ title = "t", items = { { path = "b.rs", line = 1 } }, open = false }, { cwd = dir })
    local item = vim.fn.getqflist()[1]
    assert.are.equal(vim.fs.normalize(path):lower(), vim.fs.normalize(vim.api.nvim_buf_get_name(item.bufnr)):lower())
  end)

  it("opens the list without taking the human's window", function()
    local path = file "a.rs"
    local entry = vim.api.nvim_get_current_win()
    local reply = quickfix.write({ title = "t", items = { { path = path, line = 1 } } }, {})
    assert.is_true(reply.opened)
    assert.are.equal(entry, vim.api.nvim_get_current_win())
    assert.are_not.equal(0, vim.fn.getqflist({ winid = 0 }).winid)
  end)

  it("refuses a list with nothing in it, or an entry without a line", function()
    local path = file "a.rs"
    assert.has_error(function() quickfix.write({ title = "t", items = {} }, {}) end)
    assert.has_error(function() quickfix.write({ title = "t", items = { { path = path } } }, {}) end)
    assert.has_error(function() quickfix.write({ items = { { path = path, line = 1 } } }, {}) end)
  end)
end)
