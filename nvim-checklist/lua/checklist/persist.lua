--- State file save/restore. Lives outside the repo by default so nothing can
--- be committed by accident and no per-repo setup is needed.
local config = require "checklist.config"
local state = require "checklist.state"

local M = {}

M.VERSION = 1
M.restored = false

local timer = nil

--- Keyed on the realpath of the git root. fs_realpath normalises the slash
--- convention, which vim.fs.root does not, so two spellings of one repo must
--- not hash differently.
function M.path()
  local cwd = vim.uv.cwd()
  local root = vim.fs.root(cwd, ".git") or cwd
  if config.options.store == "repo" then return vim.fs.joinpath(root, ".claude", "checklist.json") end
  local key = vim.fn.sha256(vim.uv.fs_realpath(root) or root):sub(1, 16)
  return vim.fs.joinpath(vim.fn.stdpath "state", "checklist", key .. ".json")
end

local function cancel_timer()
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
  timer = nil
end

function M.save()
  local path = M.path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")

  local ok, encoded = pcall(vim.json.encode, {
    v = M.VERSION,
    ts = os.time(),
    items = state.items,
    order = state.order,
  })
  if not ok then return false end

  local fd = io.open(path, "wb")
  if not fd then return false end
  fd:write(encoded)
  fd:close()
  return true
end

--- Lazy, guarded, and silent on every failure path. A corrupt, stale or
--- version-mismatched file is equivalent to no file.
function M.restore()
  if M.restored then return false end
  M.restored = true

  local fd = io.open(M.path(), "rb")
  if not fd then return false end
  local raw = fd:read "*a"
  fd:close()

  local ok, saved = pcall(vim.json.decode, raw)
  if not ok or type(saved) ~= "table" then return false end
  if saved.v ~= M.VERSION then return false end
  if type(saved.items) ~= "table" or type(saved.order) ~= "table" then return false end

  local max_age = config.options.max_age
  if max_age and max_age > 0 and (os.time() - (tonumber(saved.ts) or 0)) > max_age then return false end

  -- Only ids present on both sides survive, so the invariant cannot be broken
  -- by a hand-edited file. Fields go back through the same sanitizer the ops
  -- path uses, because a newline reaching a buffer line aborts the render.
  local limits = state.LIMITS
  local items, order = {}, {}
  for _, id in ipairs(saved.order) do
    local item = saved.items[id]
    if type(item) == "table" and type(item.text) == "string" then
      items[id] = {
        text = state.sanitize(item.text, limits.text),
        state = item.state or "todo",
        group = type(item.group) == "string" and state.sanitize(item.group, limits.group) or nil,
        note = type(item.note) == "string" and state.sanitize(item.note, limits.note) or nil,
      }
      order[#order + 1] = id
    end
  end

  state.items, state.order = items, order
  return true
end

function M.schedule_save()
  cancel_timer()
  timer = vim.defer_fn(function()
    timer = nil
    M.save()
  end, config.options.debounce)
end

function M.flush()
  cancel_timer()
  M.save()
end

return M
