local lsp = require "nvim-mcp.lsp"
local mcp = require "nvim-mcp"
local notice = require "nvim-mcp.lsp.notice"
local position = require "nvim-mcp.lsp.position"
local fake = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/fake_lsp.lua")

local notified
local original_notify = vim.notify

local function setup_pair(handlers)
  local path, dir = fake.file { "local foo = 1", "print(foo)" }
  local other = dir .. "/b.txt"
  vim.fn.writefile({ "use(foo)" }, other)
  local buffer = position.buffer(path)
  vim.bo[buffer].buflisted = true
  fake.start(buffer, dir, {
    capabilities = { renameProvider = true, documentFormattingProvider = true, documentRangeFormattingProvider = true },
    handlers = handlers(vim.uri_from_fname(path), vim.uri_from_fname(other)),
  })
  return path, other, buffer
end

local function rename_edit(uri, other_uri, name)
  return {
    changes = {
      [uri] = {
        { range = fake.range(0, 6, 9), newText = name },
        { range = fake.range(1, 6, 9), newText = name },
      },
      [other_uri] = { { range = fake.range(0, 4, 7), newText = name } },
    },
  }
end

describe("rename", function()
  before_each(function()
    notified = {}
    vim.notify = function(message) notified[#notified + 1] = message end
  end)
  after_each(function()
    vim.notify = original_notify
    fake.stop_all()
  end)

  it("renames across files, saves them, and announces it", function()
    local shown_while_running
    local path, other = setup_pair(function(uri, other_uri)
      return {
        ["textDocument/rename"] = function(params)
          shown_while_running = notice.active ~= nil and notice.active.shown ~= nil
          return rename_edit(uri, other_uri, params.newName)
        end,
      }
    end)
    local reply = lsp.rename { path = path, line = 1, symbol = "foo", new_name = "bar" }
    assert.is_true(reply.applied)
    assert.are.equal("fake", reply.server)
    assert.are.same({ "local bar = 1", "print(bar)" }, vim.fn.readfile(path))
    assert.are.same({ "use(bar)" }, vim.fn.readfile(other))
    assert.are.equal(2, #reply.changed)
    assert.is_true(shown_while_running, "the notice must be up while the editor waits")
    assert.matches("Claude renamed foo → bar in 2 files", notified[1])
  end)

  it("refuses when a touched buffer has unsaved work, and touches nothing", function()
    local path, other, buffer = setup_pair(function(uri, other_uri)
      return { ["textDocument/rename"] = function(params) return rename_edit(uri, other_uri, params.newName) end }
    end)
    vim.api.nvim_buf_set_lines(buffer, 1, 2, false, { "print(foo) -- mine" })
    local reply = lsp.rename { path = path, line = 1, symbol = "foo", new_name = "bar" }
    assert.is_false(reply.applied)
    assert.are.equal("modified", reply.reason)
    assert.are.same({ "use(foo)" }, vim.fn.readfile(other))
    assert.are.same({}, notified)
  end)

  it("says so when the server has no edit", function()
    local path = setup_pair(function() return {} end)
    local reply = lsp.rename { path = path, line = 1, symbol = "foo", new_name = "bar" }
    assert.is_false(reply.applied)
    assert.are.equal("no edit", reply.reason)
  end)

  it("reports a timeout", function()
    local path = setup_pair(function() return { ["textDocument/rename"] = function() return fake.NEVER end } end)
    local reply = lsp.rename { path = path, line = 1, symbol = "foo", new_name = "bar", timeout = 0.2 }
    assert.is_false(reply.applied)
    assert.is_true(reply.timed_out)
  end)

  it("needs a new name", function()
    assert.has_error(function() lsp.rename { path = "x", line = 1, symbol = "foo" } end)
  end)
end)

describe("format", function()
  before_each(function()
    notified = {}
    vim.notify = function(message) notified[#notified + 1] = message end
  end)
  after_each(function()
    vim.notify = original_notify
    fake.stop_all()
  end)

  it("formats the file and saves it", function()
    local path = setup_pair(function()
      return {
        ["textDocument/formatting"] = function(params)
          assert(params.options.tabSize)
          return { { range = fake.range(0, 5, 6), newText = "  " } }
        end,
      }
    end)
    local reply = lsp.format { path = path }
    assert.is_true(reply.applied)
    assert.are.same({ "local  foo = 1", "print(foo)" }, vim.fn.readfile(path))
    assert.matches("Claude formatted", notified[1])
  end)

  it("formats a range when given lines", function()
    local seen
    local path = setup_pair(function()
      return {
        ["textDocument/rangeFormatting"] = function(params)
          seen = params.range
          return {}
        end,
      }
    end)
    local reply = lsp.format { path = path, line = 2, end_line = 2 }
    assert.are.same({ line = 1, character = 0 }, seen.start)
    assert.is_true(reply.applied)
    assert.are.equal("Already formatted.", reply.note)
  end)
end)

describe("rename registration", function()
  it("advertises rename and hides format", function()
    mcp.tools, mcp.order = {}, {}
    lsp.setup()
    local listed = vim.tbl_map(function(t) return t.name end, mcp.listed())
    assert.is_true(vim.tbl_contains(listed, "rename"))
    assert.is_false(vim.tbl_contains(listed, "format"))
    assert.is_truthy(mcp.tools.format)
  end)
end)
