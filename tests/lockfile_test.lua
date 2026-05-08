package.path = package.path
  .. ";../lib/?.lua;../lib/?/init.lua"
  .. ";../../lualibs/?/init.lua;../../lualibs/?.lua"

-- Fake fs for pathkit.
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
  list = function(p) return {} end,
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
  delete = function(p) files[p] = nil end,
  move = function(s, d) files[d] = files[s]; files[s] = nil end,
  copy = function(s, d) files[d] = { content = files[s].content } end,
}

local lockfile = require("lockfile")
local pkg_mod = require("pkg")

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

-- Empty lockfile.
local lock = lockfile.empty()
check("empty has spec", "allay/v1.0.0", lock.spec)
check("empty has packages", true, type(lock.packages) == "table")
check("empty no packages", 0, #lockfile.installed_packages(lock))

-- Insert + query.
lockfile.insert(lock, "hash", {
  version = "1.0.0",
  source = "allaycc/core",
  manual = true,
  pinned = false,
  files = {
    { dest = "/usr/allay/lib/hash/init.lua", sha256 = string.rep("a", 64) },
  },
  dependencies = {},
  dependents = {},
})

check("after insert is_installed", true, lockfile.is_installed(lock, "hash"))
check("after insert not_installed", false, lockfile.is_installed(lock, "missing"))

-- Insert package with deps.
lockfile.insert(lock, "secure-rednet", {
  version = "1.0.0",
  source = "allaycc/core",
  manual = true,
  pinned = false,
  files = {
    { dest = "/usr/allay/lib/secure-rednet/init.lua", sha256 = string.rep("b", 64) },
  },
  dependencies = { "hash" },
  dependents = {},
})

check("dep dependents updated", "secure-rednet", lock.packages.hash.dependents[1])

-- Insert another package with same dep.
lockfile.insert(lock, "auth", {
  version = "1.0.0",
  source = "allaycc/core",
  manual = true,
  pinned = false,
  files = { { dest = "/usr/allay/lib/auth/init.lua", sha256 = string.rep("c", 64) } },
  dependencies = { "hash" },
  dependents = {},
})

check("dep dependents now 2", 2, #lock.packages.hash.dependents)

-- Owner lookup.
check("owner_of", "hash", lockfile.owner_of(lock, "/usr/allay/lib/hash/init.lua"))
check("owner_of unknown", nil, lockfile.owner_of(lock, "/nonexistent"))

-- Save + load roundtrip.
files = {}
local ok, err = lockfile.save(lock, "/test.lock")
check("save ok", true, ok)

local loaded, load_err = lockfile.load("/test.lock")
check("load ok", true, loaded ~= nil)
check("load preserves package count", 3, #lockfile.installed_packages(loaded))
check("load preserves version", "1.0.0", loaded.packages.hash.version)
check("load preserves dependents", 2, #loaded.packages.hash.dependents)

-- Remove.
lockfile.remove(lock, "auth")
check("after remove dependents = 1", 1, #lock.packages.hash.dependents)
check("after remove not installed", false, lockfile.is_installed(lock, "auth"))

-- Orphans. Deps must be inserted before dependents (which is how the
-- resolver actually works in practice, by topological order).
local lock2 = lockfile.empty()
lockfile.insert(lock2, "auto-dep", {
  version = "1.0.0", manual = false, pinned = false,
  dependencies = {}, dependents = {}, files = {},
})
lockfile.insert(lock2, "manual-pkg", {
  version = "1.0.0", manual = true, pinned = false,
  dependencies = { "auto-dep" },
  dependents = {}, files = {},
})
local orphans_before = lockfile.orphans(lock2)
check("no orphans while needed", 0, #orphans_before)

lockfile.remove(lock2, "manual-pkg")
local orphans_after = lockfile.orphans(lock2)
check("auto-dep is orphan after remove", 1, #orphans_after)
check("orphan name correct", "auto-dep", orphans_after[1])

-- package.dest_path.
check("dest_path lib", "/usr/allay/lib/foo/init.lua", pkg_mod.dest_path("foo", "lib", "init.lua"))
check("dest_path bin", "/bin/foo.lua", pkg_mod.dest_path("foo", "bin", "foo"))
check("dest_path startup", "/startup/foo_run.lua", pkg_mod.dest_path("foo", "startup", "run.lua"))
check("dest_path etc", "/etc/foo/conf.lua", pkg_mod.dest_path("foo", "etc", "conf.lua"))

-- package.load_string.
local pkg_src = [[return {
  name = "test",
  base_url = "https://example.com/test",
  files = { lib = { ["src/init.lua"] = "init.lua" } },
}]]
local pkg, err2 = pkg_mod.load_string(pkg_src)
check("load_string parses", true, pkg ~= nil)
check("load_string name", "test", pkg and pkg.name)

-- package.iter_files.
local pkg2 = {
  name = "foo",
  base_url = "x",
  files = {
    lib = { ["src/init.lua"] = "init.lua" },
    bin = { ["bin/foo.lua"] = "foo" },
  },
  hashes = {},
}
local entries = pkg_mod.iter_files(pkg2)
check("iter_files count", 2, #entries)

print()
print(string.format("lockfile/package: %d/%d tests passed", total - failed, total))
if failed > 0 then os.exit(1) end
