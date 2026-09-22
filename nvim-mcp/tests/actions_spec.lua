local actions = require "nvim-mcp.actions"

describe("diagnostics detail", function()
  it("summarises by default and keeps the attachment signal", function()
    local result = actions.diagnostics({}, {})
    assert.are.equal("summary", result.detail)
    -- These two are what distinguish "nothing wrong" from "nothing watching",
    -- so they must survive summarising.
    assert.is_not_nil(result.clients)
    assert.is_not_nil(result.unattached)
    assert.is_not_nil(result.by_file)
    assert.is_boolean(result.truncated)
  end)

  it("returns everything when asked for full", function()
    local result = actions.diagnostics({}, { detail = "full" })
    assert.are.equal("full", result.detail)
    assert.is_not_nil(result.buffers)
    assert.is_nil(result.truncated)
  end)

  it("caps the summary item list", function()
    local result = actions.diagnostics({}, {})
    assert.is_true(#result.items <= 10)
    assert.is_true(result.count >= #result.items)
  end)
end)

describe("actions", function()
  it("registers the editor-driving set", function()
    local mcp = require "nvim-mcp"
    mcp.tools, mcp.order = {}, {}
    actions.setup()
    local names = vim.tbl_map(function(t) return t.name end, mcp.specs())
    for _, expected in ipairs { "show", "state", "diagnostics", "close", "identify" } do
      assert.is_true(vim.tbl_contains(names, expected), "missing action: " .. expected)
    end
  end)

  it("refuses show and close without a path", function()
    assert.has_error(function() actions.show {} end)
    assert.has_error(function() actions.close {} end)
  end)

  it("reports a buffer that is not open", function()
    local result = actions.close { path = "Z:/definitely/not/open.txt" }
    assert.is_false(result.closed)
    assert.are.equal("not open", result.reason)
  end)

  it("identifies this instance", function()
    local result = actions.identify()
    assert.is_string(result.cwd)
    assert.is_number(result.count)
  end)
end)
