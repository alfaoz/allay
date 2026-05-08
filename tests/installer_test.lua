package.path = package.path
  .. ";../lib/?.lua;../lib/?/init.lua"
  .. ";../../lualibs/?/init.lua;../../lualibs/?.lua"

-- Fake fs.
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

-- Suppress logs during tests.
_G.term = nil
_G.colors = nil
_G.printError = nil

-- Fake http.
local http_responses = {}
_G.http = {
  checkURL = function() return true end,
  get = function(opts)
    local url = type(opts) == "string" and opts or opts.url
    if http_responses[url] then
      return {
        readAll = function() return http_responses[url] end,
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

local hash = require("hash")
local resolver = require("resolver")
local installer = require("installer")
local lockfile_mod = require("lockfile")
local log = require("log")
log.set_level("ERROR")  -- silence info during tests

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

-- Set up: one package "foo" with one file. Hash declared.
local function setup_simple()
  files = {}
  http_responses = {}

  local foo_init = "return { greet = function() return 'hi' end }"
  local foo_init_hash = hash.sha256hex(foo_init)

  http_responses["https://example.com/repo/index.lua"] = [[{
    spec = "allay/v1.0.0",
    packages = {
      foo = { version = "1.0.0" },
    },
  }]]

  http_responses["https://example.com/repo/foo.lua"] = string.format([[return {
    name = "foo",
    version = "1.0.0",
    base_url = "https://example.com/files/foo",
    files = { lib = { ["src/init.lua"] = "init.lua" } },
    hashes = { ["src/init.lua"] = %q },
  }]], foo_init_hash)

  http_responses["https://example.com/files/foo/src/init.lua"] = foo_init

  return foo_init, foo_init_hash
end

-- Successful install.
setup_simple()
local source = { id = "test/source", url = "https://example.com/repo" }
local lock = lockfile_mod.empty()
local plan, err = resolver.resolve({"foo"}, lock, { source })
check("resolve ok", true, plan ~= nil)

local results, install_err = installer.install_plan(plan, lock)
check("install ok", true, results ~= nil)
check("install no error", nil, install_err)
check("install result count", 1, results and #results or 0)
check("install result name", "foo", results and results[1].name)

-- Files actually placed.
check("file installed", true, fs.exists("/usr/allay/lib/foo/init.lua"))

-- Lockfile updated.
check("lockfile has foo", true, lock.packages.foo ~= nil)
check("lockfile foo version", "1.0.0", lock.packages.foo.version)
check("lockfile foo manual", true, lock.packages.foo.manual)
check("lockfile file count", 1, #lock.packages.foo.files)
check("lockfile file dest", "/usr/allay/lib/foo/init.lua", lock.packages.foo.files[1].dest)

-- TOFU is false (hash was declared).
check("not tofu when hash declared", false, lock.packages.foo.files[1].tofu)

-- Hash mismatch causes rollback.
files = {}
http_responses = {}
http_responses["https://example.com/repo/index.lua"] = [[{
  spec = "allay/v1.0.0",
  packages = { bad = { version = "1.0.0" } },
}]]
http_responses["https://example.com/repo/bad.lua"] = [[return {
  name = "bad",
  version = "1.0.0",
  base_url = "https://example.com/files/bad",
  files = { lib = { ["src/init.lua"] = "init.lua" } },
  hashes = { ["src/init.lua"] = "0000000000000000000000000000000000000000000000000000000000000000" },
}]]
http_responses["https://example.com/files/bad/src/init.lua"] = "wrong content"

local lock2 = lockfile_mod.empty()
local plan2, _ = resolver.resolve({"bad"}, lock2, { source })
local results2, err2 = installer.install_plan(plan2, lock2)
check("hash mismatch fails", nil, results2)
check("hash mismatch error mentions hash", true, err2 ~= nil and err2:find("hash") ~= nil)
check("hash mismatch left no files", false, fs.exists("/usr/allay/lib/bad/init.lua"))
check("hash mismatch left lockfile empty", nil, lock2.packages.bad)

-- Missing file causes rollback.
files = {}
http_responses = {}
http_responses["https://example.com/repo/index.lua"] = [[{
  spec = "allay/v1.0.0",
  packages = { incomplete = { version = "1.0.0" } },
}]]
http_responses["https://example.com/repo/incomplete.lua"] = [[return {
  name = "incomplete",
  version = "1.0.0",
  base_url = "https://example.com/files/incomplete",
  files = {
    lib = {
      ["a.lua"] = "a.lua",
      ["b.lua"] = "b.lua",  -- this one will 404
    },
  },
}]]
http_responses["https://example.com/files/incomplete/a.lua"] = "x"
-- b.lua intentionally missing.

local lock3 = lockfile_mod.empty()
local plan3, _ = resolver.resolve({"incomplete"}, lock3, { source })
local results3, err3 = installer.install_plan(plan3, lock3)
check("missing file fails", nil, results3)
check("missing file no half-install", false, fs.exists("/usr/allay/lib/incomplete/a.lua"))

-- TOFU when hashes not declared.
files = {}
http_responses = {}
local tofu_content = "tofu test"
http_responses["https://example.com/repo/index.lua"] = [[{
  spec = "allay/v1.0.0",
  packages = { tofu_pkg = { version = "1.0.0" } },
}]]
http_responses["https://example.com/repo/tofu_pkg.lua"] = [[return {
  name = "tofu_pkg",
  version = "1.0.0",
  base_url = "https://example.com/files/tofu_pkg",
  files = { lib = { ["init.lua"] = "init.lua" } },
}]]
http_responses["https://example.com/files/tofu_pkg/init.lua"] = tofu_content

local lock4 = lockfile_mod.empty()
local plan4, _ = resolver.resolve({"tofu_pkg"}, lock4, { source })
local results4, err4 = installer.install_plan(plan4, lock4)
check("tofu install ok", true, results4 ~= nil)
check("tofu file recorded", true, lock4.packages.tofu_pkg.files[1].tofu)
check("tofu hash computed", hash.sha256hex(tofu_content), lock4.packages.tofu_pkg.files[1].sha256)

-- Remove a package.
local removed_ok, _ = installer.remove_package(lock4, "tofu_pkg")
check("remove ok", true, removed_ok)
check("remove cleared file", false, fs.exists("/usr/allay/lib/tofu_pkg/init.lua"))
check("remove cleared lockfile", nil, lock4.packages.tofu_pkg)

-- Inline content (wrapper init.lua pattern). The package definition has
-- one fetched file plus one inline file; the inline file should be written
-- directly without an HTTP fetch.
files = {}
http_responses = {}
http_responses["https://example.com/repo/index.lua"] = [[{
  spec = "allay/v1.0.0",
  packages = { wrapped = { version = "1.0.0" } },
}]]
http_responses["https://example.com/repo/wrapped.lua"] = [[return {
  name = "wrapped",
  version = "1.0.0",
  base_url = "https://example.com/files/wrapped",
  files = { lib = {
    ["main.lua"] = "main.lua",
    ["@wrapper"] = { dest = "init.lua",
      inline = "package.path = '/usr/allay/lib/wrapped/?.lua;' .. package.path\nreturn require('wrapped.main')" },
  } },
}]]
http_responses["https://example.com/files/wrapped/main.lua"] = "return { wrapped = true }"
-- Note: NO http response for /files/wrapped/@wrapper because the installer
-- must not fetch it; it's inline.

local lock5 = lockfile_mod.empty()
local plan5, _ = resolver.resolve({"wrapped"}, lock5, { source })
local results5, err5 = installer.install_plan(plan5, lock5)
check("inline install ok", true, results5 ~= nil)
check("inline install no error", nil, err5)
check("inline file written", true, fs.exists("/usr/allay/lib/wrapped/init.lua"))
check("fetched file written", true, fs.exists("/usr/allay/lib/wrapped/main.lua"))
local wrapper_body = files["/usr/allay/lib/wrapped/init.lua"]
check("inline content preserved", true,
  wrapper_body and wrapper_body.content
    and wrapper_body.content:find("require%('wrapped%.main'%)") ~= nil)

print()
print(string.format("installer: %d/%d tests passed", total - failed, total))
if failed > 0 then os.exit(1) end
