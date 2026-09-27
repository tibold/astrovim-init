--- Applying language server edits the way the human wants them: all or
--- nothing, and saved.
---
--- Saved, so the files on disk -- which Claude's own tools read -- match the
--- editor. All or nothing, because unsaved work in a touched buffer is the
--- human's: mixing an edit into it would leave neither version intact.
local position = require "nvim-mcp.lsp.position"

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

function M.apply(workspace_edit, encoding)
  local files = M.files(workspace_edit)
  for _, file in ipairs(files) do
    local buffer = position.buffer_for(file)
    if buffer then position.refresh(buffer) end
  end
  local dirty = M.modified(files)
  if #dirty > 0 then return { applied = false, reason = "modified", files = dirty } end

  -- Buffers the edit has to open are the edit's, not the human's: saved, then
  -- unlisted, so a rename across thirty files does not leave thirty entries in
  -- their buffer list. Unlisted rather than deleted keeps the undo history.
  local was_listed = {}
  for _, file in ipairs(files) do
    local buffer = position.buffer_for(file)
    was_listed[file] = buffer ~= nil and vim.bo[buffer].buflisted
  end

  -- Applying can fail partway -- a buffer that is not modifiable, a file that
  -- cannot be renamed -- after earlier files were already edited. Those are
  -- still saved and reported, and the reply says the edit was partial, rather
  -- than an error suggesting nothing happened.
  local whole, err = pcall(vim.lsp.util.apply_workspace_edit, workspace_edit, encoding)

  local counts, changed, failed = edit_counts(workspace_edit), {}, {}
  for _, file in ipairs(files) do
    local buffer = position.buffer_for(file)
    local landed = whole
    if buffer and vim.api.nvim_buf_is_loaded(buffer) then
      if vim.bo[buffer].modified then
        landed = true
        -- A plain :write, so the human's format-on-save and friends still run.
        local ok, write_err = pcall(vim.api.nvim_buf_call, buffer, function() vim.cmd "silent write" end)
        if not ok then failed[#failed + 1] = { file = file, error = tostring(write_err) } end
      end
      if not was_listed[file] then vim.bo[buffer].buflisted = false end
    end
    if landed and (counts[file] or vim.uv.fs_stat(file)) then
      changed[#changed + 1] = { file = file, edits = counts[file] or 0 }
    end
  end

  local reply = { applied = whole or "partial", changed = changed }
  if not whole then reply.error = tostring(err) end
  if #failed > 0 then reply.failed = failed end
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
    if result.applied == true then return { applied = true } end
    if result.reason == "modified" then
      return { applied = false, failureReason = "Unsaved changes in " .. table.concat(result.files, ", ") }
    end
    return { applied = false, failureReason = "Applied only partly: " .. tostring(result.error) }
  end
  local ok, value = pcall(fn)
  vim.lsp.handlers["workspace/applyEdit"] = original
  if not ok then error(value, 0) end
  return value, results
end

return M
