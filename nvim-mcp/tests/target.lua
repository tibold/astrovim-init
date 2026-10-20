--- A Neovim of the test's own, driven over RPC, with a UI: started in a
--- pseudo-terminal, so it runs the real TUI. Without a UI Neovim never asks:
--- confirm() and "Overwrite existing file?" take their default and a hit-enter
--- prompt never appears, so a headless instance cannot show what a prompt
--- does to the bridge.
---
--- It loads tests/minimal_init.lua, not the plugin's setup: announce would
--- write a record where the human's bridges look for editors. No swap file
--- and no ShaDa, so a killed one leaves nothing behind.
local M = {}

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local count = 0

--- Results of editor.run, by token, sent back by the editor itself.
_G.nvim_mcp_test_done = _G.nvim_mcp_test_done or {}

--- Whether an editor in `mode` is waiting on the human: at a prompt, or, with
--- `blocking`, for the next key of a command typed halfway (which the bridge
--- waits out for a while). <Esc> ends either.
function M.at_prompt(mode) return mode.blocking or mode.mode:sub(1, 1) == "r" end

function M.start()
  count = count + 1
  local address = ("nvim-mcp-test-%d-%d"):format(vim.fn.getpid(), count)
  address = vim.fn.has "win32" == 1 and [[\\.\pipe\]] .. address or vim.fn.tempname() .. ".sock"
  -- Through tests/pty_host.lua, with no stdio: see there. It is ready once it
  -- has written `ready`, which it does only after its UI attached: until then
  -- it would run no Lua, and a request would wait.
  local ready = vim.fn.tempname()
  local host = vim.system(
    { "nvim", "-u", "NONE", "-l", here .. "/pty_host.lua", address, here .. "/minimal_init.lua", ready },
    { stdin = false, stdout = false, stderr = false }
  )
  local started = vim.wait(15000, function() return vim.uv.fs_stat(ready) ~= nil end, 50)

  local ch
  if started then
    local ok, connected = pcall(vim.fn.sockconnect, "pipe", address, { rpc = true })
    if ok and connected ~= 0 then ch = connected end
  end
  if not ch then pcall(host.kill, host, 9) end
  assert(ch, "the test Neovim never started on " .. address)
  -- This channel's id on the editor's side, for it to send results back to.
  local peer = vim.rpcrequest(ch, "nvim_get_api_info")[1]

  local editor = { address = address, host = host }

  --- nvim_get_mode: a fast function, so it answers even at a prompt.
  function editor.mode() return vim.rpcrequest(ch, "nvim_get_mode") end

  --- Keys, in <> notation, as the human would type them. nvim_input is fast
  --- too, so this answers a prompt.
  function editor.input(keys) vim.rpcrequest(ch, "nvim_input", keys) end

  --- Run Lua in it and wait for the result. Only for code that cannot stop at
  --- a prompt, in an editor not at one: such a request is never answered.
  function editor.exec(code, ...) return vim.rpcrequest(ch, "nvim_exec_lua", code, { ... }) end

  --- Run Lua that might stop at a prompt, the way the bridge does: sent as a
  --- notification, its result sent back as one, the mode watched meanwhile.
  --- A prompt is answered with `answer` (default <Esc>) so the run finishes.
  --- Returns the result ({ ok, result }) and every prompt mode seen.
  function editor.run(code, args, answer)
    count = count + 1
    local token = count
    local wrapped = ([[
local ok, result = pcall(function(...) %s end, ...)
if not ok then result = tostring(result) end
vim.rpcnotify(%d, "nvim_exec_lua", "local token, value = ... _G.nvim_mcp_test_done[token] = value",
  { %d, { ok = ok, result = result } })]]):format(code, peer, token)
    vim.rpcnotify(ch, "nvim_exec_lua", wrapped, args or {})
    local prompts = {}
    vim.wait(20000, function()
      if _G.nvim_mcp_test_done[token] then return true end
      local mode = editor.mode()
      if M.at_prompt(mode) then
        prompts[#prompts + 1] = mode.mode
        editor.input(answer or "<Esc>")
      end
      return false
    end, 100)
    local done = _G.nvim_mcp_test_done[token]
    _G.nvim_mcp_test_done[token] = nil
    return done, prompts
  end

  --- Wait until `fn(mode)` holds.
  function editor.wait_mode(fn)
    return vim.wait(5000, function() return fn(editor.mode()) end, 20)
  end

  --- Stop it, and make sure it is gone: answer whatever it is waiting on,
  --- quit, and kill it if that did not work.
  function editor.stop()
    for _ = 1, 3 do
      local ok, mode = pcall(editor.mode)
      if not ok or not M.at_prompt(mode) then break end
      pcall(editor.input, "<Esc>")
      vim.wait(100)
    end
    pcall(vim.rpcnotify, ch, "nvim_command", "qa!")
    -- The host exits once its editor has.
    local gone = pcall(host.wait, host, 3000)
    if not gone or (editor.pid and vim.uv.kill(editor.pid, 0) == 0) then
      if editor.pid then pcall(vim.uv.kill, editor.pid, 9) end
      pcall(host.kill, host, 9)
    end
    pcall(vim.fn.chanclose, ch)
  end

  -- A startup error would leave it at a prompt, where Lua would never run.
  local mode = editor.mode()
  if M.at_prompt(mode) then editor.stop() end
  assert(not M.at_prompt(mode), "the test Neovim started at a prompt (mode " .. mode.mode .. ")")
  editor.pid = editor.exec "return vim.fn.getpid()"
  local attached = editor.exec "return #vim.api.nvim_list_uis()" > 0
  if not attached then editor.stop() end
  assert(attached, "the test Neovim has no UI")
  return editor
end

--- The bridge as a long-lived process, one request at a time, so a test can
--- change the editor between calls. `env` adds to the bridge's environment;
--- NVIM always names `address`, never the editor running the tests, and the
--- bridge never scans for the human's editors.
function M.bridge(address, env)
  local bridge = vim.fs.normalize(here .. "/../../claude/server.lua")
  local lines, pending = {}, ""
  local proc = vim.system({ "nvim", "-u", "NONE", "-l", bridge }, {
    stdin = true,
    env = vim.tbl_extend("force", { NVIM = address, NVIM_MCP_SCAN = "0" }, env or {}),
    stdout = function(_, data)
      if not data then return end
      pending = pending .. data
      while true do
        local line, rest = pending:match "^([^\n]*)\n(.*)$"
        if not line then break end
        lines[#lines + 1], pending = line, rest
      end
    end,
  })

  local id, self = 0, {}

  --- One request; returns the reply and how long it took in milliseconds.
  function self.request(method, params)
    id = id + 1
    local this = id
    local started = vim.uv.hrtime()
    proc:write(vim.json.encode { jsonrpc = "2.0", id = this, method = method, params = params } .. "\n")
    local reply
    vim.wait(30000, function()
      for _, line in ipairs(lines) do
        local ok, message = pcall(vim.json.decode, line)
        if ok and type(message) == "table" and message.id == this then reply = message end
      end
      return reply ~= nil
    end, 10)
    return reply, (vim.uv.hrtime() - started) / 1e6
  end

  --- One tools/call; returns the reply and how long it took in milliseconds.
  function self.call(tool, arguments) return self.request("tools/call", { name = tool, arguments = arguments }) end

  --- How many notifications named `method` the bridge has sent so far.
  function self.notified(method)
    local sent = 0
    for _, line in ipairs(lines) do
      local ok, message = pcall(vim.json.decode, line)
      if ok and type(message) == "table" and message.id == nil and message.method == method then sent = sent + 1 end
    end
    return sent
  end

  function self.close()
    pcall(proc.write, proc, nil)
    pcall(proc.wait, proc, 5000)
    pcall(proc.kill, proc, 9)
  end

  return self
end

return M
