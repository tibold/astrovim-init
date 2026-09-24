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

  --- Read a file from the repository root, or fail the test naming the path.
  local function read_repo_file(relative)
    local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
    local repo = vim.fn.fnamemodify(here, ":h:h")
    local path = repo .. "/" .. relative
    assert.is_not_nil(vim.uv.fs_stat(path), "missing at " .. path)
    local fd = assert(io.open(path, "rb"))
    local text = fd:read "*a"
    fd:close()
    return text
  end

  it("has the full contract in the checklist skill", function()
    local text = read_repo_file "claude/skills/checklist/SKILL.md"
    for _, phrase in ipairs { "Write-only", "read it back", "sweep", "stable slug", "group" } do
      assert.is_true(text:find(phrase, 1, true) ~= nil, "skill is missing: " .. phrase)
    end
  end)

  it("tells both the skill and the hook to defer rather than drop", function()
    -- A deferred item dropped is a decision lost: nothing else in the session
    -- records that it was raised and consciously set aside. Asserted in both
    -- places because the hook is what carries the habit into sessions where
    -- the skill never loads.
    for _, relative in ipairs { "claude/skills/checklist/SKILL.md", "claude/hooks/session-start.lua" } do
      local text = read_repo_file(relative)
      assert.is_true(text:find("Deferred", 1, true) ~= nil, relative .. " does not mention a Deferred group")
      assert.is_true(text:find("drop", 1, true) ~= nil, relative .. " does not contrast deferring with dropping")
    end
  end)

  it("keeps the contract out of the nvim skill, but reachable from it", function()
    -- The checklist moved to its own skill so that it triggers on starting a
    -- task rather than on wanting to drive the editor. Duplicating the ops
    -- table back into the nvim skill would put the two out of step.
    local text = read_repo_file "claude/skills/nvim/SKILL.md"
    assert.is_true(text:find("`checklist` skill", 1, true) ~= nil, "nvim skill does not point at the checklist skill")
    assert.is_nil(text:find("stable slug", 1, true), "nvim skill still carries the contract")
  end)

  it("injects the checklist habit at session start, only when in an editor", function()
    local hooks = vim.json.decode(read_repo_file "claude/hooks/hooks.json")
    local entry = hooks.hooks.SessionStart[1]
    -- All five sources, not the three superpowers matches. Omitting `resume`
    -- means the hook never fires for anyone who restarts and picks a session
    -- back up, which is the normal way a long session continues.
    for _, source in ipairs { "startup", "resume", "clear", "compact", "fork" } do
      assert.is_true(entry.matcher:find(source, 1, true) ~= nil, "matcher does not cover " .. source)
    end
    assert.is_true(entry.hooks[1].command:find "session%-start%.lua" ~= nil, entry.hooks[1].command)

    local script = read_repo_file "claude/hooks/session-start.lua"
    -- Without the gate this would cost context in every session, including the
    -- ones with no Neovim to draw a panel in.
    assert.is_true(script:find("vim.env.NVIM", 1, true) ~= nil, "hook is not gated on $NVIM")
    -- `print` goes to stderr under `nvim -l`, so the payload would vanish.
    assert.is_true(script:find("io.stdout:write", 1, true) ~= nil, "hook does not write to stdout")
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
