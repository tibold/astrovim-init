--- The notice the human sees while their editor waits on a request.
---
--- A floating window drawn with an explicit redraw, not vim.notify: a notifier
--- plugin may render on a later tick, which never comes while the main loop is
--- blocked. A delayed notice still works because request_sync waits with
--- vim.wait, which runs scheduled callbacks.
local M = {}

--- The handle currently on screen, if any.
M.active = nil

--- Its own highlights, so it stands out from ordinary floats rather than
--- blending in. Defined only when nothing else has defined them, so a colour
--- scheme or the human's config wins; checked on every show because
--- :colorscheme clears them.
local function define_highlights()
  vim.api.nvim_set_hl(0, "NvimMcpNoticeBorder", { default = true, fg = "#D97757", bold = true })
  if vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = "NvimMcpNotice" })) then
    -- NormalFloat's colours, bold: a link could not add the bold.
    local base = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
    vim.api.nvim_set_hl(0, "NvimMcpNotice", { fg = base.fg, bg = base.bg, bold = true })
  end
end

local function show(text)
  define_highlights()
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { text })
  local width = math.max(1, math.min(vim.fn.strdisplaywidth(text), vim.o.columns - 4))
  local window = vim.api.nvim_open_win(buffer, false, {
    relative = "editor",
    anchor = "NE",
    row = 1,
    col = vim.o.columns - 1,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    focusable = false,
    noautocmd = true,
    zindex = 250,
  })
  vim.wo[window].winhighlight = "NormalFloat:NvimMcpNotice,FloatBorder:NvimMcpNoticeBorder"
  vim.cmd.redraw()
  return { window = window, buffer = buffer }
end

--- Put `text` up now, or after `delay_ms` if still open by then.
function M.open(text, delay_ms)
  local handle = { text = text }
  if not delay_ms or delay_ms <= 0 then
    handle.shown = show(text)
    M.active = handle
    return handle
  end
  handle.timer = vim.uv.new_timer()
  handle.timer:start(delay_ms, 0, vim.schedule_wrap(function()
    if handle.closed then return end
    handle.shown = show(text)
    M.active = handle
  end))
  return handle
end

function M.close(handle)
  handle.closed = true
  if handle.timer then
    handle.timer:stop()
    if not handle.timer:is_closing() then handle.timer:close() end
  end
  if handle.shown then
    pcall(vim.api.nvim_win_close, handle.shown.window, true)
    pcall(vim.api.nvim_buf_delete, handle.shown.buffer, { force = true })
    pcall(vim.cmd.redraw)
  end
  if M.active == handle then M.active = nil end
end

--- Run `fn` with the notice up, closing it however `fn` ends.
function M.during(text, delay_ms, fn)
  local handle = M.open(text, delay_ms)
  local results = vim.F.pack_len(pcall(fn))
  M.close(handle)
  if not results[1] then error(results[2], 0) end
  return unpack(results, 2, results.n)
end

return M
