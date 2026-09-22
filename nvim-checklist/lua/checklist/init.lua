--- Public API. `load` is the only function reached from outside the editor.
local config = require "checklist.config"
local persist = require "checklist.persist"
local render = require "checklist.render"
local state = require "checklist.state"
local window = require "checklist.window"

local M = {}

local function read_file(path)
  if type(path) ~= "string" or path == "" then return nil end
  local fd = io.open(path, "rb")
  if not fd then return nil end
  local contents = fd:read "*a"
  fd:close()
  return contents
end

--- Restore lazily, on first load or first open, whichever comes first.
--- Sessions that never use the panel pay nothing.
local function ensure_restored()
  if not persist.restored then pcall(persist.restore) end
end

--- Apply an already-decoded payload: validate, render, surface, save. Shared by
--- the file entry point and the MCP tool, so both behave identically.
--- Returns true, or false plus a reason.
function M.apply(payload)
  ensure_restored()

  local applied, reason = state.apply_payload(payload)
  if not applied then return false, reason or "rejected" end

  render.render()
  -- Surface the panel on an update, but never take the cursor: window.open
  -- returns focus to the originating window unless focus_on_open is set. An
  -- empty checklist is not worth a window, so a `clear` does not pop one up.
  if config.options.auto_open and #state.order > 0 then window.open() end
  persist.schedule_save()
  return true
end

--- Decode, validate, apply and render a payload file.
--- Returns 1 on success, 0 on any failure. Never throws, never reports.
--- With NVIM_CHECKLIST_DEBUG=1 a failure returns its reason instead of 0.
function M.load(path)
  local ok, result = pcall(function()
    local raw = read_file(path)
    if not raw then return "unreadable payload" end

    local decoded_ok, payload = pcall(vim.json.decode, raw)
    if not decoded_ok then return "undecodable JSON" end

    local applied, reason = M.apply(payload)
    if not applied then return reason end
    return true
  end)

  if ok and result == true then return 1 end
  if vim.env.NVIM_CHECKLIST_DEBUG == "1" then return tostring(result) end
  return 0
end

--- Bring back a checklist left over from the last session. Called at startup,
--- scheduled so neo-tree already exists and the panel lands below it rather
--- than in its own split. A checklist that restores empty opens nothing.
function M.open_restored()
  if not config.options.open_on_startup then return end
  ensure_restored()
  if #state.order == 0 then return end
  render.render()
  window.open()
end

function M.setup(opts)
  config.setup(opts)
  render.setup_highlights()

  local group = vim.api.nvim_create_augroup("Checklist", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = render.setup_highlights })
  -- A fractional height is meaningless if it does not follow the screen.
  vim.api.nvim_create_autocmd("VimResized", { group = group, callback = window.resize })
  -- Must be synchronous: a debounced save pending at exit is otherwise lost.
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = persist.flush })

  window.on_mutate = persist.schedule_save

  -- Register with the Neovim MCP server, if installed, so Claude can drive the
  -- panel with nothing on PATH and no CLAUDE.md boilerplate.
  require("checklist.mcp").attach()

  vim.api.nvim_create_user_command("ChecklistToggle", M.toggle, { desc = "Toggle the session checklist" })
  vim.api.nvim_create_user_command("ChecklistSweep", M.sweep, { desc = "Drop completed checklist items" })
  -- No confirmation here: typing the command is the confirmation. The panel's
  -- `C` mapping asks, because a stray keypress is easier than a stray command.
  vim.api.nvim_create_user_command("ChecklistClear", M.clear, { desc = "Clear the session checklist" })

  -- Loading on VeryLazy means VimEnter has usually already fired, in which case
  -- an autocmd for it would never run.
  if vim.v.vim_did_enter == 1 then
    vim.schedule(M.open_restored)
  else
    vim.api.nvim_create_autocmd("VimEnter", {
      group = group,
      once = true,
      callback = function() vim.schedule(M.open_restored) end,
    })
  end
end

M.toggle = function()
  ensure_restored()
  render.render()
  window.toggle()
end

M.open = function()
  ensure_restored()
  render.render()
  window.open()
end

M.close = function() window.close() end
M.render = function() render.render() end

--- Every Lua-facing mutation re-renders, drops an emptied panel and schedules a
--- save, so clearing from anywhere leaves nothing behind to restore.
local function mutate(fn, ...)
  -- Restore first. Otherwise a clear() before any restore is undone by the next
  -- apply(), which restores the saved file and resurrects what was just cleared.
  ensure_restored()
  fn(...)
  window.after_mutation()
end

M.set = function(id, opts) mutate(state.set, id, opts) end
M.drop = function(id) mutate(state.drop, id) end
M.clear = function() mutate(state.clear) end
M.sweep = function() mutate(state.sweep) end

return M
