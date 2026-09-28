-- Neovim forwards a mouse event to the program in a terminal only when it
-- lands on the text area and is a kind it can translate (src/nvim/terminal.c,
-- send_mouse_event). Anything else -- a click on the pane's status line or
-- edge, a wheel event it will not forward -- leaves terminal mode and is
-- handled as in normal mode. Harmless in a shell, but in the Claude pane it
-- means keystrokes quietly stop reaching Claude. So when a mouse event drops
-- the pane out of terminal mode, put it back once the mouse is done: straight
-- away for a wheel event, on release for a click, so dragging the status line
-- to resize still works. A key pressed in between, or the click landing in
-- another window, means normal mode was wanted and it is left alone.
--
-- ModeChanged says the pane left terminal mode but not why, so the key that
-- did it has to be seen on its way in. The key watcher only runs while that
-- matters: in terminal mode in the Claude pane, and after a click, until the
-- release. Everywhere else no watcher is attached at all.
local function keep_terminal_mode()
  -- Slot name for our on_key callback (on_key calls fn for every key Neovim receives).
  local ns = vim.api.nvim_create_namespace "claude_keep_terminal_mode"
  -- The most recent key typed into the pane, e.g. "<LeftMouse>" or "a".
  local last_key

  -- True when the cursor is in the Claude terminal.
  local function in_claude_pane()
    local ok, terminal = pcall(require, "claudecode.terminal")
    return ok and terminal.get_active_terminal_bufnr() == vim.api.nvim_get_current_buf()
  end

  -- A key as readable text, e.g. "<ScrollWheelLeft>".
  local function keyname(key, typed) return vim.fn.keytrans((typed and typed ~= "") and typed or key) end

  -- True for clicks, drags, releases and wheel events.
  local function is_mouse(name)
    return name:find "Mouse" or name:find "Release" or name:find "Drag" or name:find "ScrollWheel"
  end

  -- One slot: on_key replaces whatever is registered under `ns`, so each watch
  -- swaps the watcher rather than adding one, and unwatch empties the slot.
  local function watch(fn) vim.on_key(fn, ns) end
  local function unwatch() vim.on_key(nil, ns) end

  -- Put the pane back in terminal mode, unless the user has moved on.
  local function restore()
    vim.schedule(function()
      if in_claude_pane() and vim.api.nvim_get_mode().mode == "nt" then vim.cmd.startinsert() end
    end)
  end

  -- Bucket for our autocmds; clear = true avoids duplicates when reloaded.
  local group = vim.api.nvim_create_augroup("claude_keep_terminal_mode", { clear = true })

  -- Pane entered terminal mode: start recording keys.
  vim.api.nvim_create_autocmd("TermEnter", {
    group = group,
    callback = function()
      if not in_claude_pane() then return end
      last_key = nil
      watch(function(key, typed) last_key = keyname(key, typed) end)
    end,
  })

  -- Pane dropped from terminal (t) to normal (nt) mode: decide whether it was a stray mouse event.
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    pattern = "t:nt",
    callback = function()
      -- Not the mouse, e.g. <C-\><C-n>: normal mode was wanted, stop watching.
      if not in_claude_pane() or not (last_key and is_mouse(last_key)) then return unwatch() end
      -- A wheel event is over as soon as it happens: go straight back.
      if last_key:find "ScrollWheel" then
        unwatch()
        return restore()
      end
      -- A click: the button is still down. Back to terminal mode on release,
      -- unless something other than the mouse comes first.
      watch(function(key, typed)
        local name = keyname(key, typed)
        if name:find "Release" then
          unwatch()
          restore()
        elseif not is_mouse(name) then
          unwatch()
        end
      end)
    end,
  })

  -- Leaving the pane: stop watching; coming back re-enters terminal mode and TermEnter resumes.
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    callback = function()
      if in_claude_pane() then unwatch() end
    end,
  })
end

return {
  "coder/claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },
  -- The MCP server reaches Claude through the Claude Code plugin in `claude/`,
  -- registered once with `claude plugin marketplace add`. Nothing is wired here:
  -- doing both would register the same server name twice.
  opts = {
    terminal = {
      snacks_win_opts = {
        keys = {
          -- snacks maps a double <Esc> in its terminals to leave terminal mode,
          -- which collides with Claude Code's own Esc and Esc Esc.
          -- <C-\><C-n> still gets there on purpose, for scrolling back.
          term_normal = false,
          -- A touchpad sends a little sideways scroll with nearly every
          -- vertical swipe, and each one that is not forwarded to Claude would
          -- scroll the pane sideways in normal mode. The output wraps, so
          -- there is nothing to the side to scroll to.
          no_scroll_left = { "<ScrollWheelLeft>", "<Nop>", mode = "t" },
          no_scroll_right = { "<ScrollWheelRight>", "<Nop>", mode = "t" },
        },
      },
    },
  },
  config = function(_, opts)
    require("claudecode").setup(opts)
    keep_terminal_mode()
  end,
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
