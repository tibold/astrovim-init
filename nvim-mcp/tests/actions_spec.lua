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

describe("project", function()
  local function dir()
    local path = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(path, "p")
    vim.fn.writefile({ "x" }, path .. "/main.txt")
    return path
  end

  local function same(a, b) return vim.fs.normalize(a):lower() == vim.fs.normalize(b):lower() end

  after_each(function()
    while #vim.api.nvim_list_tabpages() > 1 do
      vim.cmd "tablast | tabclose!"
    end
  end)

  it("opens a directory in a new tab with its own cwd, and keeps the human's tab", function()
    local path = dir()
    local entry = vim.api.nvim_get_current_tabpage()
    local cwd = vim.fn.getcwd()
    local reply = actions.project({ path = path }, {})
    assert.is_true(reply.created)
    assert.are.equal(2, #vim.api.nvim_list_tabpages())
    assert.are.equal(entry, vim.api.nvim_get_current_tabpage())
    assert.are.equal(cwd, vim.fn.getcwd(), "the human's tab kept its directory")
    assert.is_true(same(path, vim.fn.getcwd(-1, reply.tab)))
  end)

  it("reuses the tab already open on that directory", function()
    local path = dir()
    local first = actions.project({ path = path }, {})
    local again = actions.project({ path = path .. "/" }, {})
    assert.is_false(again.created)
    assert.are.equal(first.tab, again.tab)
    assert.are.equal(2, #vim.api.nvim_list_tabpages())
  end)

  it("opens a file in the project's tab", function()
    local path = dir()
    local reply = actions.project({ path = path, file = "main.txt" }, {})
    local tab = vim.api.nvim_list_tabpages()[reply.tab]
    local window = vim.api.nvim_tabpage_get_win(tab)
    assert.is_true(same(path .. "/main.txt", vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(window))))
  end)

  it("switches to the tab when asked", function()
    local reply = actions.project({ path = dir(), focus = true }, {})
    assert.are.equal(reply.tab, vim.fn.tabpagenr())
  end)

  it("refuses something that is not a directory", function()
    assert.has_error(function() actions.project({ path = vim.fn.tempname() }, {}) end)
  end)
end)
