local announce = require "nvim-mcp.announce"

describe("announce", function()
  local dir

  before_each(function()
    dir = vim.fs.normalize(vim.fn.tempname())
    vim.env.NVIM_MCP_INSTANCES = dir
  end)

  after_each(function() vim.env.NVIM_MCP_INSTANCES = nil end)

  it("writes this editor's address, pid and directory, and removes them", function()
    if vim.v.servername == "" then vim.fn.serverstart() end
    announce.write()
    local record = vim.json.decode(table.concat(vim.fn.readfile(announce.path(vim.fn.getpid())), ""))
    assert.are.same({ vim.v.servername, vim.fn.getpid(), vim.fn.getcwd() }, { record.address, record.pid, record.cwd })
    announce.remove()
    assert.is_nil(vim.uv.fs_stat(announce.path(vim.fn.getpid())))
  end)
end)
