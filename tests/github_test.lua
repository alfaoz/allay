package.path = package.path
  .. ";../lib/?.lua;../lib/?/init.lua"
  .. ";../../lualibs/?/init.lua;../../lualibs/?.lua"

-- Stub transport so we can inject fake API responses.
package.loaded.transport = {
  fetch = function(url)
    return _G._http_responses[url] or nil, "404 Not Found"
  end,
  scheme_of = function(url) return url:match("^([%w%+%-%.]+)://") end,
}
_G._http_responses = {}

local github = require("github")

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

-- ---------------------------------------------------------------------------
-- Parsing
-- ---------------------------------------------------------------------------

local p1 = github.parse("user/repo")
check("parse user/repo", "user", p1 and p1.user)
check("parse repo name", "repo", p1 and p1.repo)
check("parse no ref", nil, p1 and p1.ref)

local p2 = github.parse("user/repo@v1.0.0")
check("parse with ref user", "user", p2 and p2.user)
check("parse with ref ref", "v1.0.0", p2 and p2.ref)

local p3 = github.parse("gh:Xella37/Pine3D")
check("parse gh: prefix user", "Xella37", p3 and p3.user)
check("parse gh: prefix repo", "Pine3D", p3 and p3.repo)

local p4, p4err = github.parse("garbage")
check("parse invalid", nil, p4)
check("parse invalid has err", true, p4err ~= nil)

-- ---------------------------------------------------------------------------
-- Builtin detection
-- ---------------------------------------------------------------------------

check("cc builtin: turtle",     true,  github.is_cc_builtin("turtle"))
check("cc builtin: cc.expect",  true,  github.is_cc_builtin("cc.expect"))
check("cc builtin: rednet",     true,  github.is_cc_builtin("rednet"))
check("cc not builtin: foo",    false, github.is_cc_builtin("foo"))
check("cc not builtin: ccthing", false, github.is_cc_builtin("ccthing"))

check("lua builtin: string",  true,  github.is_lua_builtin("string"))
check("lua builtin: math",    true,  github.is_lua_builtin("math"))
check("lua builtin: bit32",   true,  github.is_lua_builtin("bit32"))
check("lua not builtin: foo", false, github.is_lua_builtin("foo"))

-- ---------------------------------------------------------------------------
-- Require scanning
-- ---------------------------------------------------------------------------

local refs1 = github.scan_requires([[
local foo = require("foo")
local bar = require('bar.baz')
local qux = require "qux"
]])
table.sort(refs1)
check("scan refs count", 3, #refs1)
check("scan refs has bar (top-level)", "bar", refs1[1])
check("scan refs has foo", "foo", refs1[2])
check("scan refs has qux", "qux", refs1[3])

-- Skip dynamic requires (the libFolder pattern from Pine3D).
local refs2 = github.scan_requires([[
local libFolder = (...):match("(.-)[^%.]+$")
local x = require(libFolder .. "betterblittle")
local y = require("realpkg")
]])
check("scan skips dynamic require", 1, #refs2)
check("scan keeps static require", "realpkg", refs2[1])

-- dofile and os.loadAPI.
local refs3 = github.scan_requires([[
dofile("/some/path/foo.lua")
os.loadAPI("api/bar.lua")
]])
table.sort(refs3)
check("scan dofile/loadapi count", 2, #refs3)
check("scan dofile basename", "bar", refs3[1])
check("scan loadAPI basename", "foo", refs3[2])

-- ---------------------------------------------------------------------------
-- File categorization
-- ---------------------------------------------------------------------------

check("categorize root .lua",      "lib",     github.categorize("foo.lua", "test"))
check("categorize bin/",           "bin",     github.categorize("bin/foo.lua", "test"))
check("categorize startup/",       "startup", github.categorize("startup/init.lua", "test"))
check("categorize README",         "skip",    github.categorize("README.md", "test"))
check("categorize LICENSE",        "skip",    github.categorize("LICENSE", "test"))
check("categorize .vscode",        "skip",    github.categorize(".vscode/settings.json", "test"))
check("categorize tests/",         "skip",    github.categorize("tests/x_test.lua", "test"))
check("categorize examples/",      "skip",    github.categorize("examples/demo.lua", "test"))
check("categorize minified",       "skip",    github.categorize("minified/foo.lua", "test"))
check("categorize Howlfile.lua",   "skip",    github.categorize("Howlfile.lua", "test"))
check("categorize nested .lua",    "lib",     github.categorize("subdir/inner.lua", "test"))
check("categorize .nfp image",     "share",   github.categorize("models/box.nfp", "test"))

-- ---------------------------------------------------------------------------
-- Tree fetch (mocked)
-- ---------------------------------------------------------------------------

_G._http_responses["https://api.github.com/repos/foo/bar/git/trees/main?recursive=1"] = [[
{
  "sha": "abc",
  "tree": [
    {"path": "init.lua", "mode": "100644", "type": "blob", "size": 100},
    {"path": "lib/util.lua", "mode": "100644", "type": "blob", "size": 50},
    {"path": "bin/run.lua", "mode": "100644", "type": "blob", "size": 30},
    {"path": "tests/run_test.lua", "mode": "100644", "type": "blob", "size": 40},
    {"path": "README.md", "mode": "100644", "type": "blob", "size": 200},
    {"path": "lib", "mode": "040000", "type": "tree"}
  ]
}
]]

local entries, ref = github.fetch_tree("foo", "bar", "main")
check("fetch_tree returns entries", true, entries ~= nil)
check("fetch_tree ref echoed", "main", ref)
check("fetch_tree count", 6, entries and #entries or 0)

-- ---------------------------------------------------------------------------
-- Synthesize a package
-- ---------------------------------------------------------------------------

local file_bodies = {
  ["init.lua"]    = 'local x = require("util")\nreturn {}\n',
  ["lib/util.lua"] = 'return {}\n',
  ["bin/run.lua"] = 'require("init")\nrequire("ext_thing")\n',
}

local pkg, info = github.synthesize("foo", "bar", "main", entries, {
  scan_requires = true,
  fetch_file = function(p) return file_bodies[p] end,
  external_resolver = function(name)
    return name == "ext_thing"  -- pretend ext_thing is in some source
  end,
})

check("synth name", "bar", pkg.name)
check("synth base_url",
  "https://raw.githubusercontent.com/foo/bar/main", pkg.base_url)
check("synth has lib files", true, pkg.files.lib ~= nil)
check("synth has bin files", true, pkg.files.bin ~= nil)
check("synth init.lua in lib", "init.lua", pkg.files.lib["init.lua"])
check("synth bin/run.lua in bin", "run", pkg.files.bin["bin/run.lua"])
check("synth skip README", nil, pkg.files.lib and pkg.files.lib["README.md"])
check("synth skip tests", nil, pkg.files.lib
  and pkg.files.lib["tests/run_test.lua"])
check("synth deps detected", "ext_thing", pkg.dependencies and pkg.dependencies[1])
check("synth no unresolved", 0, #info.unresolved)

-- Synthesize without the external_resolver: the ext_thing should be unresolved.
local pkg2, info2 = github.synthesize("foo", "bar", "main", entries, {
  scan_requires = true,
  fetch_file = function(p) return file_bodies[p] end,
})
local found_unresolved = false
for _, n in ipairs(info2.unresolved) do
  if n == "ext_thing" then found_unresolved = true end
end
check("synth without resolver: ext_thing unresolved", true, found_unresolved)
check("synth without resolver: util is internal (not unresolved)", false,
  (function()
    for _, n in ipairs(info2.unresolved) do
      if n == "util" then return true end
    end
    return false
  end)())

-- ---------------------------------------------------------------------------
-- Fetch cache: synthesize records every body it pulled
-- ---------------------------------------------------------------------------

check("fetch_cache present", true, info2.fetch_cache ~= nil)
check("fetch_cache has init.lua",
  file_bodies["init.lua"], info2.fetch_cache["init.lua"])
check("fetch_cache has lib/util.lua",
  file_bodies["lib/util.lua"], info2.fetch_cache["lib/util.lua"])

-- ---------------------------------------------------------------------------
-- Truncation: GitHub returns "truncated": true for huge repos
-- ---------------------------------------------------------------------------

_G._http_responses["https://api.github.com/repos/big/repo/git/trees/main?recursive=1"] = [[
{
  "sha": "abc",
  "tree": [
    {"path": "a.lua", "mode": "100644", "type": "blob", "size": 10}
  ],
  "truncated": true
}
]]
local entries_t, ref_t, err_t = github.fetch_tree("big", "repo", "main")
check("truncated tree returns nil entries", nil, entries_t)
check("truncated tree has clear error",
  true, err_t ~= nil and err_t:find("truncated") ~= nil)

-- ---------------------------------------------------------------------------
-- Rate limit: error message gets a clear hint
-- ---------------------------------------------------------------------------

-- Stub the transport.fetch to return a rate-limit-style error.
local original_fetch = package.loaded.transport.fetch
package.loaded.transport.fetch = function(url)
  if url:find("ratelimited/repo") then
    return nil, "HTTP 403: API rate limit exceeded"
  end
  return original_fetch(url)
end

local _, _, err_rl = github.fetch_tree("ratelimited", "repo", "main")
check("rate limit error has hint",
  true, err_rl ~= nil and err_rl:find("rate limit") ~= nil)
check("rate limit error mentions GITHUB_TOKEN",
  true, err_rl ~= nil and err_rl:find("GITHUB_TOKEN") ~= nil)

package.loaded.transport.fetch = original_fetch

-- ---------------------------------------------------------------------------
-- Subdir-strip heuristic: files inside <pkgname>/ get the prefix stripped
-- ---------------------------------------------------------------------------

local nested_tree = {
  { path = "ccryptolib/random.lua",        type = "blob", size = 100 },
  { path = "ccryptolib/aead.lua",          type = "blob", size = 100 },
  { path = "ccryptolib/internal/sha.lua",  type = "blob", size = 100 },
  { path = "spec/aead_spec.lua",           type = "blob", size = 100 },
  { path = "README.md",                    type = "blob", size = 100 },
}
local nested_pkg, _ = github.synthesize("migeyel", "ccryptolib", "main",
  nested_tree, {})

check("subdir strip: random.lua", "random.lua",
  nested_pkg.files.lib and nested_pkg.files.lib["ccryptolib/random.lua"])
check("subdir strip: aead.lua", "aead.lua",
  nested_pkg.files.lib and nested_pkg.files.lib["ccryptolib/aead.lua"])
check("subdir strip: nested internal", "internal/sha.lua",
  nested_pkg.files.lib and nested_pkg.files.lib["ccryptolib/internal/sha.lua"])
check("subdir strip: spec files skipped (matches /spec/ pattern)", nil,
  nested_pkg.files.lib and nested_pkg.files.lib["spec/aead_spec.lua"])

-- Without a matching subdir, files keep their paths as-is.
local flat_tree = {
  { path = "main.lua", type = "blob", size = 100 },
  { path = "util.lua", type = "blob", size = 100 },
}
local flat_pkg, _ = github.synthesize("foo", "bar", "main", flat_tree, {})
check("no subdir to strip: main.lua", "main.lua",
  flat_pkg.files.lib and flat_pkg.files.lib["main.lua"])

-- ---------------------------------------------------------------------------
-- Done
-- ---------------------------------------------------------------------------

print()
print("github: " .. (total - failed) .. "/" .. total .. " tests passed")
if failed > 0 then os.exit(1) end
