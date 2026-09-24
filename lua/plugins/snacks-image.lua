-- lua/plugins/snacks-image.lua
--
-- snacks.image only draws in terminals on its own list (kitty, ghostty,
-- wezterm) and has no option to add one, so Rio -- which speaks the Kitty
-- graphics protocol -- is appended to that list here. terminal.envs() returns
-- the list itself, not a copy, and snacks reads it lazily the first time an
-- image is shown, so adding to it while snacks loads is enough. opts rather
-- than init, which runs before snacks is on the runtimepath.
--
-- Matched by TERM_PROGRAM, which Rio sets, as well as by its XTVERSION reply:
-- that reply cannot be relied on to arrive in time on Windows, where the
-- query goes out through ConPTY.
--
-- With Unicode placeholders, which Rio implements: the image is drawn in text
-- cells nvim owns, so it goes away with the buffer. Without them snacks places
-- it at a screen position and never takes it down when another buffer is
-- shown in the window -- the next image lands on top of the last. WezTerm
-- has no placeholders, so it keeps that problem.
--
-- On Windows, images only get through ConPTY 1.22 and later. Rio's installer
-- does not ship it, so conpty.dll and OpenConsole.exe from the
-- Microsoft.Windows.Console.ConPTY NuGet package have to sit next to rio.exe.

-- snacks sizes images from the terminal's cell size in pixels, which it asks
-- the tty for with an ioctl that Windows does not have. It then assumes 9x18
-- cells and a 9/8 display scale, so images come out the wrong size and the
-- terminal rescales them, blurring them. Measured instead from the window
-- that has focus -- the terminal nvim is in, whenever an image is being
-- opened -- divided by the grid nvim draws on it. Padding and a tab bar make
-- it a slight overestimate, which is harmless next to the guess.
local function measure_windows_cells(terminal)
  local ffi = require "ffi"
  pcall(
    ffi.cdef,
    [[
    typedef struct { long left, top, right, bottom; } SNACKS_RECT;
    void *GetForegroundWindow(void);
    int GetClientRect(void *hwnd, SNACKS_RECT *rect);
    unsigned int GetDpiForWindow(void *hwnd);
  ]]
  )
  local user32 = ffi.load "user32"
  local guess = terminal.size

  terminal.size = function()
    local ok, size = pcall(function()
      local hwnd = user32.GetForegroundWindow()
      local rect = ffi.new "SNACKS_RECT"
      if hwnd == nil or user32.GetClientRect(hwnd, rect) == 0 then return end
      local width, height = rect.right - rect.left, rect.bottom - rect.top
      if width <= 0 or height <= 0 then return end
      return {
        width = width,
        height = height,
        columns = vim.o.columns,
        rows = vim.o.lines,
        cell_width = width / vim.o.columns,
        cell_height = height / vim.o.lines,
        scale = math.max(1, user32.GetDpiForWindow(hwnd) / 96),
      }
    end)
    return ok and size or guess()
  end
end

return {
  "folke/snacks.nvim",
  optional = true,
  -- lazy.nvim can resolve opts more than once, hence the checks.
  opts = function()
    local terminal = require "snacks.image.terminal"

    local envs = terminal.envs()
    if not vim.iter(envs):any(function(e) return e.name == "rio" end) then
      table.insert(envs, {
        name = "rio",
        terminal = "rio",
        env = { TERM_PROGRAM = "rio" },
        supported = true,
        placeholders = true,
      })
    end

    if vim.fn.has "win32" == 1 and not terminal.__measured then
      terminal.__measured = true
      measure_windows_cells(terminal)
    end

    -- snacks scales an image by the DPI stored in the file, and ImageMagick
    -- reports 72 -- the old Mac screen's -- for the many files that store
    -- none: most PNGs, screenshots from Windows, webp. Those were enlarged by
    -- 96/72 and the terminal upscaled them, blurred. 72 is read as "none"
    -- and becomes one image pixel to one screen pixel; a real DPI, such as
    -- the 144 a Retina screenshot stores, is left for snacks to honour.
    local util = require "snacks.image.util"
    if not util.__native then
      util.__native = true
      local fit = util.fit
      util.fit = function(file, cells, o)
        local dpi = o and o.info and o.info.dpi
        if dpi and dpi.width == 72 and dpi.height == 72 then
          local native = 96 * (terminal.size().scale or 1)
          o = vim.tbl_extend("force", o, {
            info = vim.tbl_extend("force", o.info, { dpi = { width = native, height = native } }),
          })
        end
        return fit(file, cells, o)
      end
    end
  end,
}
