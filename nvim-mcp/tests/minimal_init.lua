local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(here, ":h")

-- From stdpath rather than a spelled-out home directory: the user name differs
-- between machines, and a missing plenary hangs the run instead of failing it.
vim.opt.rtp:append(vim.fn.stdpath "data" .. "/lazy/plenary.nvim")
vim.opt.rtp:append(root)
vim.cmd "runtime plugin/plenary.vim"
