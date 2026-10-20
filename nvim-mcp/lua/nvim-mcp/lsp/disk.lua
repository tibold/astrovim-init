--- Buffers kept in step with the files behind them, without ever asking.
---
--- Claude's own Edit tool, scripts and git write files behind the editor's
--- back. A language server computes an edit from the text the editor last sent
--- it, so an edit computed against a stale buffer lands at the wrong columns
--- once that buffer catches up. And Vim asks before it reloads or overwrites a
--- file that changed under it: a question in the middle of an action holds the
--- tool call until the human answers it. Every route here is one that cannot
--- ask.
local M = {}

--- While an edit action runs, each loaded buffer's changedtick as sync() left
--- it; nil otherwise. edit.apply reads it through moved().
M.ticks = nil

--- Each buffer's file as it was when reload() last found the buffer current
--- with it: buffer -> { name, size, sec, nsec }. A file that still matches
--- needs no second look, so sync() costs one fs_stat per buffer, however
--- often an edit is retried while its server loads.
local seen = {}

--- Files reloaded for an edit whose reply has not said so yet (editing()).
local unreported, reported = {}, {}

--- Whether Vim took `buffer` for a file that did not exist when it was opened
--- ("[New]"). No API says so; `:file` does, after the quoted name. nil when it
--- cannot be asked: `:file` runs in the buffer's window, and text lock -- a
--- call made from an on_lines callback, say -- forbids switching to it.
function M.is_new(buffer)
  local ok, info = pcall(vim.api.nvim_buf_call, buffer, function() return vim.fn.execute "file" end)
  if not ok then return nil end
  local after_name = info:match '.*()"'
  local new = vim.fn.exists "*gettext" == 1 and vim.fn.gettext "[New]" or "[New]"
  return after_name ~= nil and info:find(new, after_name, true) ~= nil
end

--- Run `fn(...)` opening files without a question about another session's
--- swap file. A file another session has unsaved work in -- one that crashed,
--- or another editor with it open -- asks E325 ATTENTION whatever :silent
--- says; bufload(), which lookups and edits open files with, then throws, and
--- with a UI leaves the editor at "Press ENTER". 'shortmess' "A" opens the
--- file regardless, as "Edit anyway" would; what an edit does about the swap
--- file is edit.apply's business (see elsewhere()). Returns what pcall(fn,
--- ...) does.
function M.unasked(fn, ...)
  local shortmess = vim.o.shortmess
  vim.opt.shortmess:append "A"
  local results = vim.F.pack_len(pcall(fn, ...))
  vim.o.shortmess = shortmess
  return unpack(results, 1, results.n)
end

local function same_file(a, b) return vim.fs.normalize(a):lower() == vim.fs.normalize(b):lower() end

--- The directories Neovim may keep `file`'s swap files in: its 'directory'
--- entries, where "." and "./sub" are the file's own directory.
local function swap_dirs(file)
  local dirs = {}
  for _, entry in ipairs(vim.split(vim.o.directory, ",", { trimempty = true })) do
    -- A trailing "//" asks for swap files named after the whole path.
    entry = entry:gsub("[/\\]+$", "")
    if entry == "." then
      entry = vim.fs.dirname(file)
    elseif entry:match "^%.[/\\]" then
      entry = vim.fs.joinpath(vim.fs.dirname(file), entry:sub(3))
    else
      entry = vim.fn.expand(entry)
    end
    if entry ~= "" then dirs[#dirs + 1] = vim.fs.normalize(entry) end
  end
  return dirs
end

--- Other sessions' swap files on any of `files`: a Neovim that crashed, or
--- another editor that has the file open. A swap file's name holds its
--- file's, so candidates are those in swap_dirs() that do; swapinfo() says
--- which file each is for, whether it holds unsaved work, and whether its
--- session is still running. swapfilelist() would do the looking, but on
--- Windows it joins a "//" directory to names that already hold the whole
--- path. Returns { file, swap, running, dirty } for each.
function M.elsewhere(files)
  local listed, out, own = {}, {}, vim.fn.getpid()
  for _, file in ipairs(files) do
    local name = vim.fs.basename(file):lower()
    for _, dir in ipairs(swap_dirs(file)) do
      if not listed[dir] then
        local found = {}
        listed[dir] = {}
        for _, pattern in ipairs { "/*.s??", "/.*.s??" } do
          for _, swap in ipairs(vim.fn.glob(dir .. pattern, true, true)) do
            swap = vim.fs.normalize(swap)
            if not found[swap] then
              found[swap] = true
              table.insert(listed[dir], swap)
            end
          end
        end
      end
      for _, swap in ipairs(listed[dir]) do
        if vim.fs.basename(swap):lower():find(name, 1, true) then
          local info = vim.fn.swapinfo(swap)
          if not info.error and info.pid ~= own and same_file(vim.fn.fnamemodify(info.fname, ":p"), file) then
            out[#out + 1] = { file = file, swap = swap, running = info.pid > 0, dirty = info.dirty == 1 }
          end
        end
      end
    end
  end
  return out
end

--- Reload `buffer` if its file changed on disk. Returns true when it did.
---
--- Only an unmodified buffer: unsaved work is the human's, and an edit refuses
--- a modified buffer anyway. Two routes, because a bare `:checktime` can ask:
---
--- - An ordinary buffer goes through `:checktime` with a FileChangedShell
---   handler that answers "reload", which stops Vim asking. Vim tells the
---   handler whether only the timestamp or the mode moved, the text being the
---   same -- a build step, a checkout, `touch`. That is still read, or the
---   next `:write` would ask whether to overwrite a file "changed since
---   reading it", but it is no change: not reported, and its changedtick is
---   taken as current (settle()). 'autoread' is off meanwhile, because it
---   reloads without consulting the handler.
--- - A buffer Vim took for a new file, whose file now exists, would not: Vim
---   warns that the file "has been created after editing started" and asks,
---   whatever FileChangedShell says, and writing it would ask "Overwrite
---   existing file?". `:edit!` reads the file instead and makes it an ordinary
---   buffer. It also detaches the language servers, those still starting
---   included, which reattach only on FileType through whatever started them,
---   so they are attached again here; that is a no-op for one already back,
---   and sends the others the text.
---
--- A buffer that cannot be looked at now is left for the next call.
function M.reload(buffer)
  if not vim.api.nvim_buf_is_loaded(buffer) or vim.bo[buffer].buftype ~= "" or vim.bo[buffer].modified then
    return false
  end
  local name = vim.api.nvim_buf_get_name(buffer)
  if name == "" then return false end
  local stat = vim.uv.fs_stat(name)
  if not stat or stat.type ~= "file" then return false end
  local file = { name = name, size = stat.size, sec = stat.mtime.sec, nsec = stat.mtime.nsec }
  if vim.deep_equal(seen[buffer], file) then return false end

  local new = M.is_new(buffer)
  if new == nil then return false end
  local tick, checked, same = vim.api.nvim_buf_get_changedtick(buffer), false, false
  if new then
    local clients = vim.lsp.get_clients { bufnr = buffer, _uninitialized = true }
    checked = M.unasked(function()
      vim.api.nvim_buf_call(buffer, function() vim.cmd "silent keepalt keepjumps edit!" end)
    end)
    for _, client in ipairs(clients) do
      if not client:is_stopped() then pcall(vim.lsp.buf_attach_client, buffer, client.id) end
    end
  else
    local group = vim.api.nvim_create_augroup("nvim_mcp_refresh", { clear = true })
    vim.api.nvim_create_autocmd("FileChangedShell", {
      group = group,
      buffer = buffer,
      callback = function()
        same = vim.v.fcs_reason == "time" or vim.v.fcs_reason == "mode"
        vim.v.fcs_choice = "reload"
      end,
    })
    local autoread = vim.go.autoread
    vim.go.autoread = false
    checked = pcall(vim.cmd, "silent checktime " .. buffer)
    vim.go.autoread = autoread
    vim.api.nvim_del_augroup_by_id(group)
  end
  if not vim.api.nvim_buf_is_loaded(buffer) then return false end
  if checked then seen[buffer] = file end
  if vim.api.nvim_buf_get_changedtick(buffer) == tick then return false end
  if same then
    M.settle(buffer)
    return false
  end
  return true
end

--- Reload every loaded buffer whose file changed on disk (see reload). The
--- language servers hear of each reload at once -- Neovim closes and reopens
--- the document with them -- so a request sent after this is computed from
--- the text on disk. Returns the files reloaded.
function M.sync()
  local reloaded = {}
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if M.reload(buffer) then reloaded[#reloaded + 1] = vim.fs.normalize(vim.api.nvim_buf_get_name(buffer)) end
  end
  return reloaded
end

--- Run an edit action's `fn` on buffers current with disk. The reply names the
--- files that had to be reloaded first, as `reloaded`: once, in the first
--- reply that finishes. The bridge retries an edit whose server is still
--- loading, and the attempt that reloaded a file may not be that one.
---
--- Meanwhile `ticks` holds each buffer's changedtick as sync() left it. A
--- buffer the edit touches whose tick has moved by the time it is applied
--- changed while the server was computing the edit -- reloaded, or edited and
--- saved by another call -- and the edit is aimed at the old text (moved()).
function M.editing(fn, ...)
  for _, file in ipairs(M.sync()) do
    if not reported[file] then
      reported[file] = true
      unreported[#unreported + 1] = file
    end
  end
  local outer = M.ticks
  M.ticks = {}
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buffer) then M.ticks[buffer] = vim.api.nvim_buf_get_changedtick(buffer) end
  end
  local results = vim.F.pack_len(pcall(fn, ...))
  M.ticks = outer
  if not results[1] then error(results[2], 0) end
  if #unreported > 0 and type(results[2]) == "table" then
    results[2].reloaded = unreported
    unreported, reported = {}, {}
  end
  return unpack(results, 2, results.n)
end

--- Whether `buffer` changed after sync() made it current, during an edit
--- action. A buffer loaded since then is not in `ticks`, and reads as not.
function M.moved(buffer)
  local tick = M.ticks and M.ticks[buffer]
  return tick ~= nil and vim.api.nvim_buf_is_loaded(buffer) and vim.api.nvim_buf_get_changedtick(buffer) ~= tick
end

--- Take `buffer` as it is now as current: the edit action's own change to it,
--- which the server hears of and computes its next edit from.
function M.settle(buffer)
  if M.ticks and vim.api.nvim_buf_is_loaded(buffer) then M.ticks[buffer] = vim.api.nvim_buf_get_changedtick(buffer) end
end

local function same(a, b) return a.size == b.size and a.mtime.sec == b.mtime.sec and a.mtime.nsec == b.mtime.nsec end

--- The readable part of a `:write` error: "E45: 'readonly' option is set ...".
local function vim_error(err)
  local text = tostring(err)
  return text:match "(E%d+:[^\n]*)" or text
end

--- Save `buffer` with a plain `:write`, so the human's format-on-save and
--- friends still run, but never with a question. Returns true, or false and
--- why it was left unsaved. `before` is the file's fs_stat from before the
--- edit was applied, or nil when there was no file.
---
--- - A file changed on disk since the buffer was read makes `:write` ask
---   "Do you really want to write to it", whatever 'confirm' says. Comparing
---   with `before` catches it first, and the buffer is left unsaved.
--- - 'confirm' turns the other refusals -- a file that appeared since the
---   buffer was opened (E13), a readonly buffer (E45) -- into questions. It is
---   off for the write, so they come back as errors instead.
function M.write(buffer, before)
  local name = vim.api.nvim_buf_get_name(buffer)
  local now = vim.uv.fs_stat(name)
  if before and now and not same(before, now) then
    return false, "the file changed on disk while the edit was applied; the edit is in the buffer, unsaved"
  end

  local confirm = vim.o.confirm
  vim.o.confirm = false
  local ok, err = pcall(vim.api.nvim_buf_call, buffer, function() vim.cmd "silent write" end)
  vim.o.confirm = confirm
  if not ok then return false, vim_error(err) end
  if vim.bo[buffer].modified then return false, "not written; the edit is in the buffer, unsaved" end
  return true
end

return M
