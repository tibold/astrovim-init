local lsp = require "nvim-mcp.lsp"
local position = require "nvim-mcp.lsp.position"
local fake = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/fake_lsp.lua")

local original_notify = vim.notify

--- A server offering: an edit action, a command action whose edit arrives via
--- workspace/applyEdit, a resolvable action, and a command that changes nothing.
local function server()
  local path, dir = fake.file { "local foo = 1", "print(foo)" }
  local buffer = position.buffer(path)
  vim.bo[buffer].buflisted = true
  local uri = vim.uri_from_fname(path)
  local answers = {}
  local function change(line0, from, to, text)
    return { changes = { [uri] = { { range = fake.range(line0, from, to), newText = text } } } }
  end
  fake.start(buffer, dir, {
    capabilities = {
      codeActionProvider = { resolveProvider = true },
      executeCommandProvider = { commands = { "fill", "noop" } },
    },
    handlers = {
      ["textDocument/codeAction"] = function()
        return {
          { title = "Make it const", kind = "quickfix", edit = change(0, 0, 5, "const") },
          { title = "Fill it", kind = "refactor", command = { title = "Fill it", command = "fill" } },
          { title = "Resolve me", kind = "refactor", data = 1 },
          { title = "Do nothing", command = "noop" },
        }
      end,
      ["codeAction/resolve"] = function(action)
        action.edit = change(1, 0, 5, "trace")
        return action
      end,
      ["workspace/executeCommand"] = function(params, dispatchers)
        if params.command == "fill" then
          answers[#answers + 1] = dispatchers.server_request("workspace/applyEdit", { edit = change(0, 6, 9, "bar") })
        end
        return vim.NIL
      end,
    },
  })
  return path, buffer, answers
end

describe("code actions", function()
  before_each(function() vim.notify = function() end end)
  after_each(function()
    vim.notify = original_notify
    fake.stop_all()
  end)

  it("lists what is available with index, title and kind", function()
    local path = server()
    local reply = lsp.code_actions { path = path, line = 1 }
    assert.are.equal(4, reply.count)
    assert.are.same({ index = 1, title = "Make it const", kind = "quickfix", server = "fake" }, reply.actions[1])
  end)

  it("applies an action's edit by title, and saves", function()
    local path = server()
    local reply = lsp.code_action { path = path, line = 1, title = "Make it const" }
    assert.is_true(reply.applied)
    assert.are.equal("Make it const", reply.title)
    assert.are.same({ "const foo = 1", "print(foo)" }, vim.fn.readfile(path))
  end)

  it("lets the title win over a stale index", function()
    local path = server()
    local reply = lsp.code_action { path = path, line = 1, title = "Make it const", index = 2 }
    assert.are.equal("Make it const", reply.title)
    assert.are.same({ "const foo = 1", "print(foo)" }, vim.fn.readfile(path))
  end)

  it("lists the available titles for an unknown one", function()
    local path = server()
    local ok, err = pcall(lsp.code_action, { path = path, line = 1, title = "Nope" })
    assert.is_false(ok)
    assert.matches("Make it const | Fill it", err.message)
  end)

  it("captures the edit a command sends back, and saves it", function()
    local path, _, answers = server()
    local reply = lsp.code_action { path = path, line = 1, title = "Fill it" }
    assert.is_true(reply.applied)
    assert.are.same({ "local bar = 1", "print(foo)" }, vim.fn.readfile(path))
    assert.are.equal(1, #reply.changed)
    assert.are.same({ applied = true }, answers[1])
  end)

  it("refuses a command's edit into unsaved work, and tells the server", function()
    local path, buffer, answers = server()
    vim.api.nvim_buf_set_lines(buffer, 1, 2, false, { "print(foo) -- mine" })
    local reply = lsp.code_action { path = path, line = 1, title = "Fill it" }
    assert.is_false(reply.applied)
    assert.are.equal("modified", reply.reason)
    assert.is_false(answers[1].applied)
    assert.are.same({ "local foo = 1", "print(foo)" }, vim.fn.readfile(path))
  end)

  it("resolves an action that arrives without its edit", function()
    local path = server()
    local reply = lsp.code_action { path = path, line = 1, title = "Resolve me" }
    assert.is_true(reply.applied)
    assert.are.same({ "local foo = 1", "trace(foo)" }, vim.fn.readfile(path))
  end)

  it("says so when an action changes nothing", function()
    local path = server()
    local reply = lsp.code_action { path = path, line = 1, title = "Do nothing" }
    assert.is_true(reply.applied)
    assert.are.equal(0, #reply.changed)
    assert.matches("changed no files", reply.note)
  end)

  it("needs a title", function()
    assert.has_error(function() lsp.code_action { path = "x", line = 1 } end)
  end)
end)

describe("code action commands that go wrong", function()
  before_each(function() vim.notify = function() end end)
  after_each(function()
    vim.notify = original_notify
    rawset(vim.lsp.commands, "client.pick", nil)
    fake.stop_all()
  end)

  --- A server with one action; `execute` answers workspace/executeCommand.
  local function offering(action, execute)
    local path, dir = fake.file { "local foo = 1", "print(foo)" }
    local buffer = position.buffer(path)
    vim.bo[buffer].buflisted = true
    local uri = vim.uri_from_fname(path)
    local function change(line0, from, to, text)
      return { changes = { [uri] = { { range = fake.range(line0, from, to), newText = text } } } }
    end
    fake.start(buffer, dir, {
      capabilities = { codeActionProvider = true, executeCommandProvider = { commands = { "fill" } } },
      handlers = {
        ["textDocument/codeAction"] = function() return { action(change) } end,
        ["workspace/executeCommand"] = function(_, dispatchers) return execute(change, dispatchers) end,
      },
    })
    return path, buffer
  end

  it("does not run a client-side command, and says the human is needed", function()
    -- roslyn.nvim's "Fix all" opens a picker in the human's editor and applies
    -- whatever they choose, unsaved: nothing this action could report on.
    local ran = false
    vim.lsp.commands["client.pick"] = function() ran = true end
    local path = offering(function() return { title = "Fix all", command = { title = "Fix all", command = "client.pick" } } end)
    local reply = lsp.code_action { path = path, line = 1, title = "Fix all" }
    assert.is_false(ran)
    assert.is_false(reply.applied)
    assert.are.equal("client command", reply.reason)
    assert.matches("ask the human", reply.message)
  end)

  it("keeps the refusal when the server then fails the command", function()
    local path, buffer = offering(
      function() return { title = "Fill it", command = { title = "Fill it", command = "fill" } } end,
      function(change, dispatchers)
        dispatchers.server_request("workspace/applyEdit", { edit = change(0, 6, 9, "bar") })
        return fake.failure(-32603, "edit was rejected")
      end
    )
    vim.api.nvim_buf_set_lines(buffer, 1, 2, false, { "print(foo) -- mine" })
    local reply = lsp.code_action { path = path, line = 1, title = "Fill it" }
    assert.is_false(reply.applied)
    assert.are.equal("modified", reply.reason)
    assert.matches("edit was rejected", reply.server_error)
  end)

  it("reports the files an action changed even when its command then fails", function()
    local path = offering(
      function(change) return { title = "Both", edit = change(0, 0, 5, "const"), command = { title = "Both", command = "fill" } } end,
      function() return fake.failure(-32603, "command blew up") end
    )
    local reply = lsp.code_action { path = path, line = 1, title = "Both" }
    assert.are.same({ "const foo = 1", "print(foo)" }, vim.fn.readfile(path))
    assert.are.equal(1, #reply.changed)
    assert.matches("command blew up", reply.server_error)
  end)
end)
