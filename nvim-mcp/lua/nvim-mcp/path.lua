--- Paths as Neovim itself spells them on this platform.
local M = {}

local windows = vim.fn.has "win32" == 1

--- An absolute path in the platform's own form: backslashes and a capital
--- drive on Windows.
---
--- Claude spells paths with forward slashes, and a buffer named that way is a
--- different string from the one Neovim and its plugins build for the same
--- file. Most compare paths normalised; neotest compares them by prefix with
--- the platform separator, so a test file opened with forward slashes was never
--- inside its backslashed project, and merging the two trees crashed discovery.
--- Language servers send lowercase drives, which :p keeps. Every buffer,
--- directory and quickfix entry nvim-mcp creates goes through here.
function M.native(path)
  local full = vim.fn.fnamemodify(path, ":p")
  if windows then full = full:gsub("/", "\\"):gsub("^%a:", string.upper) end
  return full
end

return M
