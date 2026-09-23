-- lua/plugins/dadbod.lua
--
-- The plugins themselves now come from `astrocommunity.pack.full-dadbod`,
-- which supplies the `:DBUI*` lazy triggers and the blink.cmp source that
-- completes table and column names inside sql buffers. This file is only the
-- keymaps and connection handling on top.
--
-- dadbod does not speak any wire protocol itself: it shells out to the vendor
-- CLI, invoking bare `psql` and bare `sqlite3` (see its autoload/db/adapter/).
-- Both must therefore be on PATH under exactly those names. Installing them is
-- the dotfiles' job, not this repository's; recorded here only so the
-- requirement is discoverable from the plugin that imposes it.
--
--   psql      win   winget install PostgreSQL.PostgreSQL.18  (see below)
--             mac   brew install libpq                       (keg-only)
--             deb   apt install postgresql-client
--             rpm   dnf install postgresql
--             arch  pacman -S postgresql-libs
--
--   sqlite3   win   winget install SQLite.SQLite
--             mac   preinstalled at /usr/bin/sqlite3
--             deb   apt install sqlite3
--             rpm   dnf install sqlite
--             arch  pacman -S sqlite
--
-- Two platforms need a PATH edit the package manager will not make for you.
-- On Windows there is no client-only PostgreSQL package: the installer is
-- component based, so deselect "PostgreSQL Server", "pgAdmin" and "Stack
-- Builder", take "Command Line Tools" alone, and add
-- `C:\Program Files\PostgreSQL\18\bin`. On macOS libpq is keg-only because it
-- conflicts with the full postgresql formula, so add
-- `$(brew --prefix libpq)/bin`.
--
-- Connections are *not* stored here. `:DBUIAddConnection` writes them to
-- `db_ui_save_location` below, which is outside this repository, so a password
-- in a URL never ends up in git. For a connection you want in every session,
-- prefer an environment variable read at startup over a literal (see the
-- commented example).

-- astrocommunity.pack.full-dadbod tries to turn the icons on, but sets
-- `db_use_nerd_fonts`; the variable vim-dadbod-ui actually reads is
-- `db_ui_use_nerd_fonts` (plugin/db_ui.vim:25). Its guard also evaluates
-- `vim.g.icons_enabled` while that is still nil, so it resolves to nil twice
-- over and the drawer renders without icons. Setting the real name here.
vim.g.db_ui_use_nerd_fonts = 1

vim.g.db_ui_save_location = vim.fn.stdpath "data" .. "/db_ui"
-- By default `:w` in a query buffer runs the query (query.vim:143). Keeping
-- saving and executing separate means an absent-minded `:w` cannot fire
-- something at a live database. `<Leader>S` runs the buffer, or the selection
-- in visual mode; `<Leader>W` saves the query for reuse (ftplugin/sql.vim).
vim.g.db_ui_execute_on_save = false

-- Picking a table helper in the drawer runs it straight away rather than
-- leaving the generated query sitting there unexecuted. With the option above
-- off, this path calls execute_query() directly (query.vim:146).
vim.g.db_ui_auto_execute_table_helpers = true

-- Connections available in every session. Anything listed here is visible in
-- `:DBUI` without being saved to disk.
--   local url = vim.env.DATABASE_URL
--   if url then vim.g.dbs = { { name = "app", url = url } } end
--
-- URL shapes, for reference:
--   postgresql://user:password@localhost:5432/dbname
--   sqlite:C:/path/to/file.db

---@type LazySpec
return {
  "AstroNvim/astrocore",
  opts = {
    mappings = {
      n = {
        ["<Leader>D"] = { desc = "Database" },
        ["<Leader>Du"] = { "<Cmd>DBUIToggle<CR>", desc = "Toggle DBUI" },
        ["<Leader>Da"] = { "<Cmd>DBUIAddConnection<CR>", desc = "Add connection" },
        ["<Leader>Df"] = { "<Cmd>DBUIFindBuffer<CR>", desc = "Find DB buffer" },
      },
    },
  },
}
