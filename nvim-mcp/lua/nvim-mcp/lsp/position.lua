--- Turning `{ path, line, symbol | column }` into an LSP position.
---
--- Lines and columns are 1-based and count characters, as Read output and the
--- editor show them. Columns are where a caller slips, so `symbol` -- the word
--- at that spot -- is the preferred way to point, and the column is found here.
local M = {}

function M.invalid(message) error { code = -32602, message = message } end

local function same_file(a, b) return vim.fs.normalize(a):lower() == vim.fs.normalize(b):lower() end

--- The buffer already holding `path`, if any. bufnr() would read the path as a
--- pattern, and Windows spells one file several ways, so names are compared
--- normalised, as `close` does.
function M.buffer_for(path)
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buffer)
    if name ~= "" and same_file(name, path) then return buffer end
  end
end

--- Reload an unmodified buffer whose file changed on disk. Claude's own Edit
--- tool writes files behind the editor's back: without this a lookup reads
--- stale text, and saving an edit hits Vim's "file has changed" prompt, which
--- blocks the tool call until the human answers it. A buffer with unsaved
--- work is left alone -- an edit refuses it as modified anyway.
function M.refresh(buffer)
  if not vim.api.nvim_buf_is_loaded(buffer) or vim.bo[buffer].buftype ~= "" then return end
  local group = vim.api.nvim_create_augroup("nvim_mcp_refresh", { clear = true })
  vim.api.nvim_create_autocmd("FileChangedShell", {
    group = group,
    buffer = buffer,
    callback = function() vim.v.fcs_choice = vim.bo[buffer].modified and "" or "reload" end,
  })
  pcall(vim.cmd, "silent checktime " .. buffer)
  vim.api.nvim_del_augroup_by_id(group)
end

--- The loaded buffer for `path`, without showing it, and current with the
--- file on disk. A buffer this loads gets its filetype detected, because
--- language servers attach on FileType.
function M.buffer(path)
  if type(path) ~= "string" or path == "" then M.invalid "a path is required" end
  local full = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  if not vim.uv.fs_stat(full) then M.invalid("no such file: " .. full) end

  local buffer = M.buffer_for(full) or vim.fn.bufadd(full)
  if not vim.api.nvim_buf_is_loaded(buffer) then
    vim.fn.bufload(buffer)
    if vim.bo[buffer].filetype == "" then
      vim.api.nvim_buf_call(buffer, function() vim.cmd "filetype detect" end)
    end
  else
    M.refresh(buffer)
  end
  return buffer
end

function M.line_text(buffer, line)
  if type(line) ~= "number" or line < 1 then M.invalid "line must be a 1-based number" end
  local text = vim.api.nvim_buf_get_lines(buffer, line - 1, line, false)[1]
  if not text then
    M.invalid(("line %d is past the end of the file (%d lines)"):format(line, vim.api.nvim_buf_line_count(buffer)))
  end
  return text
end

local function is_word(char) return char ~= "" and char:match "[%w_]" ~= nil end

--- Every 1-based byte column where `symbol` occurs as a whole word. The word
--- check applies only at an edge that is itself a word character, so `->`
--- still matches between spaces.
local function occurrences(text, symbol)
  local hits, from = {}, 1
  while true do
    local first, last = text:find(symbol, from, true)
    if not first then return hits end
    local clean_start = not is_word(symbol:sub(1, 1)) or not is_word(text:sub(first - 1, first - 1))
    local clean_end = not is_word(symbol:sub(-1)) or not is_word(text:sub(last + 1, last + 1))
    if clean_start and clean_end then hits[#hits + 1] = first end
    from = first + 1
  end
end

local function words(text)
  local out, seen = {}, {}
  for word in text:gmatch "[%w_]+" do
    if not seen[word] then
      seen[word] = true
      out[#out + 1] = word
    end
  end
  return table.concat(out, ", ")
end

--- 1-based character column to 1-based byte column.
function M.char_to_byte(text, column)
  column = tonumber(column)
  if not column or column < 1 then M.invalid "column must be a 1-based number" end
  local length = vim.str_utfindex(text, "utf-32", nil, false)
  if column > length + 1 then
    M.invalid(("column %d is past the end of the line (%d characters)"):format(column, length))
  end
  return vim.str_byteindex(text, "utf-32", column - 1, false) + 1
end

--- 1-based byte column to 1-based character column.
function M.byte_to_char(text, byte) return vim.str_utfindex(text, "utf-32", byte - 1, false) + 1 end

--- The byte column to ask about. A symbol found once wins; found several
--- times, `column` picks which; not found, the error lists what is there.
function M.byte_column(buffer, line, symbol, column)
  local text = M.line_text(buffer, line)
  if symbol == nil or symbol == "" then
    if column == nil then M.invalid "pass symbol (preferred) or column" end
    return M.char_to_byte(text, column)
  end

  local hits = occurrences(text, symbol)
  if #hits == 1 then return hits[1] end
  if #hits > 1 and column ~= nil then
    local byte = M.char_to_byte(text, column)
    for _, hit in ipairs(hits) do
      if byte >= hit and byte < hit + #symbol then return hit end
    end
  end
  local why = #hits == 0 and "is not on" or ("appears %d times on"):format(#hits)
  M.invalid(("%q %s line %d; pass column to choose. Words there: %s"):format(symbol, why, line, words(text)))
end

--- TextDocumentPositionParams for a 1-based line and byte column, in the
--- server's own position encoding.
function M.params(buffer, line, byte, encoding)
  local text = M.line_text(buffer, line)
  return {
    textDocument = { uri = vim.uri_from_bufnr(buffer) },
    position = { line = line - 1, character = vim.str_utfindex(text, encoding, byte - 1, false) },
  }
end

--- A Range covering whole lines `first`..`last` (1-based, inclusive).
function M.line_range(buffer, first, last, encoding)
  first, last = tonumber(first), tonumber(last)
  if not first or not last or last < first then
    M.invalid "line and end_line must be 1-based, with end_line >= line"
  end
  M.line_text(buffer, first)
  local last_text = M.line_text(buffer, last)
  return {
    start = { line = first - 1, character = 0 },
    ["end"] = { line = last - 1, character = vim.str_utfindex(last_text, encoding, nil, false) },
  }
end

return M
