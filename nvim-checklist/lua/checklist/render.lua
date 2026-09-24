--- Buffer construction. `build` is pure so grouping, ordering and truncation
--- can be tested without touching a buffer; `render` does the side effects.
local config = require "checklist.config"
local state = require "checklist.state"

local M = {}

M.buf = nil
M.line_to_id = {}

local ns = vim.api.nvim_create_namespace "checklist"

local ICONS = {
  -- `inprogress` is the half-filled box from the same checkbox family as the
  -- other two, so the three read as one set rather than three unrelated glyphs.
  nerd = { todo = "󰄱", inprogress = "󰡖", done = "󰱒", blocked = "󰥔" },
  ascii = { todo = "[ ]", inprogress = "[~]", done = "[x]", blocked = "[!]" },
}

local HL_BY_STATE = {
  todo = "ChecklistTodo",
  inprogress = "ChecklistInprogress",
  done = "ChecklistDone",
  blocked = "ChecklistBlocked",
}

local LINKS = {
  ChecklistGroup = "Title",
  ChecklistTodo = "Normal",
  ChecklistInprogress = "DiagnosticInfo",
  ChecklistDone = "DiagnosticOk",
  ChecklistBlocked = "DiagnosticWarn",
  ChecklistNote = "Comment",
  ChecklistEmpty = "NonText",
}

--- `default = true` so a user's colorscheme override wins.
function M.setup_highlights()
  for name, link in pairs(LINKS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
  -- Stacked over ChecklistDone rather than linked, because a `link` ignores
  -- sibling attributes. Two extmarks on one range combine.
  vim.api.nvim_set_hl(0, "ChecklistStrike", { strikethrough = true, default = true })
end

function M.ensure_buf()
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then return M.buf end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "checklist"
  pcall(vim.api.nvim_buf_set_name, buf, "checklist://session")
  M.buf = buf
  return buf
end

--- Group ids by their `group`, preserving first-appearance order of both the
--- groups and the items within them. Ungrouped comes first.
local function grouped()
  local ungrouped, groups, seen = {}, {}, {}
  for _, id in ipairs(state.order) do
    local g = state.items[id].group
    if g == nil then
      ungrouped[#ungrouped + 1] = id
    else
      if not seen[g] then
        seen[g] = { name = g, ids = {} }
        groups[#groups + 1] = seen[g]
      end
      table.insert(seen[g].ids, id)
    end
  end
  return ungrouped, groups
end

--- Returns lines, highlights and the 1-indexed line -> id map. No side effects.
function M.build()
  local icons = ICONS[config.options.icons] or ICONS.nerd
  local lines, highlights, map = {}, {}, {}

  if #state.order == 0 then
    lines[1] = "  (no checklist)"
    highlights[1] = { line = 0, col_start = 0, col_end = #lines[1], group = "ChecklistEmpty" }
    return lines, highlights, map
  end

  local function push_item(id)
    local item = state.items[id]
    local icon = icons[item.state] or icons.todo
    local prefix = "    " .. icon .. " "
    local text = prefix .. item.text

    lines[#lines + 1] = text
    local lnum = #lines - 1
    map[#lines] = id

    highlights[#highlights + 1] = { line = lnum, col_start = 0, col_end = #text, group = HL_BY_STATE[item.state] }
    if item.state == "done" then
      highlights[#highlights + 1] = { line = lnum, col_start = #prefix, col_end = #text, group = "ChecklistStrike" }
    end

    -- The note goes on its own line rather than trailing the text. Appended, a
    -- note pushed the line past the panel width and the part that mattered --
    -- what a blocked item is waiting on -- was the part that fell off the end.
    -- The panel never wraps, so nothing off the right edge is readable at all.
    -- `~= ""` as well as non-nil: state.lua now clears an empty note before it
    -- gets here, but a session file written before that still carries one, and
    -- an empty note renders as an indented blank line that reads as a gap in
    -- the list rather than as nothing.
    if item.note and item.note ~= "" then
      -- Indented past the icon so it hangs under the text it belongs to.
      lines[#lines + 1] = "      " .. item.note
      highlights[#highlights + 1] =
        { line = #lines - 1, col_start = 0, col_end = #lines[#lines], group = "ChecklistNote" }
      -- Mapped to the same item, so the toggle and drop keymaps act on the item
      -- when the cursor happens to sit on its note.
      map[#lines] = id
    end
  end

  local ungrouped, groups = grouped()
  for _, id in ipairs(ungrouped) do
    push_item(id)
  end
  for _, group in ipairs(groups) do
    if #lines > 0 then lines[#lines + 1] = "" end
    lines[#lines + 1] = "  " .. group.name
    highlights[#highlights + 1] =
      { line = #lines - 1, col_start = 0, col_end = #lines[#lines], group = "ChecklistGroup" }
    for _, id in ipairs(group.ids) do
      push_item(id)
    end
  end

  return lines, highlights, map
end

function M.render()
  local buf = M.ensure_buf()
  local lines, highlights, map = M.build()

  vim.bo[buf].modifiable = true
  -- Restore modifiable even when the write throws. Leaving it on turns the
  -- panel into an editable buffer the user can type into, which then prompts
  -- to be saved on quit.
  local written, err = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  -- The buffer still holds the previous contents, so line_to_id is left
  -- pointing at them rather than at lines that were never written.
  if not written then error(err, 0) end

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(highlights) do
    pcall(vim.hl.range, buf, ns, h.group, { h.line, h.col_start }, { h.line, h.col_end })
  end

  M.line_to_id = map
end

return M
