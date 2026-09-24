local state = require "checklist.state"

--- Criterion 10: the order/items invariant, asserted after every mutation.
local function assert_invariant()
  local counted = 0
  for _, id in ipairs(state.order) do
    assert.is_truthy(state.items[id], ("order holds %s but items does not"):format(id))
  end
  for _ in pairs(state.items) do
    counted = counted + 1
  end
  assert.are.equal(#state.order, counted, "items and order counts diverged")
end

local function payload(...) return { ops = { ... } } end
local function set(id, extra) return vim.tbl_extend("force", { op = "set", id = id }, extra or {}) end

describe("state", function()
  before_each(function() state.reset() end)

  it("applies every op in array order (criterion 1)", function()
    local ok = state.apply_payload(
      payload(
        set("nodes", { text = "Provision nodes", group = "RKE2", state = "done" }),
        set("certmgr", { text = "cert-manager", group = "RKE2" }),
        set("dns", { text = "DNS cutover", group = "RKE2", state = "blocked", note = "vendor TTL" })
      )
    )
    assert.is_true(ok)
    assert.are.same({ "nodes", "certmgr", "dns" }, state.order)
    assert.are.equal("done", state.items.nodes.state)
    assert.are.equal("todo", state.items.certmgr.state)
    assert.are.equal("vendor TTL", state.items.dns.note)
    assert_invariant()
  end)

  it("leaves state untouched on a malformed payload (criterion 2)", function()
    state.apply_payload(payload(set("a", { text = "keep me" })))
    local items, order = vim.deepcopy(state.items), vim.deepcopy(state.order)
    assert.is_false((state.apply_payload { ops = "not an array" }))
    assert.is_false((state.apply_payload {}))
    assert.are.same(items, state.items)
    assert.are.same(order, state.order)
    assert_invariant()
  end)

  it("is idempotent for an identical set (criterion 3)", function()
    local op = set("a", { text = "Task", group = "G", note = "n" })
    state.apply_payload(payload(op))
    local items, order = vim.deepcopy(state.items), vim.deepcopy(state.order)
    state.apply_payload(payload(op))
    assert.are.same(items, state.items)
    assert.are.same(order, state.order)
    assert_invariant()
  end)

  it("merges only supplied fields on update (criterion 4)", function()
    state.apply_payload(payload(set("a", { text = "Original", group = "G", note = "n" })))
    state.apply_payload(payload(set("a", { state = "done" })))
    assert.are.equal("Original", state.items.a.text)
    assert.are.equal("G", state.items.a.group)
    assert.are.equal("n", state.items.a.note)
    assert.are.equal("done", state.items.a.state)
    assert_invariant()
  end)

  it("clears a field given an explicit JSON null", function()
    state.apply_payload(payload(set("a", { text = "T", group = "G" })))
    state.apply_payload(payload(set("a", { group = vim.NIL })))
    assert.is_nil(state.items.a.group)
    assert.are.equal("T", state.items.a.text)
  end)

  it("does not reorder on update (criterion 5)", function()
    state.apply_payload(payload(set("a", { text = "A" }), set("b", { text = "B" }), set("c", { text = "C" })))
    state.apply_payload(payload(set("a", { state = "done" })))
    assert.are.same({ "a", "b", "c" }, state.order)
    assert_invariant()
  end)

  it("treats drop of an unknown id as success (criterion 6)", function()
    state.apply_payload(payload(set("a", { text = "A" })))
    local ok = state.apply_payload(payload { op = "drop", id = "ghost" })
    assert.is_true(ok)
    assert.are.same({ "a" }, state.order)
    assert_invariant()
  end)

  it("sweeps exactly the done items, preserving order (criterion 7)", function()
    state.apply_payload(
      payload(
        set("a", { text = "A", state = "done" }),
        set("b", { text = "B" }),
        set("c", { text = "C", state = "done" }),
        set("d", { text = "D", state = "blocked" })
      )
    )
    state.apply_payload(payload { op = "sweep" })
    assert.are.same({ "b", "d" }, state.order)
    assert.is_nil(state.items.a)
    assert.is_nil(state.items.c)
    assert_invariant()
  end)

  it("accepts inprogress and keeps it through a sweep", function()
    -- The one item being worked on right now is precisely what must not
    -- disappear when the finished ones are cleared away.
    state.apply_payload(
      payload(
        set("a", { text = "A", state = "done" }),
        set("b", { text = "B", state = "inprogress" }),
        set("c", { text = "C", state = "blocked" })
      )
    )
    assert.are.equal("inprogress", state.items.b.state)
    state.apply_payload(payload { op = "sweep" })
    assert.are.same({ "b", "c" }, state.order)
    assert_invariant()
  end)

  it("still rejects a state that is not one of the four", function()
    -- Extra parentheses discard the message apply_payload returns alongside,
    -- which is how the rejection tests above read too.
    local before = vim.deepcopy(state.order)
    assert.is_false((state.apply_payload(payload(set("x", { text = "X", state = "in-progress" })))))
    assert.is_false((state.apply_payload(payload(set("x", { text = "X", state = "started" })))))
    assert.are.same(before, state.order)
  end)

  it("empties everything on clear (criterion 8)", function()
    state.apply_payload(payload(set("a", { text = "A" }), set("b", { text = "B" })))
    state.apply_payload(payload { op = "clear" })
    assert.are.same({}, state.order)
    assert.are.same({}, state.items)
    assert_invariant()
  end)

  it("applies none of an array containing one invalid op (criterion 9)", function()
    state.apply_payload(payload(set("keep", { text = "Keep" })))
    local ok = state.apply_payload(
      payload(set("good", { text = "Good" }), { op = "nonsense", id = "x" }, set("also", { text = "Also" }))
    )
    assert.is_false(ok)
    assert.are.same({ "keep" }, state.order)
    assert.is_nil(state.items.good)
    assert_invariant()
  end)

  it("rejects an invalid slug, a bad state, and a new item with no text", function()
    assert.is_false((state.apply_payload(payload(set("Bad Slug", { text = "x" })))))
    assert.is_false((state.apply_payload(payload(set("ok", { text = "x", state = "maybe" })))))
    assert.is_false((state.apply_payload(payload(set("ok", { state = "done" })))))
    assert.are.same({}, state.order)
    assert_invariant()
  end)

  it("truncates oversized fields rather than rejecting them", function()
    state.apply_payload(payload(set("a", { text = string.rep("x", 200), note = string.rep("y", 200) })))
    assert.are.equal(120, vim.fn.strchars(state.items.a.text))
    assert.are.equal(80, vim.fn.strchars(state.items.a.note))
    assert.are.equal("…", vim.fn.strcharpart(state.items.a.text, 119, 1))
    assert_invariant()
  end)

  it("caps items at 200, dropping the excess silently", function()
    local ops = {}
    for i = 1, 205 do
      ops[i] = set(("item-%d"):format(i), { text = ("Item %d"):format(i) })
    end
    assert.is_true((state.apply_payload { ops = ops }))
    assert.are.equal(state.MAX_ITEMS, #state.order)
    assert_invariant()
  end)
end)
