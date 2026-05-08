-- translator dispatch tests.
package.path = package.path
  .. ";../lib/?.lua;../lib/?/init.lua"
  .. ";../../lualibs/?/init.lua;../../lualibs/?.lua"

-- Fake fs: an in-memory filesystem that backs the translator loader's
-- existence check. The translator itself is loaded with the real loadfile,
-- so we need to actually write files to a temp dir on disk.
local files = {}
_G.fs = {
  exists = function(p) return files[p] ~= nil end,
}

-- Resolve a tmp dir under the test's CWD.
local TMP = os.getenv("TMPDIR") or "/tmp"
TMP = TMP:gsub("/$", "")
local TRANS_DIR = TMP .. "/allay-translator-test-" .. tostring(os.time())
os.execute("mkdir -p '" .. TRANS_DIR .. "'")

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

local translator = require("translator")
translator.TRANSLATOR_DIR = TRANS_DIR
translator.reset()

-- Stub out fs.exists to look in TRANS_DIR.
_G.fs.exists = function(p)
  local f = io.open(p, "r")
  if f then f:close() return true end
  return false
end

-- Helper: write a translator file.
local function write_translator(name, body)
  local path = TRANS_DIR .. "/" .. name .. ".lua"
  local f = io.open(path, "w")
  f:write(body)
  f:close()
end

-- ---------------------------------------------------------------------------
-- Missing translator
-- ---------------------------------------------------------------------------
local t, err = translator.load("nonexistent/v1.0.0")
check("missing translator: nil result", nil, t)
check("missing translator: err mentions format", true,
  err and err:find("nonexistent/v1.0.0") ~= nil)

-- ---------------------------------------------------------------------------
-- Working translator
-- ---------------------------------------------------------------------------
write_translator("fakefmt", [[
return {
  format_name = "fakefmt/v1.0.0",
  translate = function(raw)
    return {
      name = raw.id,
      base_url = "https://example.com/" .. raw.id,
      files = { lib = { ["init.lua"] = "init.lua" } },
      version = raw.ver or "0.0.0",
    }
  end,
}
]])

translator.reset()
local result, t_err = translator.translate("fakefmt/v1.0.0", {
  id = "thing",
  ver = "2.0.0",
})
check("working translator: ok", true, result ~= nil)
check("working translator: name", "thing", result and result.name)
check("working translator: version", "2.0.0", result and result.version)
check("working translator: base_url",
  "https://example.com/thing", result and result.base_url)

-- ---------------------------------------------------------------------------
-- Bad translator (no M.translate)
-- ---------------------------------------------------------------------------
write_translator("noinit", "return { format_name = 'noinit/v1' }")
translator.reset()
local _, bad_err = translator.load("noinit/v1")
check("bad translator: detected", true,
  bad_err and bad_err:find("missing M.translate") ~= nil)

-- ---------------------------------------------------------------------------
-- Translator that errors during translate()
-- ---------------------------------------------------------------------------
write_translator("erratic", [[
return {
  translate = function(raw)
    return nil, "bad input"
  end,
}
]])
translator.reset()
local nope, propagated_err = translator.translate("erratic/v1", {})
check("translator error: nil result", nil, nope)
check("translator error: propagates", "bad input", propagated_err)

-- ---------------------------------------------------------------------------
-- Cache: same format -> same instance (translator only loaded once)
-- ---------------------------------------------------------------------------
write_translator("cached", [[
local n = 0
return {
  translate = function(raw)
    n = n + 1
    return {
      name = "x" .. n,
      base_url = "u",
      files = { lib = { ["init.lua"] = "init.lua" } },
    }
  end,
}
]])
translator.reset()
local r1 = translator.translate("cached/v1", {})
local r2 = translator.translate("cached/v1", {})
check("cached: first call name x1", "x1", r1 and r1.name)
check("cached: second call name x2", "x2", r2 and r2.name)
-- If load were re-run, n would reset to 0 and second result would be "x1".

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------
os.execute("rm -rf '" .. TRANS_DIR .. "'")

print()
print(string.format("translator: %d/%d tests passed", total - failed, total))
if failed > 0 then os.exit(1) end
