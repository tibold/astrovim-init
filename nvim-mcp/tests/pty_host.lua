--- Hosts a test editor's pseudo-terminal, for tests/target.lua:
---   nvim -u NONE -l pty_host.lua <address> <init> <ready>
--- and lives exactly as long as that editor does. The editor writes the file
--- <ready> once it has started, which with a UI is after the UI attached.
---
--- A process of its own because of where the TUI writes. Started from a test,
--- whose stdout is a pipe to the test runner, the editor's TUI wrote into that
--- pipe instead of its pseudo-terminal, never finished starting, and never
--- attached. Started from here, with no stdio of its own, it does.
local address, init, ready = _G.arg[1], _G.arg[2], _G.arg[3]
local job = vim.fn.jobstart({
  "nvim",
  "-n",
  "-i",
  "NONE",
  "-u",
  init,
  "--listen",
  address,
  "-c",
  ("lua vim.fn.writefile({}, %q)"):format(ready),
}, { pty = true, width = 100, height = 30, on_stdout = function() end })
if job <= 0 then os.exit(1) end
while vim.fn.jobwait({ job }, 0)[1] == -1 do
  vim.wait(100)
end
