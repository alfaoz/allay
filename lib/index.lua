-- index: fetching and parsing a source's package index.
--
-- A source MAY publish an `index.lua` at its root that returns:
--   {
--     spec = "allay/v1.0.0",
--     format = "allay" | "unicornpkg/v1.0.0" | ...,
--     name = "allaycc/lualibs",
--     description = "...",
--     packages = {
--       hash = { version = "1.0.0", description = "..." },
--       ...
--     },
--   }
--
-- Sources without an index.lua run in "blind mode": package definitions are
-- fetched by name from <source>/<name>.lua, but search and list don't work.

local M = {}

local transport = require("transport")
local source_mod = require("source")

-- Fetch and parse a source's index. Returns (index_table, err).
-- If the source has no index.lua, returns (nil, "blind") which callers should
-- treat as "fall back to direct fetches by name".
function M.fetch(source)
  -- Sources declaring a non-allay format don't publish an allay index.lua
  -- (their packages are translated on the fly during resolution). Run them
  -- in blind mode: per-package fetches by name from <source.url>/<name>.lua,
  -- which the resolver pipes through the matching translator.
  if source.format and not source.format:match("^allay/") then
    return nil, "blind"
  end

  local url = source_mod.file_url(source, "index.lua")
  local body, err = transport.fetch(url)
  if not body then
    if err and (err:find("404") or err:find("not found")) then
      return nil, "blind"
    end
    return nil, err
  end

  -- index.lua is a full Lua module: must contain its own `return`.
  -- We accept both styles: a bare `{ ... }` expression or a `return { ... }`
  -- module body. Try the module form first; fall back to expression form.
  local fn, parse_err = load(body, "index", "t", {})
  if not fn then
    fn, parse_err = load("return " .. body, "index", "t", {})
  end
  if not fn then
    return nil, "index: parse error: " .. (parse_err or "?")
  end
  local ok, value = pcall(fn)
  if not ok then
    return nil, "index: eval error: " .. tostring(value)
  end
  if type(value) ~= "table" then
    return nil, "index: did not return a table"
  end
  return value
end

-- Look up a package by name in an index. Returns the entry or nil.
function M.lookup(index, name)
  if type(index) ~= "table" or type(index.packages) ~= "table" then
    return nil
  end
  return index.packages[name]
end

-- Search for packages whose name or description matches a query.
function M.search(index, query)
  local results = {}
  if type(index) ~= "table" or type(index.packages) ~= "table" then
    return results
  end
  query = query:lower()
  for name, entry in pairs(index.packages) do
    if name:lower():find(query, 1, true)
       or (entry.description and entry.description:lower():find(query, 1, true)) then
      table.insert(results, {
        name = name,
        version = entry.version,
        description = entry.description,
      })
    end
  end
  table.sort(results, function(a, b) return a.name < b.name end)
  return results
end

return M
