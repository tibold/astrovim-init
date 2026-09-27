local eval = require "nvim-mcp.eval"

describe("eval", function()
  it(
    "returns what the chunk returns",
    function()
      assert.are.same({ result = { a = 1, b = { 2, 3 } } }, eval.run { code = "return { a = 1, b = { 2, 3 } }" })
    end
  )

  it("captures what the chunk prints, and leaves print as it was", function()
    local before = print
    local reply = eval.run { code = "print('one', 2) print('three')" }
    assert.are.same({ "one\t2", "three" }, reply.printed)
    assert.are.equal(before, print)
  end)

  it("inspects a value JSON cannot carry", function()
    local reply = eval.run { code = "return { f = function() end }" }
    assert.are.equal("string", type(reply.result))
    assert.matches("function", reply.result)
  end)

  it("reports a syntax error and a runtime error as errors", function()
    assert.has_error(function() eval.run { code = "return (" } end)
    local ok, err = pcall(eval.run, { code = "error('boom')" })
    assert.is_false(ok)
    assert.matches("boom", err.message)
  end)

  it("registers on its own tool", function()
    local mcp = require "nvim-mcp"
    eval.setup()
    assert.are.equal("lua", mcp.get("eval", "lua").tool)
  end)
end)
