package.path = package.path
  .. ";../lib/?.lua;../lib/?/init.lua"
  .. ";../../lualibs/?/init.lua;../../lualibs/?.lua"

local schema = require("schema")

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

-- Valid package.
local valid_pkg = {
  name = "secure-rednet",
  base_url = "https://example.com/repo",
  files = {
    lib = { ["src/init.lua"] = "init.lua" },
  },
  hashes = {
    ["src/init.lua"] = string.rep("a", 64),
  },
  version = "1.0.0",
  dependencies = { "hash" },
}
local ok, err = schema.validate_package(valid_pkg)
check("valid package passes", true, ok)
check("valid package no error", nil, err)

-- Missing name.
ok, err = schema.validate_package({ base_url = "x", files = { lib = { a = "a" } } })
check("missing name fails", false, ok)
check("missing name has error", true, err ~= nil and err:find("name") ~= nil)

-- Bad name characters.
ok, err = schema.validate_package({
  name = "bad name!", base_url = "x", files = { lib = { a = "a" } },
})
check("bad name chars fails", false, ok)

-- No files.
ok, err = schema.validate_package({
  name = "x", base_url = "y", files = {},
})
check("empty files fails", false, ok)

-- Unknown file kind.
ok, err = schema.validate_package({
  name = "x", base_url = "y",
  files = { weird = { a = "a" } },
})
check("unknown file kind fails", false, ok)

-- Bad hash format.
ok, err = schema.validate_package({
  name = "x", base_url = "y",
  files = { lib = { a = "a" } },
  hashes = { a = "not-hex" },
})
check("bad hash format fails", false, ok)

-- Bad dependencies (not a list).
ok, err = schema.validate_package({
  name = "x", base_url = "y",
  files = { lib = { a = "a" } },
  dependencies = { foo = "bar" },  -- table, not list
})
check("non-list deps fails", false, ok)

-- Inline content for a file (wrapper pattern).
ok, err = schema.validate_package({
  name = "wrapper-pkg", base_url = "y",
  files = {
    lib = {
      ["@wrapper"] = { dest = "init.lua", inline = "return 'hi'" },
    },
  },
})
check("inline file passes", true, ok)
check("inline file no error", nil, err)

-- Inline value missing dest field.
ok, err = schema.validate_package({
  name = "x", base_url = "y",
  files = { lib = { ["@x"] = { inline = "..." } } },
})
check("inline without dest fails", false, ok)

-- Inline value with non-string content.
ok, err = schema.validate_package({
  name = "x", base_url = "y",
  files = { lib = { ["@x"] = { dest = "init.lua", inline = 42 } } },
})
check("inline with bad content fails", false, ok)

-- File value of wrong type entirely.
ok, err = schema.validate_package({
  name = "x", base_url = "y",
  files = { lib = { ["@x"] = 42 } },
})
check("non-string non-table file fails", false, ok)

-- Valid index.
local valid_idx = {
  spec = "allay/v1.0.0",
  format = "allay",
  name = "alfaoz/foo",
  packages = {
    hash = { version = "1.0.0", description = "SHA-256" },
  },
}
ok, err = schema.validate_index(valid_idx)
check("valid index passes", true, ok)

-- Invalid spec.
ok, err = schema.validate_index({
  spec = "wrong/v1",
  packages = {},
})
check("wrong spec fails", false, ok)

-- Missing packages.
ok, err = schema.validate_index({ spec = "allay/v1.0.0" })
check("missing packages fails", false, ok)

-- Valid lockfile.
local valid_lock = {
  spec = "allay/v1.0.0",
  packages = {
    hash = {
      version = "1.0.0",
      source = "alfaoz/allay-core",
      manual = true,
      pinned = false,
      files = {
        { dest = "/usr/allay/lib/hash/init.lua", sha256 = string.rep("a", 64), tofu = false },
      },
      dependencies = {},
      dependents = {},
    },
  },
}
ok, err = schema.validate_lockfile(valid_lock)
check("valid lockfile passes", true, ok)

-- Bad lockfile (non-string version).
ok, err = schema.validate_lockfile({
  spec = "allay/v1.0.0",
  packages = { hash = { version = 1 } },
})
check("bad lockfile version fails", false, ok)

print()
print(string.format("schema: %d/%d tests passed", total - failed, total))
if failed > 0 then os.exit(1) end
