-- SessionStart hook: make the checklist panel part of the working habit, and
-- put its current contents back in front of an agent that has just started,
-- been cleared, or been compacted.
--
-- A skill only loads when its description matches the situation, and "the human
-- would like to see a plan" matches almost everything, which is to say nothing
-- in particular. This injects a short standing instruction instead, and leaves
-- the contract itself in the `checklist` skill to be loaded on demand.
--
-- Run through `nvim -l` rather than a shell script. Every other entry point in
-- this plugin already invokes nvim that way, nvim is by definition installed
-- wherever this plugin is useful, and it avoids needing a bash/cmd polyglot
-- wrapper to be cross platform. `vim.json.encode` also gets the escaping right,
-- which hand-rolled JSON in shell reliably does not.
--
-- Note that under `-l`, `print` writes to stderr. Anything meant for Claude
-- Code has to go through `io.stdout` or it is silently discarded.

local SELF = _G.arg and _G.arg[0]

-- How long the editor gets to hand over its checklist. A hook that blocks
-- blocks the session starting, so this fails open rather than waiting.
local READ_MS = 2000

-- Enough for a long checklist, short of letting a runaway one crowd out the
-- conversation it is meant to support.
local MAX_CHECKLIST = 4000

-- Claude Code inherits `$NVIM` from the terminal buffer it was launched in.
-- Without it there is no editor to draw a panel in, and a standing instruction
-- to use one would be noise costing context in every unrelated session. A
-- Claude started from a plain terminal alongside Neovim misses this and reaches
-- the skill through its description instead, which is the intended fallback.
if not vim.env.NVIM or vim.env.NVIM == "" then os.exit(0) end

--- Read mode: `nvim -u NONE -l session-start.lua --checklist` prints the panel
--- as markdown. Spawned as a child by the main path below so that an editor
--- which holds its socket open without servicing RPC -- a real state, and one
--- that hung instance discovery earlier in this plugin's life -- cannot block
--- the session from starting. `vim.rpcrequest` has no timeout of its own and a
--- uv timer cannot interrupt a blocked main loop, so a child with a deadline is
--- the only bound available.
--- The address arrives as an argument rather than being read from `$NVIM` in
--- here, and that is load bearing. A child spawned by `vim.system` which reads
--- `vim.env.NVIM` itself and then issues an `rpcrequest` deadlocks: it connects
--- fine and the reply never arrives. Passing the identical string as an
--- argument works, with `$NVIM` still inherited and the environment otherwise
--- untouched, so it is the lookup that matters rather than the value or the
--- environment. Verified both ways; `claude/server.lua` avoids it by accident,
--- since its probe has always taken the address as an argument.
if _G.arg and _G.arg[1] == "--checklist" then
  local ok, channel = pcall(vim.fn.sockconnect, "pipe", _G.arg[2], { rpc = true })
  if not ok or channel == 0 then os.exit(1) end
  -- `package.loaded`, not `require`: with lazy.nvim the plugin is not on the
  -- runtimepath until it loads, and requiring it from here would be a side
  -- effect rather than a reading.
  local read_ok, markdown = pcall(
    vim.rpcrequest,
    channel,
    "nvim_exec_lua",
    [[
      local window = package.loaded["checklist.window"]
      return window and window.markdown() or ""
    ]],
    {}
  )
  if not read_ok or type(markdown) ~= "string" then os.exit(1) end
  io.stdout:write(markdown)
  os.exit(0)
end

--- The panel's current contents, or nil when there is nothing to say.
local function checklist()
  if not SELF then return nil end
  local done = vim
    .system({ "nvim", "-u", "NONE", "-l", SELF, "--checklist", vim.env.NVIM }, {
      text = true,
      timeout = READ_MS,
    })
    :wait()
  if done.code ~= 0 then return nil end

  local markdown = vim.trim(done.stdout or "")
  if markdown == "" then return nil end
  if #markdown > MAX_CHECKLIST then markdown = markdown:sub(1, MAX_CHECKLIST) .. "\n…truncated" end
  return markdown
end

-- Kept deliberately short: this is paid for in every session inside Neovim, so
-- it carries only what is needed to act. The reasoning lives in the skill.
local lines = {
  "<nvim-checklist>",
  "The human has a checklist panel beside their code. Keep it in step with the",
  'conversation using the `drive` tool (`action: "checklist_update"`): as soon',
  "as anything is open, and on every turn that changes what is open.",
  "",
  "This applies to discussions too, not just code — what has been agreed, what",
  "is still pending and what was set aside is exactly what the transcript hides.",
  "When they defer something, move it to a `Deferred` group rather than dropping",
  "it, so the decision stays visible.",
  "",
  "States: todo, inprogress, done, blocked. Mark what you are on `inprogress`,",
  "and mark things `done` as you finish them rather than in a sweep at the end.",
  "",
  "Group items by workstream — a flat wall of items is the thing this avoids.",
  "Position is fixed when an item is first mentioned, so when the shape of the",
  "plan becomes clearer, move things with `index` rather than leaving a log of",
  "the order they came up in. Batch a turn's changes into one call.",
  "",
  "Write-only: never read it back or report on it.",
  "",
  "The `checklist` skill has the contract and grouping rules.",
}

-- Compaction is exactly when the plan is lost, and it is also when this hook
-- fires, so the panel is handed over rather than merely pointed at. This is the
-- one time the checklist is read: pushed once, at a bounded cost, never pulled
-- mid-conversation.
local current = checklist()
if current then
  vim.list_extend(lines, {
    "",
    "It currently holds the following. Treat this as your plan and carry on from",
    "it; do not report it back to the human, who is looking at it.",
    "",
    current,
  })
end

lines[#lines + 1] = "</nvim-checklist>"

io.stdout:write(vim.json.encode {
  hookSpecificOutput = {
    hookEventName = "SessionStart",
    additionalContext = table.concat(lines, "\n"),
  },
})
