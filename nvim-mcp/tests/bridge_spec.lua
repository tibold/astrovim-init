--- The bridge as Claude Code runs it: a separate `nvim -l` process speaking
--- JSON-RPC on stdio, calling back into this instance over its socket.
local mcp = require "nvim-mcp"

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local bridge = vim.fs.normalize(here .. "/../../claude/server.lua")

--- Send requests through the real bridge; returns its replies keyed by id.
local function exchange(requests, cwd, env)
  local address = vim.fn.serverstart()
  local lines = { vim.json.encode { jsonrpc = "2.0", id = 0, method = "initialize", params = vim.empty_dict() } }
  for id, request in ipairs(requests) do
    lines[#lines + 1] = vim.json.encode { jsonrpc = "2.0", id = id, method = request.method, params = request.params }
  end
  local done
  vim.system({ "nvim", "-u", "NONE", "-l", bridge }, {
    stdin = table.concat(lines, "\n") .. "\n",
    env = vim.tbl_extend("force", { NVIM = address }, env or {}),
    cwd = cwd,
    text = true,
  }, function(result) done = result end)
  vim.wait(20000, function() return done ~= nil end, 20)
  vim.fn.serverstop(address)
  assert(done, "the bridge did not exit")
  local replies = {}
  for line in vim.gsplit(done.stdout or "", "\n") do
    local ok, message = pcall(vim.json.decode, line)
    if ok and type(message) == "table" and message.id then replies[message.id] = message end
  end
  return replies
end

--- One tools/call through the real bridge; returns what the action received.
local function received(arguments, cwd, tool)
  local reply =
    exchange({ { method = "tools/call", params = { name = tool or "drive", arguments = arguments } } }, cwd)[1]
  assert(reply and reply.result, vim.inspect(reply))
  return vim.json.decode(reply.result.content[1].text)
end

describe("bridge", function()
  before_each(function()
    mcp.register {
      name = "echo",
      description = "Echo the arguments.",
      handler = function(args) return { args = args } end,
    }
  end)

  it("passes timeout through to an action when not waiting", function()
    local reply = received { action = "echo", args = { timeout = 12 } }
    assert.are.equal(12, reply.args.timeout)
  end)

  it("resolves a relative path against the session's directory, not the editor's", function()
    local session = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(session, "p")
    local reply = received({ action = "echo", args = { path = "src/x.lua" } }, session)
    assert.are.equal(vim.fs.normalize(session .. "/src/x.lua"), vim.fs.normalize(reply.args.path))
  end)

  it("lists drive, lsp and lsp_edit, each with its own actions", function()
    mcp.register { name = "lookup", tool = "lsp", description = "Look.", handler = function() end }
    mcp.register { name = "change", tool = "lsp_edit", description = "Change.", handler = function() end }
    local tools = exchange({ { method = "tools/list" } })[1].result.tools
    local by_name = {}
    for _, tool in ipairs(tools) do
      by_name[tool.name] = tool.description:match "actions: ([^\n]*)"
    end
    assert.are.same({ "drive", "lsp", "lsp_edit", "debug", "lua" }, vim.tbl_map(function(t) return t.name end, tools))
    assert.is_truthy(by_name.drive:find("echo", 1, true))
    assert.is_nil(by_name.drive:find("lookup", 1, true))
    assert.is_truthy(by_name.lsp:find("lookup", 1, true))
    assert.is_nil(by_name.lsp:find("change", 1, true))
    assert.is_truthy(by_name.lsp_edit:find("change", 1, true))
  end)

  it("refuses an action through a tool it is not on", function()
    mcp.register { name = "change", tool = "lsp_edit", description = "Change.", handler = function() return "done" end }
    local replies = exchange {
      { method = "tools/call", params = { name = "lsp", arguments = { action = "change" } } },
      { method = "tools/call", params = { name = "drive", arguments = { action = "change" } } },
      { method = "tools/call", params = { name = "lsp_edit", arguments = { action = "change" } } },
    }
    assert.is_truthy(replies[1].error, vim.inspect(replies[1]))
    assert.is_truthy(replies[2].error, vim.inspect(replies[2]))
    assert.are.equal("done", replies[3].result.content[1].text)
  end)

  it("answers describe on every tool", function()
    mcp.register { name = "lookup", tool = "lsp", description = "Look.", handler = function() end }
    local reply = received({ action = "describe", args = { name = "lookup" } }, nil, "lsp")
    assert.are.equal("lsp", reply.tool)
  end)

  it("polls while an action is not ready, and returns the answer once it is", function()
    local calls = 0
    mcp.register {
      name = "cold",
      tool = "lsp",
      description = "Ready on the third try.",
      handler = function()
        calls = calls + 1
        if calls < 3 then return { not_ready = true, server = "fake", status = "Indexing" } end
        return { count = 1 }
      end,
    }
    local reply = received({ action = "cold" }, nil, "lsp")
    assert.are.equal(1, reply.count)
    assert.are.equal(3, calls)
  end)

  it("makes a final attempt when the wait is up, and marks one still not ready", function()
    local finals = 0
    mcp.register {
      name = "frozen",
      tool = "lsp",
      description = "Never ready.",
      handler = function(_, opts)
        if opts.final then finals = finals + 1 end
        return { not_ready = true, server = "fake", status = "Indexing" }
      end,
    }
    local replies = exchange(
      { { method = "tools/call", params = { name = "lsp", arguments = { action = "frozen" } } } },
      nil,
      { NVIM_MCP_READY_WAIT = "1" }
    )
    local reply = vim.json.decode(replies[1].result.content[1].text)
    assert.is_true(reply.not_ready)
    assert.is_true(reply.timed_out)
    assert.are.equal(1, finals)
  end)

  it("tells an action the session's directory", function()
    mcp.register { name = "where", description = "Where.", handler = function(_, opts) return { cwd = opts.cwd } end }
    local session = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(session, "p")
    local reply = received({ action = "where" }, session)
    assert.are.equal(session:lower(), vim.fs.normalize(reply.cwd):lower())
  end)

  it("follows an action's poll into another, and waits on that", function()
    local polled = 0
    mcp.register {
      name = "kick",
      tool = "debug",
      description = "Starts something, then asks for watch to be polled.",
      handler = function() return { poll = { action = "watch", args = { after = 7 } } } end,
    }
    mcp.register {
      name = "watch",
      tool = "debug",
      description = "Ready on the second look.",
      handler = function(args)
        polled = polled + 1
        if polled < 2 then return { not_ready = true, status = "running" } end
        return { after = args.after, done = true }
      end,
    }
    local reply = received({ action = "kick" }, nil, "debug")
    assert.is_true(reply.done)
    assert.are.equal(7, reply.after)
    assert.are.equal(2, polled)
  end)

  it("lists an announced editor that is too busy to answer, and drops a stale record", function()
    local records = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(records, "p")
    -- A real Neovim, blocked the way Roslyn blocks one while it loads.
    local address = [[\\.\pipe\nvim-mcp-busy-]] .. vim.fn.getpid()
    if vim.fn.has "win32" == 0 then address = vim.fn.tempname() .. ".sock" end
    local busy = vim.system { "nvim", "--headless", "-u", "NONE", "--listen", address, "-c", "lua vim.uv.sleep(15000)" }
    vim.wait(3000, function() return vim.uv.fs_stat(address) ~= nil or vim.fn.has "win32" == 1 end, 50)
    vim.wait(500)
    vim.fn.writefile(
      { vim.json.encode { address = address, pid = busy.pid, cwd = "C:/work/big" } },
      records .. "/busy.json"
    )
    vim.fn.writefile({ vim.json.encode { address = "nowhere", pid = 999999, cwd = "gone" } }, records .. "/stale.json")

    local reply = exchange(
      { { method = "tools/call", params = { name = "drive", arguments = { action = "instances" } } } },
      nil,
      { NVIM_MCP_INSTANCES = records }
    )[1]
    busy:kill(9)
    local listed = vim.json.decode(reply.result.content[1].text)
    local found
    for _, editor in ipairs(listed.editors) do
      if editor.address == address then found = editor end
    end
    assert.is_truthy(found, vim.inspect(listed))
    assert.is_true(found.busy)
    assert.are.equal("C:/work/big", found.info.cwd)
    assert.is_nil(vim.uv.fs_stat(records .. "/stale.json"), "the stale record was not removed")
  end)

  it("leaves an absolute path alone", function()
    local absolute = vim.fs.normalize(vim.fn.tempname() .. "/y.lua")
    local reply = received { action = "echo", args = { path = absolute } }
    assert.are.equal(absolute, reply.args.path)
  end)
end)
