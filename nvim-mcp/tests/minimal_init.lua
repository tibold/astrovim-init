local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(here, ":h")

-- From stdpath rather than a spelled-out home directory: the user name differs
-- between machines, and a missing plenary hangs the run instead of failing it.
vim.opt.rtp:append(vim.fn.stdpath "data" .. "/lazy/plenary.nvim")
-- The debug actions drive nvim-dap itself; its breakpoints and listeners are real.
vim.opt.rtp:append(vim.fn.stdpath "data" .. "/lazy/nvim-dap")
vim.opt.rtp:append(root)
-- Test instances must not share the human's ShaDa: their running editor holds
-- it, and a reload in a test (checktime) then fails with E886.
vim.o.shadafile = "NONE"
-- Nor its swap directory: a test editor that is killed leaves its swap files
-- behind there, where the human's editors then ask about them, and the swap
-- checks (nvim-mcp.lsp.disk) would read theirs.
local swap = vim.fn.tempname()
vim.fn.mkdir(swap, "p")
vim.o.directory = swap .. "//"
vim.cmd "runtime plugin/plenary.vim"
