-- Override AstroNvim's snapshot pin of aerial.nvim (`version = "^2.2"`).
--
-- aerial 2.x calls `Query:iter_matches(..., { all = false })`, an option that
-- Neovim 0.12 removed. Matches now always come back as `TSNode[]`, so the
-- markdown extension's `level_node:type()` raises "attempt to call method
-- 'type' (a nil value)" on every markdown buffer.
--
-- Fixed upstream in aerial v3.1.0 (commit f93dcee). AstroNvim's `main` already
-- bumps this pin to `^3`, but that has not landed in a v5 release yet.
--
-- Requires nvim >= 0.12 (aerial 4.0.0 dropped older versions).
return {
  { "stevearc/aerial.nvim", version = "^4" },
}
