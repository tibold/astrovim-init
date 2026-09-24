-- Runtime for the instance under test inside the container. Deliberately not
-- the real config: this exercises nvim-mcp and the bridge, not AstroNvim.
vim.opt.rtp:append "/src/nvim-mcp"
require("nvim-mcp").setup()

-- A stub with a fixed attachment list, so `wait_for` can be tested without a
-- language server in the image. The real `diagnostics` reports `clients` the
-- same way, which is the only field the bridge's wait loop reads.
require("nvim-mcp").register {
  name = "faketest",
  description = "Stub reporting a fixed clients list.",
  inputSchema = { type = "object", properties = vim.empty_dict() },
  handler = function() return { clients = { "roslyn" }, items = {}, count = 0 } end,
}
