-- CLI smoke test. Verifies argument parsing and basic command dispatch.
package.path = package.path
  .. ";../bin/?.lua"
  .. ";../lib/?.lua;../lib/?/init.lua"
  .. ";../../lualibs/?/init.lua;../../lualibs/?.lua"

-- Set up fake fs (minimal, just enough for lockfile/sources to load).
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
  delete = function(p)
    files[p] = nil
    for k, _ in pairs(files) do
      if k:sub(1, #p + 1) == p .. "/" then files[k] = nil end
    end
  end,
  move = function(s, d) files[d] = files[s]; files[s] = nil end,
  copy = function(s, d) files[d] = { content = files[s].content } end,
}

_G._ALLAY_NO_AUTORUN = true
_G.os = _G.os or {}
_G.os.exit = function() error("EXIT") end  -- catch exits in tests

local allay = require("allay")

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

-- parse_argv tests.
local args = allay.parse_argv({"install", "foo"})
check("parse install", "install", args.command)
check("parse install pkg", "foo", args.package)

args = allay.parse_argv({"install", "foo", "--yes"})
check("parse --yes", true, args.flags.yes)

args = allay.parse_argv({"install", "foo", "-y"})
check("parse -y", true, args.flags.yes)

args = allay.parse_argv({"install", "foo", "--allow-scripts"})
check("parse --allow-scripts", true, args.flags.allow_scripts)

args = allay.parse_argv({"source", "add", "alfaoz/foo"})
check("parse source command", "source", args.command)
check("parse source sub", "add", args.subcommand)
check("parse source repo", "alfaoz/foo", args.repo)

args = allay.parse_argv({"search", "hash"})
check("parse search query", "hash", args.query)

args = allay.parse_argv({})
check("no args = help", "help", args.command)

args = allay.parse_argv({"--version"})
check("--version cmd", "version", args.command)

args = allay.parse_argv({"--help"})
check("--help cmd", "help", args.command)

args = allay.parse_argv({"help", "install"})
check("help install target", "install", args.target)

args = allay.parse_argv({"info", "foo", "--help"})
check("info --help passes flag", true, args.flags.help)

-- scout command parses target.
args = allay.parse_argv({"scout", "gh:foo/bar"})
check("scout command parsed", "scout", args.command)
check("scout target parsed", "gh:foo/bar", args.target)

-- Commands table includes everything we documented.
local expected = {"install","remove","update","list","search","info","source",
  "init","doctor","reinstall","outdated","why","clean","scout","version","help"}
for _, c in ipairs(expected) do
  check("command " .. c .. " present", true, allay.commands[c] ~= nil)
end

-- version command (smoke test).
local ok = pcall(allay.commands.version, {})
check("version doesn't crash", true, ok)

-- help command (smoke test).
ok = pcall(allay.commands.help, {})
check("help doesn't crash", true, ok)

ok = pcall(allay.commands.help, { target = "install" })
check("help install doesn't crash", true, ok)

print()
print(string.format("cli: %d/%d tests passed", total - failed, total))
if failed > 0 then os.exit(1) end
