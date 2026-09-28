-- lua/mason-local/github.lua
--
-- The latest release tag of a GitHub repository, for package specs that should
-- track upstream instead of pinning. Mason requires the specs while loading its
-- registries at startup, so this never waits on the network: it answers from a
-- cache file and refreshes that in the background, at most once a day. A new
-- release therefore reaches mason on the start after it is fetched, and shows
-- up in :Mason as an update like any other.
local M = {}

local MAX_AGE = 24 * 60 * 60

local function cache_path(repo) return vim.fn.stdpath "cache" .. "/mason-local/" .. repo:gsub("/", "-") .. ".tag" end

--- Only a plain semver tag is trusted, so an error page or a pre-release naming
--- scheme can never end up interpolated into an asset URL.
local function valid(tag) return type(tag) == "string" and tag:match "^v%d+%.%d+%.%d+$" ~= nil end

local function read(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local tag = vim.trim(file:read "*a" or "")
  file:close()
  return valid(tag) and tag or nil
end

local function refresh(repo, path)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local url = ("https://api.github.com/repos/%s/releases/latest"):format(repo)
  -- Offline, rate limited or curl missing all land here as a failure, which
  -- leaves the cache as it was: the next start simply tries again.
  pcall(vim.system, { "curl", "-fsSL", "--max-time", "10", url }, { text = true }, function(result)
    if result.code ~= 0 then return end
    local ok, body = pcall(vim.json.decode, result.stdout)
    if not ok or not valid(body.tag_name) then return end
    local file = io.open(path, "w")
    if not file then return end
    file:write(body.tag_name)
    file:close()
  end)
end

--- The cached latest tag of `repo`, or `fallback` until one has been fetched.
---@param repo string owner/name
---@param fallback string the version to use before the first fetch succeeds
---@return string
function M.latest(repo, fallback)
  local path = cache_path(repo)
  local stat = vim.uv.fs_stat(path)
  if not stat or os.time() - stat.mtime.sec > MAX_AGE then refresh(repo, path) end
  return read(path) or fallback
end

return M
