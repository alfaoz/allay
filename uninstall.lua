-- allay uninstall script.
--
-- Wipes allay and everything it installed. Run with:
--   wget run https://raw.githubusercontent.com/allaycc/allay/main/uninstall.lua
--
-- This is a separate script (not an `allay` CLI command) by design, the
-- same way Homebrew ships its uninstall as a separate curl-piped script.
-- Self-uninstall is destructive and should be hard to trigger by accident.
--
-- The script:
--   1. Walks the lockfile to collect every file path owned by an installed
--      package (so packages that put files outside /usr/allay/ get cleaned
--      up too — e.g. /bin/msks).
--   2. Asks for confirmation, listing what will be removed.
--   3. Deletes per-package files, then allay's own directories
--      (/usr/allay, /etc/allay, /var/allay), the startup shim, and the CLI.

local LOCKFILE     = "/var/allay/allay.lock"
local STARTUP_FILE = "/startup/00_allay.lua"
local CLI_FILE     = "/bin/allay.lua"
local OWN_DIRS     = { "/usr/allay", "/etc/allay", "/var/allay" }

-- ---------------------------------------------------------------------------
-- Output helpers
-- ---------------------------------------------------------------------------

local function color(c, text)
  if term and colors and term.setTextColor then
    local prev = term.getTextColor and term.getTextColor()
    term.setTextColor(colors[c] or colors.white)
    io.write(text)
    if prev then term.setTextColor(prev) end
  else
    io.write(text)
  end
end

local function ok(s)   color("green",  s .. "\n") end
local function info(s) color("white",  s .. "\n") end
local function warn(s) color("yellow", s .. "\n") end
local function fail(s) color("red",    s .. "\n") end

local function ask(prompt)
  io.write(prompt)
  io.flush()
  local r = io.read("*l") or ""
  return r:gsub("^%s+", ""):gsub("%s+$", "")
end

-- ---------------------------------------------------------------------------
-- Read the lockfile (if present) and collect file paths.
-- ---------------------------------------------------------------------------

local function read_lockfile()
  if not fs.exists(LOCKFILE) then return nil end
  local f = fs.open(LOCKFILE, "r")
  if not f then return nil end
  local body = f.readAll()
  f.close()
  local fn = load("return " .. body, "lockfile", "t", {})
  if not fn then return nil end
  local ok_load, value = pcall(fn)
  if not ok_load or type(value) ~= "table" then return nil end
  return value
end

local function tracked_files(lock)
  local files = {}
  if not lock or type(lock.packages) ~= "table" then return files end
  for _, entry in pairs(lock.packages) do
    if type(entry.files) == "table" then
      for _, f in ipairs(entry.files) do
        if type(f) == "table" and type(f.dest) == "string" then
          table.insert(files, f.dest)
        end
      end
    end
  end
  return files
end

-- ---------------------------------------------------------------------------
-- Main flow
-- ---------------------------------------------------------------------------

print()
warn("  allay uninstall")
warn("  this will REMOVE allay and every package it installed.")
print()

local lock = read_lockfile()
local pkg_files = tracked_files(lock)
local pkg_count = 0
if lock and lock.packages then
  for _ in pairs(lock.packages) do pkg_count = pkg_count + 1 end
end

info("The following will be deleted:")
for _, d in ipairs(OWN_DIRS) do info("  " .. d) end
info("  " .. STARTUP_FILE)
info("  " .. CLI_FILE)
if pkg_count > 0 then
  info(string.format("  %d installed package%s (%d file%s outside /usr/allay)",
    pkg_count, pkg_count == 1 and "" or "s",
    #pkg_files, #pkg_files == 1 and "" or "s"))
end
print()

-- Typed confirmation, no [y/n]. The user must literally type UNINSTALL.
warn("Type the word UNINSTALL (in caps) to confirm, anything else to abort.")
io.write("> ")
io.flush()
local r = ask("")
if r ~= "UNINSTALL" then
  info("Aborted.")
  return
end

-- Phase 1: delete tracked package files (anything outside /usr/allay).
print()
info("Removing package files...")
for _, path in ipairs(pkg_files) do
  if fs.exists(path) then fs.delete(path) end
end

-- Phase 2: nuke allay's own directories and shims.
info("Removing allay directories...")
for _, d in ipairs(OWN_DIRS) do
  if fs.exists(d) then fs.delete(d) end
end
if fs.exists(STARTUP_FILE) then fs.delete(STARTUP_FILE) end
if fs.exists(CLI_FILE)     then fs.delete(CLI_FILE)     end

print()
ok("  allay removed.")
info("  Reboot to clear the path setup from your shell.")
print()
