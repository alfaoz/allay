-- transport: pluggable file-fetching backends.
--
-- Each transport implements a `fetch(url) -> body, err` function. The core
-- ships https:// and disk://; rednet:// and others are optional packages that
-- register themselves here at load time.

local M = {}

local registry = {}

-- Register a transport by scheme (the part before "://").
function M.register(scheme, impl)
  assert(type(scheme) == "string", "transport.register: scheme must be string")
  assert(type(impl) == "table" and type(impl.fetch) == "function",
    "transport.register: impl must have a fetch function")
  registry[scheme] = impl
end

-- Pull the scheme out of a URL like "https://x.com" or "disk://foo".
function M.scheme_of(url)
  return url:match("^([%w%+%-%.]+)://")
end

-- Fetch a URL using the appropriate transport. Returns (body, err).
function M.fetch(url)
  if type(url) ~= "string" then
    return nil, "transport.fetch: url must be a string"
  end
  local scheme = M.scheme_of(url)
  if not scheme then
    return nil, "transport.fetch: no scheme in url: " .. url
  end
  local impl = registry[scheme]
  if not impl then
    return nil, string.format("transport.fetch: no transport for scheme %s://", scheme)
  end
  return impl.fetch(url)
end

-- Schemes that are currently registered.
function M.schemes()
  local list = {}
  for k, _ in pairs(registry) do table.insert(list, k) end
  table.sort(list)
  return list
end

-- For tests: clear the registry.
function M._reset()
  registry = {}
end

-- Auto-register the built-in transports.
local function setup_builtins()
  M.register("https", require("transport.https"))
  M.register("http",  require("transport.https"))  -- same impl, http allowed too
  M.register("disk",  require("transport.disk"))
end

local ok, err = pcall(setup_builtins)
if not ok then
  -- Tests might require this module before its siblings are on the path.
  -- The transports can be loaded manually in that case.
end

return M
