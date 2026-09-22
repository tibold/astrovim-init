local mcp = require "nvim-mcp"

local function tool(extra)
  return vim.tbl_extend("force", {
    name = "demo",
    description = "A demo tool.",
    inputSchema = { type = "object", properties = { x = { type = "string" } } },
    handler = function(args) return "got:" .. tostring(args.x) end,
  }, extra or {})
end

describe("registry", function()
  before_each(function()
    mcp.tools, mcp.order = {}, {}
  end)

  it("registers a well-formed tool", function()
    assert.is_true((mcp.register(tool())))
    assert.are.same({ "demo" }, mcp.order)
    assert.is_truthy(mcp.tools.demo)
  end)

  it("rejects a tool missing its parts", function()
    -- `tool { handler = nil }` would not clear the field: a nil value in a
    -- table literal is simply absent, so tbl_extend keeps the original.
    local handlerless = tool()
    handlerless.handler = nil

    assert.is_false((mcp.register { description = "d", handler = function() end }))
    assert.is_false((mcp.register(tool { description = "" })))
    assert.is_false((mcp.register(handlerless)))
    assert.is_false((mcp.register(tool { name = "has-a-dash" })))
    assert.is_false((mcp.register "not a table"))
    assert.are.same({}, mcp.order)
  end)

  it("replaces on re-registration rather than duplicating", function()
    mcp.register(tool())
    mcp.register(tool { description = "Updated." })
    assert.are.same({ "demo" }, mcp.order)
    assert.are.equal("Updated.", mcp.tools.demo.description)
  end)

  it("keeps registration order in specs", function()
    mcp.register(tool { name = "first" })
    mcp.register(tool { name = "second" })
    mcp.register(tool { name = "third" })
    local names = vim.tbl_map(function(s) return s.name end, mcp.specs())
    assert.are.same({ "first", "second", "third" }, names)
  end)

  it("omits handlers from specs, which cross an RPC boundary", function()
    mcp.register(tool())
    local spec = mcp.specs()[1]
    assert.is_nil(spec.handler)
    assert.are.equal("demo", spec.name)
    assert.is_truthy(spec.inputSchema.properties.x)
  end)

  it("encodes an empty properties map as an object, not an array", function()
    mcp.register(tool { inputSchema = { type = "object", properties = {} } })
    local encoded = vim.json.encode(mcp.specs()[1].inputSchema)
    assert.is_true(encoded:find('"properties":{}', 1, true) ~= nil, encoded)
  end)

  it("unregisters", function()
    mcp.register(tool())
    assert.is_true(mcp.unregister "demo")
    assert.are.same({}, mcp.order)
    assert.is_false(mcp.unregister "demo")
  end)

  it("invokes a tool and wraps a bare string as MCP content", function()
    mcp.register(tool())
    local result = mcp.invoke("demo", { x = "hello" })
    assert.is_true(result.ok)
    assert.are.same({ { type = "text", text = "got:hello" } }, result.content)
  end)

  it("passes through content a handler builds itself", function()
    mcp.register(tool {
      handler = function() return { content = { { type = "text", text = "custom" } } } end,
    })
    assert.are.same({ { type = "text", text = "custom" } }, mcp.invoke("demo", {}).content)
  end)

  it("encodes a data table rather than dropping it", function()
    -- Regression: anything without a `content` key fell through to "ok", so
    -- every action that reported data silently returned nothing.
    mcp.register(tool { handler = function() return { cwd = "D:/repo", count = 2 } end })
    local result = mcp.invoke("demo", {})
    assert.is_true(result.ok)
    local decoded = vim.json.decode(result.content[1].text)
    assert.are.equal("D:/repo", decoded.cwd)
    assert.are.equal(2, decoded.count)
  end)

  it("passes response options to the handler, separate from args", function()
    local seen
    mcp.register(tool {
      handler = function(args, opts)
        seen = { arg = args.x, detail = opts.detail }
        return "ok"
      end,
    })
    mcp.invoke("demo", { x = "a" }, { detail = "full" })
    assert.are.same({ arg = "a", detail = "full" }, seen)
  end)

  it("gives a handler an empty opts table when none is passed", function()
    local seen
    mcp.register(tool {
      handler = function(_, opts)
        seen = opts
        return "ok"
      end,
    })
    mcp.invoke("demo", {})
    assert.are.same({}, seen)
  end)

  it("keeps hidden actions out of the advertised list but callable", function()
    mcp.register(tool { name = "common" })
    mcp.register(tool { name = "rare", hidden = true, description = "A monthly chore." })

    local listed = vim.tbl_map(function(t) return t.name end, mcp.listed())
    assert.are.same({ "common" }, listed)
    -- still reachable, which is the whole point of hiding rather than removing
    assert.is_true(mcp.invoke("rare", {}).ok)
  end)

  it("finds a hidden action by name or description", function()
    mcp.register(tool { name = "rare", hidden = true, description = "Rotate the widget gaskets." })
    local by_name = vim.tbl_map(function(t) return t.name end, mcp.search "rare")
    local by_desc = vim.tbl_map(function(t) return t.name end, mcp.search "gaskets")
    assert.is_true(vim.tbl_contains(by_name, "rare"))
    assert.is_true(vim.tbl_contains(by_desc, "rare"))
  end)

  it("returns schemas from search, so a match is immediately callable", function()
    mcp.register(tool { name = "rare", hidden = true, description = "Rotate the gaskets." })
    local hit = mcp.search("gaskets")[1]
    assert.are.equal("rare", hit.name)
    assert.is_truthy(hit.inputSchema)
  end)

  it("ranks a name match above a description match, and respects limit", function()
    mcp.register(tool { name = "gaskets", description = "Unrelated." })
    mcp.register(tool { name = "other", description = "Mentions gaskets in passing." })
    local names = vim.tbl_map(function(t) return t.name end, mcp.search "gaskets")
    assert.are.equal("gaskets", names[1])
    assert.are.equal(1, #mcp.search("gaskets", 1))
  end)

  it("describes the full roster without schemas, hidden included", function()
    mcp.register(tool { name = "common" })
    mcp.register(tool { name = "rare", hidden = true })
    local roster = mcp.describe()
    assert.are.equal(2, #roster)
    for _, entry in ipairs(roster) do
      assert.is_nil(entry.inputSchema)
    end
    assert.is_truthy(mcp.describe("rare").inputSchema)
  end)

  it("reports an unknown tool rather than throwing", function()
    local result = mcp.invoke("nope", {})
    assert.is_false(result.ok)
    assert.is_true(result.message:find("Unknown tool", 1, true) ~= nil)
  end)

  it("never lets a throwing handler escape", function()
    mcp.register(tool { handler = function() error "handler exploded" end })
    local result
    assert.has_no.errors(function() result = mcp.invoke("demo", {}) end)
    assert.is_false(result.ok)
    assert.is_true(result.message:find("handler exploded", 1, true) ~= nil)
  end)

  it("surfaces a structured error message from a handler", function()
    mcp.register(tool { handler = function() error { code = -32602, message = "bad args" } end })
    assert.are.equal("bad args", mcp.invoke("demo", {}).message)
  end)
end)

describe("config", function()
  local config = require "nvim-mcp.config"

  it("points at the bridge inside the Claude Code plugin", function()
    -- The bridge lives there because that directory is what gets copied on
    -- plugin install, which is what makes ${CLAUDE_PLUGIN_ROOT} resolve to it.
    local script = config.server_script()
    assert.is_true(script:find("claude/server.lua", 1, true) ~= nil, script)
    assert.is_not_nil(vim.uv.fs_stat(script), "bridge missing at " .. script)
  end)

  it("builds the payload Claude Code expects", function()
    local payload = config.payload()
    assert.is_truthy(payload.mcpServers.nvim)
    assert.are.equal("stdio", payload.mcpServers.nvim.type)
    assert.are.equal("nvim", payload.mcpServers.nvim.command)
    -- -u NONE keeps a user plugin from printing into the JSON-RPC stream.
    assert.are.same({ "-u", "NONE", "-l", config.server_script() }, payload.mcpServers.nvim.args)
  end)

  it("uses the = form, because --mcp-config is variadic", function()
    local cmd = config.claude_cmd()
    assert.is_true(cmd:find("--mcp-config=", 1, true) ~= nil, cmd)
    assert.is_false(cmd:find("--mcp-config ", 1, true) ~= nil, cmd)
  end)

  it("writes a config file that decodes", function()
    local path = config.write()
    assert.is_not_nil(path)
    local fd = assert(io.open(path, "rb"))
    local decoded = vim.json.decode(fd:read "*a")
    fd:close()
    assert.is_truthy(decoded.mcpServers.nvim)
  end)
end)
