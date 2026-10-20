--- The test editor itself (tests/target.lua): what the other specs rely on.
local target = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/target.lua")

describe("target editor.run", function()
  local editor

  before_each(function() editor = target.start() end)
  after_each(function() editor.stop() end)

  it("hands back a false or nil result as it is, not as a string", function()
    local done = editor.run "return false"
    assert.is_true(done.ok)
    assert.is_false(done.result)

    done = editor.run "return nil"
    assert.is_true(done.ok)
    assert.is_nil(done.result)
  end)

  it("hands back an error as its message", function()
    local done = editor.run 'error("broke", 0)'
    assert.is_false(done.ok)
    assert.are.equal("broke", done.result)
  end)
end)
