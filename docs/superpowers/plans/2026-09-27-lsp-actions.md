# LSP actions for nvim-mcp — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the language servers the human's Neovim is already running — navigation and LSP-driven edits — as nvim-mcp actions, plus an `lsp` skill telling Claude when to use them.

**Architecture:** A new `nvim-mcp/lua/nvim-mcp/lsp/` package registers actions into the existing nvim-mcp registry, the way nvim-checklist does; the bridge is untouched. Four small modules carry the plumbing — `position` (path/line/symbol → LSP position), `request` (pick a client, synchronous request with timeout), `notice` (a floating "Claude · LSP …" window while the editor is blocked), `edit` (all-or-nothing apply-and-save of a WorkspaceEdit) — and `lsp/init.lua` holds the actions and their registration.

**Tech Stack:** Lua on Neovim 0.12 (`vim.lsp` client methods, `vim.lsp.util`), plenary.nvim busted tests, an in-process fake language server (`vim.lsp.start` with a `cmd` function).

**Spec:** `docs/superpowers/specs/2026-09-27-lsp-actions-design.md` — read it before starting any task.

## Global Constraints

- Neovim 0.12 APIs: `client:request_sync`, `client:supports_method(method, bufnr)`, `vim.lsp.get_configs`, `vim.str_utfindex(s, encoding, index, strict)`.
- Lines and columns in args and replies are **1-based and count characters** (not bytes).
- Requests are synchronous; `timeout` is in seconds, **default 5, capped at 30**.
- Read-only actions show the notice only after **300 ms** (`QUIET_MS`); edit actions show it immediately.
- Summaries cap location lists at **20** (`SHOWN`); `detail = "full"` returns everything.
- Every edit is **applied and saved**; if any touched buffer has unsaved changes the whole edit is refused with `{ applied = false, reason = "modified", files = [...] }` and nothing is applied.
- Errors are `error { code, message }`: `-32602` for bad arguments, `-32603` for server/editor failures. Never let a raw Lua error escape.
- Action descriptions are one line; detail belongs in the `lsp` skill.
- Advertised: `definition`, `references`, `hover`, `rename`. Hidden: `implementation`, `symbols`, `calls`, `code_actions`, `code_action`, `format`.
- Code style: match `nvim-mcp/lua/nvim-mcp/actions.lua` — `---` doc comments that explain *why*, `require "x"` without parentheses, two-space indent.
- Commit messages: imperative subject, a short body explaining why, ending with
  `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`. Commit only the files the task touched (the working tree carries unrelated human changes — `lazy-lock.json`, `lua/community.lua`, `lua/plugins/neotest.lua`, `lua/plugins/rust.lua` — never stage them).

## Review Focus

1. **Characters wider than one byte before the symbol** (`é`, emoji) — the server must receive the right column in its own encoding (utf-16 / utf-8). Pinned in Task 1.
2. **A path spelled differently from the open buffer** (backslashes, other case on Windows, relative) — must resolve to the already-open buffer, never a duplicate. Pinned in Task 1.
3. **An edit touching files that were not open** — they are edited and saved, then unlisted so a 30-file rename does not leave 30 buffers in the human's bufferline; undo history kept. Pinned in Task 5.
4. **A touched file that cannot be written** (read-only buffer) — the rest are still saved and the failure is reported in `failed`, not swallowed. Pinned in Task 5.
5. **A server command whose `workspace/applyEdit` lands in a buffer with unsaved work** — refused, the server is told `applied = false`, and the reply says why. Pinned in Task 7.

## File Structure

| file | responsibility |
|---|---|
| `nvim-mcp/tests/minimal_init.lua` | fix: plenary path from `stdpath("data")`, not a hardcoded user |
| `nvim-mcp/tests/fake_lsp.lua` | create: in-process fake language server for tests |
| `nvim-mcp/lua/nvim-mcp/lsp/position.lua` | create: buffer lookup/loading, symbol → column, encodings, ranges |
| `nvim-mcp/lua/nvim-mcp/lsp/request.lua` | create: timeout, client selection, synchronous send |
| `nvim-mcp/lua/nvim-mcp/lsp/notice.lua` | create: the floating notice |
| `nvim-mcp/lua/nvim-mcp/lsp/edit.lua` | create: refuse-or-apply-and-save, applyEdit capture |
| `nvim-mcp/lua/nvim-mcp/lsp/init.lua` | create: the actions and `setup()` registration |
| `nvim-mcp/lua/nvim-mcp/init.lua` | modify: `setup()` also calls `require("nvim-mcp.lsp").setup()` |
| `nvim-mcp/tests/lsp_*_spec.lua` | create: one spec per module / action group |
| `claude/skills/lsp/SKILL.md` | create: the skill |
| `claude/skills/nvim/SKILL.md` | modify: one-line pointer to `lsp` |
| `nvim-mcp/README.md` | modify: document the LSP actions |

**Running tests** (from `C:\Users\Tibold\AppData\Local\nvim\nvim-mcp`, after Task 1 Step 1):

```bash
# one file
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lsp_position_spec.lua"
# everything
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"
```

Both exit on their own and print `Success / Failed / Errors` counts. Baseline before this plan: 31 passing.

---

### Task 1: Test harness and `position`

**Files:**
- Modify: `nvim-mcp/tests/minimal_init.lua`
- Create: `nvim-mcp/tests/fake_lsp.lua`
- Create: `nvim-mcp/lua/nvim-mcp/lsp/position.lua`
- Test: `nvim-mcp/tests/lsp_position_spec.lua`

**Interfaces:**
- Produces (`fake_lsp`): `file(lines, name?) -> path, dir`; `start(buffer, root, opts) -> client, requests` where `opts = { name?, capabilities?, handlers? = { [method] = function(params, dispatchers) -> result } }`; sentinels `NEVER` (never answer) and `failure(code, message)` (answer with an error); `range(line0, from, to)`; `stop_all()`.
- Produces (`position`): `invalid(message)` (throws -32602); `buffer_for(path) -> bufnr|nil`; `buffer(path) -> bufnr`; `line_text(buffer, line) -> string`; `byte_column(buffer, line, symbol?, column?) -> byte (1-based)`; `char_to_byte(text, column) -> byte`; `byte_to_char(text, byte) -> column`; `params(buffer, line, byte, encoding) -> TextDocumentPositionParams`; `line_range(buffer, first, last, encoding) -> Range`.

- [ ] **Step 1: Fix the test init so the suite runs on this machine**

`tests/minimal_init.lua` hardcodes `C:/Users/TiboldKandrai/...`, which does not exist here; the suite hangs. Replace the whole file:

```lua
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(here, ":h")

-- From stdpath rather than a spelled-out home directory: the user name differs
-- between machines, and a missing plenary hangs the run instead of failing it.
vim.opt.rtp:append(vim.fn.stdpath "data" .. "/lazy/plenary.nvim")
vim.opt.rtp:append(root)
vim.cmd "runtime plugin/plenary.vim"
```

Run the full suite. Expected: 31 successes, 0 failed, 0 errors.

- [ ] **Step 2: Write the fake server helper**

Create `tests/fake_lsp.lua`:

```lua
--- An in-process language server for tests: vim.lsp.start with a `cmd`
--- function, as Neovim's own LSP tests do. Handlers answer with fixed data, so
--- the actions can be tested without a real server installed.
local M = {}

--- Returned by a handler: never answer, so the request times out.
M.NEVER = setmetatable({}, { __name = "NEVER" })

--- Returned by a handler: answer with an LSP error instead of a result.
function M.failure(code, message) return { __failure = { code = code, message = message } } end

--- Write `lines` to a new file in a fresh temp directory.
function M.file(lines, name)
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/" .. (name or "a.txt")
  vim.fn.writefile(lines, path)
  return path, dir
end

--- A range on one line, 0-based as LSP has it.
function M.range(line, from, to)
  return { start = { line = line, character = from }, ["end"] = { line = line, character = to } }
end

--- Start a fake server attached to `buffer`, which must already be loaded:
--- vim.lsp.start returns nil for an unloaded buffer.
--- Returns the initialised client and a log of every request it received.
function M.start(buffer, root, opts)
  opts = opts or {}
  local requests = {}
  local id = vim.lsp.start({
    name = opts.name or "fake",
    root_dir = root,
    cmd = function(dispatchers)
      local count = 0
      return {
        request = function(method, params, callback)
          count = count + 1
          requests[#requests + 1] = { method = method, params = params }
          -- Answer on a later tick, as a real server would: the client is
          -- still inside request() at this point.
          vim.schedule(function()
            local result
            if method == "initialize" then
              result = { capabilities = opts.capabilities or {} }
            elseif method == "shutdown" then
              result = vim.NIL
            else
              local handler = (opts.handlers or {})[method]
              if handler then result = handler(params, dispatchers) end
            end
            if result == M.NEVER then return end
            if type(result) == "table" and result.__failure then return callback(result.__failure, nil) end
            if result == nil then result = vim.NIL end
            callback(nil, result)
          end)
          return true, count
        end,
        notify = function() return true end,
        is_closing = function() return false end,
        terminate = function() end,
      }
    end,
  }, { bufnr = buffer })
  assert(id, "vim.lsp.start refused: is the buffer loaded?")
  local client = vim.lsp.get_client_by_id(id)
  vim.wait(1000, function() return client.initialized end, 10)
  return client, requests
end

--- Stop every client, so one test's server cannot answer another's request.
function M.stop_all()
  for _, client in ipairs(vim.lsp.get_clients()) do
    client:stop(true)
  end
  vim.wait(1000, function() return #vim.lsp.get_clients() == 0 end, 10)
end

return M
```

- [ ] **Step 3: Write the failing position tests**

Create `tests/lsp_position_spec.lua`:

```lua
local position = require "nvim-mcp.lsp.position"
local fake = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/fake_lsp.lua")

local function loaded(lines)
  local path = fake.file(lines)
  return position.buffer(path), path
end

describe("position.buffer", function()
  it("loads a file without listing it", function()
    local buffer = loaded { "x" }
    assert.is_true(vim.api.nvim_buf_is_loaded(buffer))
    assert.is_false(vim.bo[buffer].buflisted)
  end)

  it("refuses a missing file and a missing path", function()
    assert.has_error(function() position.buffer "Z:/definitely/not/here.lua" end)
    assert.has_error(function() position.buffer(nil) end)
  end)

  it("finds the open buffer however the path is spelled", function()
    local path = fake.file { "x" }
    local opened = vim.fn.bufadd(path)
    vim.fn.bufload(opened)
    local spelled = path:gsub("/", "\\")
    if vim.fn.has "win32" == 1 then spelled = spelled:upper() end
    assert.are.equal(opened, position.buffer(spelled))
  end)
end)

describe("position.byte_column", function()
  it("finds a symbol as a whole word", function()
    local buffer = loaded { "foo foobar foo_x" }
    assert.are.equal(5, position.byte_column(buffer, 1, "foobar"))
  end)

  it("does not match a symbol inside a longer word", function()
    local buffer = loaded { "foobar foo" }
    assert.are.equal(8, position.byte_column(buffer, 1, "foo"))
  end)

  it("matches symbols that start or end with punctuation", function()
    local buffer = loaded { "a -> b" }
    assert.are.equal(3, position.byte_column(buffer, 1, "->"))
  end)

  it("lists the words on the line when the symbol is missing", function()
    local buffer = loaded { "local value = other" }
    local ok, err = pcall(position.byte_column, buffer, 1, "missing")
    assert.is_false(ok)
    assert.are.equal(-32602, err.code)
    assert.matches("is not on line 1", err.message)
    assert.matches("local, value, other", err.message)
  end)

  it("asks for a column when the symbol is ambiguous, and honours one", function()
    local buffer = loaded { "foo(foo)" }
    local ok, err = pcall(position.byte_column, buffer, 1, "foo")
    assert.is_false(ok)
    assert.matches("appears 2 times", err.message)
    assert.are.equal(5, position.byte_column(buffer, 1, "foo", 6))
  end)

  it("takes a character column when no symbol is given", function()
    local buffer = loaded { "é = foo" }
    assert.are.equal(6, position.byte_column(buffer, 1, nil, 5))
  end)

  it("refuses a line past the end and a missing position", function()
    local buffer = loaded { "one" }
    assert.has_error(function() position.byte_column(buffer, 2, "one") end)
    assert.has_error(function() position.byte_column(buffer, 1) end)
  end)
end)

describe("position encodings", function()
  it("converts past wide characters for each encoding", function()
    local buffer = loaded { "é😀 = foo" }
    local byte = position.byte_column(buffer, 1, "foo")
    assert.are.equal(10, byte) -- é is 2 bytes, 😀 is 4
    assert.are.equal(9, position.params(buffer, 1, byte, "utf-8").position.character)
    assert.are.equal(6, position.params(buffer, 1, byte, "utf-16").position.character) -- 😀 is a surrogate pair
    assert.are.equal(5, position.params(buffer, 1, byte, "utf-32").position.character)
    assert.are.equal(0, position.params(buffer, 1, byte, "utf-16").position.line)
  end)

  it("round-trips byte and character columns", function()
    assert.are.equal(6, position.char_to_byte("é = foo", 5))
    assert.are.equal(5, position.byte_to_char("é = foo", 6))
  end)

  it("builds a whole-line range ending at the last line's length", function()
    local buffer = loaded { "first", "sé" }
    local range = position.line_range(buffer, 1, 2, "utf-16")
    assert.are.same({ line = 0, character = 0 }, range.start)
    assert.are.same({ line = 1, character = 2 }, range["end"])
    assert.has_error(function() position.line_range(buffer, 2, 1, "utf-16") end)
  end)
end)
```

- [ ] **Step 4: Run it to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lsp_position_spec.lua"`
Expected: errors — `module 'nvim-mcp.lsp.position' not found`.

- [ ] **Step 5: Implement `position`**

Create `lua/nvim-mcp/lsp/position.lua`:

```lua
--- Turning `{ path, line, symbol | column }` into an LSP position.
---
--- Lines and columns are 1-based and count characters, as Read output and the
--- editor show them. Columns are where a caller slips, so `symbol` -- the word
--- at that spot -- is the preferred way to point, and the column is found here.
local M = {}

function M.invalid(message) error { code = -32602, message = message } end

local function same_file(a, b) return vim.fs.normalize(a):lower() == vim.fs.normalize(b):lower() end

--- The buffer already holding `path`, if any. bufnr() would read the path as a
--- pattern, and Windows spells one file several ways, so names are compared
--- normalised, as `close` does.
function M.buffer_for(path)
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buffer)
    if name ~= "" and same_file(name, path) then return buffer end
  end
end

--- The loaded buffer for `path`, without showing it. A buffer this loads gets
--- its filetype detected, because language servers attach on FileType.
function M.buffer(path)
  if type(path) ~= "string" or path == "" then M.invalid "a path is required" end
  local full = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  if not vim.uv.fs_stat(full) then M.invalid("no such file: " .. full) end

  local buffer = M.buffer_for(full) or vim.fn.bufadd(full)
  if not vim.api.nvim_buf_is_loaded(buffer) then
    vim.fn.bufload(buffer)
    if vim.bo[buffer].filetype == "" then
      vim.api.nvim_buf_call(buffer, function() vim.cmd "filetype detect" end)
    end
  end
  return buffer
end

function M.line_text(buffer, line)
  if type(line) ~= "number" or line < 1 then M.invalid "line must be a 1-based number" end
  local text = vim.api.nvim_buf_get_lines(buffer, line - 1, line, false)[1]
  if not text then
    M.invalid(("line %d is past the end of the file (%d lines)"):format(line, vim.api.nvim_buf_line_count(buffer)))
  end
  return text
end

local function is_word(char) return char ~= "" and char:match "[%w_]" ~= nil end

--- Every 1-based byte column where `symbol` occurs as a whole word. The word
--- check applies only at an edge that is itself a word character, so `->`
--- still matches between spaces.
local function occurrences(text, symbol)
  local hits, from = {}, 1
  while true do
    local first, last = text:find(symbol, from, true)
    if not first then return hits end
    local clean_start = not is_word(symbol:sub(1, 1)) or not is_word(text:sub(first - 1, first - 1))
    local clean_end = not is_word(symbol:sub(-1)) or not is_word(text:sub(last + 1, last + 1))
    if clean_start and clean_end then hits[#hits + 1] = first end
    from = first + 1
  end
end

local function words(text)
  local out, seen = {}, {}
  for word in text:gmatch "[%w_]+" do
    if not seen[word] then
      seen[word] = true
      out[#out + 1] = word
    end
  end
  return table.concat(out, ", ")
end

--- 1-based character column to 1-based byte column.
function M.char_to_byte(text, column)
  column = tonumber(column)
  if not column or column < 1 then M.invalid "column must be a 1-based number" end
  local length = vim.str_utfindex(text, "utf-32", nil, false)
  if column > length + 1 then
    M.invalid(("column %d is past the end of the line (%d characters)"):format(column, length))
  end
  return vim.str_byteindex(text, "utf-32", column - 1, false) + 1
end

--- 1-based byte column to 1-based character column.
function M.byte_to_char(text, byte) return vim.str_utfindex(text, "utf-32", byte - 1, false) + 1 end

--- The byte column to ask about. A symbol found once wins; found several
--- times, `column` picks which; not found, the error lists what is there.
function M.byte_column(buffer, line, symbol, column)
  local text = M.line_text(buffer, line)
  if symbol == nil or symbol == "" then
    if column == nil then M.invalid "pass symbol (preferred) or column" end
    return M.char_to_byte(text, column)
  end

  local hits = occurrences(text, symbol)
  if #hits == 1 then return hits[1] end
  if #hits > 1 and column ~= nil then
    local byte = M.char_to_byte(text, column)
    for _, hit in ipairs(hits) do
      if byte >= hit and byte < hit + #symbol then return hit end
    end
  end
  local why = #hits == 0 and "is not on" or ("appears %d times on"):format(#hits)
  M.invalid(("%q %s line %d; pass column to choose. Words there: %s"):format(symbol, why, line, words(text)))
end

--- TextDocumentPositionParams for a 1-based line and byte column, in the
--- server's own position encoding.
function M.params(buffer, line, byte, encoding)
  local text = M.line_text(buffer, line)
  return {
    textDocument = { uri = vim.uri_from_bufnr(buffer) },
    position = { line = line - 1, character = vim.str_utfindex(text, encoding, byte - 1, false) },
  }
end

--- A Range covering whole lines `first`..`last` (1-based, inclusive).
function M.line_range(buffer, first, last, encoding)
  first, last = tonumber(first), tonumber(last)
  if not first or not last or last < first then
    M.invalid "line and end_line must be 1-based, with end_line >= line"
  end
  M.line_text(buffer, first)
  local last_text = M.line_text(buffer, last)
  return {
    start = { line = first - 1, character = 0 },
    ["end"] = { line = last - 1, character = vim.str_utfindex(last_text, encoding, nil, false) },
  }
end

return M
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lsp_position_spec.lua"`
Expected: all pass. If "finds the open buffer however the path is spelled" fails, `buffer_for` is not being consulted before `bufadd` — fix the code, not the test.

- [ ] **Step 7: Commit**

```bash
git add nvim-mcp/tests/minimal_init.lua nvim-mcp/tests/fake_lsp.lua nvim-mcp/lua/nvim-mcp/lsp/position.lua nvim-mcp/tests/lsp_position_spec.lua
git commit -m "Resolve LSP positions from a line and the symbol on it" -m "Columns are where a caller slips -- counted from Read output, off by a tab or a
multi-byte character -- so the word at that spot is the preferred way to point,
and the column is found and converted to the server's encoding here.

The test init named a plenary path under another user's home, which hung the
suite on this machine; it now comes from stdpath.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `request` and `notice`

**Files:**
- Create: `nvim-mcp/lua/nvim-mcp/lsp/request.lua`
- Create: `nvim-mcp/lua/nvim-mcp/lsp/notice.lua`
- Test: `nvim-mcp/tests/lsp_request_spec.lua`

**Interfaces:**
- Consumes: `fake_lsp` (Task 1).
- Produces (`request`): `DEFAULT_TIMEOUT = 5`, `MAX_TIMEOUT = 30`; `timeout_ms(args) -> integer`; `clients(buffer, method, ms) -> client[]` (throws -32603 with an explanation when none); `client(buffer, method, ms) -> client`; `send(client, method, params, buffer?, ms) -> result|nil, timed_out:boolean`.
- Produces (`notice`): `open(text, delay_ms) -> handle`; `close(handle)`; `during(text, delay_ms, fn) -> ...fn's returns`; `active` — the handle currently shown, or nil (tests read it).

- [ ] **Step 1: Write the failing tests**

Create `tests/lsp_request_spec.lua`:

```lua
local request = require "nvim-mcp.lsp.request"
local notice = require "nvim-mcp.lsp.notice"
local position = require "nvim-mcp.lsp.position"
local fake = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/fake_lsp.lua")

local function with_server(opts)
  local path, dir = fake.file { "local foo = 1" }
  local buffer = position.buffer(path)
  local client = fake.start(buffer, dir, opts)
  return buffer, client
end

local HOVER = "textDocument/hover"
local function params(buffer) return position.params(buffer, 1, 7, "utf-16") end

describe("request.timeout_ms", function()
  it("defaults to five seconds and clamps", function()
    assert.are.equal(5000, request.timeout_ms {})
    assert.are.equal(30000, request.timeout_ms { timeout = 600 })
    assert.are.equal(100, request.timeout_ms { timeout = 0 })
    assert.are.equal(1500, request.timeout_ms { timeout = 1.5 })
  end)
end)

describe("request.clients", function()
  after_each(fake.stop_all)

  it("fails at once, naming the filetype, when nothing is attached", function()
    local buffer = position.buffer(fake.file({ "x" }, "plain.txt"))
    local started = vim.uv.now()
    local ok, err = pcall(request.clients, buffer, HOVER, 5000)
    assert.is_false(ok)
    assert.are.equal(-32603, err.code)
    assert.matches("No language server is attached", err.message)
    assert.matches('filetype "text"', err.message)
    assert.is_true(vim.uv.now() - started < 1000, "must not wait for a server that is not coming")
  end)

  it("names the servers when none supports the method", function()
    local buffer = with_server { capabilities = {} }
    local ok, err = pcall(request.clients, buffer, HOVER, 1000)
    assert.is_false(ok)
    assert.matches("fake: no server here supports textDocument/hover", err.message)
  end)

  it("returns the servers that support the method", function()
    local buffer = with_server { capabilities = { hoverProvider = true } }
    local found = request.clients(buffer, HOVER, 1000)
    assert.are.equal(1, #found)
    assert.are.equal("fake", found[1].name)
  end)
end)

describe("request.send", function()
  after_each(fake.stop_all)

  it("returns the result", function()
    local buffer, client = with_server {
      capabilities = { hoverProvider = true },
      handlers = { [HOVER] = function() return { contents = "hi" } end },
    }
    local result, timed_out = request.send(client, HOVER, params(buffer), buffer, 1000)
    assert.are.same({ contents = "hi" }, result)
    assert.is_false(timed_out)
  end)

  it("maps a null result to nil", function()
    local buffer, client = with_server { capabilities = { hoverProvider = true } }
    local result = request.send(client, HOVER, params(buffer), buffer, 1000)
    assert.is_nil(result)
  end)

  it("reports a timeout rather than throwing", function()
    local buffer, client = with_server {
      capabilities = { hoverProvider = true },
      handlers = { [HOVER] = function() return fake.NEVER end },
    }
    local result, timed_out = request.send(client, HOVER, params(buffer), buffer, 100)
    assert.is_nil(result)
    assert.is_true(timed_out)
  end)

  it("turns a server error into a readable one", function()
    local buffer, client = with_server {
      capabilities = { hoverProvider = true },
      handlers = { [HOVER] = function() return fake.failure(-32801, "content modified") end },
    }
    local ok, err = pcall(request.send, client, HOVER, params(buffer), buffer, 1000)
    assert.is_false(ok)
    assert.are.equal(-32603, err.code)
    assert.matches("fake: content modified", err.message)
  end)
end)

describe("notice", function()
  local function text_of(handle)
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(handle.shown.window), 0, -1, false)[1]
  end

  it("shows immediately without a delay, and closes", function()
    local handle = notice.open("Claude · LSP rename a → b (fake)…", 0)
    assert.is_truthy(handle.shown)
    assert.matches("rename a → b", text_of(handle))
    assert.are.equal(handle, notice.active)
    local window = handle.shown.window
    notice.close(handle)
    assert.is_false(vim.api.nvim_win_is_valid(window))
    assert.is_nil(notice.active)
  end)

  it("waits out the delay, and never shows if closed first", function()
    local late = notice.open("late", 50)
    assert.is_nil(late.shown)
    vim.wait(500, function() return late.shown ~= nil end, 10)
    assert.is_truthy(late.shown)
    notice.close(late)

    local early = notice.open("early", 50)
    notice.close(early)
    vim.wait(150)
    assert.is_nil(early.shown)
  end)

  it("shows a delayed notice while a slow request blocks", function()
    local buffer, client = with_server {
      capabilities = { hoverProvider = true },
      handlers = {
        [HOVER] = function() return fake.NEVER end,
      },
    }
    local seen = false
    notice.during("slow", 50, function()
      local timer = vim.uv.new_timer()
      timer:start(200, 0, vim.schedule_wrap(function()
        seen = notice.active ~= nil and notice.active.shown ~= nil
        timer:close()
      end))
      request.send(client, HOVER, params(buffer), buffer, 400)
    end)
    assert.is_true(seen)
    fake.stop_all()
  end)

  it("closes and rethrows when the work fails", function()
    local ok, err = pcall(notice.during, "x", 0, function() error { code = -32603, message = "boom" } end)
    assert.is_false(ok)
    assert.are.equal("boom", err.message)
    assert.is_nil(notice.active)
  end)

  it("passes every return value through", function()
    local a, b = notice.during("x", 0, function() return 1, true end)
    assert.are.equal(1, a)
    assert.is_true(b)
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lsp_request_spec.lua"`
Expected: errors — `module 'nvim-mcp.lsp.request' not found`.

- [ ] **Step 3: Implement `request`**

Create `lua/nvim-mcp/lsp/request.lua`:

```lua
--- Choosing a server and asking it, synchronously.
---
--- Synchronous on purpose: one tool call per request, nothing to poll. The cost
--- is that the human's editor waits while a request runs, so every request
--- carries a timeout and the notice says what is happening. If the wait ever
--- becomes a problem, the fix is bridge-side polling, as `wait_for` does -- not
--- making calls less efficient.
local M = {}

M.DEFAULT_TIMEOUT = 5
M.MAX_TIMEOUT = 30

function M.timeout_ms(args)
  local seconds = tonumber(args and args.timeout) or M.DEFAULT_TIMEOUT
  seconds = math.max(0.1, math.min(seconds, M.MAX_TIMEOUT))
  return math.floor(seconds * 1000)
end

local function names(clients)
  return table.concat(vim.tbl_map(function(client) return client.name end, clients), ", ")
end

--- The servers on `buffer` that answer `method`. A server still initialising
--- is waited for, up to `ms`; none attached at all fails at once, because
--- waiting would freeze the editor for a server that is not coming.
function M.clients(buffer, method, ms)
  local function supporting()
    return vim.tbl_filter(
      function(client) return client.initialized and client:supports_method(method, buffer) end,
      vim.lsp.get_clients { bufnr = buffer }
    )
  end

  local found = supporting()
  if #found == 0 then
    vim.wait(ms, function()
      found = supporting()
      local starting = vim.iter(vim.lsp.get_clients { bufnr = buffer }):any(function(c) return not c.initialized end)
      return #found > 0 or not starting
    end, 20)
  end
  if #found > 0 then return found end

  local attached = vim.lsp.get_clients { bufnr = buffer }
  if #attached == 0 then
    local filetype = vim.bo[buffer].filetype
    local configured = vim.tbl_map(
      function(config) return config.name end,
      vim.lsp.get_configs { enabled = true, filetype = filetype }
    )
    local hint = #configured > 0 and (" %s is configured for it."):format(table.concat(configured, ", ")) or ""
    error {
      code = -32603,
      message = ("No language server is attached to %s (filetype %q).%s If one is still starting, call diagnostics with wait_for, then retry."):format(
        vim.api.nvim_buf_get_name(buffer),
        filetype,
        hint
      ),
    }
  end
  error { code = -32603, message = ("%s: no server here supports %s"):format(names(attached), method) }
end

function M.client(buffer, method, ms) return M.clients(buffer, method, ms)[1] end

--- One request. Returns the result (nil for a null one) and whether it timed
--- out; a timed-out request is cancelled by request_sync itself.
function M.send(client, method, params, buffer, ms)
  local response, reason = client:request_sync(method, params, ms, buffer)
  if not response then
    if reason == "timeout" then return nil, true end
    error { code = -32603, message = ("%s: %s failed (%s)"):format(client.name, method, reason or "request refused") }
  end
  if response.err then
    local message = type(response.err) == "table" and response.err.message or tostring(response.err)
    error { code = -32603, message = ("%s: %s"):format(client.name, message) }
  end
  if response.result == vim.NIL then return nil, false end
  return response.result, false
end

return M
```

- [ ] **Step 4: Implement `notice`**

Create `lua/nvim-mcp/lsp/notice.lua`:

```lua
--- The notice the human sees while their editor waits on a request.
---
--- A floating window drawn with an explicit redraw, not vim.notify: a notifier
--- plugin may render on a later tick, which never comes while the main loop is
--- blocked. A delayed notice still works because request_sync waits with
--- vim.wait, which runs scheduled callbacks.
local M = {}

--- The handle currently on screen, if any.
M.active = nil

local function show(text)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { text })
  local width = math.max(1, math.min(vim.fn.strdisplaywidth(text), vim.o.columns - 4))
  local window = vim.api.nvim_open_win(buffer, false, {
    relative = "editor",
    anchor = "NE",
    row = 1,
    col = vim.o.columns - 1,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    focusable = false,
    noautocmd = true,
    zindex = 250,
  })
  vim.cmd.redraw()
  return { window = window, buffer = buffer }
end

--- Put `text` up now, or after `delay_ms` if still open by then.
function M.open(text, delay_ms)
  local handle = { text = text }
  if not delay_ms or delay_ms <= 0 then
    handle.shown = show(text)
    M.active = handle
    return handle
  end
  handle.timer = vim.uv.new_timer()
  handle.timer:start(delay_ms, 0, vim.schedule_wrap(function()
    if handle.closed then return end
    handle.shown = show(text)
    M.active = handle
  end))
  return handle
end

function M.close(handle)
  handle.closed = true
  if handle.timer then
    handle.timer:stop()
    if not handle.timer:is_closing() then handle.timer:close() end
  end
  if handle.shown then
    pcall(vim.api.nvim_win_close, handle.shown.window, true)
    pcall(vim.api.nvim_buf_delete, handle.shown.buffer, { force = true })
    pcall(vim.cmd.redraw)
  end
  if M.active == handle then M.active = nil end
end

--- Run `fn` with the notice up, closing it however `fn` ends.
function M.during(text, delay_ms, fn)
  local handle = M.open(text, delay_ms)
  local results = vim.F.pack_len(pcall(fn))
  M.close(handle)
  if not results[1] then error(results[2], 0) end
  return vim.F.unpack_len(results, 2)
end

return M
```

Note: `vim.F.unpack_len(t, 2)` — if `vim.F.unpack_len` does not accept a start index in this Neovim, use `unpack(results, 2, results.n)` instead.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lsp_request_spec.lua"`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add nvim-mcp/lua/nvim-mcp/lsp/request.lua nvim-mcp/lua/nvim-mcp/lsp/notice.lua nvim-mcp/tests/lsp_request_spec.lua
git commit -m "Ask language servers synchronously, with a notice while the editor waits"
```

---

### Task 3: Navigation actions and registration

**Files:**
- Create: `nvim-mcp/lua/nvim-mcp/lsp/init.lua`
- Modify: `nvim-mcp/lua/nvim-mcp/init.lua` (`M.setup`, last function in the file)
- Test: `nvim-mcp/tests/lsp_navigate_spec.lua`

**Interfaces:**
- Consumes: `position.*`, `request.*`, `notice.during` (Tasks 1–2).
- Produces (`nvim-mcp.lsp`): `QUIET_MS = 300`, `SHOWN = 20`; `locate(args, method) -> at` where `at = { buffer, client, ms, line, byte, params, what }`; `label(verb, at) -> string`; `locations(result, encoding) -> { file, line, column, text }[]`; `summarise(locations, opts) -> reply`; actions `definition(args, opts)`, `references(args, opts)`, `implementation(args, opts)`, `hover(args)`; `SCHEMA` helpers `positioned(extra, required)`; `setup()`. Later tasks add actions to this same module and extend `setup()`.

- [ ] **Step 1: Write the failing tests**

Create `tests/lsp_navigate_spec.lua`:

```lua
local lsp = require "nvim-mcp.lsp"
local mcp = require "nvim-mcp"
local position = require "nvim-mcp.lsp.position"
local fake = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/fake_lsp.lua")

local LINES = { "local foo = 1", "print(foo)", "print(foo + foo)" }

local function server(handlers)
  local path, dir = fake.file(LINES)
  local buffer = position.buffer(path)
  local uri = vim.uri_from_fname(path)
  local _, requests = fake.start(buffer, dir, {
    capabilities = {
      definitionProvider = true,
      referencesProvider = true,
      hoverProvider = true,
      implementationProvider = true,
    },
    handlers = handlers(uri),
  })
  return path, requests
end

describe("navigation", function()
  after_each(fake.stop_all)

  it("finds a definition from the symbol on a line", function()
    local path, requests = server(function(uri)
      return { ["textDocument/definition"] = function() return { uri = uri, range = fake.range(0, 6, 9) } end }
    end)
    local reply = lsp.definition({ path = path, line = 2, symbol = "foo" }, {})
    assert.are.equal("fake", reply.server)
    assert.are.equal(1, reply.count)
    assert.are.same(
      { file = vim.fs.normalize(path), line = 1, column = 7, text = "local foo = 1" },
      reply.locations[1]
    )
    local sent = requests[#requests].params.position
    assert.are.same({ line = 1, character = 6 }, sent)
  end)

  it("accepts a LocationLink answer", function()
    local path = server(function(uri)
      return {
        ["textDocument/definition"] = function()
          return { { targetUri = uri, targetRange = fake.range(0, 0, 13), targetSelectionRange = fake.range(0, 6, 9) } }
        end,
      }
    end)
    local reply = lsp.definition({ path = path, line = 2, symbol = "foo" }, {})
    assert.are.equal(1, reply.locations[1].line)
  end)

  it("summarises references, grouped by file, and asks for the declaration", function()
    local original = lsp.SHOWN
    lsp.SHOWN = 2
    local path, requests = server(function(uri)
      return {
        ["textDocument/references"] = function()
          return {
            { uri = uri, range = fake.range(0, 6, 9) },
            { uri = uri, range = fake.range(1, 6, 9) },
            { uri = uri, range = fake.range(2, 6, 9) },
          }
        end,
      }
    end)
    local reply = lsp.references({ path = path, line = 1, symbol = "foo" }, {})
    lsp.SHOWN = original
    assert.are.equal(3, reply.count)
    assert.are.equal(2, #reply.locations)
    assert.is_true(reply.truncated)
    assert.are.same({ { file = vim.fs.normalize(path), count = 3 } }, reply.by_file)
    assert.is_true(requests[#requests].params.context.includeDeclaration)

    local full = lsp.references({ path = path, line = 1, symbol = "foo" }, { detail = "full" })
    assert.are.equal(3, #full.locations)
    assert.is_nil(full.truncated)
  end)

  it("reads hover contents as markdown", function()
    local path = server(function()
      return { ["textDocument/hover"] = function() return { contents = { kind = "markdown", value = "**foo** `number`" } } end }
    end)
    local reply = lsp.hover { path = path, line = 1, symbol = "foo" }
    assert.are.equal("**foo** `number`", reply.text)
  end)

  it("answers an empty list, with the server, when nothing is found", function()
    local path = server(function() return {} end)
    local reply = lsp.implementation({ path = path, line = 1, symbol = "foo" }, {})
    assert.are.equal(0, reply.count)
    assert.are.equal("fake", reply.server)
  end)

  it("reports a timeout", function()
    local path = server(function()
      return { ["textDocument/definition"] = function() return fake.NEVER end }
    end)
    local reply = lsp.definition({ path = path, line = 2, symbol = "foo", timeout = 0.2 }, {})
    assert.is_true(reply.timed_out)
    assert.are.equal(0, reply.count)
  end)

  it("works end to end through the registry, as JSON", function()
    mcp.tools, mcp.order = {}, {}
    lsp.setup()
    local path = server(function(uri)
      return { ["textDocument/definition"] = function() return { uri = uri, range = fake.range(0, 6, 9) } end }
    end)
    local out = mcp.invoke("definition", { path = path, line = 2, symbol = "foo" }, {})
    assert.is_true(out.ok)
    local decoded = vim.json.decode(out.content[1].text)
    assert.are.equal(1, decoded.locations[1].line)
  end)
end)

describe("registration", function()
  it("advertises the everyday actions and hides the rest", function()
    mcp.tools, mcp.order = {}, {}
    lsp.setup()
    local listed = vim.tbl_map(function(t) return t.name end, mcp.listed())
    for _, name in ipairs { "definition", "references", "hover" } do
      assert.is_true(vim.tbl_contains(listed, name), "should be advertised: " .. name)
    end
    assert.is_false(vim.tbl_contains(listed, "implementation"))
    assert.is_truthy(mcp.tools.implementation)
    assert.are.same({ "path", "line" }, mcp.tools.definition.inputSchema.required)
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lsp_navigate_spec.lua"`
Expected: errors — `module 'nvim-mcp.lsp' not found`.

- [ ] **Step 3: Implement the module with the navigation actions**

Create `lua/nvim-mcp/lsp/init.lua`:

```lua
--- Language server actions: the servers this editor is already running,
--- reached through `drive`. They are warm and configured the way the human
--- sees them, which Claude Code's own LSP tool -- a second set of servers --
--- cannot promise.
---
--- Navigation answers with locations. Edits are applied and saved, all or
--- nothing (see nvim-mcp.lsp.edit). Requests block the editor while they run;
--- the notice tells the human why.
local mcp = require "nvim-mcp"
local position = require "nvim-mcp.lsp.position"
local request = require "nvim-mcp.lsp.request"
local notice = require "nvim-mcp.lsp.notice"

local M = {}

--- Read-only requests usually answer in milliseconds; a notice flashing on
--- every hover would be noise, so it appears only once one has run this long.
M.QUIET_MS = 300
--- Locations kept in a summary.
M.SHOWN = 20

--- Everything a request at a position needs. The symbol is resolved before a
--- server is chosen, so a typo fails without waiting on anything.
function M.locate(args, method)
  local buffer = position.buffer(args.path)
  local line = tonumber(args.line)
  if not line then position.invalid "line is required" end
  local byte = position.byte_column(buffer, line, args.symbol, args.column)
  local ms = request.timeout_ms(args)
  local client = request.client(buffer, method, ms)
  return {
    buffer = buffer,
    client = client,
    ms = ms,
    line = line,
    byte = byte,
    params = position.params(buffer, line, byte, client.offset_encoding),
    what = args.symbol or ("%s:%d"):format(vim.fs.basename(vim.api.nvim_buf_get_name(buffer)), line),
  }
end

function M.label(verb, at) return ("Claude · LSP %s %s (%s)…"):format(verb, at.what, at.client.name) end

--- Locations (or LocationLinks) as { file, line, column, text }, 1-based
--- characters like everything else here.
function M.locations(result, encoding)
  if result == nil then return {} end
  if result.uri or result.targetUri then result = { result } end
  local out = {}
  for _, item in ipairs(vim.lsp.util.locations_to_items(result, encoding)) do
    local text = item.text or ""
    out[#out + 1] = {
      file = vim.fs.normalize(item.filename),
      line = item.lnum,
      column = position.byte_to_char(text, item.col),
      text = vim.trim(text),
    }
  end
  return out
end

--- A big codebase can return hundreds of references; a summary keeps the
--- count per file and the first few, as `diagnostics` does.
function M.summarise(locations, opts)
  if opts and opts.detail == "full" then return { count = #locations, locations = locations, detail = "full" } end
  local per_file, order = {}, {}
  for _, location in ipairs(locations) do
    if not per_file[location.file] then
      per_file[location.file] = 0
      order[#order + 1] = location.file
    end
    per_file[location.file] = per_file[location.file] + 1
  end
  return {
    count = #locations,
    by_file = vim.tbl_map(function(file) return { file = file, count = per_file[file] } end, order),
    locations = vim.list_slice(locations, 1, math.min(M.SHOWN, #locations)),
    truncated = #locations > M.SHOWN,
    detail = "summary",
  }
end

local function navigate(method, verb, extend)
  return function(args, opts)
    local at = M.locate(args, method)
    if extend then extend(at.params) end
    local result, timed_out = notice.during(M.label(verb, at), M.QUIET_MS, function()
      return request.send(at.client, method, at.params, at.buffer, at.ms)
    end)
    local reply = M.summarise(M.locations(result, at.client.offset_encoding), opts)
    reply.server = at.client.name
    reply.timed_out = timed_out or nil
    return reply
  end
end

M.definition = navigate("textDocument/definition", "definition of")
M.implementation = navigate("textDocument/implementation", "implementations of")
M.references = navigate(
  "textDocument/references",
  "references to",
  function(params) params.context = { includeDeclaration = true } end
)

function M.hover(args)
  local at = M.locate(args, "textDocument/hover")
  local result, timed_out = notice.during(M.label("hover", at), M.QUIET_MS, function()
    return request.send(at.client, "textDocument/hover", at.params, at.buffer, at.ms)
  end)
  local text = ""
  if result and result.contents then
    text = vim.trim(table.concat(vim.lsp.util.convert_input_to_markdown_lines(result.contents), "\n"))
  end
  return { server = at.client.name, text = text, timed_out = timed_out or nil }
end

local POSITION = {
  path = { type = "string", description = "The file to ask about." },
  line = { type = "integer", minimum = 1, description = "1-based line." },
  symbol = { type = "string", description = "The word at that spot on the line. Preferred over column." },
  column = { type = "integer", minimum = 1, description = "1-based character column; picks among repeats of symbol." },
  timeout = { type = "number", description = "Seconds to wait. Default 5, capped at 30." },
}

function M.positioned(extra, required)
  return {
    type = "object",
    properties = vim.tbl_extend("force", POSITION, extra or {}),
    required = vim.list_extend({ "path", "line" }, required or {}),
  }
end

function M.setup()
  mcp.register {
    name = "definition",
    description = "Where the symbol at a file and line is defined, from the editor's language server.",
    inputSchema = M.positioned(),
    handler = M.definition,
  }
  mcp.register {
    name = "references",
    description = "Every reference to the symbol at a file and line, grouped by file.",
    inputSchema = M.positioned(),
    handler = M.references,
  }
  mcp.register {
    name = "hover",
    description = "Type and documentation for the symbol at a file and line.",
    inputSchema = M.positioned(),
    handler = M.hover,
  }
  mcp.register {
    name = "implementation",
    hidden = true,
    description = "Implementations of the interface or abstract member at a file and line.",
    inputSchema = M.positioned(),
    handler = M.implementation,
  }
end

return M
```

- [ ] **Step 4: Wire it into `setup`**

In `lua/nvim-mcp/init.lua`, replace `M.setup`:

```lua
function M.setup(opts)
  require("nvim-mcp.config").setup(opts)
  require("nvim-mcp.actions").setup()
  require("nvim-mcp.lsp").setup()
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lsp_navigate_spec.lua"`, then the full suite.
Expected: all pass, and the earlier 31 still pass.

- [ ] **Step 6: Commit**

```bash
git add nvim-mcp/lua/nvim-mcp/lsp/init.lua nvim-mcp/lua/nvim-mcp/init.lua nvim-mcp/tests/lsp_navigate_spec.lua
git commit -m "Add definition, references, hover and implementation actions"
```

---

### Task 4: `symbols` and `calls`

**Files:**
- Modify: `nvim-mcp/lua/nvim-mcp/lsp/init.lua` (add actions before `M.setup`, extend `M.setup`)
- Test: `nvim-mcp/tests/lsp_structure_spec.lua`

**Interfaces:**
- Consumes: `M.locate`, `M.label`, `M.positioned`, `M.QUIET_MS` (Task 3); `request.*`, `notice.during`, `position.*`.
- Produces: `M.symbols(args, opts)`, `M.calls(args)`; `M.SYMBOLS_SHOWN = 50`; both registered hidden.

- [ ] **Step 1: Write the failing tests**

Create `tests/lsp_structure_spec.lua`:

```lua
local lsp = require "nvim-mcp.lsp"
local position = require "nvim-mcp.lsp.position"
local fake = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/fake_lsp.lua")

local LINES = { "function outer()", "  inner()", "end", "function inner() end" }

local function server(handlers)
  local path, dir = fake.file(LINES)
  local buffer = position.buffer(path)
  local uri = vim.uri_from_fname(path)
  fake.start(buffer, dir, {
    capabilities = { documentSymbolProvider = true, workspaceSymbolProvider = true, callHierarchyProvider = true },
    handlers = handlers(uri),
  })
  return path
end

local function item(uri, name, line)
  return { name = name, kind = 12, uri = uri, range = fake.range(line, 0, 3), selectionRange = fake.range(line, 9, 14) }
end

describe("symbols", function()
  after_each(fake.stop_all)

  it("outlines a file, nested symbols included", function()
    local path = server(function()
      return {
        ["textDocument/documentSymbol"] = function()
          return {
            {
              name = "outer", kind = 12, range = fake.range(0, 0, 16), selectionRange = fake.range(0, 9, 14),
              children = { { name = "local", kind = 13, range = fake.range(1, 2, 7), selectionRange = fake.range(1, 2, 7) } },
            },
            { name = "inner", kind = 12, range = fake.range(3, 0, 20), selectionRange = fake.range(3, 9, 14) },
          }
        end,
      }
    end)
    local reply = lsp.symbols({ path = path }, {})
    assert.are.equal(3, reply.count)
    assert.matches("outer", reply.symbols[1].name)
    assert.are.equal(1, reply.symbols[1].line)
    assert.are.equal(vim.fs.normalize(path), reply.symbols[1].file)
  end)

  it("searches the workspace by query", function()
    local path = server(function(uri)
      return {
        ["workspace/symbol"] = function(params)
          assert(params.query == "inn")
          return { { name = "inner", kind = 12, location = { uri = uri, range = fake.range(3, 9, 14) } } }
        end,
      }
    end)
    local reply = lsp.symbols({ query = "inn" }, {})
    assert.are.equal(1, reply.count)
    assert.are.equal(4, reply.symbols[1].line)
    assert.are.equal(vim.fs.normalize(path), reply.symbols[1].file)
  end)

  it("needs a path or a query", function()
    assert.has_error(function() lsp.symbols({}, {}) end)
  end)
end)

describe("calls", function()
  after_each(fake.stop_all)

  it("lists incoming calls one level deep", function()
    local path = server(function(uri)
      return {
        ["textDocument/prepareCallHierarchy"] = function() return { item(uri, "inner", 3) } end,
        ["callHierarchy/incomingCalls"] = function(params)
          assert(params.item.name == "inner")
          return { { from = item(uri, "outer", 0), fromRanges = { fake.range(1, 2, 7) } } }
        end,
      }
    end)
    local reply = lsp.calls { path = path, line = 4, symbol = "inner" }
    assert.are.equal("incoming", reply.direction)
    assert.are.same({ name = "outer", file = vim.fs.normalize(path), line = 1, sites = 1 }, reply.calls[1])
  end)

  it("lists outgoing calls", function()
    local path = server(function(uri)
      return {
        ["textDocument/prepareCallHierarchy"] = function() return { item(uri, "outer", 0) } end,
        ["callHierarchy/outgoingCalls"] = function() return { { to = item(uri, "inner", 3), fromRanges = {} } } end,
      }
    end)
    local reply = lsp.calls { path = path, line = 1, symbol = "outer", direction = "outgoing" }
    assert.are.equal("inner", reply.calls[1].name)
    assert.are.equal(4, reply.calls[1].line)
  end)

  it("answers empty when there is nothing to prepare", function()
    local path = server(function() return {} end)
    local reply = lsp.calls { path = path, line = 1, symbol = "outer" }
    assert.are.equal(0, reply.count)
  end)

  it("refuses an unknown direction", function()
    assert.has_error(function() lsp.calls { path = "x", line = 1, symbol = "x", direction = "sideways" } end)
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lsp_structure_spec.lua"`
Expected: FAIL — `attempt to call field 'symbols' (a nil value)`.

- [ ] **Step 3: Implement**

In `lua/nvim-mcp/lsp/init.lua`, add before `function M.setup()`:

```lua
M.SYMBOLS_SHOWN = 50

local function symbol_reply(items, server, timed_out, opts)
  local symbols = vim.tbl_map(
    function(item) return { name = item.text, file = vim.fs.normalize(item.filename or ""), line = item.lnum } end,
    items
  )
  local limit = (opts and opts.detail == "full") and #symbols or M.SYMBOLS_SHOWN
  return {
    server = server,
    count = #symbols,
    symbols = vim.list_slice(symbols, 1, math.min(limit, #symbols)),
    truncated = #symbols > limit or nil,
    timed_out = timed_out or nil,
  }
end

--- A file's outline with `path`, or a workspace-wide search with `query`. A
--- search asks every server that can answer, since a workspace may hold more
--- than one language; they share one time budget.
function M.symbols(args, opts)
  local ms = request.timeout_ms(args)
  if type(args.path) == "string" and args.path ~= "" then
    local buffer = position.buffer(args.path)
    local method = "textDocument/documentSymbol"
    local client = request.client(buffer, method, ms)
    local what = vim.fs.basename(vim.api.nvim_buf_get_name(buffer))
    local result, timed_out = notice.during(
      ("Claude · LSP symbols in %s (%s)…"):format(what, client.name),
      M.QUIET_MS,
      function() return request.send(client, method, { textDocument = { uri = vim.uri_from_bufnr(buffer) } }, buffer, ms) end
    )
    return symbol_reply(vim.lsp.util.symbols_to_items(result or {}, buffer, client.offset_encoding), client.name, timed_out, opts)
  end

  if type(args.query) ~= "string" or args.query == "" then
    position.invalid "symbols needs a path (a file's outline) or a query (a workspace search)"
  end
  local clients = vim.tbl_filter(
    function(client) return client.initialized and client:supports_method "workspace/symbol" end,
    vim.lsp.get_clients()
  )
  if #clients == 0 then error { code = -32603, message = "No running language server supports workspace symbol search" } end

  local items, servers, timed_out = {}, {}, false
  notice.during(("Claude · LSP symbols matching %q…"):format(args.query), M.QUIET_MS, function()
    local started = vim.uv.now()
    for _, client in ipairs(clients) do
      local left = ms - (vim.uv.now() - started)
      if left <= 0 then
        timed_out = true
        break
      end
      local result, late = request.send(client, "workspace/symbol", { query = args.query }, nil, left)
      timed_out = timed_out or late
      vim.list_extend(items, vim.lsp.util.symbols_to_items(result or {}, nil, client.offset_encoding))
      servers[#servers + 1] = client.name
    end
  end)
  return symbol_reply(items, table.concat(servers, ", "), timed_out, opts)
end

--- One level of the call hierarchy: who calls the symbol, or what it calls.
function M.calls(args)
  local direction = args.direction or "incoming"
  if direction ~= "incoming" and direction ~= "outgoing" then
    position.invalid 'direction must be "incoming" or "outgoing"'
  end
  local at = M.locate(args, "textDocument/prepareCallHierarchy")
  local method = ("callHierarchy/%sCalls"):format(direction)

  local found, timed_out = notice.during(M.label(direction .. " calls of", at), M.QUIET_MS, function()
    local started = vim.uv.now()
    local items, late = request.send(at.client, "textDocument/prepareCallHierarchy", at.params, at.buffer, at.ms)
    if late or not items or #items == 0 then return {}, late end
    local left = math.max(1, at.ms - (vim.uv.now() - started))
    return request.send(at.client, method, { item = items[1] }, at.buffer, left)
  end)

  local calls = {}
  for _, call in ipairs(found or {}) do
    local target = call.from or call.to
    calls[#calls + 1] = {
      name = target.name,
      file = vim.fs.normalize(vim.uri_to_fname(target.uri)),
      line = target.selectionRange.start.line + 1,
      sites = #(call.fromRanges or {}),
    }
  end
  return { server = at.client.name, direction = direction, count = #calls, calls = calls, timed_out = timed_out or nil }
end
```

Note the test for `calls` expects exactly `{ name, file, line, sites }` — do not add `detail` or other fields.

At the end of `M.setup()` add:

```lua
  mcp.register {
    name = "symbols",
    hidden = true,
    description = "A file's symbol outline (path), or a workspace-wide symbol search (query).",
    inputSchema = {
      type = "object",
      properties = {
        path = { type = "string", description = "Outline this file." },
        query = { type = "string", description = "Search the workspace for symbols matching this." },
        timeout = { type = "number", description = "Seconds to wait. Default 5, capped at 30." },
      },
    },
    handler = M.symbols,
  }
  mcp.register {
    name = "calls",
    hidden = true,
    description = "Who calls the function at a file and line (incoming), or what it calls (outgoing).",
    inputSchema = M.positioned { direction = { type = "string", enum = { "incoming", "outgoing" } } },
    handler = M.calls,
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the spec file, then the full suite. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add nvim-mcp/lua/nvim-mcp/lsp/init.lua nvim-mcp/tests/lsp_structure_spec.lua
git commit -m "Add symbols and call hierarchy actions"
```

---

### Task 5: `edit` — refuse or apply-and-save

**Files:**
- Create: `nvim-mcp/lua/nvim-mcp/lsp/edit.lua`
- Test: `nvim-mcp/tests/lsp_edit_spec.lua`

**Interfaces:**
- Consumes: `position.buffer_for` (Task 1).
- Produces: `files(workspace_edit) -> path[]`; `modified(paths) -> path[]`; `apply(workspace_edit, encoding) -> { applied = true, changed = { {file, edits} }, failed? } | { applied = false, reason = "modified", files }`; `capturing(encoding, fn) -> fn_result, results[]` (routes `workspace/applyEdit` through `apply` while `fn` runs).

- [ ] **Step 1: Write the failing tests**

Create `tests/lsp_edit_spec.lua`:

```lua
local edit = require "nvim-mcp.lsp.edit"
local position = require "nvim-mcp.lsp.position"
local fake = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/fake_lsp.lua")

local function rename_in(path, line0, from, to, text)
  return { [vim.uri_from_fname(path)] = { { range = fake.range(line0, from, to), newText = text } } }
end

local function open_listed(path)
  local buffer = vim.fn.bufadd(path)
  vim.fn.bufload(buffer)
  vim.bo[buffer].buflisted = true
  return buffer
end

describe("edit.files", function()
  it("collects files from changes and documentChanges", function()
    local a, b = fake.file { "a" }, fake.file { "b" }
    local files = edit.files {
      changes = rename_in(a, 0, 0, 1, "x"),
      documentChanges = { { textDocument = { uri = vim.uri_from_fname(b), version = vim.NIL }, edits = {} } },
    }
    table.sort(files)
    local expected = { vim.fs.normalize(a), vim.fs.normalize(b) }
    table.sort(expected)
    assert.are.same(expected, vim.tbl_map(vim.fs.normalize, files))
  end)
end)

describe("edit.apply", function()
  it("edits and saves a file that was not open, then unlists it", function()
    local path = fake.file { "local foo = 1" }
    local reply = edit.apply({ changes = rename_in(path, 0, 6, 9, "bar") }, "utf-16")
    assert.is_true(reply.applied)
    assert.are.same({ "local bar = 1" }, vim.fn.readfile(path))
    assert.are.equal(1, reply.changed[1].edits)
    local buffer = position.buffer_for(path)
    assert.is_false(vim.bo[buffer].buflisted)
    assert.is_false(vim.bo[buffer].modified)
  end)

  it("keeps an open buffer listed, saved, and undoable", function()
    local path = fake.file { "local foo = 1" }
    local buffer = open_listed(path)
    edit.apply({ changes = rename_in(path, 0, 6, 9, "bar") }, "utf-16")
    assert.is_true(vim.bo[buffer].buflisted)
    assert.is_false(vim.bo[buffer].modified)
    vim.api.nvim_buf_call(buffer, function() vim.cmd "silent undo" end)
    assert.are.same({ "local foo = 1" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
  end)

  it("refuses the whole edit when any touched buffer has unsaved work", function()
    local clean, dirty = fake.file { "one" }, fake.file { "two" }
    local buffer = open_listed(dirty)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "two, edited" })
    local reply = edit.apply({ changes = vim.tbl_extend("error", rename_in(clean, 0, 0, 3, "ONE"), rename_in(dirty, 0, 0, 3, "TWO")) }, "utf-16")
    assert.is_false(reply.applied)
    assert.are.equal("modified", reply.reason)
    assert.are.same({ vim.fs.normalize(dirty) }, vim.tbl_map(vim.fs.normalize, reply.files))
    assert.are.same({ "one" }, vim.fn.readfile(clean))
    assert.are.same({ "two, edited" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
  end)

  it("saves the rest and reports a file it cannot write", function()
    local writable, locked = fake.file { "one" }, fake.file { "two" }
    local buffer = open_listed(locked)
    vim.bo[buffer].readonly = true
    local reply = edit.apply({ changes = vim.tbl_extend("error", rename_in(writable, 0, 0, 3, "ONE"), rename_in(locked, 0, 0, 3, "TWO")) }, "utf-16")
    assert.is_true(reply.applied)
    assert.are.same({ "ONE" }, vim.fn.readfile(writable))
    assert.are.equal(1, #reply.failed)
    assert.are.equal(vim.fs.normalize(locked), vim.fs.normalize(reply.failed[1].file))
  end)
end)

describe("edit.capturing", function()
  it("routes applyEdit through apply while running, and restores the handler", function()
    local original = vim.lsp.handlers["workspace/applyEdit"]
    local path = fake.file { "abc" }
    local answer
    local _, results = edit.capturing("utf-16", function()
      answer = vim.lsp.handlers["workspace/applyEdit"](nil, { edit = { changes = rename_in(path, 0, 0, 3, "xyz") } }, { client_id = -1 })
    end)
    assert.are.same({ applied = true }, answer)
    assert.are.equal(1, #results)
    assert.are.same({ "xyz" }, vim.fn.readfile(path))
    assert.are.equal(original, vim.lsp.handlers["workspace/applyEdit"])
  end)

  it("answers applied = false with a reason for unsaved work", function()
    local path = fake.file { "abc" }
    local buffer = open_listed(path)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "mine" })
    local answer
    edit.capturing("utf-16", function()
      answer = vim.lsp.handlers["workspace/applyEdit"](nil, { edit = { changes = rename_in(path, 0, 0, 3, "xyz") } }, { client_id = -1 })
    end)
    assert.is_false(answer.applied)
    assert.matches("Unsaved changes", answer.failureReason)
  end)

  it("restores the handler when the work throws", function()
    local original = vim.lsp.handlers["workspace/applyEdit"]
    assert.has_error(function() edit.capturing("utf-16", function() error "boom" end) end)
    assert.are.equal(original, vim.lsp.handlers["workspace/applyEdit"])
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lsp_edit_spec.lua"`
Expected: errors — `module 'nvim-mcp.lsp.edit' not found`.

- [ ] **Step 3: Implement**

Create `lua/nvim-mcp/lsp/edit.lua`:

```lua
--- Applying language server edits the way the human wants them: all or
--- nothing, and saved.
---
--- Saved, so the files on disk -- which Claude's own tools read -- match the
--- editor. All or nothing, because unsaved work in a touched buffer is the
--- human's: mixing an edit into it would leave neither version intact.
local position = require "nvim-mcp.lsp.position"

local M = {}

--- Every file a WorkspaceEdit touches.
function M.files(workspace_edit)
  local seen, out = {}, {}
  local function add(uri)
    local file = vim.uri_to_fname(uri)
    if not seen[file] then
      seen[file] = true
      out[#out + 1] = file
    end
  end
  for uri in pairs(workspace_edit.changes or {}) do
    add(uri)
  end
  for _, change in ipairs(workspace_edit.documentChanges or {}) do
    if change.textDocument then
      add(change.textDocument.uri)
    elseif change.kind == "rename" then
      add(change.oldUri)
      add(change.newUri)
    elseif change.uri then
      add(change.uri)
    end
  end
  return out
end

local function edit_counts(workspace_edit)
  local counts = {}
  for uri, edits in pairs(workspace_edit.changes or {}) do
    local file = vim.uri_to_fname(uri)
    counts[file] = (counts[file] or 0) + #edits
  end
  for _, change in ipairs(workspace_edit.documentChanges or {}) do
    if change.textDocument then
      local file = vim.uri_to_fname(change.textDocument.uri)
      counts[file] = (counts[file] or 0) + #change.edits
    end
  end
  return counts
end

--- The files among `files` whose buffers hold unsaved work.
function M.modified(files)
  local out = {}
  for _, file in ipairs(files) do
    local buffer = position.buffer_for(file)
    if buffer and vim.api.nvim_buf_is_loaded(buffer) and vim.bo[buffer].modified then out[#out + 1] = file end
  end
  return out
end

function M.apply(workspace_edit, encoding)
  local files = M.files(workspace_edit)
  local dirty = M.modified(files)
  if #dirty > 0 then return { applied = false, reason = "modified", files = dirty } end

  -- Buffers the edit has to open are the edit's, not the human's: saved, then
  -- unlisted, so a rename across thirty files does not leave thirty entries in
  -- their buffer list. Unlisted rather than deleted keeps the undo history.
  local was_listed = {}
  for _, file in ipairs(files) do
    local buffer = position.buffer_for(file)
    was_listed[file] = buffer ~= nil and vim.bo[buffer].buflisted
  end

  vim.lsp.util.apply_workspace_edit(workspace_edit, encoding)

  local counts, changed, failed = edit_counts(workspace_edit), {}, {}
  for _, file in ipairs(files) do
    local buffer = position.buffer_for(file)
    if buffer and vim.api.nvim_buf_is_loaded(buffer) then
      if vim.bo[buffer].modified then
        -- A plain :write, so the human's format-on-save and friends still run.
        local ok, err = pcall(vim.api.nvim_buf_call, buffer, function() vim.cmd "silent write" end)
        if not ok then failed[#failed + 1] = { file = file, error = tostring(err) } end
      end
      if not was_listed[file] then vim.bo[buffer].buflisted = false end
    end
    if counts[file] or vim.uv.fs_stat(file) then changed[#changed + 1] = { file = file, edits = counts[file] or 0 } end
  end

  local reply = { applied = true, changed = changed }
  if #failed > 0 then reply.failed = failed end
  return reply
end

--- Run `fn` with `workspace/applyEdit` routed through apply(), so an edit a
--- server sends back while executing a command obeys the same rules. Returns
--- what `fn` returns and the result of every edit that arrived.
function M.capturing(encoding, fn)
  local results = {}
  local original = vim.lsp.handlers["workspace/applyEdit"]
  vim.lsp.handlers["workspace/applyEdit"] = function(_, params, ctx)
    local client = ctx and vim.lsp.get_client_by_id(ctx.client_id)
    local result = M.apply(params.edit, client and client.offset_encoding or encoding)
    results[#results + 1] = result
    if result.applied then return { applied = true } end
    return { applied = false, failureReason = "Unsaved changes in " .. table.concat(result.files, ", ") }
  end
  local ok, value = pcall(fn)
  vim.lsp.handlers["workspace/applyEdit"] = original
  if not ok then error(value, 0) end
  return value, results
end

return M
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the spec file. Expected: all pass. If the read-only test finds `apply_workspace_edit` itself refusing a read-only buffer (the edit never lands), keep the test's intent — the other file saved, the locked one reported in `failed` — and adapt the implementation, not the assertion.

- [ ] **Step 5: Commit**

```bash
git add nvim-mcp/lua/nvim-mcp/lsp/edit.lua nvim-mcp/tests/lsp_edit_spec.lua
git commit -m "Apply language server edits all or nothing, and save them"
```

---

### Task 6: `rename` and `format`

**Files:**
- Modify: `nvim-mcp/lua/nvim-mcp/lsp/init.lua` (require `edit` at the top; add actions; extend `setup`)
- Test: `nvim-mcp/tests/lsp_rename_spec.lua`

**Interfaces:**
- Consumes: `M.locate`, `M.positioned` (Task 3); `edit.apply` (Task 5); `position.line_range` (Task 1); `notice.during`, `notice.active`.
- Produces: `M.rename(args)`, `M.format(args)`; local helper `announce(reply, message)`; `rename` advertised, `format` hidden.

- [ ] **Step 1: Write the failing tests**

Create `tests/lsp_rename_spec.lua`:

```lua
local lsp = require "nvim-mcp.lsp"
local mcp = require "nvim-mcp"
local notice = require "nvim-mcp.lsp.notice"
local position = require "nvim-mcp.lsp.position"
local fake = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/fake_lsp.lua")

local notified
local original_notify = vim.notify

local function setup_pair(handlers)
  local path, dir = fake.file { "local foo = 1", "print(foo)" }
  local other = dir .. "/b.txt"
  vim.fn.writefile({ "use(foo)" }, other)
  local buffer = position.buffer(path)
  vim.bo[buffer].buflisted = true
  fake.start(buffer, dir, {
    capabilities = { renameProvider = true, documentFormattingProvider = true, documentRangeFormattingProvider = true },
    handlers = handlers(vim.uri_from_fname(path), vim.uri_from_fname(other)),
  })
  return path, other, buffer
end

local function rename_edit(uri, other_uri, name)
  return {
    changes = {
      [uri] = {
        { range = fake.range(0, 6, 9), newText = name },
        { range = fake.range(1, 6, 9), newText = name },
      },
      [other_uri] = { { range = fake.range(0, 4, 7), newText = name } },
    },
  }
end

describe("rename", function()
  before_each(function()
    notified = {}
    vim.notify = function(message) notified[#notified + 1] = message end
  end)
  after_each(function()
    vim.notify = original_notify
    fake.stop_all()
  end)

  it("renames across files, saves them, and announces it", function()
    local shown_while_running
    local path, other = setup_pair(function(uri, other_uri)
      return {
        ["textDocument/rename"] = function(params)
          shown_while_running = notice.active ~= nil and notice.active.shown ~= nil
          return rename_edit(uri, other_uri, params.newName)
        end,
      }
    end)
    local reply = lsp.rename { path = path, line = 1, symbol = "foo", new_name = "bar" }
    assert.is_true(reply.applied)
    assert.are.equal("fake", reply.server)
    assert.are.same({ "local bar = 1", "print(bar)" }, vim.fn.readfile(path))
    assert.are.same({ "use(bar)" }, vim.fn.readfile(other))
    assert.are.equal(2, #reply.changed)
    assert.is_true(shown_while_running, "the notice must be up while the editor waits")
    assert.matches("Claude renamed foo → bar in 2 files", notified[1])
  end)

  it("refuses when a touched buffer has unsaved work, and touches nothing", function()
    local path, other, buffer = setup_pair(function(uri, other_uri)
      return { ["textDocument/rename"] = function(params) return rename_edit(uri, other_uri, params.newName) end }
    end)
    vim.api.nvim_buf_set_lines(buffer, 1, 2, false, { "print(foo) -- mine" })
    local reply = lsp.rename { path = path, line = 1, symbol = "foo", new_name = "bar" }
    assert.is_false(reply.applied)
    assert.are.equal("modified", reply.reason)
    assert.are.same({ "use(foo)" }, vim.fn.readfile(other))
    assert.are.same({}, notified)
  end)

  it("says so when the server has no edit", function()
    local path = setup_pair(function() return {} end)
    local reply = lsp.rename { path = path, line = 1, symbol = "foo", new_name = "bar" }
    assert.is_false(reply.applied)
    assert.are.equal("no edit", reply.reason)
  end)

  it("reports a timeout", function()
    local path = setup_pair(function() return { ["textDocument/rename"] = function() return fake.NEVER end } end)
    local reply = lsp.rename { path = path, line = 1, symbol = "foo", new_name = "bar", timeout = 0.2 }
    assert.is_false(reply.applied)
    assert.is_true(reply.timed_out)
  end)

  it("needs a new name", function()
    assert.has_error(function() lsp.rename { path = "x", line = 1, symbol = "foo" } end)
  end)
end)

describe("format", function()
  before_each(function()
    notified = {}
    vim.notify = function(message) notified[#notified + 1] = message end
  end)
  after_each(function()
    vim.notify = original_notify
    fake.stop_all()
  end)

  it("formats the file and saves it", function()
    local path = setup_pair(function()
      return {
        ["textDocument/formatting"] = function(params)
          assert(params.options.tabSize)
          return { { range = fake.range(0, 5, 6), newText = "  " } }
        end,
      }
    end)
    local reply = lsp.format { path = path }
    assert.is_true(reply.applied)
    assert.are.same({ "local  foo = 1", "print(foo)" }, vim.fn.readfile(path))
    assert.matches("Claude formatted", notified[1])
  end)

  it("formats a range when given lines", function()
    local seen
    local path = setup_pair(function()
      return { ["textDocument/rangeFormatting"] = function(params) seen = params.range return {} end }
    end)
    local reply = lsp.format { path = path, line = 2, end_line = 2 }
    assert.are.same({ line = 1, character = 0 }, seen.start)
    assert.is_true(reply.applied)
    assert.are.equal("Already formatted.", reply.note)
  end)
end)

describe("rename registration", function()
  it("advertises rename and hides format", function()
    mcp.tools, mcp.order = {}, {}
    lsp.setup()
    local listed = vim.tbl_map(function(t) return t.name end, mcp.listed())
    assert.is_true(vim.tbl_contains(listed, "rename"))
    assert.is_false(vim.tbl_contains(listed, "format"))
    assert.is_truthy(mcp.tools.format)
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lsp_rename_spec.lua"`
Expected: FAIL — `attempt to call field 'rename' (a nil value)`.

- [ ] **Step 3: Implement**

In `lua/nvim-mcp/lsp/init.lua`, add to the requires at the top:

```lua
local edit = require "nvim-mcp.lsp.edit"
```

Add before `function M.setup()`:

```lua
--- Edits leave a line in the message history as well as the reply, so the
--- human can see what changed even if they were not watching the notice.
local function announce(reply, message)
  if reply.applied and reply.changed and #reply.changed > 0 then vim.notify(message, vim.log.levels.INFO) end
  return reply
end

local function files_phrase(count) return ("%d file%s"):format(count, count == 1 and "" or "s") end

function M.rename(args)
  if type(args.new_name) ~= "string" or args.new_name == "" then position.invalid "rename needs new_name" end
  local at = M.locate(args, "textDocument/rename")
  at.params.newName = args.new_name

  local reply = notice.during(
    ("Claude · LSP rename %s → %s (%s)…"):format(at.what, args.new_name, at.client.name),
    0,
    function()
      local result, timed_out = request.send(at.client, "textDocument/rename", at.params, at.buffer, at.ms)
      if timed_out then return { applied = false, timed_out = true } end
      if not result then return { applied = false, reason = "no edit", message = "The server returned no rename edit here." } end
      return edit.apply(result, at.client.offset_encoding)
    end
  )
  reply.server = at.client.name
  return announce(
    reply,
    ("Claude renamed %s → %s in %s"):format(at.what, args.new_name, files_phrase(reply.changed and #reply.changed or 0))
  )
end

--- Format a file, or whole lines `line`..`end_line`.
function M.format(args)
  local buffer = position.buffer(args.path)
  local ms = request.timeout_ms(args)
  local ranged = args.line ~= nil
  local method = ranged and "textDocument/rangeFormatting" or "textDocument/formatting"
  local client = request.client(buffer, method, ms)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(buffer) },
    options = { tabSize = vim.lsp.util.get_effective_tabstop(buffer), insertSpaces = vim.bo[buffer].expandtab },
  }
  if ranged then params.range = position.line_range(buffer, args.line, args.end_line or args.line, client.offset_encoding) end

  local name = vim.fs.basename(vim.api.nvim_buf_get_name(buffer))
  local reply = notice.during(("Claude · LSP format %s (%s)…"):format(name, client.name), 0, function()
    local result, timed_out = request.send(client, method, params, buffer, ms)
    if timed_out then return { applied = false, timed_out = true } end
    if not result or #result == 0 then return { applied = true, changed = {}, note = "Already formatted." } end
    return edit.apply({ changes = { [vim.uri_from_bufnr(buffer)] = result } }, client.offset_encoding)
  end)
  reply.server = client.name
  return announce(reply, ("Claude formatted %s"):format(name))
end
```

At the end of `M.setup()` add:

```lua
  mcp.register {
    name = "rename",
    description = "Rename the symbol at a file and line across the workspace; applied and saved.",
    inputSchema = M.positioned({ new_name = { type = "string" } }, { "new_name" }),
    handler = M.rename,
  }
  mcp.register {
    name = "format",
    hidden = true,
    description = "Format a file, or lines line..end_line, with its language server; applied and saved.",
    inputSchema = {
      type = "object",
      properties = {
        path = { type = "string" },
        line = { type = "integer", minimum = 1 },
        end_line = { type = "integer", minimum = 1 },
        timeout = { type = "number", description = "Seconds to wait. Default 5, capped at 30." },
      },
      required = { "path" },
    },
    handler = M.format,
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the spec file, then the full suite. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add nvim-mcp/lua/nvim-mcp/lsp/init.lua nvim-mcp/tests/lsp_rename_spec.lua
git commit -m "Add rename and format, applied and saved"
```

---

### Task 7: `code_actions` and `code_action`

**Files:**
- Modify: `nvim-mcp/lua/nvim-mcp/lsp/init.lua`
- Test: `nvim-mcp/tests/lsp_code_action_spec.lua`

**Interfaces:**
- Consumes: `edit.apply`, `edit.capturing` (Task 5); `announce`, `files_phrase` (Task 6, same file); `position.line_range`; `request.clients`, `request.send`, `request.timeout_ms`; `notice.during`.
- Produces: `M.code_actions(args)`, `M.code_action(args)`, `M.run_action(action, client, buffer, ms)`, `M.run_command(command, client, buffer, ms)`; both actions registered hidden.

- [ ] **Step 1: Write the failing tests**

Create `tests/lsp_code_action_spec.lua`:

```lua
local lsp = require "nvim-mcp.lsp"
local position = require "nvim-mcp.lsp.position"
local fake = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/fake_lsp.lua")

local original_notify = vim.notify

--- A server offering: an edit action, a command action whose edit arrives via
--- workspace/applyEdit, a resolvable action, and a command that changes nothing.
local function server()
  local path, dir = fake.file { "local foo = 1", "print(foo)" }
  local buffer = position.buffer(path)
  vim.bo[buffer].buflisted = true
  local uri = vim.uri_from_fname(path)
  local answers = {}
  local function change(line0, from, to, text) return { changes = { [uri] = { { range = fake.range(line0, from, to), newText = text } } } } end
  fake.start(buffer, dir, {
    capabilities = {
      codeActionProvider = { resolveProvider = true },
      executeCommandProvider = { commands = { "fill", "noop" } },
    },
    handlers = {
      ["textDocument/codeAction"] = function()
        return {
          { title = "Make it const", kind = "quickfix", edit = change(0, 0, 5, "const") },
          { title = "Fill it", kind = "refactor", command = { title = "Fill it", command = "fill" } },
          { title = "Resolve me", kind = "refactor", data = 1 },
          { title = "Do nothing", command = "noop" },
        }
      end,
      ["codeAction/resolve"] = function(action)
        action.edit = change(1, 0, 5, "trace")
        return action
      end,
      ["workspace/executeCommand"] = function(params, dispatchers)
        if params.command == "fill" then
          answers[#answers + 1] = dispatchers.server_request("workspace/applyEdit", { edit = change(0, 6, 9, "bar") })
        end
        return vim.NIL
      end,
    },
  })
  return path, buffer, answers
end

describe("code actions", function()
  before_each(function() vim.notify = function() end end)
  after_each(function()
    vim.notify = original_notify
    fake.stop_all()
  end)

  it("lists what is available with index, title and kind", function()
    local path = server()
    local reply = lsp.code_actions { path = path, line = 1 }
    assert.are.equal(4, reply.count)
    assert.are.same({ index = 1, title = "Make it const", kind = "quickfix", server = "fake" }, reply.actions[1])
  end)

  it("applies an action's edit by title, and saves", function()
    local path = server()
    local reply = lsp.code_action { path = path, line = 1, title = "Make it const" }
    assert.is_true(reply.applied)
    assert.are.equal("Make it const", reply.title)
    assert.are.same({ "const foo = 1", "print(foo)" }, vim.fn.readfile(path))
  end)

  it("lets the title win over a stale index", function()
    local path = server()
    local reply = lsp.code_action { path = path, line = 1, title = "Make it const", index = 2 }
    assert.are.equal("Make it const", reply.title)
    assert.are.same({ "const foo = 1", "print(foo)" }, vim.fn.readfile(path))
  end)

  it("lists the available titles for an unknown one", function()
    local path = server()
    local ok, err = pcall(lsp.code_action, { path = path, line = 1, title = "Nope" })
    assert.is_false(ok)
    assert.matches("Make it const | Fill it", err.message)
  end)

  it("captures the edit a command sends back, and saves it", function()
    local path, _, answers = server()
    local reply = lsp.code_action { path = path, line = 1, title = "Fill it" }
    assert.is_true(reply.applied)
    assert.are.same({ "local bar = 1", "print(foo)" }, vim.fn.readfile(path))
    assert.are.equal(1, #reply.changed)
    assert.are.same({ applied = true }, answers[1])
  end)

  it("refuses a command's edit into unsaved work, and tells the server", function()
    local path, buffer, answers = server()
    vim.api.nvim_buf_set_lines(buffer, 1, 2, false, { "print(foo) -- mine" })
    local reply = lsp.code_action { path = path, line = 1, title = "Fill it" }
    assert.is_false(reply.applied)
    assert.are.equal("modified", reply.reason)
    assert.is_false(answers[1].applied)
    assert.are.same({ "local foo = 1", "print(foo)" }, vim.fn.readfile(path))
  end)

  it("resolves an action that arrives without its edit", function()
    local path = server()
    local reply = lsp.code_action { path = path, line = 1, title = "Resolve me" }
    assert.is_true(reply.applied)
    assert.are.same({ "local foo = 1", "trace(foo)" }, vim.fn.readfile(path))
  end)

  it("says so when an action changes nothing", function()
    local path = server()
    local reply = lsp.code_action { path = path, line = 1, title = "Do nothing" }
    assert.is_true(reply.applied)
    assert.are.equal(0, #reply.changed)
    assert.matches("changed no files", reply.note)
  end)

  it("needs a title", function()
    assert.has_error(function() lsp.code_action { path = "x", line = 1 } end)
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lsp_code_action_spec.lua"`
Expected: FAIL — `attempt to call field 'code_actions' (a nil value)`.

- [ ] **Step 3: Implement**

In `lua/nvim-mcp/lsp/init.lua`, add before `function M.setup()`:

```lua
--- The diagnostics on lines first..last in the shape a server expects back:
--- quick fixes are keyed to them.
local function context_diagnostics(buffer, first, last)
  local out = {}
  for _, diagnostic in ipairs(vim.diagnostic.get(buffer)) do
    local lsp_form = diagnostic.user_data and diagnostic.user_data.lsp
    if lsp_form and diagnostic.lnum >= first - 1 and diagnostic.lnum <= last - 1 then out[#out + 1] = lsp_form end
  end
  return out
end

--- Every server's code actions over whole lines, in one list. Asked fresh
--- each time: a list kept from an earlier call goes stale with the first edit.
local function gather(args)
  local buffer = position.buffer(args.path)
  local first = tonumber(args.line)
  if not first then position.invalid "line is required" end
  local last = tonumber(args.end_line) or first
  local ms = request.timeout_ms(args)
  local clients = request.clients(buffer, "textDocument/codeAction", ms)

  local found, timed_out, started = {}, false, vim.uv.now()
  for _, client in ipairs(clients) do
    local left = ms - (vim.uv.now() - started)
    if left <= 0 then
      timed_out = true
      break
    end
    local params = {
      textDocument = { uri = vim.uri_from_bufnr(buffer) },
      range = position.line_range(buffer, first, last, client.offset_encoding),
      context = { diagnostics = context_diagnostics(buffer, first, last), triggerKind = 1 },
    }
    local result, late = request.send(client, "textDocument/codeAction", params, buffer, left)
    timed_out = timed_out or late
    for _, action in ipairs(result or {}) do
      found[#found + 1] = { action = action, client = client }
    end
  end
  return { buffer = buffer, ms = ms, actions = found, timed_out = timed_out }
end

function M.code_actions(args)
  local where = ("%s:%s"):format(vim.fs.basename(tostring(args.path or "")), tostring(args.line))
  local found = notice.during(("Claude · LSP code actions at %s…"):format(where), M.QUIET_MS, function() return gather(args) end)
  local list = {}
  for index, entry in ipairs(found.actions) do
    list[#list + 1] = {
      index = index,
      title = entry.action.title,
      kind = entry.action.kind,
      server = entry.client.name,
      disabled = entry.action.disabled and entry.action.disabled.reason or nil,
    }
  end
  return { count = #list, actions = list, timed_out = found.timed_out or nil }
end

--- Run a Command: client-side if Neovim or the client registered it, otherwise
--- on the server. Either way an edit it sends back goes through edit.apply.
function M.run_command(command, client, buffer, ms)
  local reply = { applied = true, changed = {} }
  local _, results = edit.capturing(client.offset_encoding, function()
    local handler = client.commands[command.command] or vim.lsp.commands[command.command]
    if handler then
      handler(command, { bufnr = buffer, client_id = client.id })
    else
      local _, late = request.send(
        client,
        "workspace/executeCommand",
        { command = command.command, arguments = command.arguments },
        buffer,
        ms
      )
      reply.timed_out = late or nil
    end
  end)
  for _, result in ipairs(results) do
    if not result.applied then return result end
    vim.list_extend(reply.changed, result.changed)
  end
  return reply
end

--- Apply one code action: resolve it if it came without its edit, apply the
--- edit, then run its command -- the order the protocol prescribes.
function M.run_action(action, client, buffer, ms)
  -- A bare Command in the list rather than a CodeAction.
  if type(action.command) == "string" then return M.run_command(action, client, buffer, ms) end
  if action.disabled then return { applied = false, reason = "disabled", message = action.disabled.reason } end

  if not action.edit and not action.command and client:supports_method("codeAction/resolve", buffer) then
    local resolved, late = request.send(client, "codeAction/resolve", action, buffer, ms)
    if late then return { applied = false, timed_out = true } end
    action = resolved or action
  end

  local reply = { applied = true, changed = {} }
  if action.edit then
    reply = edit.apply(action.edit, client.offset_encoding)
    if not reply.applied then return reply end
  end
  if action.command then
    local ran = M.run_command(action.command, client, buffer, ms)
    if not ran.applied then
      ran.changed = reply.changed -- the action's own edit did land
      return ran
    end
    vim.list_extend(reply.changed, ran.changed)
    reply.timed_out = ran.timed_out
  end
  return reply
end

function M.code_action(args)
  if type(args.title) ~= "string" or args.title == "" then
    position.invalid "code_action needs the exact title from code_actions"
  end
  local reply, server = notice.during(("Claude · LSP code action %q…"):format(args.title), 0, function()
    local found = gather(args)
    local chosen
    local index = tonumber(args.index)
    -- An index only picks among duplicates of the same title: a list that
    -- shifted since code_actions must not apply the wrong fix.
    if index and found.actions[index] and found.actions[index].action.title == args.title then chosen = found.actions[index] end
    if not chosen then
      for _, entry in ipairs(found.actions) do
        if entry.action.title == args.title then
          chosen = entry
          break
        end
      end
    end
    if not chosen then
      local titles = vim.tbl_map(function(entry) return entry.action.title end, found.actions)
      error {
        code = -32602,
        message = ("No code action titled %q here. Available: %s"):format(
          args.title,
          #titles > 0 and table.concat(titles, " | ") or "none"
        ),
      }
    end
    return M.run_action(chosen.action, chosen.client, found.buffer, found.ms), chosen.client.name
  end)

  reply.server, reply.title = server, args.title
  if reply.applied and #(reply.changed or {}) == 0 and not reply.timed_out then
    reply.note = "The action ran but changed no files."
  end
  return announce(reply, ("Claude applied %q in %s"):format(args.title, files_phrase(#(reply.changed or {}))))
end
```

At the end of `M.setup()` add:

```lua
  mcp.register {
    name = "code_actions",
    hidden = true,
    description = "List the fixes and refactors language servers offer on lines line..end_line; changes nothing.",
    inputSchema = {
      type = "object",
      properties = {
        path = { type = "string" },
        line = { type = "integer", minimum = 1 },
        end_line = { type = "integer", minimum = 1 },
        timeout = { type = "number", description = "Seconds to wait. Default 5, capped at 30." },
      },
      required = { "path", "line" },
    },
    handler = M.code_actions,
  }
  mcp.register {
    name = "code_action",
    hidden = true,
    description = "Apply one code action by its exact title from code_actions; applied and saved.",
    inputSchema = {
      type = "object",
      properties = {
        path = { type = "string" },
        line = { type = "integer", minimum = 1 },
        end_line = { type = "integer", minimum = 1 },
        title = { type = "string", description = "Exact title from code_actions." },
        index = { type = "integer", minimum = 1, description = "Picks among duplicate titles; ignored if its title differs." },
        timeout = { type = "number", description = "Seconds to wait. Default 5, capped at 30." },
      },
      required = { "path", "line", "title" },
    },
    handler = M.code_action,
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the spec file, then the full suite. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add nvim-mcp/lua/nvim-mcp/lsp/init.lua nvim-mcp/tests/lsp_code_action_spec.lua
git commit -m "Add code actions, including commands that send their edit back"
```

---

### Task 8: The `lsp` skill and the docs

**Files:**
- Create: `claude/skills/lsp/SKILL.md`
- Modify: `claude/skills/nvim/SKILL.md` (the "## The checklist panel" section — add a sibling section after it)
- Modify: `nvim-mcp/README.md` (after the "## Built-in actions" section, before "## Tests"; update the test count line)

**Interfaces:**
- Consumes: action names, arguments and reply fields from Tasks 3–7, exactly as registered.

- [ ] **Step 1: Write the skill**

Create `claude/skills/lsp/SKILL.md`:

````markdown
---
name: lsp
description: Use when Neovim is attached ($NVIM set) and you need what a language server knows — where something is defined, every reference or caller, a symbol's type or docs, a file's outline — or want to rename a symbol, apply a quick fix or refactor, or format a file. Covers the LSP actions on the `drive` tool, when they beat grep, and how their edits behave.
---

# Language servers through the human's Neovim

The editor is already running language servers for the files in front of the
human: warm, indexed, configured the way they see them. These actions reach
those servers through `drive`. Prefer them to Claude Code's own `LSP` tool,
which starts a second, cold copy of each server; use that only when no Neovim
is attached.

## When LSP, when grep

- **LSP for meaning:** where a symbol is defined, every real reference to it,
  who calls a function, what type something has, what implements an
  interface. Grep cannot tell a reference from a same-named local, a comment
  or a string.
- **Grep for text:** strings, comments, config keys, log messages, and files
  no server understands.
- **Renames go through `rename`,** not search-and-replace with Edit. The
  server knows scoping, shadowing, overloads and every file involved.

## Pointing at a symbol

Every positioned action takes `path`, `line` and **`symbol` — the word at that
spot**. The column is found for you; do not count columns from Read output.
If the word appears more than once on the line, the error says so and
`column` (1-based characters) picks one. If it is not there, the error lists
the words that are.

```json
{ "action": "references", "args": { "path": "src/config.rs", "line": 42, "symbol": "parse_config" } }
```

## The actions

| action | args beyond the position | answers |
|---|---|---|
| `definition` | — | locations `{ file, line, column, text }` |
| `references` | — | `count`, `by_file`, first 20 `locations`, `truncated` |
| `hover` | — | `text` (markdown) |
| `rename` | `new_name` | `applied`, `changed: [{ file, edits }]` |
| `implementation` *(hidden)* | — | locations |
| `calls` *(hidden)* | `direction: incoming\|outgoing` | `calls: [{ name, file, line, sites }]` |
| `symbols` *(hidden)* | `path` **or** `query` instead of a position | `symbols: [{ name, file, line }]` |
| `code_actions` *(hidden)* | `path`, `line`, `end_line?` | `actions: [{ index, title, kind, server }]` |
| `code_action` *(hidden)* | `path`, `line`, `end_line?`, `title`, `index?` | like `rename` |
| `format` *(hidden)* | `path`, `line?`, `end_line?` | like `rename` |

Hidden actions are callable directly by name; `describe` gives a schema.
`detail: "full"` lifts the caps on lists. Every action takes `timeout` in
seconds (default 5, max 30).

## Workflow

1. **Is a server watching?** For a file the human has not opened recently,
   `diagnostics` shows what is attached. A cold Roslyn or rust-analyzer can
   take a minute: `diagnostics` with `wait_for` first, then ask.
2. **Ask.** Read the reply, not just the count.
3. **Show** the interesting location with `show` when you are discussing it —
   showing beats pasting.
4. **After an edit,** `diagnostics` again: the server's view of the result is
   the fastest check there is.

## Edits

`rename`, `code_action` and `format` are **applied and saved**: the files on
disk — what Read and Edit see — match the editor. Each touched buffer gets
one undo step. A notification records what changed.

**If any touched buffer has unsaved changes, nothing is applied** and the
reply is `{ applied: false, reason: "modified", files }`. That work is the
human's. Tell them which files, and ask them to save or discard; never try to
get around it.

Code actions: call `code_actions` first, then `code_action` with the exact
`title`. The list is fetched fresh each time and matched by title, so an index
from an earlier list cannot apply the wrong fix; `index` only chooses between
duplicate titles. Some actions run a server command whose edit arrives
separately — the reply still lists what changed, and says so when nothing did.

## Reading replies

- **A reply names its `server`.** An empty list from a server that answered
  means "none found".
- **No server attached** is an error, not an empty answer. It names the
  filetype and any configured server; wait for it or tell the human.
- **Capabilities differ.** `marksman has no implementation provider` is an
  answer, not a failure to retry.
- **`timed_out: true`** means the answer is partial or missing. Retry with a
  larger `timeout` only if the server was plausibly still indexing.

## The human's editor waits

Requests are synchronous: while one runs, the human's Neovim does not respond,
and a small `Claude · LSP …` notice in the corner says why. Most answer in
milliseconds. Use the actions as freely as you need; this is a known trade,
and if it bites, the fix belongs in the bridge rather than in fewer calls.
````

- [ ] **Step 2: Point to it from the `nvim` skill**

In `claude/skills/nvim/SKILL.md`, directly after the `## The checklist panel` section (before `## Closing a buffer`), add:

```markdown
## Code navigation and refactoring

Definitions, references, hover, renames and code actions through the editor's
own language servers are covered by the `lsp` skill.
```

- [ ] **Step 3: Document the actions in the README**

In `nvim-mcp/README.md`, insert before `## Tests`:

```markdown
## LSP actions

`nvim-mcp.lsp` registers the editor's language servers as actions:
`definition`, `references`, `hover` and `rename` advertised; `implementation`,
`symbols`, `calls`, `code_actions`, `code_action` and `format` hidden. The
`lsp` skill in `../claude/skills/lsp` explains when to use each.

- **Addressing** is `{ path, line, symbol }`; the column is found from the
  symbol, converted to the server's position encoding.
- **Requests are synchronous**, with `timeout` (default 5 s, max 30 s). The
  editor waits while one runs, so a floating `Claude · LSP …` notice is drawn
  with an explicit redraw — immediately for edits, after 300 ms for lookups.
  If the wait ever matters, slow requests move to bridge-side polling, as
  `wait_for` does; the action interface stays the same.
- **Edits are applied and saved, all or nothing.** A touched buffer with
  unsaved changes refuses the whole edit. Buffers an edit had to open are
  unlisted again afterwards. Edits a server sends back while running a command
  (`workspace/applyEdit`) are captured and follow the same rules.

Design: `../docs/superpowers/specs/2026-09-27-lsp-actions-design.md`.
```

Then run the full suite and replace the test-count sentence under `## Tests` ("31 tests covering …") with the new total and coverage, e.g. `N tests covering registration, …, the ported editor actions, config generation, and the LSP actions against an in-process fake server.` — use the real `N` from the run.

- [ ] **Step 4: Run the full suite**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"`
Expected: every file reports `Failed : 0` and `Errors : 0`.

- [ ] **Step 5: Commit**

```bash
git add claude/skills/lsp/SKILL.md claude/skills/nvim/SKILL.md nvim-mcp/README.md
git commit -m "Add the lsp skill and document the LSP actions"
```

---

### Task 9: Live verification in the human's Neovim

Nothing to commit unless a bug is found; each bug found gets a failing test first, then the fix, in the task that owns the code.

- [ ] **Step 1: Load the new code into the running editor**

The human's Neovim loaded nvim-mcp at startup; restarting it would end this Claude session (it runs inside it). Ask the human to run, in Neovim:

```vim
:lua for k in pairs(package.loaded) do if k:match("^nvim%-mcp%.lsp") then package.loaded[k] = nil end end; require("nvim-mcp.lsp").setup()
```

Then `drive` with `describe` must list `definition`, `references`, `hover`, `rename` and the hidden six. (Claude Code may need `/mcp` reconnect only if `describe` shows them but calls fail.)

- [ ] **Step 2: Read-only actions on real servers**

Using a Lua file in this repo (lua_ls, if configured) and `README.md` (marksman):
- `definition` of `request` at `nvim-mcp/lua/nvim-mcp/lsp/init.lua` where it is used → lands on its `local request = require …` line.
- `references` to `M.summarise`, `hover` on `vim.lsp.util.locations_to_items`, `symbols` with `path` on `lsp/init.lua`, `symbols` with `query = "summarise"`, `calls` incoming on `locate`.
- On a file with no server (a `.txt`): the error names the filetype and fails immediately.
- Ask the human: did the `Claude · LSP …` notice appear for a slow request, and **not** flash for instant ones? If a timer-drawn notice never appears live, switch read-only actions to `QUIET_MS = 0` (update the spec's *Notice* section and the README).

- [ ] **Step 3: Edits on scratch files**

Create scratch Markdown files in the scratchpad (marksman supports heading rename and a TOC code action), open one in Neovim:
- `rename` a heading referenced from a second, unopened file → both saved; the second file's buffer is unlisted; `u` in the first reverts it; a notification appeared.
- Type into the first file without saving, then `rename` again → refused with `reason = "modified"`, nothing changed on disk.
- `code_actions` then `code_action` by title (e.g. marksman's TOC action) → applied and saved.
- `format` on a Lua file if a formatter server is attached (null-ls/stylua) → saved.

- [ ] **Step 4: Report**

Summarise to the human what worked, what was adjusted, and any server behaviour worth adding to the `lsp` skill's "Reading replies" section; add it if so and commit.
