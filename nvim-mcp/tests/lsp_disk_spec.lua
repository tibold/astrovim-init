--- Edits against files that changed on disk behind their buffers: the edit is
--- computed from what is on disk, and nothing on the way asks the human.
local lsp = require "nvim-mcp.lsp"
local disk = require "nvim-mcp.lsp.disk"
local position = require "nvim-mcp.lsp.position"
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local fake = dofile(here .. "/fake_lsp.lua")
local target = dofile(here .. "/target.lua")

local original_notify = vim.notify

--- Change a file behind the editor's back, as Claude's Edit tool or a script
--- does; the later mtime makes sure Neovim can tell.
local function behind(path, lines)
  vim.fn.writefile(lines, path)
  vim.uv.fs_utime(path, os.time() + 10, os.time() + 10)
end

--- Another Neovim with `path` open, keeping its swap files in `swap`. With
--- `keys` typed it holds unsaved work there. Returned once its swap file says
--- so; kill it for a session that crashed.
local function session(swap, path, keys)
  local args = { "nvim", "--headless", "-u", "NONE", "-i", "NONE", "--cmd", "set directory=" .. swap .. "//" }
  if keys then vim.list_extend(args, { "-c", "normal! " .. keys }) end
  args[#args + 1] = path
  local proc = vim.system(args)
  local written = vim.wait(5000, function()
    for _, file in ipairs(vim.fn.glob(swap .. "/*" .. vim.fs.basename(path) .. ".sw?", true, true)) do
      local info = vim.fn.swapinfo(file)
      if not info.error and info.dirty == (keys and 1 or 0) then return true end
    end
    return false
  end, 20)
  if not written then proc:kill(9) end
  assert(written, "the other session never wrote its swap file")
  return proc
end

--- Swap files in a directory of the test's own while `fn` runs, as `fn(dir)`.
local function swapping(fn)
  local swap = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(swap, "p")
  local directory = vim.o.directory
  vim.o.directory = swap .. "//"
  local ok, err = pcall(fn, swap)
  vim.o.directory = directory
  if not ok then error(err, 0) end
end

--- A server that computes renames from the text it was sent, attached to
--- every buffer given. `wrap`, if given, wraps its rename handler. Returns
--- the documents it holds.
local function server(root, buffers, wrap)
  local documents = {}
  local rename = fake.word_rename(documents)
  local client = fake.start(buffers[1], root, {
    capabilities = { renameProvider = true, textDocumentSync = fake.FULL_SYNC },
    documents = documents,
    handlers = { ["textDocument/rename"] = wrap and wrap(rename) or rename },
  })
  for index = 2, #buffers do
    vim.lsp.buf_attach_client(buffers[index], client.id)
  end
  vim.wait(1000, function() return vim.tbl_count(documents) == #buffers end, 10)
  return documents, client
end

describe("disk.sync", function()
  after_each(fake.stop_all)

  it("reloads an unmodified buffer whose file changed, and leaves the rest alone", function()
    local stale, dir = fake.file { "old" }
    local unchanged, dirty = dir .. "/same.txt", dir .. "/dirty.txt"
    vim.fn.writefile({ "same" }, unchanged)
    vim.fn.writefile({ "disk" }, dirty)
    local buffers = { position.buffer(stale), position.buffer(unchanged), position.buffer(dirty) }
    vim.api.nvim_buf_set_lines(buffers[3], 0, -1, false, { "mine" })
    local tick = vim.api.nvim_buf_get_changedtick(buffers[2])
    behind(stale, { "new" })
    behind(dirty, { "disk, changed" })

    local reloaded = disk.sync()
    assert.are.same({ vim.fs.normalize(stale) }, reloaded)
    assert.are.same({ "new" }, vim.api.nvim_buf_get_lines(buffers[1], 0, -1, false))
    assert.are.equal(tick, vim.api.nvim_buf_get_changedtick(buffers[2]))
    assert.are.same({ "mine" }, vim.api.nvim_buf_get_lines(buffers[3], 0, -1, false))
    assert.is_true(vim.bo[buffers[3]].modified)
  end)

  it("reads a file that appeared under a buffer Neovim took for a new one, and tells its server", function()
    local path, dir = fake.file { "local foo = 1" }
    local new = dir .. "/new.txt"
    local a, b = position.buffer(path), vim.fn.bufadd(new)
    vim.fn.bufload(b)
    assert.is_true(disk.is_new(b))
    local documents = server(dir, { a, b })
    behind(new, { "use(foo)" })

    assert.are.same({ vim.fs.normalize(new) }, disk.sync())
    assert.are.same({ "use(foo)" }, vim.api.nvim_buf_get_lines(b, 0, -1, false))
    assert.is_false(disk.is_new(b))
    assert.are.equal(1, #vim.lsp.get_clients { bufnr = b })
    assert.matches("^use%(foo%)\r?\n$", documents[vim.uri_from_bufnr(b)])
  end)

  it("keeps a server that was still starting attached to a buffer it reads afresh", function()
    local _, dir = fake.file { "x" }
    local new = dir .. "/new.txt"
    local b = vim.fn.bufadd(new)
    vim.fn.bufload(b)
    local id = vim.lsp.start({
      name = "slow",
      root_dir = dir,
      cmd = fake.cmd { initialize_delay = 300, capabilities = { textDocumentSync = fake.FULL_SYNC } },
    }, { bufnr = b })
    local client = vim.lsp.get_client_by_id(id)
    assert.is_falsy(client.initialized)
    behind(new, { "x" })

    disk.sync()
    assert.is_true(vim.wait(2000, function() return client.initialized end, 10))
    assert.are.equal(1, #vim.lsp.get_clients { bufnr = b })
  end)

  it("reads a file that appeared under a [New] buffer without asking about a crashed session's swap file", function()
    swapping(function(swap)
      local _, dir = fake.file { "x" }
      local new = dir .. "/new.txt"
      -- A session that was editing new.txt and died: its swap file stays.
      local crashed = session(swap, new, "ix")
      crashed:kill(9)
      crashed:wait()
      -- Opened here before the file existed; the human answered the question then.
      local b = vim.fn.bufadd(new)
      local shortmess = vim.o.shortmess
      vim.opt.shortmess:append "A"
      vim.fn.bufload(b)
      vim.o.shortmess = shortmess
      behind(new, { "use(foo)" })

      local ok, reloaded = pcall(disk.sync)
      assert.is_true(ok, reloaded)
      assert.are.same({ vim.fs.normalize(new) }, reloaded)
      assert.are.same({ "use(foo)" }, vim.api.nvim_buf_get_lines(b, 0, -1, false))
      -- Headless, Neovim answers the question itself: "Open Read-Only".
      assert.is_false(vim.bo[b].readonly)
      assert.are.equal(
        1,
        #vim.fn.glob(swap .. "/*new.txt.swp", true, true),
        "the swap file is the human's to recover from"
      )
      vim.api.nvim_buf_delete(b, { force = true })
    end)
  end)

  it("takes a rewrite with the same text as no change", function()
    -- A build step, a checkout or `touch` rewrites a file with what it held.
    local path = fake.file { "same" }
    local b = position.buffer(path)
    behind(path, { "same" })

    assert.are.same({}, disk.sync())
    assert.are.same({ "same" }, vim.api.nvim_buf_get_lines(b, 0, -1, false))
    -- Read, all the same: a save would otherwise ask whether to overwrite a
    -- file "changed since reading it". Headless, it would wait for an answer.
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "edited" })
    assert.is_true(disk.write(b, vim.uv.fs_stat(path)))
    assert.are.same({ "edited" }, vim.fn.readfile(path))
  end)

  it("notices every change to a file, not just the first", function()
    local path = fake.file { "one" }
    local b = position.buffer(path)
    behind(path, { "two" })
    assert.are.same({ vim.fs.normalize(path) }, disk.sync())
    assert.are.same({}, disk.sync())
    vim.fn.writefile({ "three" }, path)
    vim.uv.fs_utime(path, os.time() + 20, os.time() + 20)
    assert.are.same({ vim.fs.normalize(path) }, disk.sync())
    assert.are.same({ "three" }, vim.api.nvim_buf_get_lines(b, 0, -1, false))
  end)

  it("answers while text is locked, and catches up on the next call", function()
    -- Inside a buffer's on_lines callback, `:file` (which tells a [New]
    -- buffer) cannot run; a call that lands there must still answer.
    local path = fake.file { "old" }
    local b = position.buffer(path)
    behind(path, { "new" })
    local scratch = vim.api.nvim_create_buf(true, false)
    local result
    vim.api.nvim_buf_attach(scratch, false, {
      on_lines = function()
        result = { pcall(disk.sync) }
        return true
      end,
    })
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "x" })
    assert.is_true(result[1], result[2])

    assert.are.same({ vim.fs.normalize(path) }, disk.sync())
    assert.are.same({ "new" }, vim.api.nvim_buf_get_lines(b, 0, -1, false))
    vim.api.nvim_buf_delete(scratch, { force = true })
  end)
end)

describe("disk.editing", function()
  it("reports files reloaded for an attempt that did not finish with the next one that does", function()
    -- The bridge retries an edit whose server was still loading; the first
    -- attempt reloaded the file, so the retry finds nothing left to reload.
    local path = fake.file { "old" }
    position.buffer(path)
    behind(path, { "new" })

    local ok = pcall(disk.editing, function() error { not_ready = true } end)
    assert.is_false(ok)
    local reply = disk.editing(function() return { applied = true } end)
    assert.are.same({ vim.fs.normalize(path) }, reply.reloaded)
    assert.is_nil(disk.editing(function() return { applied = true } end).reloaded, "reported once")
  end)
end)

describe("a file another session has unsaved work in", function()
  local edit = require "nvim-mcp.lsp.edit"
  local function rename_foo(path)
    return { changes = { [vim.uri_from_fname(path)] = { { range = fake.range(0, 4, 7), newText = "bar" } } } }
  end

  --- `fn(swap, path)` with `path` open in another session, which `keys`
  --- leave with unsaved work; `crash` kills it first.
  local function elsewhere(keys, crash, fn)
    swapping(function(swap)
      local path = fake.file { "use(foo)" }
      local other = session(swap, path, keys)
      if crash then
        other:kill(9)
        other:wait()
      end
      local ok, err = pcall(fn, swap, path)
      other:kill(9)
      local buffer = position.buffer_for(path)
      if buffer then vim.api.nvim_buf_delete(buffer, { force = true }) end
      if not ok then error(err, 0) end
    end)
  end

  it("opens for a lookup without asking", function()
    -- Neovim asks E325 ATTENTION, and with a UI leaves the editor at "Press
    -- ENTER" afterwards; headless, the load throws.
    elsewhere("ix", true, function(_, path)
      local ok, buffer = pcall(position.buffer, path)
      assert.is_true(ok, buffer)
      assert.are.same({ "use(foo)" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
    end)
  end)

  it("edits a file a crashed session left unsaved work in, and deletes that swap file", function()
    -- A crash is the only reason it is still there; left, it would ask about
    -- text that no longer fits the file.
    elsewhere("ix", true, function(swap, path)
      local left = vim.fn.glob(swap .. "/*a.txt.swp", true, true)[1]
      assert.is_truthy(left)
      local reply = edit.apply(rename_foo(path), "utf-16")
      assert.is_true(reply.applied, vim.inspect(reply))
      assert.are.same({ "use(bar)" }, vim.fn.readfile(path))
      assert.is_nil(vim.uv.fs_stat(left))
      assert.are.same({ { file = vim.fs.normalize(path), swap = vim.fs.normalize(left) } }, reply.deleted_swaps)
    end)
  end)

  it("deletes a crashed session's swap file that holds nothing, too", function()
    -- Neovim deletes one itself when it opens the file, but not when told
    -- not to ask about swap files, as edits are.
    elsewhere(nil, true, function(swap, path)
      local left = vim.fn.glob(swap .. "/*a.txt.swp", true, true)[1]
      local reply = edit.apply(rename_foo(path), "utf-16")
      assert.is_true(reply.applied, vim.inspect(reply))
      assert.is_nil(vim.uv.fs_stat(left))
    end)
  end)

  it("keeps a crashed session's swap file when the edit could not save the file", function()
    elsewhere("ix", true, function(swap, path)
      local left = vim.fn.glob(swap .. "/*a.txt.swp", true, true)[1]
      vim.uv.fs_chmod(path, tonumber("444", 8))
      local reply = edit.apply(rename_foo(path), "utf-16")
      vim.uv.fs_chmod(path, tonumber("644", 8))
      assert.are.equal(1, #(reply.failed or {}), vim.inspect(reply))
      assert.is_truthy(vim.uv.fs_stat(left))
      assert.is_nil(reply.deleted_swaps)
    end)
  end)

  it("refuses an edit when another editor still open holds unsaved work in a file it touches", function()
    elsewhere("ix", false, function(swap, path)
      local reply = edit.apply(rename_foo(path), "utf-16")
      assert.is_false(reply.applied, vim.inspect(reply))
      assert.are.equal("swap file", reply.reason)
      assert.are.same({ vim.fs.normalize(path) }, reply.files)
      assert.are.equal(1, #reply.swaps)
      assert.are.equal(vim.fs.normalize(path), reply.swaps[1].file)
      assert.are.equal(swap, vim.fs.dirname(reply.swaps[1].swap))
      assert.is_truthy(vim.uv.fs_stat(reply.swaps[1].swap), "that editor's swap file")
      assert.are.same({ "use(foo)" }, vim.fn.readfile(path))
    end)
  end)

  it("edits a file another editor has open without unsaved work, without asking", function()
    elsewhere(nil, false, function(swap, path)
      local held = vim.fn.glob(swap .. "/*a.txt.swp", true, true)[1]
      local reply = edit.apply(rename_foo(path), "utf-16")
      assert.is_true(reply.applied, vim.inspect(reply))
      assert.is_nil(reply.failed)
      assert.are.same({ "use(bar)" }, vim.fn.readfile(path))
      assert.is_truthy(vim.uv.fs_stat(held), "the other editor holds its swap file")
      assert.is_nil(reply.deleted_swaps)
    end)
  end)

  it("tells a server whose edit it refused why", function()
    elsewhere("ix", false, function(_, path)
      local answer
      edit.capturing(
        "utf-16",
        function()
          answer = vim.lsp.handlers["workspace/applyEdit"](nil, { edit = rename_foo(path) }, { client_id = -1 })
        end
      )
      assert.is_false(answer.applied)
      assert.matches("swap file", answer.failureReason)
    end)
  end)
end)

describe("edits after a file changed on disk", function()
  before_each(function()
    vim.notify = function() end
  end)
  after_each(function()
    vim.notify = original_notify
    fake.stop_all()
  end)

  it("computes a rename from the new text of a buffer that went stale", function()
    -- The bug: the server renamed in the text it had been sent, the buffer
    -- caught up with disk only afterwards, and the edit landed at the
    -- columns of the old text.
    local path, dir = fake.file { "local foo = 1", "print(foo)" }
    local other = dir .. "/b.txt"
    vim.fn.writefile({ "use(foo)" }, other)
    server(dir, { position.buffer(path), position.buffer(other) })
    behind(other, { "-- moved down", "    use(foo)" })

    local reply = lsp.rename { path = path, line = 1, symbol = "foo", new_name = "bar" }
    assert.is_true(reply.applied, vim.inspect(reply))
    assert.are.same({ "local bar = 1", "print(bar)" }, vim.fn.readfile(path))
    assert.are.same({ "-- moved down", "    use(bar)" }, vim.fn.readfile(other))
    assert.are.same({ vim.fs.normalize(other) }, reply.reloaded)
  end)

  it("renames in a buffer Neovim took for a new file once that file exists", function()
    local path, dir = fake.file { "local foo = 1" }
    local new = dir .. "/new.txt"
    local b = vim.fn.bufadd(new)
    vim.fn.bufload(b)
    server(dir, { position.buffer(path), b })
    behind(new, { "use(foo)" })

    local reply = lsp.rename { path = new, line = 1, symbol = "foo", new_name = "bar" }
    assert.is_true(reply.applied, vim.inspect(reply))
    assert.are.same({ "use(bar)" }, vim.fn.readfile(new))
    assert.are.same({ "local bar = 1" }, vim.fn.readfile(path))
    assert.is_nil(reply.failed)
  end)

  it("refuses an edit when a file it touches changed while the server computed it", function()
    local path, dir = fake.file { "local foo = 1" }
    local other = dir .. "/b.txt"
    vim.fn.writefile({ "use(foo)" }, other)
    server(dir, { position.buffer(path), position.buffer(other) }, function(rename)
      return function(params)
        -- A script writes while the request is out; the edit is computed
        -- from the text before.
        behind(other, { "-- moved down", "    use(foo)" })
        return rename(params)
      end
    end)

    local reply = lsp.rename { path = path, line = 1, symbol = "foo", new_name = "bar" }
    assert.is_false(reply.applied, vim.inspect(reply))
    assert.are.equal("changed on disk", reply.reason)
    assert.are.same({ vim.fs.normalize(other) }, reply.files)
    assert.are.same({ "local foo = 1" }, vim.fn.readfile(path))
    assert.are.same({ "-- moved down", "    use(foo)" }, vim.fn.readfile(other))
  end)

  it("refuses an edit when a touched buffer was changed and saved while the server computed it", function()
    -- Nothing to reload: another call, or an autosave, changed the buffer and
    -- wrote it, so buffer and disk agree, but not with the text the server
    -- computed from.
    local path, dir = fake.file { "local foo = 1" }
    local other = dir .. "/b.txt"
    vim.fn.writefile({ "use(foo)" }, other)
    server(dir, { position.buffer(path), position.buffer(other) }, function(rename)
      return function(params)
        local result = rename(params)
        local b = position.buffer_for(other)
        vim.api.nvim_buf_set_lines(b, 0, 0, false, { "-- moved down" })
        vim.api.nvim_buf_call(b, function() vim.cmd "silent write" end)
        return result
      end
    end)

    local reply = lsp.rename { path = path, line = 1, symbol = "foo", new_name = "bar" }
    assert.is_false(reply.applied, vim.inspect(reply))
    assert.are.equal("changed on disk", reply.reason)
    assert.are.same({ vim.fs.normalize(other) }, reply.files)
    assert.are.same({ "local foo = 1" }, vim.fn.readfile(path))
    assert.are.same({ "-- moved down", "use(foo)" }, vim.fn.readfile(other))
  end)

  it("applies an edit when a touched file was rewritten with the same text while the server computed it", function()
    local path, dir = fake.file { "local foo = 1" }
    local other = dir .. "/b.txt"
    vim.fn.writefile({ "use(foo)" }, other)
    server(dir, { position.buffer(path), position.buffer(other) }, function(rename)
      return function(params)
        behind(other, { "use(foo)" })
        return rename(params)
      end
    end)

    local reply = lsp.rename { path = path, line = 1, symbol = "foo", new_name = "bar" }
    assert.is_true(reply.applied, vim.inspect(reply))
    assert.is_nil(reply.failed)
    assert.are.same({ "local bar = 1" }, vim.fn.readfile(path))
    assert.are.same({ "use(bar)" }, vim.fn.readfile(other))
  end)

  it("applies the edits of a code action that sends several, each after the last was saved", function()
    -- Each workspace/applyEdit lands and is saved before the server sends
    -- the next, computed from the text after it: not a change behind its back.
    local path, dir = fake.file { "local foo = 1" }
    local b = position.buffer(path)
    local change = function(from, to, text)
      return { changes = { [vim.uri_from_fname(path)] = { { range = fake.range(0, from, to), newText = text } } } }
    end
    local answers = {}
    fake.start(b, dir, {
      capabilities = { codeActionProvider = true, executeCommandProvider = { commands = { "twice" } } },
      handlers = {
        ["textDocument/codeAction"] = function()
          return { { title = "Twice", command = { title = "Twice", command = "twice" } } }
        end,
        ["workspace/executeCommand"] = function(_, dispatchers)
          answers[#answers + 1] = dispatchers.server_request("workspace/applyEdit", { edit = change(6, 9, "bar") })
          answers[#answers + 1] = dispatchers.server_request("workspace/applyEdit", { edit = change(0, 5, "const") })
          return vim.NIL
        end,
      },
    })

    local reply = lsp.code_action { path = path, line = 1, title = "Twice" }
    assert.is_truthy(reply.applied ~= false, vim.inspect(reply))
    assert.are.same({ "const bar = 1" }, vim.fn.readfile(path))
    assert.are.equal(2, #answers)
    for _, answer in ipairs(answers) do
      assert.is_true(answer.applied, vim.inspect(answers))
    end
  end)
end)

describe("disk.write", function()
  it("leaves a buffer unsaved rather than overwrite a change made since the edit began", function()
    -- Neovim would ask "Do you really want to write to it", whatever
    -- 'confirm' says; a test that got this wrong would hang there.
    local path = fake.file { "one" }
    local buffer = position.buffer(path)
    local before = vim.uv.fs_stat(path)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "edited" })
    behind(path, { "someone else's" })

    local saved, why = disk.write(buffer, before)
    assert.is_false(saved)
    assert.matches("changed on disk", why)
    assert.are.same({ "someone else's" }, vim.fn.readfile(path))
    assert.is_true(vim.bo[buffer].modified)
  end)

  it("writes, and restores 'confirm'", function()
    local path = fake.file { "one" }
    local buffer = position.buffer(path)
    local before = vim.uv.fs_stat(path)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "edited" })
    vim.o.confirm = true
    local saved = disk.write(buffer, before)
    local confirm = vim.o.confirm
    vim.o.confirm = false
    assert.is_true(saved)
    assert.is_true(confirm)
    assert.are.same({ "edited" }, vim.fn.readfile(path))
  end)
end)

--- In an editor with a UI, where Neovim does ask: the incident's own shape.
--- A fake server there, with 'confirm' on as the human's config has it. Not
--- lsp.setup(): its readiness tracking would count a server that never
--- reports progress as starting for ten seconds. `...` is the fake server's
--- file, the project directory and the files to attach it to; the last is
--- shown in the window.
local SETUP = [[
local fake_path, root = ...
local files = { select(3, ...) }
local fake = dofile(fake_path)
vim.o.confirm = true
local buffers = {}
for index, file in ipairs(files) do
  if index == #files then
    vim.cmd.edit(vim.fn.fnameescape(file))
    buffers[index] = vim.api.nvim_get_current_buf()
  else
    buffers[index] = vim.fn.bufadd(file)
    vim.fn.bufload(buffers[index])
  end
end
_G.documents = {}
local client = fake.start(buffers[1], root, {
  capabilities = { renameProvider = true, textDocumentSync = fake.FULL_SYNC },
  documents = _G.documents,
  handlers = { ["textDocument/rename"] = fake.word_rename(_G.documents) },
})
for index = 2, #buffers do
  vim.lsp.buf_attach_client(buffers[index], client.id)
end
vim.wait(1000, function() return vim.tbl_count(_G.documents) == #buffers end, 10)
return vim.tbl_count(_G.documents)
]]

describe("edits in an editor with a UI", function()
  local editor

  before_each(function() editor = target.start() end)
  after_each(function() editor.stop() end)

  it("renames in a buffer Neovim took for a new file once that file exists, without asking", function()
    -- What happened: the buffer was opened before the file existed, a script
    -- then created it, and the rename's save asked "Overwrite existing
    -- file?". Reloading it the plain way would ask too ("created after
    -- editing started").
    local path, dir = fake.file { "local foo = 1" }
    local new = dir .. "/new.txt"
    assert.are.equal(2, editor.exec(SETUP, here .. "/fake_lsp.lua", dir, path, new))
    behind(new, { "use(foo)" })

    local done, prompts = editor.run(
      'return require("nvim-mcp.lsp").rename(...)',
      { { path = new, line = 1, symbol = "foo", new_name = "bar" } }
    )
    assert.are.same({}, prompts)
    assert.is_truthy(done and done.ok, vim.inspect(done))
    assert.is_true(done.result.applied, vim.inspect(done.result))
    assert.is_nil(done.result.failed)
    assert.are.same({ "use(bar)" }, vim.fn.readfile(new))
    assert.are.same({ "local bar = 1" }, vim.fn.readfile(path))
    assert.is_false(target.at_prompt(editor.mode()))
  end)

  it("reports a save that would ask, instead of asking", function()
    -- With 'confirm' on, writing a readonly buffer asks whether to write
    -- anyway.
    local path, dir = fake.file { "local foo = 1" }
    local other = dir .. "/b.txt"
    vim.fn.writefile({ "use(foo)" }, other)
    assert.are.equal(2, editor.exec(SETUP, here .. "/fake_lsp.lua", dir, other, path))
    editor.exec("vim.bo[vim.fn.bufnr(...)].readonly = true", other)

    local done, prompts = editor.run(
      'return require("nvim-mcp.lsp").rename(...)',
      { { path = path, line = 1, symbol = "foo", new_name = "bar" } }
    )
    assert.are.same({}, prompts)
    assert.is_truthy(done and done.ok, vim.inspect(done))
    assert.is_true(done.result.applied, vim.inspect(done.result))
    assert.are.same({ "local bar = 1" }, vim.fn.readfile(path))
    assert.are.same({ "use(foo)" }, vim.fn.readfile(other))
    assert.are.equal(1, #done.result.failed)
    assert.are.equal(vim.fs.normalize(other), vim.fs.normalize(done.result.failed[1].file))
    assert.matches("^E45:", done.result.failed[1].error)
  end)
end)
