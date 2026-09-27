local lsp = require "nvim-mcp.lsp"
local mcp = require "nvim-mcp"
local position = require "nvim-mcp.lsp.position"
local fake = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/fake_lsp.lua")

local LINES = { "local foo = 1", "print(foo)", "print(foo + foo)" }

local function server(handlers)
  local path, dir = fake.file(LINES)
  local buffer = position.buffer(path)
  local uri = vim.uri_from_fname(path)
  local _, requests = fake.start(buffer, dir, {
    capabilities = {
      definitionProvider = true,
      referencesProvider = true,
      hoverProvider = true,
      implementationProvider = true,
    },
    handlers = handlers(uri),
  })
  return path, requests
end

describe("navigation", function()
  after_each(fake.stop_all)

  it("finds a definition from the symbol on a line", function()
    local path, requests = server(function(uri)
      return { ["textDocument/definition"] = function() return { uri = uri, range = fake.range(0, 6, 9) } end }
    end)
    local reply = lsp.definition({ path = path, line = 2, symbol = "foo" }, {})
    assert.are.equal("fake", reply.server)
    assert.are.equal(1, reply.count)
    assert.are.same({ file = vim.fs.normalize(path), line = 1, column = 7, text = "local foo = 1" }, reply.locations[1])
    local sent = requests[#requests].params.position
    assert.are.same({ line = 1, character = 6 }, sent)
  end)

  it("accepts a LocationLink answer", function()
    local path = server(function(uri)
      return {
        ["textDocument/definition"] = function()
          return { { targetUri = uri, targetRange = fake.range(0, 0, 13), targetSelectionRange = fake.range(0, 6, 9) } }
        end,
      }
    end)
    local reply = lsp.definition({ path = path, line = 2, symbol = "foo" }, {})
    assert.are.equal(1, reply.locations[1].line)
  end)

  it("summarises references, grouped by file, and asks for the declaration", function()
    local original = lsp.SHOWN
    lsp.SHOWN = 2
    local path, requests = server(function(uri)
      return {
        ["textDocument/references"] = function()
          return {
            { uri = uri, range = fake.range(0, 6, 9) },
            { uri = uri, range = fake.range(1, 6, 9) },
            { uri = uri, range = fake.range(2, 6, 9) },
          }
        end,
      }
    end)
    local reply = lsp.references({ path = path, line = 1, symbol = "foo" }, {})
    lsp.SHOWN = original
    assert.are.equal(3, reply.count)
    assert.are.equal(2, #reply.locations)
    assert.is_true(reply.truncated)
    assert.are.same({ { file = vim.fs.normalize(path), count = 3 } }, reply.by_file)
    assert.is_true(requests[#requests].params.context.includeDeclaration)

    local full = lsp.references({ path = path, line = 1, symbol = "foo" }, { detail = "full" })
    assert.are.equal(3, #full.locations)
    assert.is_nil(full.truncated)
  end)

  it("reads hover contents as markdown", function()
    local path = server(function()
      return {
        ["textDocument/hover"] = function() return { contents = { kind = "markdown", value = "**foo** `number`" } } end,
      }
    end)
    local reply = lsp.hover { path = path, line = 1, symbol = "foo" }
    assert.are.equal("**foo** `number`", reply.text)
  end)

  it("answers an empty list, with the server, when nothing is found", function()
    local path = server(function() return {} end)
    local reply = lsp.implementation({ path = path, line = 1, symbol = "foo" }, {})
    assert.are.equal(0, reply.count)
    assert.are.equal("fake", reply.server)
  end)

  it("reports a timeout", function()
    local path = server(function()
      return { ["textDocument/definition"] = function() return fake.NEVER end }
    end)
    local reply = lsp.definition({ path = path, line = 2, symbol = "foo", timeout = 0.2 }, {})
    assert.is_true(reply.timed_out)
    assert.are.equal(0, reply.count)
  end)

  it("works end to end through the registry, as JSON", function()
    mcp.tools, mcp.order = {}, {}
    lsp.setup()
    local path = server(function(uri)
      return { ["textDocument/definition"] = function() return { uri = uri, range = fake.range(0, 6, 9) } end }
    end)
    -- The fake server reports no progress; readiness is lsp_ready_spec's concern.
    local ready = require "nvim-mcp.lsp.ready"
    ready.FIRST_PROGRESS_MS = 0
    local out = mcp.invoke("definition", { path = path, line = 2, symbol = "foo" }, {})
    ready.FIRST_PROGRESS_MS = 10000
    assert.is_true(out.ok)
    local decoded = vim.json.decode(out.content[1].text)
    assert.are.equal(1, decoded.locations[1].line)
  end)
end)

describe("registration", function()
  it("lists every lookup on the lsp tool and none on drive", function()
    mcp.tools, mcp.order = {}, {}
    lsp.setup()
    local on_lsp = {}
    for _, action in ipairs(mcp.listed()) do
      assert.are_not.equal("drive", action.tool, action.name)
      if action.tool == "lsp" then on_lsp[#on_lsp + 1] = action.name end
    end
    assert.are.same(
      { "definition", "references", "hover", "implementation", "symbols", "calls", "code_actions" },
      on_lsp
    )
    assert.are.same({ "path", "line" }, mcp.get("definition", "lsp").inputSchema.required)
  end)
end)
