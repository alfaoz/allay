-- allay: package manager for CC: Tweaked.
--
-- Entry point. Parses args, dispatches to a command handler. Handlers
-- live in this file because the CLI's surface is small enough that
-- splitting them would just add ceremony.

-- Set up the lib path. allay's own lib dir comes first.
package.path = "/usr/allay/lib/allay/?.lua;/usr/allay/lib/allay/?/init.lua;"
            .. "/usr/allay/lib/?/init.lua;/usr/allay/lib/?.lua;"
            .. package.path

local argparse = require("argparse")
local source_mod = require("source")
local index_mod = require("index")
local resolver = require("resolver")
local installer = require("installer")
local lockfile_mod = require("lockfile")
local pathkit = require("pathkit")
local pkg_mod = require("pkg")
local hash = require("hash")
local log = require("log")
local github = require("scout")
local ui = require("ui")
local levenshtein = require("levenshtein")

local VERSION = "0.1.0"

-- ---------------------------------------------------------------------------
-- Output helpers (thin aliases for ui)
-- ---------------------------------------------------------------------------

local color, ok, info, warn, fail = ui.color, ui.ok, ui.info, ui.warn, ui.fail
local confirm = ui.confirm
local with_spinner = ui.with_spinner

local function suggest_command(unknown, valid)
  return (levenshtein.suggest(unknown, valid))
end

-- ---------------------------------------------------------------------------
-- Command implementations
-- ---------------------------------------------------------------------------

local commands = {}

-- Helper: load lockfile or bail.
local function must_load_lockfile()
  local lock, err = lockfile_mod.load()
  if not lock then
    fail("error: cannot load lockfile: " .. (err or "?"))
    return
  end
  return lock
end

local function must_load_sources()
  local sources, err = source_mod.load()
  if not sources then
    fail("error: cannot load sources: " .. (err or "?"))
    return
  end
  if #sources == 0 then
    warn("warning: no sources configured. Add one with: allay source add <user/repo>")
  end
  return sources
end

-- Build the set of package names known to the configured sources. Used by
-- gh: bundle's external_resolver so internal vs external require()s get
-- classified correctly. Quiet on failure; an unreachable source just means
-- fewer hits in the known set.
local function build_known(sources)
  local known = {}
  for _, source in ipairs(sources) do
    local idx = index_mod.fetch(source)
    if idx and idx.packages then
      for n in pairs(idx.packages) do known[n] = true end
    end
  end
  return known
end

-- Look up the upgrade-source pkg/source pair for a lockfile entry. Routes
-- gh:user/repo[@ref] entries through the bundle path and regular entries
-- through the resolver, restricted to the recorded source so a package
-- isn't silently swapped for a same-named one in another configured source.
--
-- Returns (pkg, source, info, err). info.kind is "gh" or "regular".
-- For gh: kind, info.fetch_cache holds bodies the bundle pre-fetched.
local function lookup_for_upgrade(name, entry, sources, known)
  local source_id = entry.source or ""
  if source_id:sub(1, #github.SCHEME) == github.SCHEME then
    local pkg, source, bundle_info, err = github.bundle(source_id, known)
    if not pkg then return nil, nil, nil, err end
    return pkg, source, {
      kind = "gh",
      fetch_cache = bundle_info and bundle_info.fetch_cache,
      bundle_info = bundle_info,
    }
  end
  local pkg, source, err = resolver.find_package(name, sources, {
    from_source = source_id,
  })
  if not pkg then return nil, nil, nil, err end
  return pkg, source, { kind = "regular" }
end

-- Compare a freshly-bundled gh: package's file hashes against what the
-- lockfile entry recorded. Returns true when the files on disk match the
-- bundled output -- i.e., upstream hasn't changed and `update` can skip
-- this package. fetch_cache contains the bodies pulled during the bundle
-- walk, so this check is local-only (no extra network round trips).
local function gh_unchanged(pkg, fetch_cache, entry)
  if not entry.files or #entry.files == 0 then return false end

  local lock_hashes = {}
  for _, f in ipairs(entry.files) do
    lock_hashes[f.dest] = f.sha256 and f.sha256:lower() or ""
  end

  local seen = 0
  for _, fi in ipairs(pkg_mod.iter_files(pkg)) do
    seen = seen + 1
    local body = fi.inline or (fetch_cache and fetch_cache[fi.src_path])
    if not body then return false end
    local actual = hash.sha256hex(body):lower()
    if lock_hashes[fi.dest_path] ~= actual then return false end
  end

  -- File-count mismatch (added or removed file) counts as a change.
  return seen == #entry.files
end

-- ---------------------------------------------------------------------------
-- install
-- ---------------------------------------------------------------------------
function commands.install(args)
  if not args.package then
    fail("error: missing package name")
    info("usage: allay install <package>[@<version>] [--yes] [--allow-scripts]")
    info("       allay install gh:user/repo[@ref]   # bundle install from GitHub")
    return
  end

  local lock = must_load_lockfile()
  local sources = must_load_sources()

  -- gh: prefix routes through the greedy bundle installer. The synthesized
  -- package is registered via opts.synthesized so the resolver consumes it
  -- like any other package.
  local synthesized = {}
  local request_name = args.package
  if request_name:sub(1, #github.SCHEME) == github.SCHEME then
    local pkg, source, info_data, err = with_spinner(
      "walking " .. request_name,
      function() return github.bundle(request_name, build_known(sources)) end)
    if not pkg then
      fail("error: " .. (err or "github bundle failed"))
      return
    end

    info(string.format("Bundle: %s (%d files, %d deps detected)",
      info_data.repo, info_data.total_files, #info_data.detected_deps))
    if #info_data.unresolved > 0 then
      warn("Unresolved require()s (will not be auto-installed):")
      for _, n in ipairs(info_data.unresolved) do
        warn("  - " .. n)
      end
      warn("If these are needed, install them yourself before this package is loaded.")
    end

    synthesized[pkg.name] = {
      pkg = pkg,
      source = source,
      fetch_cache = info_data.fetch_cache,
    }
    request_name = pkg.name
  end

  info("Resolving " .. request_name .. "...")
  local plan, err = resolver.resolve({ request_name }, lock, sources, {
    reinstall = args.flags.reinstall,
    synthesized = synthesized,
  })
  if not plan then
    fail("error: " .. err)
    return
  end

  if #plan == 0 then
    info(args.package .. " is already installed.")
    return
  end

  local conflict_ok, conflict_err = resolver.check_conflicts(plan, lock)
  if not conflict_ok then
    fail("error: " .. conflict_err)
    return
  end

  -- Show plan.
  for _, item in ipairs(plan) do
    local dep_note = item.manual and "" or "  (dep)"
    info(string.format("  + %s@%s%s", item.name,
      item.package.version or "0.0.0", dep_note))
  end

  if not confirm("Continue?", { yes_flag = args.flags.yes }) then
    info("Aborted.")
    return
  end

  local results, install_err = with_spinner(
    string.format("installing %d package%s",
      #plan, #plan == 1 and "" or "s"),
    function() return installer.install_plan(plan, lock) end)
  if not results then
    fail("error: " .. install_err)
    return
  end

  ok(string.format("Installed %d package%s.", #results,
    #results == 1 and "" or "s"))

  -- Show post-install messages.
  for _, r in ipairs(results) do
    if r.post_install_message then
      info("")
      info(r.name .. ": " .. r.post_install_message)
    end
  end

  -- Note hooks (CLI handles consent for now: skip without flag).
  for _, r in ipairs(results) do
    if r.has_hooks then
      if args.flags.allow_scripts then
        info("(hook execution will be implemented in a future release)")
      else
        warn(r.name .. " declared install scripts. Re-run with --allow-scripts to enable.")
      end
    end
  end

  -- TOFU notice.
  local tofu_total = 0
  for _, r in ipairs(results) do tofu_total = tofu_total + r.tofu_count end
  if tofu_total > 0 then
    info(string.format("(%d file%s installed without author-pinned hashes; recorded as TOFU)",
      tofu_total, tofu_total == 1 and "" or "s"))
  end
end

-- ---------------------------------------------------------------------------
-- remove
-- ---------------------------------------------------------------------------
function commands.remove(args)
  if not args.package then
    fail("error: missing package name")
    return
  end

  local lock = must_load_lockfile()
  if not lockfile_mod.is_installed(lock, args.package) then
    fail("error: not installed: " .. args.package)
    return
  end

  -- Find orphans we'd create.
  local entry = lock.packages[args.package]
  local orphan_candidates = {}
  for _, dep_name in ipairs(entry.dependencies or {}) do
    local dep = lock.packages[dep_name]
    if dep and dep.manual == false then
      local would_be_orphan = true
      for _, other in ipairs(dep.dependents or {}) do
        if other ~= args.package then
          would_be_orphan = false
          break
        end
      end
      if would_be_orphan then table.insert(orphan_candidates, dep_name) end
    end
  end

  -- Show plan.
  info("Removing " .. args.package .. ".")
  if #orphan_candidates > 0 then
    info("These dependencies will become orphans and can also be removed:")
    for _, n in ipairs(orphan_candidates) do
      info("  - " .. n)
    end
  end

  if not confirm("Continue?", { yes_flag = args.flags.yes }) then
    info("Aborted.")
    return
  end

  local removed_ok, err = installer.remove_package(lock, args.package)
  if not removed_ok then
    fail("error: " .. err)
    return
  end

  -- Remove orphans if user agrees.
  if #orphan_candidates > 0 then
    if confirm("Also remove orphans?", { yes_flag = args.flags.yes }) then
      for _, name in ipairs(orphan_candidates) do
        installer.remove_package(lock, name)
        info("  removed " .. name)
      end
    end
  end

  ok("Removed " .. args.package .. ".")
end

-- ---------------------------------------------------------------------------
-- update
-- ---------------------------------------------------------------------------
function commands.update(args)
  local lock = must_load_lockfile()
  local sources = must_load_sources()

  local target_names
  if args.package then
    if not lockfile_mod.is_installed(lock, args.package) then
      fail("error: not installed: " .. args.package)
      return
    end
    target_names = { args.package }
  else
    target_names = {}
    for _, item in ipairs(lockfile_mod.installed_packages(lock)) do
      table.insert(target_names, item.name)
    end
  end

  info(string.format("Checking %d package%s for updates...",
    #target_names, #target_names == 1 and "" or "s"))

  local known = build_known(sources)
  local upgrades = {}
  for i, name in ipairs(target_names) do
    local entry = lock.packages[name]
    io.write(string.format("  [%d/%d] %s ", i, #target_names, name))
    io.flush()
    if entry.pinned then
      color("yellow", "(pinned)\n")
    else
      local pkg, source, lookup_info, err = lookup_for_upgrade(
        name, entry, sources, known)
      if not pkg then
        color("red", (err or "lookup failed") .. "\n")
      elseif lookup_info.kind == "gh" then
        if gh_unchanged(pkg, lookup_info.fetch_cache, entry) then
          color("green", "ok\n")
        else
          color("yellow", "(refresh " .. (entry.source or "") .. ")\n")
          table.insert(upgrades, {
            name = name,
            current = entry.version or "0.0.0",
            target = "(refresh)",
            package = pkg,
            source = source,
            fetch_cache = lookup_info.fetch_cache,
          })
        end
      else
        local current = entry.version or "0.0.0"
        local available = pkg.version or "0.0.0"
        if available ~= current then
          color("yellow", string.format("%s -> %s\n", current, available))
          table.insert(upgrades, {
            name = name,
            current = current,
            target = available,
            package = pkg,
            source = source,
          })
        else
          color("green", "ok\n")
        end
      end
    end
  end

  if #upgrades == 0 then
    ok("Everything is up to date.")
    return
  end

  info("Plan:")
  for _, u in ipairs(upgrades) do
    info(string.format("  %s: %s -> %s", u.name, u.current, u.target))
  end

  if not confirm("Continue?", { yes_flag = args.flags.yes }) then
    info("Aborted.")
    return
  end

  -- Reinstall by removing and re-installing each upgrade.
  for _, u in ipairs(upgrades) do
    local was_manual = lock.packages[u.name].manual
    installer.remove_package(lock, u.name)
    local plan = {{
      name = u.name, package = u.package, source = u.source,
      manual = was_manual, requested_by = nil,
      fetch_cache = u.fetch_cache,
    }}
    local res, err = installer.install_plan(plan, lock)
    if not res then
      fail("error: " .. err)
      return
    end
  end

  ok(string.format("Upgraded %d package%s.", #upgrades,
    #upgrades == 1 and "" or "s"))
end

-- ---------------------------------------------------------------------------
-- list
-- ---------------------------------------------------------------------------
function commands.list(_)
  local lock = must_load_lockfile()
  local installed = lockfile_mod.installed_packages(lock)

  if #installed == 0 then
    info("No packages installed.")
    return
  end

  for _, item in ipairs(installed) do
    local marker = item.entry.manual and "  " or "* "
    local pinned = item.entry.pinned and " [pinned]" or ""
    info(string.format("%s%-24s %s%s", marker, item.name,
      item.entry.version or "?", pinned))
  end
  info("")
  info("(* = installed as a dependency)")
end

-- ---------------------------------------------------------------------------
-- search
-- ---------------------------------------------------------------------------
function commands.search(args)
  if not args.query then
    fail("error: missing search query")
    return
  end

  local sources = must_load_sources()
  local found_any = false
  for _, source in ipairs(sources) do
    local idx, err = index_mod.fetch(source)
    if idx then
      local results = index_mod.search(idx, args.query)
      if #results > 0 then
        info("From " .. source.id .. ":")
        for _, r in ipairs(results) do
          info(string.format("  %-24s %s  %s",
            r.name, r.version or "", r.description or ""))
        end
        found_any = true
      end
    elseif err ~= "blind" then
      log.warnf("source %s: %s", source.id, err)
    end
  end
  if not found_any then
    info("No packages matching '" .. args.query .. "'.")
  end
end

-- ---------------------------------------------------------------------------
-- info
-- ---------------------------------------------------------------------------
function commands.info(args)
  if not args.package then
    fail("error: missing package name")
    return
  end

  local lock = must_load_lockfile()
  local sources = must_load_sources()

  local installed = lock.packages[args.package]
  if installed then
    info(args.package)
    info("  status:       installed")
    info("  version:      " .. (installed.version or "?"))
    info("  source:       " .. (installed.source or "?"))
    info("  manual:       " .. tostring(installed.manual))
    if installed.pinned then info("  pinned:       true") end
    info("  dependencies: " .. (#(installed.dependencies or {}) > 0
      and table.concat(installed.dependencies, ", ") or "(none)"))
    info("  dependents:   " .. (#(installed.dependents or {}) > 0
      and table.concat(installed.dependents, ", ") or "(none)"))
    info("  files:        " .. tostring(#(installed.files or {})))
    return
  end

  -- Look up in sources.
  local pkg, source = resolver.find_package(args.package, sources, {})
  if not pkg then
    fail("error: package not found: " .. args.package)
    return
  end

  info(args.package)
  info("  status:       available")
  info("  version:      " .. (pkg.version or "?"))
  info("  description:  " .. (pkg.description or ""))
  info("  author:       " .. (pkg.author or "(unknown)"))
  info("  license:      " .. (pkg.license or "(unspecified)"))
  info("  source:       " .. source.id)
  if pkg.dependencies and #pkg.dependencies > 0 then
    info("  dependencies: " .. table.concat(pkg.dependencies, ", "))
  end
end

-- ---------------------------------------------------------------------------
-- source
-- ---------------------------------------------------------------------------
function commands.source(args)
  local sub = args.subcommand
  if sub == "add" then
    if not args.repo then
      fail("error: missing repository")
      return
    end
    local add_opts = {}
    if args.options.format then add_opts.format = args.options.format end
    if args.options.url then add_opts.url = args.options.url end
    local entry, err = source_mod.add(args.repo, add_opts)
    if not entry then
      fail("error: " .. err)
      return
    end
    local fmt = entry.format and ("  [" .. entry.format .. "]") or ""
    ok("Added source: " .. entry.id .. " -> " .. entry.url .. fmt)
  elseif sub == "remove" then
    if not args.repo then
      fail("error: missing repository")
      return
    end
    local removed_ok, err = source_mod.remove(args.repo)
    if not removed_ok then
      fail("error: " .. err)
      return
    end
    ok("Removed source: " .. args.repo)
  elseif sub == "list" then
    local sources = source_mod.list()
    if #sources == 0 then
      info("No sources configured.")
    else
      for _, s in ipairs(sources) do
        local fmt = s.format and ("  [" .. s.format .. "]") or ""
        info(string.format("%-32s %s%s", s.id, s.url, fmt))
      end
    end
  else
    fail("error: unknown source subcommand: " .. tostring(sub))
    return
  end
end

-- ---------------------------------------------------------------------------
-- init (scaffolds an allay.lua)
-- ---------------------------------------------------------------------------
function commands.init(args)
  local target = args.target or "."
  local skeleton = [[return {
  name = "REPLACE_ME",
  version = "0.1.0",
  description = "A short description of this package.",
  author = "your name here",
  license = "MIT",

  base_url = "https://raw.githubusercontent.com/USER/REPO/main",

  files = {
    lib = {
      ["src/init.lua"] = "init.lua",
    },
  },

  hashes = {
    -- ["src/init.lua"] = "compute with: hash.sha256hex(io.open('src/init.lua'):read('a'))",
  },

  -- dependencies = { "hash" },
}
]]

  local target_path = target .. "/allay.lua"
  if pathkit.exists(target_path) then
    fail("error: " .. target_path .. " already exists")
    return
  end

  pathkit.write_atomic(target_path, skeleton)
  ok("Wrote " .. target_path)
  info("Edit it with your package's metadata, then publish to GitHub.")
end

-- ---------------------------------------------------------------------------
-- doctor
-- ---------------------------------------------------------------------------
function commands.doctor(_)
  local lock = must_load_lockfile()

  local issues = 0
  for name, entry in pairs(lock.packages) do
    for _, f in ipairs(entry.files or {}) do
      if not pathkit.exists(f.dest) then
        fail("missing: " .. f.dest .. " (owned by " .. name .. ")")
        issues = issues + 1
      else
        local content = pathkit.read(f.dest)
        if content and f.sha256 then
          local actual = hash.sha256hex(content)
          if actual:lower() ~= f.sha256:lower() then
            local marker = f.tofu and " [TOFU]" or ""
            fail(string.format("hash mismatch%s: %s (owned by %s)",
              marker, f.dest, name))
            issues = issues + 1
          end
        end
      end
    end
  end

  if issues == 0 then
    ok(string.format("All %d installed package%s look healthy.",
      #lockfile_mod.installed_packages(lock),
      #lockfile_mod.installed_packages(lock) == 1 and "" or "s"))
  else
    fail(string.format("%d issue%s found.", issues, issues == 1 and "" or "s"))
    return
  end
end

-- ---------------------------------------------------------------------------
-- reinstall
-- ---------------------------------------------------------------------------
function commands.reinstall(args)
  if not args.package then
    fail("error: missing package name")
    return
  end
  local lock = must_load_lockfile()
  if not lockfile_mod.is_installed(lock, args.package) then
    fail("error: not installed: " .. args.package)
    return
  end

  -- Capture entry before removal so we can reach back for source info.
  local lock_name = args.package
  local source_id = (lock.packages[lock_name] or {}).source or ""

  installer.remove_package(lock, lock_name)

  -- Rewrite args.package so the install pipeline pulls from the same place
  -- the original install came from. For gh: bundles, the source IS the gh:
  -- spec verbatim (gh:user/repo@ref) so install rewalks via the bundle
  -- path. For regular sources, prepend the source id as a qualifier so the
  -- resolver doesn't drift to a same-named package elsewhere.
  if source_id:sub(1, #github.SCHEME) == github.SCHEME then
    args.package = source_id
  elseif source_id ~= "" then
    args.package = source_id .. ":" .. lock_name
  end

  args.flags.reinstall = true
  return commands.install(args)
end

-- ---------------------------------------------------------------------------
-- outdated
-- ---------------------------------------------------------------------------
function commands.outdated(_)
  local lock = must_load_lockfile()
  local sources = must_load_sources()

  local outdated_count = 0
  for _, item in ipairs(lockfile_mod.installed_packages(lock)) do
    if not item.entry.pinned then
      local pkg = resolver.find_package(item.name, sources, {})
      if pkg then
        local current = item.entry.version or "0.0.0"
        local latest = pkg.version or "0.0.0"
        if latest ~= current then
          info(string.format("  %-24s %s -> %s", item.name, current, latest))
          outdated_count = outdated_count + 1
        end
      end
    end
  end

  if outdated_count == 0 then
    ok("Everything is up to date.")
  else
    info("")
    info("Run `allay update` to upgrade.")
  end
end

-- ---------------------------------------------------------------------------
-- why
-- ---------------------------------------------------------------------------
function commands.why(args)
  if not args.package then
    fail("error: missing package name")
    return
  end
  local lock = must_load_lockfile()
  local entry = lock.packages[args.package]
  if not entry then
    fail("error: not installed: " .. args.package)
    return
  end

  if entry.manual then
    info(args.package .. " is installed manually.")
    return
  end

  if not entry.dependents or #entry.dependents == 0 then
    info(args.package .. " is an orphan (no manual install, no dependents).")
    info("Run `allay remove " .. args.package .. "` to clean up.")
    return
  end

  info(args.package .. " is installed because:")
  for _, d in ipairs(entry.dependents) do
    info("  " .. d .. " depends on it")
  end
end

-- ---------------------------------------------------------------------------
-- clean
-- ---------------------------------------------------------------------------
function commands.clean(_)
  local cache_dir = "/var/allay/cache"
  local tmp_dir = "/var/allay/.tmp"
  if pathkit.exists(cache_dir) then pathkit.delete(cache_dir) end
  if pathkit.exists(tmp_dir) then pathkit.delete(tmp_dir) end
  pathkit.mkdir_p(cache_dir)
  ok("Cache cleared.")
end

-- ---------------------------------------------------------------------------
-- scout
-- ---------------------------------------------------------------------------
-- Walk a GitHub repo and print the synthesized allay.lua to stdout. Useful
-- for seeding curated sources from existing upstream repos.
function commands.scout(args)
  if not args.target then
    fail("error: missing target")
    info("usage: allay scout gh:user/repo[@ref]")
    info("       allay scout user/repo")
    return
  end

  local sources = source_mod.load() or {}

  local pkg, source, info_data, err = with_spinner(
    "walking " .. args.target,
    function() return github.bundle(args.target, build_known(sources)) end)
  if not pkg then
    fail("error: " .. (err or "scout failed"))
    return
  end

  -- Pretty-print the synthesized allay.lua.
  local lines = { "-- Synthesized by `allay scout " .. args.target .. "`" }
  table.insert(lines, "-- " .. info_data.repo .. "@" .. info_data.ref
    .. ", " .. info_data.total_files .. " files")
  if #info_data.unresolved > 0 then
    table.insert(lines, "-- Unresolved: " .. table.concat(info_data.unresolved, ", "))
  end
  table.insert(lines, "")
  table.insert(lines, "return {")
  table.insert(lines, string.format("  name = %q,", pkg.name))
  table.insert(lines, string.format("  version = %q,", pkg.version))
  table.insert(lines, string.format("  description = %q,", pkg.description))
  table.insert(lines, string.format("  base_url = %q,", pkg.base_url))
  table.insert(lines, "")
  table.insert(lines, "  files = {")
  for kind, group in pairs(pkg.files) do
    table.insert(lines, string.format("    %s = {", kind))
    -- Stable order.
    local keys = {}
    for k in pairs(group) do table.insert(keys, k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
      table.insert(lines, string.format("      [%q] = %q,", k, group[k]))
    end
    table.insert(lines, "    },")
  end
  table.insert(lines, "  },")
  table.insert(lines, "  hashes = {},")
  if pkg.dependencies and #pkg.dependencies > 0 then
    local deps = {}
    for _, d in ipairs(pkg.dependencies) do
      table.insert(deps, string.format("%q", d))
    end
    table.insert(lines, string.format("  dependencies = { %s },",
      table.concat(deps, ", ")))
  end
  table.insert(lines, "}")
  table.insert(lines, "")

  print(table.concat(lines, "\n"))

  if #info_data.unresolved > 0 then
    warn("Note: some require() calls didn't resolve. Review and add deps manually:")
    for _, n in ipairs(info_data.unresolved) do
      warn("  - " .. n)
    end
  end

  -- Use source so it doesn't trigger linting.
  _ = source
end

-- ---------------------------------------------------------------------------
-- version
-- ---------------------------------------------------------------------------
function commands.version(_)
  info("allay " .. VERSION)
end

-- ---------------------------------------------------------------------------
-- help
-- ---------------------------------------------------------------------------
local HELP_LINES = {
  "allay " .. VERSION,
  "Package manager for CC: Tweaked.",
  "",
  "Usage:",
  "  allay <command> [options]",
  "",
  "Commands:",
  "  install <pkg>[@<version>]   Install a package",
  "  remove <pkg>                Uninstall a package",
  "  update [<pkg>]              Update all (or one) package",
  "  list                        Show installed packages",
  "  search <query>              Find packages across sources",
  "  info <pkg>                  Show package details",
  "  outdated                    Show packages with available updates",
  "  why <pkg>                   Explain why a package is installed",
  "  source add/remove/list      Manage package sources",
  "  init [<dir>]                Scaffold an allay.lua",
  "  doctor                      Verify installed files",
  "  reinstall <pkg>             Reinstall a package",
  "  clean                       Clear the download cache",
  "  scout <gh:user/repo>        Synthesize an allay.lua from a GitHub repo",
  "  version                     Print allay's version",
  "  help [<command>]            Show this help (or detail for one command)",
  "",
  "Common flags:",
  "  --yes, -y       Skip confirmation prompts",
  "  --allow-scripts Allow packages' install scripts to run",
  "  --help, -h      Show help for a command",
}

local DETAILED_HELP = {
  install = "allay install <pkg>[@<version>] [--yes] [--allow-scripts]\n\n"
    .. "Install a package and its dependencies. The plan is shown for review\n"
    .. "before any files are written.",
  remove = "allay remove <pkg> [--yes]\n\n"
    .. "Uninstall a package. Orphan dependencies (deps that came along with\n"
    .. "this package and aren't needed by anything else) are offered for\n"
    .. "removal too.",
  update = "allay update [<pkg>] [--yes]\n\n"
    .. "Without args, update everything. With a package name, update just\n"
    .. "that one. Pinned packages are skipped.",
  source = "allay source add <user/repo> [--url=<url>] [--format=<fmt>]\n"
    .. "allay source remove <user/repo>\n"
    .. "allay source list\n\n"
    .. "Manage the list of package sources. Sources can be GitHub shorthand\n"
    .. "(user/repo) or full HTTPS URLs.\n\n"
    .. "  --url=<url>     Use this exact URL instead of expanding the shorthand.\n"
    .. "                  Useful for GitHub Pages-hosted sources.\n"
    .. "  --format=<fmt>  Tag the source with a translator format. Packages\n"
    .. "                  fetched from this source are routed through the\n"
    .. "                  matching translator at /usr/allay/translators/.\n"
    .. "                  Currently supported: unicornpkg/v1.0.0",
  scout = "allay scout gh:user/repo[@ref]\n\n"
    .. "Walk a GitHub repo, classify its files, and print a synthesized\n"
    .. "allay.lua to stdout. Use this to seed a curated source with a\n"
    .. "starting-point package definition that you can then refine by hand.\n\n"
    .. "Note: dep detection is greedy. Review the unresolved list before\n"
    .. "publishing the synthesized definition.",
}

function commands.help(args)
  if args.target and DETAILED_HELP[args.target] then
    info(DETAILED_HELP[args.target])
    return
  end
  for _, line in ipairs(HELP_LINES) do print(line) end
end

-- ---------------------------------------------------------------------------
-- Argparse setup
-- ---------------------------------------------------------------------------

local function parse_argv(argv)
  -- Minimal hand-rolled parsing that mirrors argparse but yields a simpler
  -- args table. Each command has its own positional/flag expectations.

  if #argv == 0 then
    return { command = "help" }
  end

  local first = argv[1]
  if first == "--version" or first == "-v" then return { command = "version" } end
  if first == "--help" or first == "-h" then return { command = "help" } end

  local cmd = first
  local rest = {}
  for i = 2, #argv do table.insert(rest, argv[i]) end

  -- Common flag extraction.
  local args = { command = cmd, flags = {}, options = {} }
  local positionals = {}
  for _, a in ipairs(rest) do
    if a == "--yes" or a == "-y" then
      args.flags.yes = true
    elseif a == "--allow-scripts" then
      args.flags.allow_scripts = true
    elseif a == "--reinstall" then
      args.flags.reinstall = true
    elseif a == "--help" or a == "-h" then
      args.flags.help = true
    elseif a:sub(1, 2) == "--" then
      local key, val = a:sub(3):match("^([^=]+)=(.*)$")
      if key then
        args.options[key] = val
      else
        args.flags[a:sub(3)] = true
      end
    else
      table.insert(positionals, a)
    end
  end

  if cmd == "install" or cmd == "remove" or cmd == "info"
     or cmd == "why" or cmd == "reinstall" then
    args.package = positionals[1]
  elseif cmd == "update" then
    args.package = positionals[1]
  elseif cmd == "search" then
    args.query = positionals[1]
  elseif cmd == "source" then
    args.subcommand = positionals[1]
    args.repo = positionals[2]
  elseif cmd == "init" then
    args.target = positionals[1] or "."
  elseif cmd == "help" then
    args.target = positionals[1]
  elseif cmd == "scout" then
    args.target = positionals[1]
  end

  return args
end

local function main(argv)
  local args = parse_argv(argv)

  if args.flags and args.flags.help and args.command ~= "help" then
    return commands.help({ target = args.command })
  end

  local handler = commands[args.command]
  if not handler then
    fail("error: unknown command: " .. tostring(args.command))
    local valid = {}
    for k, _ in pairs(commands) do table.insert(valid, k) end
    table.sort(valid)
    local s = suggest_command(args.command, valid)
    if s then
      info("Did you mean: " .. s .. "?")
    else
      info("Run `allay help` for the command list.")
    end
    return
  end

  return handler(args)
end

-- Allow `require`-ing this file for testing without running main.
if _G._ALLAY_NO_AUTORUN then
  return { main = main, commands = commands, parse_argv = parse_argv }
end

main({...})
