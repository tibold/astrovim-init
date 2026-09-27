local path = require "nvim-mcp.path"
local actions = require "nvim-mcp.actions"
local position = require "nvim-mcp.lsp.position"

--- Claude spells paths with forward slashes; on Windows a buffer named that way
--- is a different string from the one Neovim and its plugins build.
local windows = vim.fn.has "win32" == 1

local function forward_file(name)
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  local file = dir .. "/" .. name
  vim.fn.writefile({ "x" }, file)
  return file, dir
end

local function native_name(buffer)
  local name = vim.api.nvim_buf_get_name(buffer)
  return not windows or not name:find("/", 1, true), name
end

describe("native paths", function()
  it("spells an absolute path the platform's way", function()
    local file = forward_file "a.txt"
    local native = path.native(file)
    assert.are.equal(vim.fs.normalize(file):lower(), vim.fs.normalize(native):lower())
    if windows then assert.is_nil(native:find("/", 1, true)) end
  end)

  it("names the buffers show opens natively", function()
    local file = forward_file "shown.txt"
    local reply = actions.show { path = file }
    assert.is_true(native_name(vim.fn.bufnr(reply.file)))
  end)

  it("names the buffers the language server actions load natively", function()
    local file = forward_file "loaded.txt"
    local ok, name = native_name(position.buffer(file))
    assert.is_true(ok, name)
  end)

  it("sets a project tab's directory and file natively", function()
    local file, dir = forward_file "main.txt"
    local reply = actions.project({ path = dir, file = "main.txt" }, {})
    assert.is_true(native_name(vim.fn.bufnr(reply.file)))
    if windows then assert.is_nil(vim.fn.getcwd(-1, reply.tab):find("/", 1, true)) end
    vim.cmd "tablast | tabclose!"
  end)

  it("names quickfix entries natively", function()
    local file = forward_file "fix.txt"
    require("nvim-mcp.quickfix").write({ title = "t", items = { { path = file, line = 1 } }, open = false }, {})
    local ok, name = native_name(vim.fn.getqflist()[1].bufnr)
    assert.is_true(ok, name)
  end)

  it("gives a language server time to attach to buffers show and project open", function()
    local ready = require "nvim-mcp.lsp.ready"
    local shown = forward_file "shown2.txt"
    local reply = actions.show { path = shown }
    assert.is_true(ready.recently_loaded(vim.fn.bufnr(reply.file)))
    local file, dir = forward_file "main2.txt"
    local project = actions.project({ path = dir, file = "main2.txt" }, {})
    assert.is_true(ready.recently_loaded(vim.fn.bufnr(project.file)))
    vim.cmd "tablast | tabclose!"
  end)
end)
