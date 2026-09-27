local position = require "nvim-mcp.lsp.position"
local fake = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/fake_lsp.lua")

local function loaded(lines)
  local path = fake.file(lines)
  return position.buffer(path), path
end

describe("position.buffer", function()
  it("loads a file without listing it", function()
    local buffer = loaded { "x" }
    assert.is_true(vim.api.nvim_buf_is_loaded(buffer))
    assert.is_false(vim.bo[buffer].buflisted)
  end)

  it("refuses a missing file and a missing path", function()
    assert.has_error(function() position.buffer "Z:/definitely/not/here.lua" end)
    assert.has_error(function() position.buffer(nil) end)
  end)

  it("reloads an unmodified buffer whose file changed on disk", function()
    -- Claude's Edit tool writes behind the editor's back; a lookup must not
    -- read the old text.
    local path = fake.file { "old" }
    local buffer = vim.fn.bufadd(path)
    vim.fn.bufload(buffer)
    vim.fn.writefile({ "new" }, path)
    vim.uv.fs_utime(path, os.time() + 10, os.time() + 10)
    assert.are.equal(buffer, position.buffer(path))
    assert.are.same({ "new" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
  end)

  it("leaves unsaved work alone when the file also changed on disk", function()
    local path = fake.file { "old" }
    local buffer = vim.fn.bufadd(path)
    vim.fn.bufload(buffer)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "mine" })
    vim.fn.writefile({ "new" }, path)
    vim.uv.fs_utime(path, os.time() + 10, os.time() + 10)
    position.buffer(path)
    assert.are.same({ "mine" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
    assert.is_true(vim.bo[buffer].modified)
  end)

  it("finds the open buffer however the path is spelled", function()
    local path = fake.file { "x" }
    local opened = vim.fn.bufadd(path)
    vim.fn.bufload(opened)
    local spelled = path:gsub("/", "\\")
    if vim.fn.has "win32" == 1 then spelled = spelled:upper() end
    assert.are.equal(opened, position.buffer(spelled))
  end)
end)

describe("position.byte_column", function()
  it("finds a symbol as a whole word", function()
    local buffer = loaded { "foo foobar foo_x" }
    assert.are.equal(5, position.byte_column(buffer, 1, "foobar"))
  end)

  it("does not match a symbol inside a longer word", function()
    local buffer = loaded { "foobar foo" }
    assert.are.equal(8, position.byte_column(buffer, 1, "foo"))
  end)

  it("matches symbols that start or end with punctuation", function()
    local buffer = loaded { "a -> b" }
    assert.are.equal(3, position.byte_column(buffer, 1, "->"))
  end)

  it("lists the words on the line when the symbol is missing", function()
    local buffer = loaded { "local value = other" }
    local ok, err = pcall(position.byte_column, buffer, 1, "missing")
    assert.is_false(ok)
    assert.are.equal(-32602, err.code)
    assert.matches("is not on line 1", err.message)
    assert.matches("local, value, other", err.message)
  end)

  it("asks for a column when the symbol is ambiguous, and honours one", function()
    local buffer = loaded { "foo(foo)" }
    local ok, err = pcall(position.byte_column, buffer, 1, "foo")
    assert.is_false(ok)
    assert.matches("appears 2 times", err.message)
    assert.are.equal(5, position.byte_column(buffer, 1, "foo", 6))
  end)

  it("takes a character column when no symbol is given", function()
    local buffer = loaded { "é = foo" }
    assert.are.equal(6, position.byte_column(buffer, 1, nil, 5))
  end)

  it("refuses a line past the end and a missing position", function()
    local buffer = loaded { "one" }
    assert.has_error(function() position.byte_column(buffer, 2, "one") end)
    assert.has_error(function() position.byte_column(buffer, 1) end)
  end)
end)

describe("position encodings", function()
  it("converts past wide characters for each encoding", function()
    local buffer = loaded { "é😀 = foo" }
    local byte = position.byte_column(buffer, 1, "foo")
    assert.are.equal(10, byte) -- é is 2 bytes, 😀 is 4
    assert.are.equal(9, position.params(buffer, 1, byte, "utf-8").position.character)
    assert.are.equal(6, position.params(buffer, 1, byte, "utf-16").position.character) -- 😀 is a surrogate pair
    assert.are.equal(5, position.params(buffer, 1, byte, "utf-32").position.character)
    assert.are.equal(0, position.params(buffer, 1, byte, "utf-16").position.line)
  end)

  it("round-trips byte and character columns", function()
    assert.are.equal(6, position.char_to_byte("é = foo", 5))
    assert.are.equal(5, position.byte_to_char("é = foo", 6))
  end)

  it("builds a whole-line range ending at the last line's length", function()
    local buffer = loaded { "first", "sé" }
    local range = position.line_range(buffer, 1, 2, "utf-16")
    assert.are.same({ line = 0, character = 0 }, range.start)
    assert.are.same({ line = 1, character = 2 }, range["end"])
    assert.has_error(function() position.line_range(buffer, 2, 1, "utf-16") end)
  end)
end)
