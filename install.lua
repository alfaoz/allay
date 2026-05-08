-- allay bootstrap installer.
--
-- Run with:
--   wget run https://raw.githubusercontent.com/alfaoz/allay/main/install.lua
--
-- This script fetches allay's CLI and its core libraries from GitHub raw,
-- installs them under /usr/allay, and configures the system so `allay` is
-- available from the shell.
--
-- The bootstrap trusts HTTPS for its fetches (no embedded hash verification
-- yet). After bootstrap, every subsequent allay operation verifies hashes
-- against the lockfile.

local BASE = "https://raw.githubusercontent.com/alfaoz/allay/main"
local CORE_BASE = "https://raw.githubusercontent.com/alfaoz/lualibs/main"
local UNICORNPKG_COMPAT_BASE =
  "https://raw.githubusercontent.com/alfaoz/allay-unicornpkg-compat/main"

-- Files to fetch: { url, dest }
local CORE_FILES = {
  -- allay's CLI and libs.
  { BASE .. "/bin/allay.lua",                  "/bin/allay.lua" },
  { BASE .. "/lib/source.lua",                 "/usr/allay/lib/allay/source.lua" },
  { BASE .. "/lib/index.lua",                  "/usr/allay/lib/allay/index.lua" },
  { BASE .. "/lib/schema.lua",                 "/usr/allay/lib/allay/schema.lua" },
  { BASE .. "/lib/pkg.lua",                    "/usr/allay/lib/allay/pkg.lua" },
  { BASE .. "/lib/lockfile.lua",               "/usr/allay/lib/allay/lockfile.lua" },
  { BASE .. "/lib/resolver.lua",               "/usr/allay/lib/allay/resolver.lua" },
  { BASE .. "/lib/installer.lua",              "/usr/allay/lib/allay/installer.lua" },
  { BASE .. "/lib/github.lua",                 "/usr/allay/lib/allay/github.lua" },
  { BASE .. "/lib/transport/init.lua",         "/usr/allay/lib/transport/init.lua" },
  { BASE .. "/lib/transport/https.lua",        "/usr/allay/lib/transport/https.lua" },
  { BASE .. "/lib/transport/disk.lua",         "/usr/allay/lib/transport/disk.lua" },

  -- Core libs (allay's own deps).
  { CORE_BASE .. "/hash/init.lua",             "/usr/allay/lib/hash/init.lua" },
  { CORE_BASE .. "/httpkit/init.lua",          "/usr/allay/lib/httpkit/init.lua" },
  { CORE_BASE .. "/pathkit/init.lua",          "/usr/allay/lib/pathkit/init.lua" },
  { CORE_BASE .. "/log/init.lua",              "/usr/allay/lib/log/init.lua" },
  { CORE_BASE .. "/argparse/init.lua",         "/usr/allay/lib/argparse/init.lua" },

  -- unicornpkg compat translator. Shipped by default so the unicornpkg
  -- catalog (which is the largest existing CC: Tweaked package ecosystem)
  -- works out of the box. Removable: `allay source remove unicornpkg/unicornpkg-main`
  -- and delete `/usr/allay/translators/unicornpkg.lua`.
  { UNICORNPKG_COMPAT_BASE .. "/init.lua",     "/usr/allay/translators/unicornpkg.lua" },
}

local DIRECTORIES = {
  "/usr/allay",
  "/usr/allay/lib",
  "/usr/allay/lib/allay",
  "/usr/allay/lib/transport",
  "/usr/allay/translators",
  "/usr/allay/providers",
  "/var/allay",
  "/var/allay/cache",
  "/etc/allay",
  "/bin",
  "/startup",
}

local STARTUP_FILE = "/startup/00_allay.lua"
-- The startup file does only what's portable across CC's per-program env
-- model: prepend /bin to the shell path so `allay` is callable. Each
-- program (allay's CLI, the lua REPL, user code) gets its own `package`
-- in CC: Tweaked, so a global package.path mutation here would not
-- propagate. User programs that want to require allay's libs must set
-- up package.path themselves at the top of the program.
local STARTUP_CONTENT = [[-- allay path setup.
if shell and shell.setPath then
  shell.setPath("/bin:" .. shell.path())
end
-- Best-effort: also try the require.path setting, which some CC: Tweaked
-- builds use to seed each program's package.path. Harmless if unused.
if settings and settings.set then
  local extra = "/usr/allay/lib/allay/?.lua;/usr/allay/lib/allay/?/init.lua;"
             .. "/usr/allay/lib/?/init.lua;/usr/allay/lib/?.lua;"
  pcall(function()
    settings.set("require.path",
      extra .. (settings.get("require.path") or ""))
  end)
end
]]

local SOURCES_FILE = "/etc/allay/sources.lua"
local DEFAULT_SOURCES = [[{
  { id = "alfaoz/allay-core",
    url = "https://raw.githubusercontent.com/alfaoz/allay-core/main" },
  { id = "unicornpkg/unicornpkg-main",
    url = "https://raw.githubusercontent.com/unicornpkg/unicornpkg-main/main" },
}
]]

local LOCKFILE = "/var/allay/allay.lock"
local INITIAL_LOCK = [[{
  spec = "allay/v1.0.0",
  packages = {},
}
]]

-- ---------------------------------------------------------------------------
-- Helpers
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
  return r:lower():gsub("^%s+", ""):gsub("%s+$", "")
end

local function confirm(prompt)
  local r = ask(prompt .. " [Y/n]: ")
  return r == "" or r == "y" or r == "yes"
end

local function fetch(url)
  if not http or not http.get then
    return nil, "HTTP API not available"
  end
  local response, err = http.get(url)
  if not response then return nil, err or "fetch failed" end
  local code = response.getResponseCode and response.getResponseCode() or 200
  if code >= 400 then
    response.close()
    return nil, "HTTP " .. code
  end
  local body = response.readAll()
  response.close()
  return body
end

local function write_file(path, content)
  local parent = path:match("^(.*)/[^/]*$")
  if parent and parent ~= "" and not fs.exists(parent) then
    fs.makeDir(parent)
  end
  local f = fs.open(path, "w")
  if not f then return false, "cannot open " .. path end
  f.write(content)
  f.close()
  return true
end

-- ---------------------------------------------------------------------------
-- Main flow
-- ---------------------------------------------------------------------------

local function main()
  print()
  info("  allay v0.1.0")
  info("  the package manager for CC: Tweaked")
  info("  installing...")
  print()

  -- Sanity checks.
  if not http or not http.get then
    fail("HTTP API is disabled on this computer.")
    info("Allay needs HTTP to fetch packages.")
    info("Enable the HTTP API in CC's config (httpEnabled = true), or use the")
    info("offline floppy bootstrap (see https://allay.docs/offline).")
    return
  end

  if not fs or not fs.makeDir then
    fail("Filesystem API not available.")
    return
  end

  -- Confirm.
  print("This will install allay onto this computer. The following directories")
  print("will be created (existing files at these paths will not be touched):")
  for _, d in ipairs(DIRECTORIES) do
    print("  " .. d)
  end
  print()

  if not confirm("Continue?") then
    info("Aborted.")
    return
  end

  -- Make directories.
  for _, dir in ipairs(DIRECTORIES) do
    if not fs.exists(dir) then fs.makeDir(dir) end
  end

  -- Fetch and install files.
  print()
  info("Fetching allay core...")
  for _, entry in ipairs(CORE_FILES) do
    local url, dest = entry[1], entry[2]
    io.write("  " .. dest .. " ")
    io.flush()
    local body, err = fetch(url)
    if not body then
      print()
      fail("  fetch failed: " .. (err or "?"))
      fail("  URL: " .. url)
      return
    end
    local ok_w, write_err = write_file(dest, body)
    if not ok_w then
      print()
      fail("  write failed: " .. (write_err or "?"))
      return
    end
    color("green", "ok\n")
  end

  -- Initialize state files.
  print()
  info("Configuring...")
  if not fs.exists(LOCKFILE) then
    -- Build a lockfile populated with everything we just bootstrapped, so
    -- `allay list / update / remove` see them as real packages from day one.
    -- We hash the on-disk content using allay's own hash module, which is
    -- now available because we just wrote it to /usr/allay/lib/hash/.
    package.path = "/usr/allay/lib/allay/?.lua;/usr/allay/lib/allay/?/init.lua;"
                .. "/usr/allay/lib/?/init.lua;/usr/allay/lib/?.lua;"
                .. package.path
    local ok_lib, hash_lib = pcall(require, "hash")
    if not ok_lib then
      write_file(LOCKFILE, INITIAL_LOCK)
      warn("  wrote " .. LOCKFILE .. " (empty: hash module not loadable)")
    else
      local pkg_to_files = {
        allay = {
          version = "0.1.0", source = "alfaoz/allay-core", manual = true,
          dests = {
            "/bin/allay.lua",
            "/usr/allay/lib/allay/source.lua",
            "/usr/allay/lib/allay/index.lua",
            "/usr/allay/lib/allay/schema.lua",
            "/usr/allay/lib/allay/pkg.lua",
            "/usr/allay/lib/allay/lockfile.lua",
            "/usr/allay/lib/allay/resolver.lua",
            "/usr/allay/lib/allay/installer.lua",
            "/usr/allay/lib/allay/github.lua",
            "/usr/allay/lib/transport/init.lua",
            "/usr/allay/lib/transport/https.lua",
            "/usr/allay/lib/transport/disk.lua",
          },
        },
        hash     = { version = "1.0.0", source = "alfaoz/allay-core",
                     dests = { "/usr/allay/lib/hash/init.lua" } },
        httpkit  = { version = "1.0.0", source = "alfaoz/allay-core",
                     dests = { "/usr/allay/lib/httpkit/init.lua" } },
        pathkit  = { version = "1.0.0", source = "alfaoz/allay-core",
                     dests = { "/usr/allay/lib/pathkit/init.lua" } },
        log      = { version = "1.0.0", source = "alfaoz/allay-core",
                     dests = { "/usr/allay/lib/log/init.lua" } },
        argparse = { version = "1.0.0", source = "alfaoz/allay-core",
                     dests = { "/usr/allay/lib/argparse/init.lua" } },
        ["allay-unicornpkg-compat"] = {
          version = "1.0.0", source = "alfaoz/allay-core",
          dests = { "/usr/allay/translators/unicornpkg.lua" },
        },
      }

      local lock = { spec = "allay/v1.0.0", packages = {} }
      for name, meta in pairs(pkg_to_files) do
        local files = {}
        for _, dest in ipairs(meta.dests) do
          local fh = fs.open(dest, "r")
          local body = fh and fh.readAll() or ""
          if fh then fh.close() end
          table.insert(files, {
            dest = dest,
            sha256 = hash_lib.sha256hex(body),
            tofu = true,
          })
        end
        lock.packages[name] = {
          version = meta.version,
          source = meta.source,
          manual = meta.manual == true,
          pinned = false,
          dependencies = {},
          dependents = {},
          files = files,
        }
      end

      -- Serialize and write.
      local lines = { "{", "  spec = " .. string.format("%q", lock.spec) .. ",",
                      "  packages = {" }
      for name, entry in pairs(lock.packages) do
        table.insert(lines, "    [" .. string.format("%q", name) .. "] = {")
        table.insert(lines, "      version = " .. string.format("%q", entry.version) .. ",")
        table.insert(lines, "      source = " .. string.format("%q", entry.source) .. ",")
        table.insert(lines, "      manual = " .. tostring(entry.manual) .. ",")
        table.insert(lines, "      pinned = false,")
        table.insert(lines, "      dependencies = {},")
        table.insert(lines, "      dependents = {},")
        table.insert(lines, "      files = {")
        for _, f in ipairs(entry.files) do
          table.insert(lines, string.format(
            "        { dest = %q, sha256 = %q, tofu = true },",
            f.dest, f.sha256))
        end
        table.insert(lines, "      },")
        table.insert(lines, "    },")
      end
      table.insert(lines, "  },")
      table.insert(lines, "}")
      table.insert(lines, "")
      write_file(LOCKFILE, table.concat(lines, "\n"))
      info("  wrote " .. LOCKFILE
        .. string.format(" (%d bootstrap packages tracked)",
          (function() local n=0 for _ in pairs(lock.packages) do n=n+1 end return n end)()))
    end
  end

  if not fs.exists(SOURCES_FILE) then
    write_file(SOURCES_FILE, DEFAULT_SOURCES)
    info("  wrote " .. SOURCES_FILE
      .. " (default sources: alfaoz/allay-core, unicornpkg/unicornpkg-main)")
  end

  if fs.exists(STARTUP_FILE) then
    fs.delete(STARTUP_FILE)
  end
  write_file(STARTUP_FILE, STARTUP_CONTENT)
  info("  wrote " .. STARTUP_FILE)

  -- Done.
  print()
  ok("  allay v0.1.0 installed.")
  info("  unicornpkg packages also available (via the bundled translator).")
  print()
  info("  Next steps:")
  info("    reboot                    (activate path setup)")
  info("    allay help                (see all commands)")
  info("    allay search <query>      (find packages)")
  info("    allay install <package>   (install something)")
  print()

  if confirm("Reboot now?") then
    if os and os.reboot then
      os.reboot()
    else
      info("(os.reboot not available; reboot manually)")
    end
  else
    info("(reboot when ready to activate the new shell path)")
  end
end

main()
