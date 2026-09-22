--- Checklist state: items, insertion order, op validation and application.
--- Pure data. No buffers, no windows, no file I/O.
local M = {}

M.items = {}
M.order = {}

M.MAX_ITEMS = 200

M.LIMITS = { text = 120, group = 60, note = 80 }
local LIMITS = M.LIMITS
local STATES = { todo = true, done = true, blocked = true }
local KNOWN_OPS = { set = true, drop = true, clear = true, sweep = true }
local SLUG = "^[a-z0-9_-]+$"

--- Collapse control whitespace, then truncate to `limit` characters inclusive
--- of the ellipsis. A buffer line cannot contain a newline and the panel never
--- wraps, so an item is single-line by construction. Collapsing happens before
--- the length check so the limit counts what is actually displayed.
function M.sanitize(s, limit)
  s = s:gsub("[\r\n\t]+", " ")
  if vim.fn.strchars(s) <= limit then return s end
  return vim.fn.strcharpart(s, 0, limit - 1) .. "…"
end

local truncate = M.sanitize

--- A field may be absent (leave unchanged), vim.NIL (clear), or a string (set).
local function merge_field(current, supplied, limit)
  if supplied == nil then return current end
  if supplied == vim.NIL then return nil end
  return truncate(supplied, limit)
end

--- Structural validation, performed in full before any mutation.
--- Returns the ops array, or nil plus a reason.
local function validate(payload)
  if type(payload) ~= "table" then return nil, "payload is not an object" end
  local ops = payload.ops
  if type(ops) ~= "table" or not vim.islist(ops) then return nil, "ops is missing or not an array" end

  for i, op in ipairs(ops) do
    if type(op) ~= "table" then return nil, ("op %d is not an object"):format(i) end
    if type(op.op) ~= "string" or not KNOWN_OPS[op.op] then
      return nil, ("op %d has unknown op %s"):format(i, vim.inspect(op.op))
    end
    if op.op == "set" or op.op == "drop" then
      if type(op.id) ~= "string" or #op.id > 64 or not op.id:match(SLUG) then
        return nil, ("op %d has an invalid id %s"):format(i, vim.inspect(op.id))
      end
    end
    if op.op == "set" then
      if op.text ~= nil and op.text ~= vim.NIL and type(op.text) ~= "string" then
        return nil, ("op %d has a non-string text"):format(i)
      end
      if op.state ~= nil and not (type(op.state) == "string" and STATES[op.state]) then
        return nil, ("op %d has an invalid state %s"):format(i, vim.inspect(op.state))
      end
    end
  end

  return ops
end

--- Apply to copies, committing only once every op has succeeded.
local function apply(ops)
  local items = vim.deepcopy(M.items)
  local order = vim.deepcopy(M.order)

  local function index_of(id)
    for i, v in ipairs(order) do
      if v == id then return i end
    end
  end

  for i, op in ipairs(ops) do
    if op.op == "set" then
      local item = items[op.id]
      if item then
        item.text = merge_field(item.text, op.text, LIMITS.text)
        item.group = merge_field(item.group, op.group, LIMITS.group)
        item.note = merge_field(item.note, op.note, LIMITS.note)
        if op.state ~= nil then item.state = op.state end
      else
        if type(op.text) ~= "string" then return false, ("op %d creates %s without text"):format(i, op.id) end
        -- Beyond the cap, creations are dropped silently rather than rejected.
        if #order < M.MAX_ITEMS then
          items[op.id] = {
            text = truncate(op.text, LIMITS.text),
            state = op.state or "todo",
            group = merge_field(nil, op.group, LIMITS.group),
            note = merge_field(nil, op.note, LIMITS.note),
          }
          order[#order + 1] = op.id
        end
      end
    elseif op.op == "drop" then
      if items[op.id] then
        items[op.id] = nil
        table.remove(order, index_of(op.id))
      end
    elseif op.op == "clear" then
      items, order = {}, {}
    elseif op.op == "sweep" then
      local kept = {}
      for _, id in ipairs(order) do
        if items[id].state == "done" then
          items[id] = nil
        else
          kept[#kept + 1] = id
        end
      end
      order = kept
    end
  end

  M.items, M.order = items, order
  return true
end

--- Validate and apply a decoded payload. All-or-nothing.
function M.apply_payload(payload)
  local ops, reason = validate(payload)
  if not ops then return false, reason end
  return apply(ops)
end

function M.set(id, opts)
  return M.apply_payload { ops = { vim.tbl_extend("force", { op = "set", id = id }, opts or {}) } }
end

function M.drop(id) return M.apply_payload { ops = { { op = "drop", id = id } } } end

function M.clear() return M.apply_payload { ops = { { op = "clear" } } } end

function M.sweep() return M.apply_payload { ops = { { op = "sweep" } } } end

--- Empty state without validation. For tests and restore.
function M.reset()
  M.items, M.order = {}, {}
end

return M
