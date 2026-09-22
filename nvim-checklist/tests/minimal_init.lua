local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(here, ":h")

vim.opt.rtp:append "C:/Users/TiboldKandrai/AppData/Local/nvim-data/lazy/plenary.nvim"
vim.opt.rtp:append(root)
vim.cmd "runtime plugin/plenary.vim"
