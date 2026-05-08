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

local resolver = require("resolver")
local lockfile_mod = require("lockfile")
local hash = require("hash")

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

-- Test setup: a source serving a few packages.
local source = { id = "test/source", url = "https://example.com/repo" }
local sources = { source }

http_responses["https://example.com/repo/index.lua"] = [[{
  spec = "allay/v1.0.0",
  format = "allay",
  packages = {
    foo = { version = "1.0.0" },
    bar = { version = "1.0.0" },
    baz = { version = "1.0.0" },
    cyc1 = { version = "1.0.0" },
    cyc2 = { version = "1.0.0" },
  },
}]]

http_responses["https://example.com/repo/foo.lua"] = [[return {
  name = "foo",
  base_url = "https://example.com/files/foo",
  files = { lib = { ["init.lua"] = "init.lua" } },
  dependencies = { "bar", "baz" },
  version = "1.0.0",
}]]

http_responses["https://example.com/repo/bar.lua"] = [[return {
  name = "bar",
  base_url = "https://example.com/files/bar",
  files = { lib = { ["init.lua"] = "init.lua" } },
  dependencies = { "baz" },
  version = "1.0.0",
}]]

http_responses["https://example.com/repo/baz.lua"] = [[return {
  name = "baz",
  base_url = "https://example.com/files/baz",
  files = { lib = { ["init.lua"] = "init.lua" } },
  version = "1.0.0",
}]]

http_responses["https://example.com/repo/cyc1.lua"] = [[return {
  name = "cyc1",
  base_url = "x",
  files = { lib = { ["init.lua"] = "init.lua" } },
  dependencies = { "cyc2" },
}]]

http_responses["https://example.com/repo/cyc2.lua"] = [[return {
  name = "cyc2",
  base_url = "x",
  files = { lib = { ["init.lua"] = "init.lua" } },
  dependencies = { "cyc1" },
}]]

-- Resolve simple package with no deps.
local lock = lockfile_mod.empty()
local plan, err = resolver.resolve({"baz"}, lock, sources)
check("resolve simple ok", true, plan ~= nil)
check("resolve simple count", 1, #plan)
check("resolve simple name", "baz", plan[1].name)
check("resolve simple manual", true, plan[1].manual)

-- Resolve package with deps; deps come first.
plan, err = resolver.resolve({"foo"}, lock, sources)
check("resolve deps ok", true, plan ~= nil)
check("resolve deps count", 3, #plan)
-- Topological order: baz before bar, bar before foo (or baz first then bar then foo)
local positions = {}
for i, item in ipairs(plan) do positions[item.name] = i end
check("baz before bar", true, positions.baz < positions.bar)
check("bar before foo", true, positions.bar < positions.foo)
check("baz before foo", true, positions.baz < positions.foo)
check("foo is manual", true, plan[positions.foo].manual)
check("baz is auto", true, plan[positions.baz].manual ~= true)
check("bar is auto", true, plan[positions.bar].manual ~= true)

-- Resolve when one dep is already installed.
local lock2 = lockfile_mod.empty()
lockfile_mod.insert(lock2, "baz", {
  version = "1.0.0", source = "test/source",
  manual = false, pinned = false,
  dependencies = {}, dependents = {}, files = {},
})
plan, err = resolver.resolve({"foo"}, lock2, sources)
check("resolve skips installed", 2, #plan)  -- only foo and bar; baz already installed
local found_baz = false
for _, item in ipairs(plan) do
  if item.name == "baz" then found_baz = true end
end
check("installed dep not in plan", false, found_baz)

-- Cycle detection.
local _, cyc_err = resolver.resolve({"cyc1"}, lockfile_mod.empty(), sources)
check("cycle detected", true, cyc_err ~= nil and cyc_err:find("cycle") ~= nil)

-- Package not found.
local _, missing_err = resolver.resolve({"nonexistent"}, lockfile_mod.empty(), sources)
check("missing package fails", true, missing_err ~= nil)

-- Synthesized package (gh: bundle path): resolver short-circuits the
-- source lookup when opts.synthesized has the requested name.
local synth_pkg = {
  name = "synthbundle",
  base_url = "https://raw.githubusercontent.com/foo/bar/main",
  files = { lib = { ["init.lua"] = "init.lua" } },
  dependencies = { "baz" },
  version = "main",
}
local synth_source = { id = "gh:foo/bar", url = synth_pkg.base_url, bundle = true }
local synth_plan, synth_err = resolver.resolve({"synthbundle"},
  lockfile_mod.empty(), sources, {
    synthesized = { synthbundle = { pkg = synth_pkg, source = synth_source } }
  })
check("synthesized resolve ok", true, synth_plan ~= nil)
check("synthesized plan length", 2, synth_plan and #synth_plan or 0)  -- baz dep + synthbundle
check("synthesized dep first", "baz", synth_plan and synth_plan[1].name)
check("synthesized package name", "synthbundle",
  synth_plan and synth_plan[2].name)
check("synthesized source preserved", "gh:foo/bar",
  synth_plan and synth_plan[2].source.id)

-- Conflict check: packages declaring conflicts.
http_responses["https://example.com/repo/conflict-a.lua"] = [[return {
  name = "conflict-a",
  base_url = "x",
  files = { lib = { a = "a" } },
  conflicts = { "conflict-b" },
}]]
http_responses["https://example.com/repo/conflict-b.lua"] = [[return {
  name = "conflict-b",
  base_url = "x",
  files = { lib = { a = "a" } },
}]]

http_responses["https://example.com/repo/index.lua"] = [[{
  spec = "allay/v1.0.0",
  format = "allay",
  packages = {
    foo = { version = "1.0.0" },
    bar = { version = "1.0.0" },
    baz = { version = "1.0.0" },
    cyc1 = { version = "1.0.0" },
    cyc2 = { version = "1.0.0" },
    ["conflict-a"] = { version = "1.0.0" },
    ["conflict-b"] = { version = "1.0.0" },
  },
}]]

local lock3 = lockfile_mod.empty()
lockfile_mod.insert(lock3, "conflict-b", {
  version = "1.0.0", source = "test/source",
  manual = true, pinned = false,
  dependencies = {}, dependents = {}, files = {},
})

local plan3, _ = resolver.resolve({"conflict-a"}, lock3, sources)
local conflict_ok, conflict_err = resolver.check_conflicts(plan3, lock3)
check("conflict with installed detected", false, conflict_ok)

-- ---------------------------------------------------------------------------
-- Translator dispatch: a source declaring format = "fakefmt/v1.0.0" routes
-- per-package fetches through a translator. We stub the translator on disk
-- and verify the resolver correctly transforms the foreign-format body into
-- an allay-shaped package.
-- ---------------------------------------------------------------------------
local translator = require("translator")
local TMP = os.getenv("TMPDIR") or "/tmp"
TMP = TMP:gsub("/$", "")
local TRANS_DIR = TMP .. "/allay-translator-resolver-test-" .. tostring(os.time())
os.execute("mkdir -p '" .. TRANS_DIR .. "'")
translator.TRANSLATOR_DIR = TRANS_DIR
translator.reset()

local prev_fs_exists = _G.fs.exists
_G.fs.exists = function(p)
  -- Defer to the in-memory fake for paths the resolver-under-test is using,
  -- but check real disk for the translator file (which lives in TRANS_DIR).
  if p:sub(1, #TRANS_DIR) == TRANS_DIR then
    local fh = io.open(p, "r")
    if fh then fh:close() return true end
    return false
  end
  return prev_fs_exists(p)
end

local f = io.open(TRANS_DIR .. "/fakefmt.lua", "w")
f:write([[
return {
  translate = function(raw)
    return {
      name = raw.foreign_id,
      base_url = "https://example.com/foreign/" .. raw.foreign_id,
      files = { lib = { ["init.lua"] = "init.lua" } },
      version = raw.foreign_version or "0.0.0",
    }
  end,
}
]])
f:close()

-- A source in foreign format. Note: no index.lua needed -- index_mod.fetch
-- short-circuits to blind mode for non-allay formats.
local foreign_source = {
  id = "foreign/main",
  url = "https://foreign.example.com",
  format = "fakefmt/v1.0.0",
}

http_responses["https://foreign.example.com/foreignpkg.lua"] = [[return {
  foreign_id = "foreignpkg",
  foreign_version = "9.9.9",
}]]

local foreign_plan, foreign_err = resolver.resolve({"foreignpkg"},
  lockfile_mod.empty(), { foreign_source })
check("foreign-format resolve ok", true, foreign_plan ~= nil)
check("foreign-format plan length", 1, foreign_plan and #foreign_plan or 0)
check("foreign-format pkg name", "foreignpkg",
  foreign_plan and foreign_plan[1].package.name)
check("foreign-format pkg version", "9.9.9",
  foreign_plan and foreign_plan[1].package.version)
check("foreign-format source preserved", "foreign/main",
  foreign_plan and foreign_plan[1].source.id)

-- Cleanup translator file.
os.execute("rm -rf '" .. TRANS_DIR .. "'")
_G.fs.exists = prev_fs_exists

print()
print(string.format("resolver: %d/%d tests passed", total - failed, total))
if failed > 0 then os.exit(1) end
