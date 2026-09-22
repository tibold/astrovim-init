local mcp = require "checklist.mcp"
local persist = require "checklist.persist"
local state = require "checklist.state"
local window = require "checklist.window"

describe("mcp tool", function()
  local tmp

  before_each(function()
    state.reset()
    if window.is_open() then window.close() end
    tmp = vim.fn.tempname() .. ".json"
    persist.path = function() return tmp end
    persist.restored = true
  end)

  after_each(function()
    os.remove(tmp)
    if window.is_open() then window.close() end
  end)

  it("is shaped the way nvim-mcp's register expects", function()
    assert.are.equal("checklist_update", mcp.tool.name)
    assert.are.equal("function", type(mcp.tool.handler))
    assert.are.equal("string", type(mcp.tool.description))
    assert.are.equal("object", mcp.tool.inputSchema.type)
    assert.are.same({ "ops" }, mcp.tool.inputSchema.required)
  end)

  it("keeps its description short, because the contract lives in the skill", function()
    -- A tool description costs ~600 tokens of permanent context; a skill costs
    -- ~140 for its index line and loads the rest only when relevant.
    local description = mcp.tool.description
    assert.is_true(#description < 250, ("description is %d chars"):format(#description))
    assert.is_true(description:find "Write%-only" ~= nil)
    assert.is_true(description:find("never read it back", 1, true) ~= nil)
  end)

  it("has the full contract in the nvim skill", function()
    local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
    local repo = vim.fn.fnamemodify(here, ":h:h")
    local skill = repo .. "/claude/skills/nvim/SKILL.md"
    assert.is_not_nil(vim.uv.fs_stat(skill), "skill missing at " .. skill)
    local fd = assert(io.open(skill, "rb"))
    local text = fd:read "*a"
    fd:close()
    for _, phrase in ipairs { "Write-only", "never read it back", "one", "sweep", "stable slug" } do
      assert.is_true(text:find(phrase, 1, true) ~= nil, "skill is missing: " .. phrase)
    end
  end)

  it("applies ops and renders", function()
    local result = mcp.tool.handler {
      ops = {
        { op = "set", id = "a", text = "From Claude", group = "G" },
        { op = "set", id = "b", text = "Blocked one", state = "blocked", note = "waiting" },
      },
    }
    assert.are.same({ "a", "b" }, state.order)
    assert.are.equal("waiting", state.items.b.note)
    local lines = vim.api.nvim_buf_get_lines(require("checklist.render").ensure_buf(), 0, -1, false)
    assert.is_true(table.concat(lines, "\n"):find("From Claude", 1, true) ~= nil)
    assert.are.equal("ok", result)
  end)

  it("replies with as little as possible", function()
    local result = mcp.tool.handler { ops = { { op = "set", id = "a", text = "x" } } }
    assert.is_true(#result <= 4)
  end)

  it("raises on a malformed call rather than failing silently", function()
    -- The shell wrapper's silence covered "no editor running"; here the only
    -- failure left is the agent sending something invalid.
    assert.has_error(function() mcp.tool.handler { ops = "not an array" } end)
    assert.has_error(function() mcp.tool.handler {} end)
    assert.has_error(function() mcp.tool.handler { ops = { { op = "nonsense" } } } end)
    assert.are.same({}, state.order)
  end)

  it("applies nothing when one op in the array is invalid", function()
    mcp.tool.handler { ops = { { op = "set", id = "keep", text = "Keep" } } }
    assert.has_error(
      function()
        mcp.tool.handler {
          ops = { { op = "set", id = "good", text = "Good" }, { op = "bogus" } },
        }
      end
    )
    assert.are.same({ "keep" }, state.order)
  end)

  it("reports no attachment when nvim-mcp is absent", function()
    -- nvim-mcp is not on the checklist test runtimepath.
    assert.is_false(mcp.attach())
  end)
end)
