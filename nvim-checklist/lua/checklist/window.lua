--- Window placement and the buffer-local keymaps. Placement prefers a split
--- below neo-tree, falling back to its own left split so the panel is never
--- unreachable when the explorer is closed.
local config = require "checklist.config"
local render = require "checklist.render"
local state = require "checklist.state"

local M = {}

M.win = nil

--- True when the panel is its own vertical split rather than a horizontal one
--- below neo-tree. Decides which dimension a resize applies to.
M.vertical = false

--- Set by init.lua so keymap mutations schedule a save without window.lua
--- taking a dependency on persist.lua.
M.on_mutate = nil

--- A size of 1 or less is a fraction of the available space; anything larger is
--- an absolute number of rows or columns. Pure, so it is testable without a UI.
function M.resolve_size(value, total, minimum)
  local resolved = value <= 1 and math.floor(total * value) or math.floor(value)
  return math.max(minimum, resolved)
end

local function panel_height() return M.resolve_size(config.options.height, vim.o.lines, 5) end

local function panel_width() return M.resolve_size(config.options.width, vim.o.columns, 20) end

--- Reapply the configured size, so a fractional height tracks window resizes.
function M.resize()
  if not M.is_open() then return end
  if M.vertical then
    vim.api.nvim_win_set_width(M.win, panel_width())
  else
    vim.api.nvim_win_set_height(M.win, panel_height())
  end
end

local WIN_OPTIONS = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  cursorline = true,
  wrap = false,
  foldcolumn = "0",
  list = false,
}

local function find_neotree_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == "neo-tree" then return win end
  end
end

function M.is_open() return M.win ~= nil and vim.api.nvim_win_is_valid(M.win) end

local function id_under_cursor()
  if not M.is_open() then return nil end
  local lnum = vim.api.nvim_win_get_cursor(M.win)[1]
  return render.line_to_id[lnum]
end

--- Re-render after a change, and drop the window once nothing is left. An
--- empty checklist is not worth a panel, which is the same rule auto-open
--- applies in the other direction.
function M.after_mutation()
  render.render()
  if #state.order == 0 then M.close() end
  if M.on_mutate then M.on_mutate() end
end

local after_mutation = M.after_mutation

function M.toggle_item_under_cursor()
  local id = id_under_cursor()
  if not id then return end
  state.set(id, { state = state.items[id].state == "done" and "todo" or "done" })
  after_mutation()
end

function M.drop_item_under_cursor()
  local id = id_under_cursor()
  if not id then return end
  state.drop(id)
  after_mutation()
end

function M.sweep()
  state.sweep()
  after_mutation()
end

function M.clear()
  vim.ui.select({ "No", "Yes" }, { prompt = "Clear the whole checklist?" }, function(choice)
    if choice ~= "Yes" then return end
    state.clear()
    after_mutation()
  end)
end

--- The checklist as markdown. Pure, so it serves both the yank keymap and the
--- SessionStart hook, which reads it over RPC to put the current plan back in
--- front of an agent that has just been compacted.
---@return string
function M.markdown()
  local out, current = {}, nil
  local marks = { todo = "- [ ] ", inprogress = "- [>] ", done = "- [x] ", blocked = "- [!] " }
  for _, id in ipairs(state.order) do
    local item = state.items[id]
    if item.group ~= current then
      current = item.group
      if current then
        out[#out + 1] = ""
        out[#out + 1] = "## " .. current
      end
    end
    out[#out + 1] = (marks[item.state] or marks.todo) .. item.text .. (item.note and ("  — " .. item.note) or "")
  end
  return table.concat(out, "\n")
end

function M.yank_markdown() vim.fn.setreg("+", M.markdown()) end

local function attach_keymaps(buf)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  map("q", M.close, "Close the checklist")
  map("<CR>", M.toggle_item_under_cursor, "Toggle todo/done")
  map("d", M.drop_item_under_cursor, "Drop this item")
  map("S", M.sweep, "Sweep completed items")
  map("C", M.clear, "Clear the checklist")
  map("gy", M.yank_markdown, "Yank as markdown")
end

function M.open()
  if M.is_open() then return end

  local buf = render.ensure_buf()
  local origin = vim.api.nvim_get_current_win()

  -- An existing window already showing the buffer is adopted rather than
  -- duplicated, which is what keeps criterion 19 true across stray opens.
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      M.win = win
      return
    end
  end

  local neotree = find_neotree_win()
  M.vertical = neotree == nil
  if neotree then
    vim.api.nvim_set_current_win(neotree)
    vim.cmd(("belowright %dsplit"):format(panel_height()))
  else
    vim.cmd(("topleft %dvsplit"):format(panel_width()))
  end

  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  for name, value in pairs(WIN_OPTIONS) do
    vim.wo[win][name] = value
  end
  -- Both, not just the dimension the split created: below neo-tree the panel
  -- shares that column, so it should keep its width as well as its height.
  vim.wo[win].winfixheight = true
  vim.wo[win].winfixwidth = true

  M.win = win
  attach_keymaps(buf)

  if not config.options.focus_on_open and vim.api.nvim_win_is_valid(origin) then
    vim.api.nvim_set_current_win(origin)
  end
end

function M.close()
  if not M.is_open() then
    M.win = nil
    return
  end
  -- Closing the last window would quit nvim; leave it alone in that case.
  if #vim.api.nvim_tabpage_list_wins(0) > 1 then vim.api.nvim_win_close(M.win, false) end
  M.win = nil
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

return M
