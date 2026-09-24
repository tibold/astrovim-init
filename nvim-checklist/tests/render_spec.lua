local state = require "checklist.state"
local render = require "checklist.render"

local function lines() return vim.api.nvim_buf_get_lines(render.ensure_buf(), 0, -1, false) end
local function set(id, extra) return vim.tbl_extend("force", { op = "set", id = id }, extra or {}) end

describe("render", function()
  before_each(function()
    state.reset()
    render.render()
  end)

  -- A heading is any non-blank line with no line_to_id entry. Deriving it from
  -- the map rather than pattern-matching icons keeps the test independent of
  -- the glyph set.
  local function headings()
    local out = {}
    for lnum, l in ipairs(lines()) do
      if l ~= "" and not render.line_to_id[lnum] then out[#out + 1] = vim.trim(l) end
    end
    return out
  end

  it("renders empty state as exactly one line (criterion 11)", function()
    assert.are.equal(1, #lines())
    assert.is_not.equal("", lines()[1])
  end)

  it("emits one heading per contiguous run, in first-appearance order (criterion 12)", function()
    state.apply_payload {
      ops = {
        set("a", { text = "A", group = "Second" }),
        set("b", { text = "B", group = "First" }),
        set("c", { text = "C", group = "Second" }),
      },
    }
    render.render()
    assert.are.same({ "Second", "First" }, headings())
  end)

  it("renders ungrouped items before the first heading (criterion 13)", function()
    state.apply_payload {
      ops = {
        set("inside", { text = "Inside", group = "Workstream" }),
        set("loose", { text = "Loose" }),
      },
    }
    render.render()
    local all = table.concat(lines(), "\n")
    assert.is_true(all:find("Loose", 1, true) < all:find("Workstream", 1, true))
    assert.are.same({ "Workstream" }, headings())
  end)

  it("truncates long text and never wraps (criterion 14)", function()
    state.apply_payload { ops = { set("a", { text = string.rep("x", 400) }) } }
    render.render()
    assert.are.equal(1, #lines()) -- one ungrouped item: no heading, no blank tail
    assert.is_true(vim.fn.strchars(lines()[1]) <= 130) -- 120 text + icon + indent
    assert.are.equal(120, vim.fn.strchars(state.items.a.text))
  end)

  it("leaves the buffer unmodifiable after every render (criterion 15)", function()
    state.apply_payload { ops = { set("a", { text = "A" }) } }
    render.render()
    assert.is_false(vim.bo[render.ensure_buf()].modifiable)
  end)

  it("updates the buffer without opening a window (criterion 16)", function()
    local before = #vim.api.nvim_tabpage_list_wins(0)
    state.apply_payload { ops = { set("a", { text = "Hidden update" }) } }
    render.render()
    assert.are.equal(before, #vim.api.nvim_tabpage_list_wins(0))
    assert.is_true(table.concat(lines(), "\n"):find("Hidden update", 1, true) ~= nil)
  end)

  it("maps item lines to ids and heading lines to nothing (criterion 17)", function()
    state.apply_payload {
      ops = {
        set("loose", { text = "Loose" }),
        set("a", { text = "A", group = "G" }),
      },
    }
    render.render()
    local mapped = 0
    for lnum, id in pairs(render.line_to_id) do
      assert.is_truthy(state.items[id])
      assert.is_true(lines()[lnum]:find(state.items[id].text, 1, true) ~= nil)
      mapped = mapped + 1
    end
    assert.are.equal(2, mapped)
  end)

  it("restores modifiable when the buffer write fails", function()
    state.apply_payload { ops = { set("a", { text = "fine" }) } }
    render.render()
    -- Assign past the sanitizer so nvim_buf_set_lines rejects the line, which
    -- is the only way a render fails in practice.
    state.items.a.text = "two\nlines"
    assert.has_error(function() render.render() end)
    assert.is_false(vim.bo[render.ensure_buf()].modifiable)
  end)

  it("cannot be typed into", function()
    state.apply_payload { ops = { set("a", { text = "An item" }) } }
    render.render()
    local buf = render.ensure_buf()
    assert.is_false(vim.bo[buf].modifiable)
    assert.is_false(vim.bo[buf].modified)
    assert.are.equal("nofile", vim.bo[buf].buftype)
    assert.is_false(vim.bo[buf].swapfile)
  end)

  it("recreates the buffer after :bwipeout (criterion 20)", function()
    local old = render.ensure_buf()
    vim.api.nvim_buf_delete(old, { force = true })
    render.render()
    local new = render.ensure_buf()
    assert.is_true(vim.api.nvim_buf_is_valid(new))
    assert.are_not.equal(old, new)
  end)

  it("puts a note on its own line beneath the item", function()
    -- Appended, a note pushed the line past the panel width, and the panel
    -- never wraps, so what a blocked item was waiting on fell off the edge.
    state.apply_payload { ops = { set("a", { text = "Cut DNS over", note = "vendor TTL is 48h" }) } }
    render.render()
    local out = lines()
    assert.are.equal(2, #out)
    assert.is_true(out[1]:find("Cut DNS over", 1, true) ~= nil)
    assert.is_nil(out[1]:find("vendor TTL", 1, true), "note is still on the item line")
    assert.is_true(out[2]:find("vendor TTL is 48h", 1, true) ~= nil)
  end)

  it("maps a note line to its own item, so the keymaps still reach it", function()
    state.apply_payload { ops = { set("a", { text = "Cut DNS over", note = "vendor TTL" }) } }
    render.render()
    assert.are.equal("a", render.line_to_id[1])
    assert.are.equal("a", render.line_to_id[2])
  end)

  it("gives the note line the muted highlight and nothing else", function()
    state.apply_payload { ops = { set("a", { text = "Item", note = "why" }) } }
    local _, highlights = render.build()
    local on_note = vim.tbl_filter(function(h) return h.line == 1 end, highlights)
    assert.are.equal(1, #on_note)
    assert.are.equal("ChecklistNote", on_note[1].group)
  end)

  it("renders an inprogress item with its own icon and highlight", function()
    state.apply_payload {
      ops = {
        set("a", { text = "Running", state = "inprogress" }),
        set("b", { text = "Waiting" }),
      },
    }
    local out, highlights = render.build()
    assert.are_not.equal(out[1], out[2])
    local first = vim.tbl_filter(function(h) return h.line == 0 end, highlights)[1]
    assert.are.equal("ChecklistInprogress", first.group)
  end)

  it("does not strike through an inprogress item, only a done one", function()
    state.apply_payload { ops = { set("a", { text = "Running", state = "inprogress" }) } }
    local _, highlights = render.build()
    for _, h in ipairs(highlights) do
      assert.are_not.equal("ChecklistStrike", h.group)
    end
  end)

  it("produces identical lines for a repeated identical payload (criterion 3)", function()
    local p = { ops = { set("a", { text = "Task", group = "G", note = "n" }) } }
    state.apply_payload(p)
    render.render()
    local first = vim.deepcopy(lines())
    state.apply_payload(p)
    render.render()
    assert.are.same(first, lines())
  end)
end)
