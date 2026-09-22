return {
  "coder/claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },
  -- The MCP server reaches Claude through the Claude Code plugin in `claude/`,
  -- registered once with `claude plugin marketplace add`. Nothing is wired here:
  -- doing both would register the same server name twice.
  config = true,
  keys = {
    -- A group label, but lazy still registers it as a real lazy-load trigger.
    -- With a nil rhs no mapping survives the load, so the first <Leader>a fell
    -- through to `a` and hit E21 on the unmodifiable dashboard.
    { "<leader>a", "<Nop>", desc = "AI/Claude Code" },
    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
    { "<leader>af", "<cmd>ClaudeCodeFocus<cr>", desc = "Focus Claude" },
    { "<leader>ar", "<cmd>ClaudeCode --resume<cr>", desc = "Resume Claude" },
    { "<leader>aC", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Claude" },
    { "<leader>ab", "<cmd>ClaudeCodeAdd %<cr>", desc = "Add current buffer" },
    { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude" },
    { "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept diff" },
    { "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Deny diff" },
  },
}
