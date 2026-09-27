local lsp = require "nvim-mcp.lsp"
local mcp = require "nvim-mcp"
local ready = require "nvim-mcp.lsp.ready"
local position = require "nvim-mcp.lsp.position"
local fake = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/fake_lsp.lua")

local LINES = { "local foo = 1", "print(foo)" }

--- A fake server answering definition and rename, registered through setup so
--- the actions are guarded and readiness is tracked, as in the editor.
local function server(handlers)
  mcp.tools, mcp.order = {}, {}
  lsp.setup()
  local path, dir = fake.file(LINES)
  local buffer = position.buffer(path)
  local uri = vim.uri_from_fname(path)
  local client = fake.start(buffer, dir, {
    capabilities = { definitionProvider = true, renameProvider = true },
    handlers = vim.tbl_extend("force", {
      ["textDocument/definition"] = function() return { uri = uri, range = fake.range(0, 6, 9) } end,
      ["textDocument/rename"] = function()
        return { changes = { [uri] = { { range = fake.range(0, 6, 9), newText = "bar" } } } }
      end,
    }, handlers or {}),
  })
  return path, client
end

local function progress(client, token, value)
  vim.api.nvim_exec_autocmds("LspProgress", {
    pattern = value.kind,
    data = { client_id = client.id, params = { token = token, value = value } },
  })
end

local function call(name, args, opts)
  local result = mcp.invoke(name, args, opts)
  assert.is_true(result.ok, result.message)
  return vim.json.decode(result.content[1].text)
end

describe("readiness", function()
  before_each(function() ready.FIRST_PROGRESS_MS = 0 end)

  after_each(function()
    ready.FIRST_PROGRESS_MS = 10000
    fake.stop_all()
    ready.final, ready.proceeded = false, nil
  end)

  it("counts a fresh server as busy until it reports progress, for a while at most", function()
    ready.FIRST_PROGRESS_MS = 400
    local _, client = server()
    assert.matches("no progress", ready.busy(client) or "")
    progress(client, "load", { kind = "begin", title = "Loading Testbed.sln" })
    assert.are.equal("Loading Testbed.sln", ready.busy(client))
    progress(client, "load", { kind = "end" })
    vim.wait(ready.SETTLE_MS + 100)
    assert.is_nil(ready.busy(client))

    local _, quiet = server()
    vim.wait(500)
    assert.is_nil(ready.busy(quiet), "a server that never reports progress waits once, at most")
  end)

  it("counts a server with progress in flight as busy, and ready once it settles", function()
    local _, client = server()
    assert.is_nil(ready.busy(client))
    progress(client, "idx", { kind = "begin", title = "Indexing" })
    progress(client, "idx", { kind = "report", message = "5/21 (core)" })
    assert.are.equal("Indexing: 5/21 (core)", ready.busy(client))
    progress(client, "idx", { kind = "end" })
    assert.is_truthy(ready.busy(client), "a gap between stages is not the end of loading")
    vim.wait(ready.SETTLE_MS + 100)
    assert.is_nil(ready.busy(client))
  end)

  it("trusts rust-analyzer's quiescent status over its progress", function()
    local _, client = server()
    local handler = client.handlers["experimental/serverStatus"]
    handler(nil, { health = "ok", quiescent = false }, { client_id = client.id }, {})
    assert.are.equal("loading the workspace", ready.busy(client))
    handler(nil, { health = "ok", quiescent = true }, { client_id = client.id }, {})
    -- flycheck runs under progress after loading; lookups answer fine meanwhile
    progress(client, "flycheck", { kind = "begin", title = "cargo clippy" })
    assert.is_nil(ready.busy(client))
  end)

  it("keeps a server's own status handler running", function()
    local seen
    local path, dir = fake.file(LINES)
    local buffer = position.buffer(path)
    ready.setup()
    local id = vim.lsp.start({
      name = "own_handler",
      root_dir = dir,
      cmd = fake.cmd {},
      handlers = { ["experimental/serverStatus"] = function(_, result) seen = result end },
    }, { bufnr = buffer })
    local client = vim.lsp.get_client_by_id(id)
    vim.wait(1000, function() return client.initialized end, 10)
    client.handlers["experimental/serverStatus"](nil, { quiescent = false }, { client_id = id }, {})
    assert.are.same({ quiescent = false }, seen)
    assert.is_truthy(ready.busy(client))
  end)

  it("replies not_ready from a lookup instead of an empty answer", function()
    local path, client = server()
    progress(client, "idx", { kind = "begin", title = "Indexing" })
    local reply = call("definition", { path = path, line = 2, symbol = "foo" })
    assert.are.same({ not_ready = true, server = "fake", status = "Indexing" }, reply)
  end)

  it("lets the final attempt look up anyway, and says the server was loading", function()
    local path, client = server()
    progress(client, "idx", { kind = "begin", title = "Indexing" })
    local reply = call("definition", { path = path, line = 2, symbol = "foo" }, { final = true })
    assert.are.equal(1, reply.count)
    assert.are.equal("fake was Indexing", reply.loading)
  end)

  it("never applies an edit against a server still loading, final or not", function()
    local path, client = server()
    progress(client, "idx", { kind = "begin", title = "Indexing" })
    local reply = call("rename", { path = path, line = 1, symbol = "foo", new_name = "bar" }, { final = true })
    assert.is_true(reply.not_ready)
    assert.are.same(LINES, vim.fn.readfile(path))
  end)

  it("treats content modified as not ready rather than failed", function()
    local path = server {
      ["textDocument/definition"] = function() return fake.failure(-32801, "content modified") end,
    }
    local reply = call("definition", { path = path, line = 2, symbol = "foo" })
    assert.is_true(reply.not_ready)
    assert.matches("content modified", reply.status)
  end)

  it("leaves a notice up while Claude waits, and takes it down after", function()
    local path, client = server()
    progress(client, "idx", { kind = "begin", title = "Indexing" })
    call("definition", { path = path, line = 2, symbol = "foo" })
    local notice = require "nvim-mcp.lsp.notice"
    assert.is_truthy(notice.lingering and notice.lingering.shown)
    vim.wait(ready.NOTICE_MS + 300, function() return notice.lingering == nil end, 20)
    assert.is_nil(notice.lingering)
  end)
end)
