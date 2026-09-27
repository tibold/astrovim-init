--- The bridge as Claude Code runs it: a separate `nvim -l` process speaking
--- JSON-RPC on stdio, calling back into this instance over its socket.
local mcp = require "nvim-mcp"

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local bridge = vim.fs.normalize(here .. "/../../claude/server.lua")

--- One tools/call through the real bridge; returns what the action received.
local function received(arguments, cwd)
  local address = vim.fn.serverstart()
  local input = table.concat({
    vim.json.encode { jsonrpc = "2.0", id = 1, method = "initialize", params = vim.empty_dict() },
    vim.json.encode { jsonrpc = "2.0", id = 2, method = "tools/call", params = { name = "drive", arguments = arguments } },
  }, "\n") .. "\n"
  local done
  vim.system(
    { "nvim", "-u", "NONE", "-l", bridge },
    { stdin = input, env = { NVIM = address }, cwd = cwd, text = true },
    function(result) done = result end
  )
  vim.wait(20000, function() return done ~= nil end, 20)
  vim.fn.serverstop(address)
  assert(done, "the bridge did not exit")
  for line in vim.gsplit(done.stdout or "", "\n") do
    local ok, message = pcall(vim.json.decode, line)
    if ok and type(message) == "table" and message.id == 2 then
      assert(message.result, vim.inspect(message))
      return vim.json.decode(message.result.content[1].text)
    end
  end
  error("no reply from the bridge: " .. vim.inspect(done))
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

  it("leaves an absolute path alone", function()
    local absolute = vim.fs.normalize(vim.fn.tempname() .. "/y.lua")
    local reply = received { action = "echo", args = { path = absolute } }
    assert.are.equal(absolute, reply.args.path)
  end)
end)
