-- Notification hook: tell the human when Claude is waiting on them.
--
-- Claude Code raises a Notification when it has sat at the prompt for about a
-- minute (idle_prompt), when a permission decision has waited a few seconds
-- (permission_prompt), and when it asks a question or needs input. hooks.json
-- routes those here, and this turns each into a desktop notification plus a
-- bell: the terminal shows the notification (Rio sends OSC 777 to the system's
-- notification centre) and marks the tab that rang, when it is not the one in
-- front.
--
-- Always sent, not only when the terminal is out of focus. The only focus a
-- program in a terminal can learn is the window's, reported to whichever tab
-- is in front when it changes -- switching tabs reports nothing -- so an nvim in
-- a background tab believes it still has focus, and would stay quiet exactly
-- when it should not. The events are late enough not to need it: a minute of
-- idling, or a prompt that has already waited.
--
-- Where the sequence goes depends on where Claude is running:
--
--   inside nvim  Claude's terminal is an nvim terminal buffer, which keeps
--                notifications and bells to itself. So nvim is asked, over
--                $NVIM, to write the sequence to the terminal nvim itself is
--                drawn in (nvim_ui_send).
--   elsewhere    the hook's output carries it as terminalSequence, which
--                Claude Code writes to its own terminal. A hook cannot write to
--                the terminal directly: its stdio belongs to Claude.
--
-- Run through `nvim -l` like session-start.lua, for the same reasons.

local ESC, BEL = "\27", "\7"

--- A notification field, safe to put inside OSC 777: `;` separates the fields
--- and a control character would end or corrupt the sequence.
local function field(text) return (tostring(text):gsub("[%c;]", " ")) end

--- The notification this event deserves, or nil for one this hook ignores.
local function describe(event)
  local kind = event.notification_type or ""
  local waiting = ({
    idle_prompt = "is waiting for your reply",
    permission_prompt = "needs your permission",
    agent_needs_input = "needs your input",
  })[kind]
  if not waiting and kind:match "^elicitation" then waiting = "has a question" end
  if not waiting then return nil end

  -- The folder names the session: several may be open at once.
  local cwd = (type(event.cwd) == "string" and event.cwd ~= "") and event.cwd or vim.uv.cwd() or ""
  local project = vim.fs.basename(vim.fs.normalize(cwd))
  if project == "" then project = "Claude" end
  return { title = "Claude", body = project .. " " .. waiting }
end

local ok, event = pcall(vim.json.decode, io.stdin:read "a" or "")
if not ok or type(event) ~= "table" then os.exit(0) end

local note = describe(event)
if not note then os.exit(0) end

-- OSC 777 for the notification, then a bell of its own for the tab mark.
local sequence = ("%s]777;notify;%s;%s%s%s"):format(ESC, field(note.title), field(note.body), BEL, BEL)

if vim.env.NVIM and vim.env.NVIM ~= "" then
  -- A notification rather than a request: nothing comes back to wait for, so
  -- an editor that is busy, or holds its socket without servicing it, cannot
  -- keep Claude waiting on this hook. Sent only to an editor with a UI
  -- attached; a headless one has no terminal to pass it to.
  local connected, channel = pcall(vim.fn.sockconnect, "pipe", vim.env.NVIM, { rpc = true })
  if connected and channel ~= 0 then
    vim.rpcnotify(
      channel,
      "nvim_exec_lua",
      [[
      if #vim.api.nvim_list_uis() > 0 then vim.api.nvim_ui_send(...) end
    ]],
      { sequence }
    )
    vim.fn.chanclose(channel)
  end
  os.exit(0)
end

-- A top-level field, not one inside hookSpecificOutput, where Claude Code
-- ignores it. Claude writes it only while its interface is on screen, and
-- only sequences on its allowlist, which OSC 777 and a bare BEL both are.
io.stdout:write(vim.json.encode { terminalSequence = sequence })
