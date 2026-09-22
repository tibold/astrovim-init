--- The editor-driving actions, ported from the driving-neovim drive.lua skill.
---
--- The point is not file management: showing beats explaining. When a question
--- is about code, put the code on the human's screen at the line under
--- discussion rather than pasting an excerpt into chat.
local mcp = require "nvim-mcp"

local M = {}

--- A window is usable when it holds an ordinary file, or an unnamed scratch,
--- which is free space. Sidebars carry names, so they are never taken.
local function is_usable(window)
  local config = vim.api.nvim_win_get_config(window)
  if config.relative ~= nil and config.relative ~= "" then return false end

  local buffer = vim.api.nvim_win_get_buf(window)
  if vim.bo[buffer].buftype == "" then return true end
  return vim.api.nvim_buf_get_name(buffer) == "" and not vim.bo[buffer].modified
end

local function is_file_window(window)
  local config = vim.api.nvim_win_get_config(window)
  return vim.bo[vim.api.nvim_win_get_buf(window)].buftype == "" and (config.relative == nil or config.relative == "")
end

--- Put a file on screen without taking the focus. Claude Code runs in a terminal
--- buffer of this very instance, so editing the current window would push the
--- conversation out of view.
function M.show(args)
  local path = args.path
  if type(path) ~= "string" or path == "" then error { code = -32602, message = "show needs a path" } end
  local line = tonumber(args.line) or 0

  local entry = vim.api.nvim_get_current_win()
  local target
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    if is_usable(window) then
      target = window
      break
    end
  end

  local created = false
  if not target then
    vim.cmd "botright vsplit"
    target = vim.api.nvim_get_current_win()
    created = true
    vim.api.nvim_set_current_win(entry)
  end

  -- Addressing the buffer directly sidesteps command line parsing, and bufadd
  -- returns the existing buffer when the file is already open.
  local buffer = vim.fn.bufadd(path)
  vim.fn.bufload(buffer)
  vim.bo[buffer].buflisted = true
  vim.api.nvim_win_set_buf(target, buffer)

  if line > 0 then
    local clamped = math.min(line, vim.api.nvim_buf_line_count(buffer))
    vim.api.nvim_win_set_cursor(target, { clamped, 0 })
    vim.api.nvim_win_call(target, function() vim.cmd "normal! zz" end)
  end

  return {
    created_window = created,
    focus_kept = vim.api.nvim_get_current_win() == entry,
    file = vim.api.nvim_buf_get_name(buffer),
    line = line,
  }
end

--- What the human is actually looking at. The current window belongs to the
--- terminal this session runs in, so the interesting buffer is the first
--- ordinary one rather than the current one.
function M.state()
  local file, cursor
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    if is_file_window(window) then
      file = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(window))
      local position = vim.api.nvim_win_get_cursor(window)
      cursor = { line = position[1], column = position[2] + 1 }
      break
    end
  end

  -- Unsaved buffers matter to a reader: what is on disk is not what is on screen.
  local modified = {}
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buffer].modified and vim.api.nvim_buf_get_name(buffer) ~= "" then
      modified[#modified + 1] = vim.api.nvim_buf_get_name(buffer)
    end
  end

  return { cwd = vim.fn.getcwd(), file = file, cursor = cursor, modified = modified, modified_count = #modified }
end

--- Language server findings, with enough context to read an empty result
--- correctly: an empty list means "nothing wrong" and "nothing watching"
--- equally, so what is attached is reported alongside.
function M.diagnostics(_, opts)
  local items = {}
  for _, diagnostic in ipairs(vim.diagnostic.get()) do
    if vim.api.nvim_buf_is_valid(diagnostic.bufnr) then
      items[#items + 1] = {
        file = vim.api.nvim_buf_get_name(diagnostic.bufnr),
        line = diagnostic.lnum + 1,
        column = diagnostic.col + 1,
        severity = vim.diagnostic.severity[diagnostic.severity],
        source = diagnostic.source,
        code = diagnostic.code and tostring(diagnostic.code) or nil,
        message = diagnostic.message,
      }
    end
  end

  local clients = {}
  for _, client in ipairs(vim.lsp.get_clients()) do
    clients[#clients + 1] = client.name
  end

  local buffers = {}
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buffer)
    if vim.api.nvim_buf_is_loaded(buffer) and vim.bo[buffer].buftype == "" and name ~= "" then
      local attached = {}
      for _, client in ipairs(vim.lsp.get_clients { bufnr = buffer }) do
        attached[#attached + 1] = client.name
      end
      buffers[#buffers + 1] = { file = name, filetype = vim.bo[buffer].filetype, clients = attached }
    end
  end

  if (opts and opts.detail) == "full" then
    return { items = items, count = #items, clients = clients, buffers = buffers, detail = "full" }
  end

  -- Summary. A big solution can return hundreds of findings, and reading them
  -- all costs more than the answer is worth mid-debug. What must survive
  -- summarising is the attachment signal: without it an empty result cannot be
  -- told from an unwatched one, which is the whole point of this action.
  local SHOWN = 10
  local by_file, order = {}, {}
  for _, item in ipairs(items) do
    if not by_file[item.file] then
      by_file[item.file] = 0
      order[#order + 1] = item.file
    end
    by_file[item.file] = by_file[item.file] + 1
  end

  local counts = {}
  for _, file in ipairs(order) do
    counts[#counts + 1] = { file = file, count = by_file[file] }
  end

  local unattached = {}
  for _, buffer in ipairs(buffers) do
    if #buffer.clients == 0 then unattached[#unattached + 1] = { file = buffer.file, filetype = buffer.filetype } end
  end

  return {
    count = #items,
    clients = clients,
    by_file = counts,
    items = vim.list_slice(items, 1, math.min(SHOWN, #items)),
    truncated = #items > SHOWN,
    unattached = unattached,
    detail = "summary",
  }
end

--- Remove a buffer, without disturbing what the human is doing.
function M.close(args)
  local path = args.path
  if type(path) ~= "string" or path == "" then error { code = -32602, message = "close needs a path" } end
  local wanted = vim.fs.normalize(path):lower()

  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buffer)
    if name ~= "" and vim.fs.normalize(name):lower() == wanted then
      -- Unsaved work in that buffer is the human's, so this never forces.
      if vim.bo[buffer].modified then return { closed = false, reason = "modified", file = name } end

      -- Deleting a buffer closes every window showing it, which would take the
      -- layout with it. Empty those windows first. The alternate is a property
      -- of the window, so it has to be read from inside the window being rescued.
      local function replacement_for(window)
        local alternate = vim.api.nvim_win_call(window, function() return vim.fn.bufnr "#" end)
        if alternate ~= -1 and alternate ~= buffer and vim.api.nvim_buf_is_valid(alternate) then return alternate end

        local best, best_used = nil, -1
        for _, info in ipairs(vim.fn.getbufinfo { buflisted = 1 }) do
          if info.bufnr ~= buffer and vim.bo[info.bufnr].buftype == "" and info.lastused > best_used then
            best, best_used = info.bufnr, info.lastused
          end
        end
        return best or vim.api.nvim_create_buf(false, true)
      end

      local kept = 0
      for _, window in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(window) == buffer then
          vim.api.nvim_win_set_buf(window, replacement_for(window))
          kept = kept + 1
        end
      end

      vim.api.nvim_buf_delete(buffer, { force = false })
      return { closed = true, file = name, windows_kept = kept }
    end
  end

  return { closed = false, reason = "not open" }
end

--- Identify this instance well enough to choose between several worktrees.
--- The bridge calls this on each instance it finds.
function M.identify()
  local files = {}
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buffer].buflisted and vim.bo[buffer].buftype == "" then
      local name = vim.api.nvim_buf_get_name(buffer)
      if name ~= "" then files[#files + 1] = name end
    end
  end
  return { cwd = vim.fn.getcwd(), files = files, count = #files }
end

--- Register everything. Descriptions are one line each: the detail lives in the
--- `nvim` skill, which loads on demand, rather than in permanent context.
function M.setup()
  mcp.register {
    name = "show",
    description = "Put a file on the human's screen at a line, without taking their cursor.",
    inputSchema = {
      type = "object",
      properties = { path = { type = "string" }, line = { type = "number" } },
      required = { "path" },
    },
    handler = M.show,
  }
  mcp.register {
    name = "state",
    description = "Working directory, the file and cursor in view, and any unsaved buffers.",
    inputSchema = { type = "object", properties = {} },
    handler = M.state,
  }
  mcp.register {
    name = "diagnostics",
    description = "Language server findings, plus what is attached so an empty result can be read.",
    inputSchema = { type = "object", properties = vim.empty_dict() },
    handler = M.diagnostics,
  }
  mcp.register {
    name = "close",
    description = "Remove a buffer. Refuses when it holds unsaved work.",
    inputSchema = {
      type = "object",
      properties = { path = { type = "string" } },
      required = { "path" },
    },
    handler = M.close,
  }
  mcp.register {
    name = "identify",
    description = "This instance's working directory and open files.",
    inputSchema = { type = "object", properties = {} },
    handler = M.identify,
  }
end

return M
