--- Applying language server edits the way the human wants them: all or
--- nothing, and saved.
---
--- Saved, so the files on disk -- which Claude's own tools read -- match the
--- editor. All or nothing, because unsaved work in a touched buffer is the
--- human's: mixing an edit into it would leave neither version intact.
local position = require "nvim-mcp.lsp.position"
local disk = require "nvim-mcp.lsp.disk"

local M = {}

--- Every file a WorkspaceEdit touches.
function M.files(workspace_edit)
  local seen, out = {}, {}
  local function add(uri)
    local file = vim.fs.normalize(vim.uri_to_fname(uri))
    if not seen[file] then
      seen[file] = true
      out[#out + 1] = file
    end
  end
  for uri in pairs(workspace_edit.changes or {}) do
    add(uri)
  end
  for _, change in ipairs(workspace_edit.documentChanges or {}) do
    if change.textDocument then
      add(change.textDocument.uri)
    elseif change.kind == "rename" then
      add(change.oldUri)
      add(change.newUri)
    elseif change.uri then
      add(change.uri)
    end
  end
  return out
end

local function edit_counts(workspace_edit)
  local counts = {}
  for uri, edits in pairs(workspace_edit.changes or {}) do
    local file = vim.fs.normalize(vim.uri_to_fname(uri))
    counts[file] = (counts[file] or 0) + #edits
  end
  for _, change in ipairs(workspace_edit.documentChanges or {}) do
    if change.textDocument then
      local file = vim.fs.normalize(vim.uri_to_fname(change.textDocument.uri))
      counts[file] = (counts[file] or 0) + #change.edits
    end
  end
  return counts
end

--- The files among `files` whose buffers hold unsaved work.
function M.modified(files)
  local out = {}
  for _, file in ipairs(files) do
    local buffer = position.buffer_for(file)
    if buffer and vim.api.nvim_buf_is_loaded(buffer) and vim.bo[buffer].modified then out[#out + 1] = file end
  end
  return out
end

--- vim.lsp.util.apply_workspace_edit, one change at a time where the edit
--- creates, renames or deletes files. Such a change is the edit's own work on
--- disk: a buffer holding a file it rewrote -- created over an existing one,
--- say -- is read again before the text edits computed for the new file land
--- in it, and the file's `before` (see apply) becomes what the change left.
--- Text edits keep their index, which decides whether their version is
--- checked, and the edit's change annotations, as Neovim's own loop does.
local function apply_changes(workspace_edit, encoding, before)
  local changes, annotations = workspace_edit.documentChanges, workspace_edit.changeAnnotations
  local resources = vim.iter(changes or {}):any(function(change) return change.kind ~= nil end)
  if not resources then return vim.lsp.util.apply_workspace_edit(workspace_edit, encoding) end
  for index, change in ipairs(changes) do
    if change.kind then
      vim.lsp.util.apply_workspace_edit({ documentChanges = { change }, changeAnnotations = annotations }, encoding)
      for _, uri in ipairs { change.uri or change.oldUri, change.newUri } do
        local file = vim.fs.normalize(vim.uri_to_fname(uri))
        local buffer = position.buffer_for(file)
        if buffer then position.refresh(buffer) end
        before[file] = vim.uv.fs_stat(file)
      end
    else
      vim.lsp.util.apply_text_document_edit(change, index, encoding, annotations)
    end
  end
end

--- Waits before each retry of a save, in milliseconds.
---
--- While another process holds a memory-mapped view of a file -- git hashing
--- one over 32 KiB, a virus scanner -- Windows refuses to truncate it, and
--- Neovim reports E212 with "unknown error". The view goes away by itself, so
--- the save is tried again for a moment before it counts as failed.
M.retry_ms = { 50, 100, 200, 400, 800 }

--- disk.write, retried while it fails with E212: whether the save worked,
--- why not, and how many retries it took. The reply carries that count, so
--- the moment something holds a file stays visible and its holder can be
--- caught.
local function save(buffer, before)
  local ok, why, retries = false, nil, 0
  for attempt = 0, #M.retry_ms do
    if attempt > 0 then
      vim.wait(M.retry_ms[attempt])
      retries = attempt
    end
    -- A plain :write, so the human's format-on-save and friends still run;
    -- one that would ask is not made, and is reported instead.
    ok, why = disk.write(buffer, before)
    if ok or not tostring(why):find("E212", 1, true) then break end
  end
  return ok, why, retries
end

function M.apply(workspace_edit, encoding)
  local files = M.files(workspace_edit)
  -- During an edit action every buffer was made current with disk before the
  -- server was asked (nvim-mcp.lsp.disk). One that has changed since --
  -- reloaded here, or edited and saved by another call meanwhile -- changed
  -- while the server was computing, and the edit is aimed at the old text:
  -- applied, it would land at the wrong columns.
  local moved = {}
  for _, file in ipairs(files) do
    local buffer = position.buffer_for(file)
    if buffer then
      local reloaded = position.refresh(buffer)
      if disk.ticks and (reloaded or disk.moved(buffer)) then moved[#moved + 1] = file end
    end
  end
  local dirty = M.modified(files)
  if #dirty > 0 then return { applied = false, reason = "modified", files = dirty } end
  -- Another session's swap file on a touched file. One whose editor is still
  -- running with unsaved work refuses the edit: the file is held there, and a
  -- save would clash with that editor's buffer. One a crashed session left is
  -- there only because of the crash: the edit goes ahead, and the swap file
  -- is deleted once the file is saved, or it would later ask about text that
  -- no longer fits the file.
  local swaps = disk.elsewhere(files)
  local held, holding, seen = {}, {}, {}
  for _, swap in ipairs(swaps) do
    if swap.running and swap.dirty then
      held[#held + 1] = { file = swap.file, swap = swap.swap }
      if not seen[swap.file] then
        seen[swap.file] = true
        holding[#holding + 1] = swap.file
      end
    end
  end
  if #held > 0 then return { applied = false, reason = "swap file", files = holding, swaps = held } end
  if #moved > 0 then return { applied = false, reason = "changed on disk", files = moved } end

  -- What each file was before the edit, so a save never overwrites a change
  -- made since (see disk.write).
  local before = {}
  for _, file in ipairs(files) do
    before[file] = vim.uv.fs_stat(file)
  end

  -- Buffers the edit has to open are the edit's, not the human's: saved, then
  -- unlisted, so a rename across thirty files does not leave thirty entries in
  -- their buffer list. Unlisted rather than deleted keeps the undo history.
  -- One whose save failed stays listed: it holds the edit, unsaved, and the
  -- human has to be able to find it.
  local was_listed = {}
  for _, file in ipairs(files) do
    local buffer = position.buffer_for(file)
    was_listed[file] = buffer ~= nil and vim.bo[buffer].buflisted
  end

  local counts = edit_counts(workspace_edit)
  position.name_natively(vim.tbl_filter(function(file) return counts[file] ~= nil end, files))

  -- Applying can fail partway -- a buffer that is not modifiable, a file that
  -- cannot be renamed -- after earlier files were already edited. Those are
  -- still saved and reported, and the reply says the edit was partial, rather
  -- than an error suggesting nothing happened. So does a file that landed in
  -- its buffer but could not be saved: `changed` lists only what is on disk.
  -- Files it opens are opened without a question about a swap file
  -- (disk.unasked).
  local whole, err = disk.unasked(apply_changes, workspace_edit, encoding, before)

  local changed, failed, saved = {}, {}, {}
  for _, file in ipairs(files) do
    local buffer = position.buffer_for(file)
    local landed, written, retried = whole, true, nil
    if buffer and vim.api.nvim_buf_is_loaded(buffer) then
      if vim.bo[buffer].modified then
        landed = true
        local why, retries
        written, why, retries = save(buffer, before[file])
        retried = retries > 0 and retries or nil
        if not written then
          failed[#failed + 1] = { file = file, edits = counts[file] or 0, error = why, retried = retried }
        end
      end
      saved[file] = landed and not vim.bo[buffer].modified
      if not was_listed[file] and not vim.bo[buffer].modified then vim.bo[buffer].buflisted = false end
      -- The server hears of this change, and computes its next edit from it.
      disk.settle(buffer)
    end
    if landed and written and (counts[file] or vim.uv.fs_stat(file)) then
      changed[#changed + 1] = { file = file, edits = counts[file] or 0, retried = retried }
    end
  end

  -- A crashed session's swap files, on files now saved; see above.
  local deleted = {}
  for _, swap in ipairs(swaps) do
    if not swap.running and saved[swap.file] and os.remove(swap.swap) then
      deleted[#deleted + 1] = { file = swap.file, swap = swap.swap }
    end
  end

  local reply = { applied = whole and #failed == 0 or "partial", changed = changed }
  if not whole then reply.error = tostring(err) end
  if #failed > 0 then reply.failed = failed end
  if #deleted > 0 then reply.deleted_swaps = deleted end
  return reply
end

--- Run `fn` with `workspace/applyEdit` routed through apply(), so an edit a
--- server sends back while executing a command obeys the same rules. Returns
--- what `fn` returns and the result of every edit that arrived.
function M.capturing(encoding, fn)
  local results = {}
  local original = vim.lsp.handlers["workspace/applyEdit"]
  vim.lsp.handlers["workspace/applyEdit"] = function(_, params, ctx)
    local client = ctx and vim.lsp.get_client_by_id(ctx.client_id)
    local result = M.apply(params.edit, client and client.offset_encoding or encoding)
    results[#results + 1] = result
    -- A file that landed but did not save still holds the edit in its buffer,
    -- which is what the server syncs from: applied, as far as it can tell.
    if result.applied == true or (result.applied == "partial" and not result.error) then return { applied = true } end
    if result.reason == "modified" then
      return { applied = false, failureReason = "Unsaved changes in " .. table.concat(result.files, ", ") }
    end
    if result.reason == "swap file" then
      return {
        applied = false,
        failureReason = "Unsaved work in another editor's swap file: " .. table.concat(result.files, ", "),
      }
    end
    if result.reason == "changed on disk" then
      return {
        applied = false,
        failureReason = "Changed on disk while the edit was computed: " .. table.concat(result.files, ", "),
      }
    end
    return { applied = false, failureReason = "Applied only partly: " .. tostring(result.error) }
  end
  local ok, value = pcall(fn)
  vim.lsp.handlers["workspace/applyEdit"] = original
  if not ok then error(value, 0) end
  return value, results
end

return M
