-- source: managing the list of package sources allay knows about.
--
-- Sources live in /etc/allay/sources.lua as a Lua-serialized list. Each
-- entry is { id = "user/repo" or url, url = expanded URL prefix }.
--
-- Adding a source resolves shorthand and pings the index to confirm the
-- source exists. Listing is just reading the file. Removing is straightforward.

local M = {}

local pathkit = require("pathkit")

M.SOURCES_FILE = "/etc/allay/sources.lua"

-- ---------------------------------------------------------------------------
-- Shorthand expansion
-- ---------------------------------------------------------------------------

-- Turn "alfaoz/foo" into "https://raw.githubusercontent.com/alfaoz/foo/main/".
-- Recognizes "alfaoz/foo@v1.0.0" or "alfaoz/foo@some-branch" too.
-- A full URL is returned verbatim.
function M.expand(spec)
  if type(spec) ~= "string" then
    return nil, "source: spec must be a string"
  end

  -- Already a URL.
  if spec:match("^[%w%+%-%.]+://") then
    -- Trim trailing slash for normalization.
    if spec:sub(-1) == "/" then spec = spec:sub(1, -2) end
    return spec
  end

  -- GitHub shorthand: user/repo[@ref]
  local user, repo, ref = spec:match("^([%w%-%.]+)/([%w%-%.]+)@([%w%-%./]+)$")
  if not user then
    user, repo = spec:match("^([%w%-%.]+)/([%w%-%.]+)$")
    ref = "main"
  end

  if not user then
    return nil, "source: cannot parse shorthand: " .. spec
  end

  return string.format("https://raw.githubusercontent.com/%s/%s/%s",
    user, repo, ref)
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

-- Read sources from disk. Returns a list (possibly empty).
function M.load()
  if not pathkit.exists(M.SOURCES_FILE) then
    return {}
  end
  local content, err = pathkit.read(M.SOURCES_FILE)
  if err then return nil, err end

  local fn, parse_err = load("return " .. content, "sources", "t", {})
  if not fn then
    return nil, "source: cannot parse sources file: " .. (parse_err or "?")
  end
  local ok, value = pcall(fn)
  if not ok or type(value) ~= "table" then
    return nil, "source: sources file did not return a table"
  end
  return value
end

-- Write sources to disk atomically.
function M.save(sources)
  -- Serialize.
  local lines = { "{" }
  for _, s in ipairs(sources) do
    table.insert(lines, string.format("  { id = %q, url = %q },",
      s.id or s.url, s.url))
  end
  table.insert(lines, "}")
  local serialized = table.concat(lines, "\n") .. "\n"
  return pathkit.write_atomic(M.SOURCES_FILE, serialized)
end

-- ---------------------------------------------------------------------------
-- Operations
-- ---------------------------------------------------------------------------

-- Add a source by spec. Returns (entry, err).
function M.add(spec)
  local url, err = M.expand(spec)
  if err then return nil, err end

  local sources, load_err = M.load()
  if load_err then return nil, load_err end

  for _, s in ipairs(sources) do
    if s.id == spec or s.url == url then
      return nil, "source already added: " .. spec
    end
  end

  local entry = { id = spec, url = url }
  table.insert(sources, entry)
  local ok, save_err = M.save(sources)
  if not ok then return nil, save_err end
  return entry
end

-- Remove a source by id or url. Returns (ok, err).
function M.remove(spec)
  local sources, load_err = M.load()
  if load_err then return nil, load_err end

  local idx = nil
  for i, s in ipairs(sources) do
    if s.id == spec or s.url == spec then
      idx = i
      break
    end
  end
  if not idx then return nil, "source not found: " .. spec end

  table.remove(sources, idx)
  return M.save(sources)
end

-- List sources.
function M.list()
  return M.load()
end

-- Build the URL to a specific file in a source.
function M.file_url(source, path)
  local url = source.url
  if url:sub(-1) ~= "/" and path:sub(1, 1) ~= "/" then
    return url .. "/" .. path
  elseif url:sub(-1) == "/" and path:sub(1, 1) == "/" then
    return url .. path:sub(2)
  else
    return url .. path
  end
end

return M
