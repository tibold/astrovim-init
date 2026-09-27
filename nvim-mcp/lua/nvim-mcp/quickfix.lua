--- The quickfix list, both ways.
---
--- Reading it is how Claude sees what the human just ran: `:make` (which the
--- rust keymaps send cargo build and clippy through), `:grep`, or a language
--- server's references. Writing it hands the human a list of places to step
--- through with `]q`, rather than paths in the chat.
---
--- Writing always adds a new list. Quickfix keeps a history of lists, so the
--- one the human was working through stays a `:colder` away instead of being
--- replaced.
local mcp = require "nvim-mcp"

local M = {}

--- Entries kept in a summary.
M.SHOWN = 20

local TYPES = { E = "error", W = "warning", I = "info", N = "note", H = "hint" }

local function invalid(message) error { code = -32602, message = message } end

--- Entries with a location, each carrying the unlocated lines printed after it.
--- A compiler's notes and help lines come through :make as entries with no
--- location; alone they are noise, under their error they are the explanation.
local function entries(raw)
  local out, preamble = {}, {}
  for _, item in ipairs(raw) do
    if item.valid == 1 and item.bufnr > 0 then
      out[#out + 1] = {
        file = vim.fs.normalize(vim.api.nvim_buf_get_name(item.bufnr)),
        line = item.lnum,
        column = item.col > 0 and item.col or nil,
        type = TYPES[item.type] or (item.type ~= "" and item.type or nil),
        text = vim.trim(item.text) ~= "" and item.text or nil,
      }
    elseif item.text ~= "" then
      local last = out[#out]
      if last then
        last.detail = last.detail or {}
        last.detail[#last.detail + 1] = item.text
      else
        preamble[#preamble + 1] = item.text
      end
    end
  end
  return out, preamble
end

--- The current quickfix list, or an older one by `nr`.
function M.read(args, opts)
  args, opts = args or {}, opts or {}
  local nr = tonumber(args.nr) or 0
  local list = vim.fn.getqflist { nr = nr, title = 1, items = 1 }
  if nr ~= 0 and (list.items == nil or vim.fn.getqflist({ nr = nr }).nr ~= nr) then
    invalid(("there is no quickfix list %d"):format(nr))
  end
  local items, preamble = entries(list.items or {})

  local types = {}
  for _, item in ipairs(items) do
    if item.type then types[item.type] = (types[item.type] or 0) + 1 end
  end

  local full = opts.detail == "full"
  return {
    title = list.title,
    nr = vim.fn.getqflist({ nr = nr }).nr,
    lists = vim.fn.getqflist({ nr = "$" }).nr,
    count = #items,
    types = types,
    items = full and items or vim.list_slice(items, 1, math.min(M.SHOWN, #items)),
    truncated = not full and #items > M.SHOWN,
    preamble = #preamble > 0 and (full and preamble or vim.list_slice(preamble, 1, 5)) or nil,
  }
end

--- Hand the human a list of places, as a new quickfix list.
function M.write(args, opts)
  args, opts = args or {}, opts or {}
  if type(args.title) ~= "string" or args.title == "" then invalid "a title is required" end
  if type(args.items) ~= "table" or #args.items == 0 then invalid "items must list at least one place" end

  -- The bridge resolves `path` for every action, but these paths sit inside
  -- items, so they are resolved here against the directory it passes along.
  local base = opts.cwd or vim.fn.getcwd()
  local items = {}
  for index, item in ipairs(args.items) do
    if type(item.path) ~= "string" or item.path == "" then invalid(("item %d needs a path"):format(index)) end
    local line = tonumber(item.line)
    if not line or line < 1 then invalid(("item %d needs a 1-based line"):format(index)) end
    local path = vim.fn.isabsolutepath(item.path) == 1 and item.path or vim.fs.joinpath(base, item.path)
    items[#items + 1] = {
      filename = require("nvim-mcp.path").native(path),
      lnum = line,
      col = tonumber(item.column) or 0,
      text = type(item.text) == "string" and item.text or "",
      type = type(item.type) == "string" and item.type:sub(1, 1):upper() or "",
    }
  end

  local title = "Claude: " .. args.title
  vim.fn.setqflist({}, " ", { title = title, items = items })

  -- Opened without taking focus: the current window is the terminal Claude
  -- runs in, and moving the human's cursor is not Claude's to do.
  local opened = false
  if args.open ~= false then
    local entry = vim.api.nvim_get_current_win()
    vim.cmd "botright copen"
    if vim.api.nvim_win_is_valid(entry) then vim.api.nvim_set_current_win(entry) end
    opened = true
  end

  return { title = title, count = #items, nr = vim.fn.getqflist({ nr = 0 }).nr, opened = opened }
end

function M.setup()
  mcp.register {
    name = "quickfix",
    description = "The quickfix list: what :make, :grep or references just put there. nr reads an older one.",
    inputSchema = {
      type = "object",
      properties = { nr = { type = "integer", minimum = 1, description = "An older list; omit for the current one." } },
    },
    handler = M.read,
  }
  mcp.register {
    name = "set_quickfix",
    description = "Hand the human a list of places as a new quickfix list; theirs stays a :colder away.",
    inputSchema = {
      type = "object",
      properties = {
        title = { type = "string", description = "What the list is; shown as 'Claude: <title>'." },
        items = {
          type = "array",
          items = {
            type = "object",
            properties = {
              path = { type = "string" },
              line = { type = "integer", minimum = 1 },
              column = { type = "integer", minimum = 1 },
              text = { type = "string" },
              type = { type = "string", description = "E, W, I or N; optional." },
            },
            required = { "path", "line" },
          },
        },
        open = { type = "boolean", description = "Open the quickfix window. Default true." },
      },
      required = { "title", "items" },
    },
    handler = M.write,
  }
end

return M
