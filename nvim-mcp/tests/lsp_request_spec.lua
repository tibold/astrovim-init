local request = require "nvim-mcp.lsp.request"
local notice = require "nvim-mcp.lsp.notice"
local position = require "nvim-mcp.lsp.position"
local ready = require "nvim-mcp.lsp.ready"
local fake = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/fake_lsp.lua")

local function with_server(opts)
  local path, dir = fake.file { "local foo = 1" }
  local buffer = position.buffer(path)
  local client = fake.start(buffer, dir, opts)
  return buffer, client
end

local HOVER = "textDocument/hover"
local function params(buffer) return position.params(buffer, 1, 7, "utf-16") end

describe("request.timeout_ms", function()
  it("defaults to five seconds and clamps", function()
    assert.are.equal(5000, request.timeout_ms {})
    assert.are.equal(30000, request.timeout_ms { timeout = 600 })
    assert.are.equal(100, request.timeout_ms { timeout = 0 })
    assert.are.equal(1500, request.timeout_ms { timeout = 1.5 })
  end)
end)

describe("request.clients", function()
  after_each(fake.stop_all)

  it("fails at once, naming the filetype, when nothing is attached", function()
    local buffer = position.buffer(fake.file({ "x" }, "plain.txt"))
    local started = vim.uv.now()
    local ok, err = pcall(request.clients, buffer, HOVER, 5000)
    assert.is_false(ok)
    assert.are.equal(-32603, err.code)
    assert.matches("No language server is attached", err.message)
    assert.matches('filetype "text"', err.message)
    assert.is_true(vim.uv.now() - started < 1000, "must not wait for a server that is not coming")
  end)

  it("says not ready while a configured server has yet to attach to a buffer it just loaded", function()
    -- lua_ls decides its root asynchronously, and rustaceanvim waits on cargo
    -- metadata: right after a buffer loads, nothing is attached, yet one is
    -- on its way. The bridge polls on not_ready; the editor does not wait.
    vim.filetype.add { extension = { latefake = "latefake" } }
    vim.lsp.config("late_fake", {
      filetypes = { "latefake" },
      cmd = fake.cmd { capabilities = { hoverProvider = true } },
      root_dir = function(_, on_dir)
        vim.defer_fn(function() on_dir(vim.fn.getcwd()) end, 200)
      end,
    })
    vim.lsp.enable "late_fake"
    local buffer = position.buffer(fake.file({ "x" }, "a.latefake"))
    local started = vim.uv.now()
    local ok, err = pcall(request.clients, buffer, HOVER, 3000)
    assert.is_false(ok)
    assert.is_true(err.not_ready, vim.inspect(err))
    assert.is_true(vim.uv.now() - started < 100, "the editor waited")

    vim.wait(3000, function() return pcall(request.clients, buffer, HOVER, 3000) end, 20)
    local found = request.clients(buffer, HOVER, 3000)
    vim.lsp.enable("late_fake", false)
    assert.are.equal("late_fake", found[1].name)
  end)

  it("says not ready while a server is attached but still starting", function()
    -- rustaceanvim starts rust-analyzer with vim.lsp.start, not a config.
    local path, dir = fake.file { "x" }
    local buffer = position.buffer(path)
    vim.lsp.start({
      name = "slow_start",
      root_dir = dir,
      cmd = fake.cmd { capabilities = { hoverProvider = true }, initialize_delay = 500 },
    }, { bufnr = buffer })
    local ok, err = pcall(request.clients, buffer, HOVER, 3000)
    assert.is_false(ok)
    assert.are.same({ true, "slow_start", "starting" }, { err.not_ready, err.server, err.status })

    vim.wait(3000, function() return pcall(request.clients, buffer, HOVER, 3000) end, 20)
    assert.are.equal("slow_start", request.clients(buffer, HOVER, 3000)[1].name)
  end)

  it("names a configured server that never attached once the wait is over", function()
    vim.filetype.add { extension = { neverfake = "neverfake" } }
    vim.lsp.config("never_fake", {
      filetypes = { "neverfake" },
      cmd = fake.cmd {},
      root_dir = function() end, -- never calls on_dir: no root here
    })
    vim.lsp.enable "never_fake"
    local buffer = position.buffer(fake.file({ "x" }, "a.neverfake"))
    assert.is_true(select(2, pcall(request.clients, buffer, HOVER, 1000)).not_ready)

    ready.final = true
    local ok, err = pcall(request.clients, buffer, HOVER, 1000)
    ready.final = false
    vim.lsp.enable("never_fake", false)
    assert.is_false(ok)
    assert.is_nil(err.not_ready)
    assert.matches("never_fake is configured", err.message)
  end)

  it("does not wait on a buffer the human already had open", function()
    vim.filetype.add { extension = { neverfake = "neverfake" } }
    vim.lsp.config("never_fake", { filetypes = { "neverfake" }, cmd = fake.cmd {}, root_dir = function() end })
    local buffer = position.buffer(fake.file({ "x" }, "b.neverfake"))
    ready.loaded[buffer] = nil
    local ok, err = pcall(request.clients, buffer, HOVER, 1000)
    assert.is_false(ok)
    assert.is_nil(err.not_ready)
  end)

  it("names the servers when none supports the method", function()
    local buffer = with_server { capabilities = {} }
    local ok, err = pcall(request.clients, buffer, HOVER, 1000)
    assert.is_false(ok)
    assert.matches("fake: no server here supports textDocument/hover", err.message)
  end)

  it("returns the servers that support the method", function()
    local buffer = with_server { capabilities = { hoverProvider = true } }
    local found = request.clients(buffer, HOVER, 1000)
    assert.are.equal(1, #found)
    assert.are.equal("fake", found[1].name)
  end)
end)

describe("request.send", function()
  after_each(fake.stop_all)

  it("returns the result", function()
    local buffer, client = with_server {
      capabilities = { hoverProvider = true },
      handlers = { [HOVER] = function() return { contents = "hi" } end },
    }
    local result, timed_out = request.send(client, HOVER, params(buffer), buffer, 1000)
    assert.are.same({ contents = "hi" }, result)
    assert.is_false(timed_out)
  end)

  it("maps a null result to nil", function()
    local buffer, client = with_server { capabilities = { hoverProvider = true } }
    local result = request.send(client, HOVER, params(buffer), buffer, 1000)
    assert.is_nil(result)
  end)

  it("reports a timeout rather than throwing", function()
    local buffer, client = with_server {
      capabilities = { hoverProvider = true },
      handlers = { [HOVER] = function() return fake.NEVER end },
    }
    local result, timed_out = request.send(client, HOVER, params(buffer), buffer, 100)
    assert.is_nil(result)
    assert.is_true(timed_out)
  end)

  it("turns a server error into a readable one", function()
    local buffer, client = with_server {
      capabilities = { hoverProvider = true },
      handlers = { [HOVER] = function() return fake.failure(-32603, "index out of bounds") end },
    }
    local ok, err = pcall(request.send, client, HOVER, params(buffer), buffer, 1000)
    assert.is_false(ok)
    assert.are.equal(-32603, err.code)
    assert.matches("fake: index out of bounds", err.message)
  end)

  it("passes content modified through as an error on the final attempt", function()
    local buffer, client = with_server {
      capabilities = { hoverProvider = true },
      handlers = { [HOVER] = function() return fake.failure(-32801, "content modified") end },
    }
    ready.final = true
    local ok, err = pcall(request.send, client, HOVER, params(buffer), buffer, 1000)
    ready.final = false
    assert.is_false(ok)
    assert.is_nil(err.not_ready)
    assert.matches("fake: content modified", err.message)
  end)
end)

describe("notice", function()
  local function text_of(handle)
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(handle.shown.window), 0, -1, false)[1]
  end

  it("shows immediately without a delay, and closes", function()
    local handle = notice.open("Claude · LSP rename a → b (fake)…", 0)
    assert.is_truthy(handle.shown)
    assert.matches("rename a → b", text_of(handle))
    assert.are.equal(handle, notice.active)
    local window = handle.shown.window
    notice.close(handle)
    assert.is_false(vim.api.nvim_win_is_valid(window))
    assert.is_nil(notice.active)
  end)

  it("stands out: its own border and text highlights, overridable", function()
    local handle = notice.open("x", 0)
    local winhighlight = vim.wo[handle.shown.window].winhighlight
    notice.close(handle)
    assert.matches("FloatBorder:NvimMcpNoticeBorder", winhighlight)
    assert.matches("NormalFloat:NvimMcpNotice", winhighlight)
    assert.is_number(vim.api.nvim_get_hl(0, { name = "NvimMcpNoticeBorder", link = false }).fg)
    assert.is_true(vim.api.nvim_get_hl(0, { name = "NvimMcpNotice", link = false }).bold)
  end)

  it("waits out the delay, and never shows if closed first", function()
    local late = notice.open("late", 50)
    assert.is_nil(late.shown)
    vim.wait(500, function() return late.shown ~= nil end, 10)
    assert.is_truthy(late.shown)
    notice.close(late)

    local early = notice.open("early", 50)
    notice.close(early)
    vim.wait(150)
    assert.is_nil(early.shown)
  end)

  it("shows a delayed notice while a slow request blocks", function()
    local buffer, client = with_server {
      capabilities = { hoverProvider = true },
      handlers = {
        [HOVER] = function() return fake.NEVER end,
      },
    }
    local seen = false
    notice.during("slow", 50, function()
      local timer = vim.uv.new_timer()
      timer:start(200, 0, vim.schedule_wrap(function()
        seen = notice.active ~= nil and notice.active.shown ~= nil
        timer:close()
      end))
      request.send(client, HOVER, params(buffer), buffer, 400)
    end)
    assert.is_true(seen)
    fake.stop_all()
  end)

  it("closes and rethrows when the work fails", function()
    local ok, err = pcall(notice.during, "x", 0, function() error { code = -32603, message = "boom" } end)
    assert.is_false(ok)
    assert.are.equal("boom", err.message)
    assert.is_nil(notice.active)
  end)

  it("passes every return value through", function()
    local a, b = notice.during("x", 0, function() return 1, true end)
    assert.are.equal(1, a)
    assert.is_true(b)
  end)
end)
