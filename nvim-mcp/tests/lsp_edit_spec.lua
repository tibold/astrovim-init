local edit = require "nvim-mcp.lsp.edit"
local position = require "nvim-mcp.lsp.position"
local fake = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/fake_lsp.lua")

local function rename_in(path, line0, from, to, text)
  return { [vim.uri_from_fname(path)] = { { range = fake.range(line0, from, to), newText = text } } }
end

local function open_listed(path)
  local buffer = vim.fn.bufadd(path)
  vim.fn.bufload(buffer)
  vim.bo[buffer].buflisted = true
  return buffer
end

describe("edit.files", function()
  it("collects files from changes and documentChanges", function()
    local a, b = fake.file { "a" }, fake.file { "b" }
    local files = edit.files {
      changes = rename_in(a, 0, 0, 1, "x"),
      documentChanges = { { textDocument = { uri = vim.uri_from_fname(b), version = vim.NIL }, edits = {} } },
    }
    files = vim.tbl_map(vim.fs.normalize, files)
    table.sort(files)
    local expected = { vim.fs.normalize(a), vim.fs.normalize(b) }
    table.sort(expected)
    assert.are.same(expected, files)
  end)
end)

describe("edit.apply", function()
  it("edits and saves a file that was not open, then unlists it", function()
    local path = fake.file { "local foo = 1" }
    local reply = edit.apply({ changes = rename_in(path, 0, 6, 9, "bar") }, "utf-16")
    assert.is_true(reply.applied)
    assert.are.same({ "local bar = 1" }, vim.fn.readfile(path))
    assert.are.equal(1, reply.changed[1].edits)
    local buffer = position.buffer_for(path)
    assert.is_false(vim.bo[buffer].buflisted)
    assert.is_false(vim.bo[buffer].modified)
  end)

  it("reports files normalised, however the server spelled the uri", function()
    -- marksman sends file:///c%3A/...: a lowercase, encoded drive, which
    -- uri_to_fname turns into c:\... on Windows.
    local path = fake.file { "abc" }
    local uri = vim.uri_from_fname(path):gsub("^file:///(%a):", function(drive) return "file:///" .. drive:lower() .. "%3A" end)
    local changes = { [uri] = { { range = fake.range(0, 0, 3), newText = "xyz" } } }
    local reply = edit.apply({ changes = changes }, "utf-16")
    assert.are.equal(vim.fs.normalize(vim.uri_to_fname(uri)), reply.changed[1].file)
    assert.is_nil(reply.changed[1].file:find("\\", 1, true))

    local buffer = open_listed(path)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "mine" })
    local refused = edit.apply({ changes = changes }, "utf-16")
    assert.is_nil(refused.files[1]:find("\\", 1, true))
  end)

  it("applies to what is on disk when the open buffer is stale, without prompting", function()
    local path = fake.file { "local foo = 1", "old" }
    open_listed(path)
    vim.fn.writefile({ "local foo = 1", "claude's line" }, path)
    vim.uv.fs_utime(path, os.time() + 10, os.time() + 10)
    local reply = edit.apply({ changes = rename_in(path, 0, 6, 9, "bar") }, "utf-16")
    assert.is_true(reply.applied)
    assert.is_nil(reply.failed)
    assert.are.same({ "local bar = 1", "claude's line" }, vim.fn.readfile(path))
  end)

  it("keeps an open buffer listed, saved, and undoable", function()
    local path = fake.file { "local foo = 1" }
    local buffer = open_listed(path)
    edit.apply({ changes = rename_in(path, 0, 6, 9, "bar") }, "utf-16")
    assert.is_true(vim.bo[buffer].buflisted)
    assert.is_false(vim.bo[buffer].modified)
    vim.api.nvim_buf_call(buffer, function() vim.cmd "silent undo" end)
    assert.are.same({ "local foo = 1" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
  end)

  it("refuses the whole edit when any touched buffer has unsaved work", function()
    local clean, dirty = fake.file { "one" }, fake.file { "two" }
    local buffer = open_listed(dirty)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "two, edited" })
    local reply = edit.apply(
      { changes = vim.tbl_extend("error", rename_in(clean, 0, 0, 3, "ONE"), rename_in(dirty, 0, 0, 3, "TWO")) },
      "utf-16"
    )
    assert.is_false(reply.applied)
    assert.are.equal("modified", reply.reason)
    assert.are.same({ vim.fs.normalize(dirty) }, vim.tbl_map(vim.fs.normalize, reply.files))
    assert.are.same({ "one" }, vim.fn.readfile(clean))
    assert.are.same({ "two, edited" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
  end)

  it("saves the rest and reports a file it cannot write", function()
    local writable, locked = fake.file { "one" }, fake.file { "two" }
    local buffer = open_listed(locked)
    vim.bo[buffer].readonly = true
    local reply = edit.apply(
      { changes = vim.tbl_extend("error", rename_in(writable, 0, 0, 3, "ONE"), rename_in(locked, 0, 0, 3, "TWO")) },
      "utf-16"
    )
    assert.is_true(reply.applied)
    assert.are.same({ "ONE" }, vim.fn.readfile(writable))
    assert.are.equal(1, #reply.failed)
    assert.are.equal(vim.fs.normalize(locked), vim.fs.normalize(reply.failed[1].file))
  end)
end)

describe("edit.capturing", function()
  it("routes applyEdit through apply while running, and restores the handler", function()
    local original = vim.lsp.handlers["workspace/applyEdit"]
    local path = fake.file { "abc" }
    local answer
    local _, results = edit.capturing("utf-16", function()
      answer = vim.lsp.handlers["workspace/applyEdit"](nil, { edit = { changes = rename_in(path, 0, 0, 3, "xyz") } }, { client_id = -1 })
    end)
    assert.are.same({ applied = true }, answer)
    assert.are.equal(1, #results)
    assert.are.same({ "xyz" }, vim.fn.readfile(path))
    assert.are.equal(original, vim.lsp.handlers["workspace/applyEdit"])
  end)

  it("answers applied = false with a reason for unsaved work", function()
    local path = fake.file { "abc" }
    local buffer = open_listed(path)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "mine" })
    local answer
    edit.capturing("utf-16", function()
      answer = vim.lsp.handlers["workspace/applyEdit"](nil, { edit = { changes = rename_in(path, 0, 0, 3, "xyz") } }, { client_id = -1 })
    end)
    assert.is_false(answer.applied)
    assert.matches("Unsaved changes", answer.failureReason)
  end)

  it("restores the handler when the work throws", function()
    local original = vim.lsp.handlers["workspace/applyEdit"]
    assert.has_error(function() edit.capturing("utf-16", function() error "boom" end) end)
    assert.are.equal(original, vim.lsp.handlers["workspace/applyEdit"])
  end)
end)

describe("edit.apply when applying fails partway", function()
  it("saves what landed and says the edit was partial", function()
    local first, second = fake.file { "one" }, fake.file { "two" }
    local locked = open_listed(second)
    vim.bo[locked].modifiable = false
    local reply = edit.apply({
      documentChanges = {
        { textDocument = { uri = vim.uri_from_fname(first), version = vim.NIL }, edits = { { range = fake.range(0, 0, 3), newText = "ONE" } } },
        { textDocument = { uri = vim.uri_from_fname(second), version = vim.NIL }, edits = { { range = fake.range(0, 0, 3), newText = "TWO" } } },
      },
    }, "utf-16")
    assert.are.equal("partial", reply.applied)
    assert.is_string(reply.error)
    assert.are.same({ "ONE" }, vim.fn.readfile(first))
    assert.are.same({ vim.fs.normalize(first) }, vim.tbl_map(function(c) return c.file end, reply.changed))
    local buffer = position.buffer_for(first)
    assert.is_false(vim.bo[buffer].modified)
  end)
end)

describe("edit.capturing when an edit lands partially", function()
  it("tells the server it was not applied, and why", function()
    local path = fake.file { "abc" }
    local buffer = open_listed(path)
    vim.bo[buffer].modifiable = false
    local answer
    edit.capturing("utf-16", function()
      answer = vim.lsp.handlers["workspace/applyEdit"](nil, { edit = { changes = rename_in(path, 0, 0, 3, "xyz") } }, { client_id = -1 })
    end)
    assert.is_false(answer.applied)
    assert.matches("modifiable", answer.failureReason)
  end)
end)
