-- SessionStart hook: make the checklist panel part of the working habit.
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

-- Claude Code inherits `$NVIM` from the terminal buffer it was launched in.
-- Without it there is no editor to draw a panel in, and a standing instruction
-- to use one would be noise costing context in every unrelated session. A
-- Claude started from a plain terminal alongside Neovim misses this and reaches
-- the skill through its description instead, which is the intended fallback.
if not vim.env.NVIM or vim.env.NVIM == "" then os.exit(0) end

-- Kept deliberately short: this is paid for in every session inside Neovim, so
-- it carries only what is needed to act. The reasoning lives in the skill.
local context = table.concat({
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
  "Group related items, batch a turn's changes into one call. Write-only: never",
  "read it back or report on it.",
  "",
  "The `checklist` skill has the contract and grouping rules.",
  "</nvim-checklist>",
}, "\n")

io.stdout:write(vim.json.encode {
  hookSpecificOutput = {
    hookEventName = "SessionStart",
    additionalContext = context,
  },
})
