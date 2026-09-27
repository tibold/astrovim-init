-- lua/plugins/neotest.lua

-- neotest's built-in "integrated" strategy always runs tests under a pty. On
-- Windows that is ConPTY, which sends an empty chunk right at startup, and the
-- strategy takes an empty chunk to mean end of output. It closes the output
-- file as soon as the process exits, before ConPTY has flushed, so adapters
-- are left parsing a file that holds nothing but terminal setup escapes. The
-- rust adapter then finds no per-test results and neotest marks every test in
-- the file failed. This does the same job with a plain pipe.
--
-- One pipe, shared by stdout and stderr, as a terminal shares one stream.
-- rustaceanvim runs cargo test with --nocapture, so a panic goes to stderr the
-- moment it happens, between "test x ... " and "FAILED". Read through two
-- pipes, every panic arrived after the summary instead, run together at the
-- end of the output with no blank line after it; rustaceanvim's parser needs
-- that blank line, matched no failure, and marked the whole file failed.

--- The child's environment: neotest's additions over the editor's own, as a
--- list, since uv.spawn replaces the environment rather than extending it.
local function environment(extra)
  local merged = vim.tbl_extend("force", vim.fn.environ(), extra or {})
  local list = {}
  for name, value in pairs(merged) do
    list[#list + 1] = name .. "=" .. tostring(value)
  end
  return list
end

local function pipe_strategy(spec)
  local nio = require "nio"
  local output_path = nio.fn.tempname()
  local file = assert(io.open(output_path, "wb"))
  local chunks, queue, done = {}, nio.control.queue(), nio.control.future()
  local code

  local function on_data(_, data)
    if not data then return end
    data = data:gsub("\r\n", "\n")
    chunks[#chunks + 1] = data
    file:write(data)
    queue.put_nowait(data)
  end

  -- A pipe from the OS rather than from libuv, so its write end is a plain
  -- file descriptor that can stand as both the child's stdout and stderr.
  local fds = assert(vim.uv.pipe({ nonblock = true }, { nonblock = false }))
  local reader = assert(vim.uv.new_pipe(false))
  reader:open(fds.read)

  local exited, drained = false, false
  local function finish()
    if exited and drained then vim.schedule(done.set) end
  end

  local command = spec.command
  local executable = vim.fn.exepath(command[1])
  local proc, err
  proc, err = vim.uv.spawn(executable ~= "" and executable or command[1], {
    args = vim.list_slice(command, 2),
    cwd = spec.cwd,
    env = environment(spec.env),
    stdio = { nil, fds.write, fds.write },
    hide = true,
  }, function(exit_code)
    code = exit_code
    exited = true
    if proc and not proc:is_closing() then proc:close() end
    finish()
  end)
  -- The child holds its own copy; closing ours is what lets the read end see
  -- end of file once the child exits.
  vim.uv.fs_close(fds.write)

  local ok = proc ~= nil
  if ok then
    reader:read_start(function(_, data)
      if data then return on_data(nil, data) end
      reader:close()
      drained = true
      finish()
    end)
  else
    reader:close()
    on_data(nil, tostring(err))
    code = 1
    done.set()
  end

  return {
    is_complete = function() return done.is_set() end,
    output = function() return output_path end,
    stop = function()
      if ok and not proc:is_closing() then proc:kill "sigterm" end
    end,
    output_stream = function()
      return function()
        local data = nio.first { queue.get, done.wait }
        if data then return data end
        if queue.size() ~= 0 then return queue.get() end
      end
    end,
    -- No live terminal to attach to; show what has arrived so far
    attach = function()
      nio.scheduler()
      vim.lsp.util.open_floating_preview(vim.split(table.concat(chunks), "\n"), "", { border = "rounded" })
    end,
    result = function()
      done.wait()
      file:close()
      return code
    end,
  }
end

return {
  "nvim-neotest/neotest",
  opts = function(_, opts)
    if vim.fn.has "win32" == 1 then opts.default_strategy = pipe_strategy end

    -- Lets Claude read the last run through nvim-mcp's `tests` action. neotest
    -- has no other way to read results than a consumer it hands its client to.
    opts.consumers = vim.tbl_extend("force", opts.consumers or {}, { nvim_mcp = require("nvim-mcp.neotest").consumer })

    -- The python pack's `base` spec is reached through more than one import,
    -- so its neotest opts function runs twice and registers neotest-python
    -- twice, which makes every python test show up (and run) twice. Keep the
    -- first adapter of each name.
    local seen = {}
    opts.adapters = vim.tbl_filter(function(adapter)
      if seen[adapter.name] then return false end
      seen[adapter.name] = true
      return true
    end, opts.adapters or {})
  end,
}
