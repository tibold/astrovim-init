local lsp = require "nvim-mcp.lsp"
local position = require "nvim-mcp.lsp.position"
local fake = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/fake_lsp.lua")

local LINES = { "function outer()", "  inner()", "end", "function inner() end" }

local function server(handlers)
  local path, dir = fake.file(LINES)
  local buffer = position.buffer(path)
  local uri = vim.uri_from_fname(path)
  fake.start(buffer, dir, {
    capabilities = { documentSymbolProvider = true, workspaceSymbolProvider = true, callHierarchyProvider = true },
    handlers = handlers(uri),
  })
  return path
end

local function item(uri, name, line)
  return { name = name, kind = 12, uri = uri, range = fake.range(line, 0, 3), selectionRange = fake.range(line, 9, 14) }
end

describe("symbols", function()
  after_each(fake.stop_all)

  it("outlines a file, nested symbols included", function()
    local path = server(function()
      return {
        ["textDocument/documentSymbol"] = function()
          return {
            {
              name = "outer", kind = 12, range = fake.range(0, 0, 16), selectionRange = fake.range(0, 9, 14),
              children = { { name = "local", kind = 13, range = fake.range(1, 2, 7), selectionRange = fake.range(1, 2, 7) } },
            },
            { name = "inner", kind = 12, range = fake.range(3, 0, 20), selectionRange = fake.range(3, 9, 14) },
          }
        end,
      }
    end)
    local reply = lsp.symbols({ path = path }, {})
    assert.are.equal(3, reply.count)
    assert.matches("outer", reply.symbols[1].name)
    assert.are.equal(1, reply.symbols[1].line)
    assert.are.equal(vim.fs.normalize(path), reply.symbols[1].file)
  end)

  it("searches the workspace by query", function()
    local path = server(function(uri)
      return {
        ["workspace/symbol"] = function(params)
          assert(params.query == "inn")
          return { { name = "inner", kind = 12, location = { uri = uri, range = fake.range(3, 9, 14) } } }
        end,
      }
    end)
    local reply = lsp.symbols({ query = "inn" }, {})
    assert.are.equal(1, reply.count)
    assert.are.equal(4, reply.symbols[1].line)
    assert.are.equal(vim.fs.normalize(path), reply.symbols[1].file)
  end)

  it("needs a path or a query", function()
    assert.has_error(function() lsp.symbols({}, {}) end)
  end)
end)

describe("calls", function()
  after_each(fake.stop_all)

  it("lists incoming calls one level deep", function()
    local path = server(function(uri)
      return {
        ["textDocument/prepareCallHierarchy"] = function() return { item(uri, "inner", 3) } end,
        ["callHierarchy/incomingCalls"] = function(params)
          assert(params.item.name == "inner")
          return { { from = item(uri, "outer", 0), fromRanges = { fake.range(1, 2, 7) } } }
        end,
      }
    end)
    local reply = lsp.calls { path = path, line = 4, symbol = "inner" }
    assert.are.equal("incoming", reply.direction)
    assert.are.same({ name = "outer", file = vim.fs.normalize(path), line = 1, sites = 1 }, reply.calls[1])
  end)

  it("lists outgoing calls", function()
    local path = server(function(uri)
      return {
        ["textDocument/prepareCallHierarchy"] = function() return { item(uri, "outer", 0) } end,
        ["callHierarchy/outgoingCalls"] = function() return { { to = item(uri, "inner", 3), fromRanges = {} } } end,
      }
    end)
    local reply = lsp.calls { path = path, line = 1, symbol = "outer", direction = "outgoing" }
    assert.are.equal("inner", reply.calls[1].name)
    assert.are.equal(4, reply.calls[1].line)
  end)

  it("answers empty when there is nothing to prepare", function()
    local path = server(function() return {} end)
    local reply = lsp.calls { path = path, line = 1, symbol = "outer" }
    assert.are.equal(0, reply.count)
  end)

  it("refuses an unknown direction", function()
    assert.has_error(function() lsp.calls { path = "x", line = 1, symbol = "x", direction = "sideways" } end)
  end)
end)
