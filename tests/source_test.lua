-- source/transport/index tests.
package.path = package.path
  .. ";../lib/?.lua;../lib/?/init.lua"
  .. ";../../lualibs/?/init.lua;../../lualibs/?.lua"

-- Fake fs (reused from pathkit pattern).
local files = {}
_G.fs = {
  exists = function(p) return files[p] ~= nil end,
  isDir = function(p) return files[p] and files[p].dir end,
  getDir = function(p) return p:match("^(.*)/[^/]*$") or "" end,
  getName = function(p) return p:match("([^/]+)$") or p end,
  getSize = function(p) return files[p] and #(files[p].content or "") or 0 end,
  makeDir = function(p)
    local parts = {}
    for part in p:gmatch("[^/]+") do
      table.insert(parts, part)
      local cur = "/" .. table.concat(parts, "/")
      if not files[cur] then files[cur] = { dir = true } end
    end
  end,
  list = function(p)
    local r, prefix = {}, p == "/" and "/" or (p .. "/")
    for k, _ in pairs(files) do
      if k:sub(1, #prefix) == prefix then
        local rest = k:sub(#prefix + 1)
        if not rest:find("/") and rest ~= "" then table.insert(r, rest) end
      end
    end
    return r
  end,
  open = function(p, mode)
    if mode == "r" then
      if not files[p] or files[p].dir then return nil end
      return { readAll = function() return files[p].content end, close = function() end }
    elseif mode == "w" then
      local entry = { content = "" }
      return {
        write = function(self, s)
          if type(self) == "string" then s = self end
          entry.content = entry.content .. s
        end,
        close = function() files[p] = entry end,
      }
    end
  end,
  delete = function(p)
    files[p] = nil
    for k, _ in pairs(files) do
      if k:sub(1, #p + 1) == p .. "/" then files[k] = nil end
    end
  end,
  move = function(s, d) files[d] = files[s]; files[s] = nil end,
  copy = function(s, d) files[d] = { content = files[s].content } end,
}

-- Fake http for transport tests.
local http_responses = {}
_G.http = {
  checkURL = function() return true end,
  get = function(opts)
    local url = type(opts) == "string" and opts or opts.url
    if http_responses[url] then
      local body = http_responses[url]
      return {
        readAll = function() return body end,
        getResponseCode = function() return 200 end,
        close = function() end,
      }
    end
    return {
      readAll = function() return "" end,
      getResponseCode = function() return 404 end,
      close = function() end,
    }
  end,
}
_G.os = _G.os or {}
_G.os.sleep = function() end

local source = require("source")
local index_mod = require("index")
local transport = require("transport")

local total, failed = 0, 0
local function check(name, expected, actual)
  total = total + 1
  if expected == actual then
    print("[PASS] " .. name)
  else
    failed = failed + 1
    print("[FAIL] " .. name)
    print("       expected: " .. tostring(expected))
    print("       actual:   " .. tostring(actual))
  end
end

-- Shorthand expansion.
check("expand basic shorthand",
  "https://raw.githubusercontent.com/alfaoz/foo/main",
  source.expand("alfaoz/foo"))

check("expand with version ref",
  "https://raw.githubusercontent.com/alfaoz/foo/v1.0.0",
  source.expand("alfaoz/foo@v1.0.0"))

check("expand passes through full url",
  "https://example.com/repo",
  source.expand("https://example.com/repo"))

check("expand strips trailing slash",
  "https://example.com/repo",
  source.expand("https://example.com/repo/"))

local _, err = source.expand("not a shorthand")
check("expand rejects garbage", true, err ~= nil)

-- Save and load roundtrip.
files = {}
local ok = source.save({
  { id = "alfaoz/foo", url = "https://raw.githubusercontent.com/alfaoz/foo/main" },
  { id = "https://x.com", url = "https://x.com" },
})
check("save returns ok", true, ok)

local loaded = source.load()
check("load count", 2, #loaded)
check("load first id", "alfaoz/foo", loaded[1].id)
check("load second url", "https://x.com", loaded[2].url)

-- Add.
files = {}
local entry, err2 = source.add("alfaoz/foo")
check("add succeeds", true, entry ~= nil)
check("add no error", nil, err2)

local _, err3 = source.add("alfaoz/foo")
check("add duplicate fails", true, err3 ~= nil)

-- Remove.
local removed = source.remove("alfaoz/foo")
check("remove succeeds", true, removed)
check("remove leaves empty list", 0, #source.load())

local _, err4 = source.remove("alfaoz/foo")
check("remove missing fails", true, err4 ~= nil)

-- file_url.
check("file_url joins correctly",
  "https://example.com/repo/foo.lua",
  source.file_url({ url = "https://example.com/repo" }, "foo.lua"))

check("file_url handles trailing slash on url",
  "https://example.com/repo/foo.lua",
  source.file_url({ url = "https://example.com/repo/" }, "foo.lua"))

check("file_url handles leading slash on path",
  "https://example.com/repo/foo.lua",
  source.file_url({ url = "https://example.com/repo" }, "/foo.lua"))

-- Transport.
check("transport scheme_of https", "https", transport.scheme_of("https://x.com"))
check("transport scheme_of disk", "disk", transport.scheme_of("disk://foo"))
check("transport scheme_of unknown", nil, transport.scheme_of("not a url"))

http_responses["https://example.com/file"] = "hello"
local body = transport.fetch("https://example.com/file")
check("transport fetch https", "hello", body)

local _, err5 = transport.fetch("ftp://x.com")
check("transport fetch unknown scheme", true, err5 ~= nil)

-- Index fetch.
http_responses["https://example.com/repo/index.lua"] = [[{
  spec = "allay/v1.0.0",
  format = "allay",
  name = "test/repo",
  packages = {
    foo = { version = "1.0.0", description = "Foo package" },
    bar = { version = "2.0.0", description = "Bar utility" },
  },
}]]

local idx, err6 = index_mod.fetch({ url = "https://example.com/repo" })
check("index fetch ok", true, idx ~= nil)
check("index has spec", "allay/v1.0.0", idx and idx.spec or nil)
check("index has packages", true, idx and idx.packages ~= nil)
check("index lookup foo", "1.0.0", index_mod.lookup(idx, "foo").version)

local results = index_mod.search(idx, "util")
check("index search count", 1, #results)
check("index search match", "bar", results[1].name)

-- Index 404 -> blind.
http_responses["https://example.com/blind/index.lua"] = nil
local _, err7 = index_mod.fetch({ url = "https://example.com/blind" })
check("blind source returns blind", "blind", err7)

print()
print(string.format("source/transport/index: %d/%d tests passed", total - failed, total))
if failed > 0 then os.exit(1) end
