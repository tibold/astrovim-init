--- The bridge and an editor waiting on the human: a hit-enter prompt, or a
--- question asked in the middle of an action. A request sent to such an
--- editor used to hang the bridge, and every call behind it, for half an hour.
--- These run against editors with a UI (tests/target.lua): without one,
--- Neovim never asks.
local target = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/target.lua")

--- Actions registered in the test editor: `echo` counts its calls, `ask`
--- stops at a question the way a write does over a file that appeared.
local ACTIONS = [[
local mcp = require "nvim-mcp"
vim.g.echoed = 0
mcp.register {
  name = "echo",
  description = "Echo the arguments.",
  handler = function(args)
    vim.g.echoed = vim.g.echoed + 1
    return { args = args }
  end,
}
mcp.register {
  name = "ask",
  description = "Ask the human.",
  handler = function()
    vim.g.answer = vim.fn.confirm("Overwrite existing file?", "&Yes\n&No", 2)
    return { late = true }
  end,
}
]]

local function hit_enter(editor)
  editor.input ":echoerr 'one' | echoerr 'two'<CR>"
  assert.is_true(editor.wait_mode(function(mode) return mode.blocking end), "no hit-enter prompt came up")
end

local function payload(reply)
  assert(reply and reply.result, vim.inspect(reply))
  return vim.json.decode(reply.result.content[1].text)
end

describe("bridge, editor at a prompt", function()
  local editor, bridge

  before_each(function()
    editor = target.start()
    editor.exec(ACTIONS)
  end)

  after_each(function()
    if bridge then bridge.close() end
    editor.stop()
    bridge = nil
  end)

  it("answers at once, sends nothing, and takes the next call once the prompt is answered", function()
    hit_enter(editor)
    bridge = target.bridge(editor.address)

    local reply, ms = bridge.call("drive", { action = "echo", args = { n = 1 } })
    assert.is_truthy(reply and reply.error, vim.inspect(reply))
    local message = reply.error.message
    assert.is_truthy(message:find(editor.address, 1, true), message)
    assert.matches("hit%-enter prompt", message)
    assert.matches("mode r%)", message)
    assert.matches("Nothing was sent", message)
    assert.matches("tell them which editor is waiting", message)
    assert.is_true(ms < 3000, ("took %d ms"):format(ms))

    editor.input "<CR>"
    assert.is_true(editor.wait_mode(function(mode) return not target.at_prompt(mode) end))
    reply = bridge.call("drive", { action = "echo", args = { n = 2 } })
    assert.are.equal(2, payload(reply).args.n)
    assert.are.equal(1, editor.exec "return vim.g.echoed", "the call made at the prompt must not have run")
  end)

  it("answers within seconds when the editor stops at a question during an action", function()
    bridge = target.bridge(editor.address)

    local reply, ms = bridge.call("drive", { action = "ask" })
    assert.is_truthy(reply and reply.error, vim.inspect(reply))
    local message = reply.error.message
    assert.is_truthy(message:find(editor.address, 1, true), message)
    assert.matches("a question that needs an answer %(mode r%?%)", message)
    assert.matches("while running `ask`", message)
    assert.matches("still running in that editor", message)
    assert.is_true(ms < 5000, ("took %d ms"):format(ms))

    -- It really is still running: answered, it finishes.
    assert.is_true(target.at_prompt(editor.mode()))
    editor.input "y"
    assert.is_true(editor.wait_mode(function(mode) return not target.at_prompt(mode) end))
    assert.are.equal(1, editor.exec "return vim.g.answer")
  end)

  it("drops the late reply of an action it gave up on", function()
    bridge = target.bridge(editor.address)
    local reply = bridge.call("drive", { action = "ask" })
    assert.is_truthy(reply and reply.error, vim.inspect(reply))

    -- Answered, the action finishes and sends its reply, which no call is
    -- waiting for any more. The next call must get its own.
    editor.input "y"
    assert.is_true(editor.wait_mode(function(mode) return not target.at_prompt(mode) end))
    assert.are.equal(1, editor.exec "return vim.g.answer")

    reply = bridge.call("drive", { action = "echo", args = { n = 3 } })
    local answer = payload(reply)
    assert.is_nil(answer.late)
    assert.are.equal(3, answer.args.n)
    reply = bridge.call("drive", { action = "echo", args = { n = 4 } })
    assert.are.equal(4, payload(reply).args.n)
  end)

  it("waits for the next key of a command the human is typing, then runs the call", function()
    -- `m` waits for its mark's name: Neovim reports `blocking`, as it does for
    -- `f`, `"`, <C-w> or a mapping's first key, and runs no call meanwhile.
    editor.input "m"
    assert.is_true(editor.wait_mode(function(mode) return mode.blocking end))
    bridge = target.bridge(editor.address)

    vim.defer_fn(function() pcall(editor.input, "a") end, 800)
    local reply = bridge.call("drive", { action = "echo", args = { n = 1 } })
    assert.are.equal(1, payload(reply).args.n)
    assert.are.equal(1, editor.exec "return vim.g.echoed")
  end)

  it("sends nothing while a command stays half typed, and says so", function()
    editor.input "m"
    assert.is_true(editor.wait_mode(function(mode) return mode.blocking end))
    bridge = target.bridge(editor.address)

    local reply, ms = bridge.call("drive", { action = "echo", args = { n = 1 } })
    assert.is_truthy(reply and reply.error, vim.inspect(reply))
    local message = reply.error.message
    assert.is_truthy(message:find(editor.address, 1, true), message)
    assert.matches("half typed", message)
    assert.matches("mode n%)", message)
    assert.matches("Nothing was sent", message)
    assert.is_true(ms < 10000, ("took %d ms"):format(ms))

    editor.input "<Esc>"
    assert.is_true(editor.wait_mode(function(mode) return not target.at_prompt(mode) end))
    vim.wait(200)
    assert.are.equal(0, editor.exec "return vim.g.echoed", "the call refused must never run")
  end)

  it("tells the client to list the tools again once an editor at a prompt answers", function()
    hit_enter(editor)
    bridge = target.bridge(editor.address)
    local init = bridge.request("initialize", vim.empty_dict())
    assert.is_true(init.result.capabilities.tools.listChanged)

    -- Listed at the prompt: the editor's own actions are missing, and each
    -- description says so and where to find them.
    local tools = bridge.request("tools/list").result.tools
    for _, tool in ipairs(tools) do
      assert.matches("prompt", tool.description, 1, true)
      assert.matches("describe", tool.description:match "\n\n([^\n]*could not[^\n]*)" or "", 1, true)
    end
    assert.is_nil(tools[1].description:match "actions: [^\n]*echo")

    editor.input "<CR>"
    assert.is_true(editor.wait_mode(function(mode) return not target.at_prompt(mode) end))
    assert.are.equal(0, bridge.notified "notifications/tools/list_changed")
    bridge.call("drive", { action = "echo", args = { n = 1 } })
    assert.are.equal(1, bridge.notified "notifications/tools/list_changed")

    tools = bridge.request("tools/list").result.tools
    assert.is_truthy(tools[1].description:match "actions: [^\n]*echo", tools[1].description)
    assert.is_nil(tools[1].description:find("could not", 1, true))
    bridge.call("drive", { action = "echo", args = { n = 2 } })
    assert.are.equal(1, bridge.notified "notifications/tools/list_changed", "told only once")
  end)

  it("lists an announced editor at a prompt as prompt = true", function()
    local records = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(records, "p")
    local pid = editor.exec "return vim.fn.getpid()"
    vim.fn.writefile(
      { vim.json.encode { address = editor.address, pid = pid, cwd = "C:/work/waiting" } },
      records .. "/w.json"
    )
    hit_enter(editor)

    bridge = target.bridge(editor.address, { NVIM_MCP_INSTANCES = records })
    local listed = payload(bridge.call("drive", { action = "instances" }))
    local found
    for _, entry in ipairs(listed.editors) do
      if entry.address == editor.address then found = entry end
    end
    assert.is_truthy(found, vim.inspect(listed))
    assert.is_true(found.prompt)
    assert.are.equal("r", found.mode)
    assert.is_nil(found.busy)
    assert.are.equal("C:/work/waiting", found.info.cwd)
    assert.is_true(found.host)
  end)
end)
