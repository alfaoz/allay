-- installer: transactional install of resolved packages.
--
-- For each package in the plan:
--   1. Fetch every file to /var/allay/.tmp/<install-id>/<pkg>/...
--   2. Verify each file's hash against the package's declared hashes,
--      or compute and TOFU-record the hash if not declared.
--   3. After all packages are fetched and verified, atomically move
--      everything to its final location.
--   4. Update the lockfile in one final atomic write.
--   5. Run post_install hooks (with user consent).
--
-- If any step fails, the partially-prepared tmp tree is wiped and nothing
-- on the filesystem outside /var/allay/.tmp is touched. The lockfile is
-- only written if everything else succeeded.

local M = {}

local hash_lib = require("hash")
local pathkit = require("pathkit")
local transport = require("transport")
local source_mod = require("source")
local pkg_mod = require("pkg")
local lockfile_mod = require("lockfile")
local log = require("log")

M.TMP_ROOT = "/var/allay/.tmp"

local function rand_id()
  return string.format("%08x", math.random(0, 0xffffffff))
end

-- Fetch a package's files into a tmp staging area. Returns (file_records, err).
-- Each record is { src_path, dest_path, dest_temp, sha256, tofu, kind, dest_name }.
local function stage_package(item, staging_dir)
  local pkg = item.package
  local source = item.source
  local declared_hashes = pkg.hashes or {}
  local records = {}

  for _, fileinfo in ipairs(pkg_mod.iter_files(pkg)) do
    local body, err
    if fileinfo.inline ~= nil then
      -- Synthesized inline content (wrapper init.lua etc.). No fetch.
      body = fileinfo.inline
    elseif item.fetch_cache and item.fetch_cache[fileinfo.src_path] then
      -- Cached body from an earlier scan pass (greedy gh: bundles use this).
      body = item.fetch_cache[fileinfo.src_path]
    else
      local file_url = source_mod.file_url(
        { url = pkg.base_url }, fileinfo.src_path)
      body, err = transport.fetch(file_url)
      if not body then
        return nil, string.format("fetch failed for %s/%s: %s",
          item.name, fileinfo.src_path, err or "?")
      end
    end

    local actual_hash = hash_lib.sha256hex(body)
    local declared = declared_hashes[fileinfo.src_path]
    local tofu = false
    if declared then
      if declared:lower() ~= actual_hash:lower() then
        return nil, string.format(
          "hash mismatch for %s/%s: declared %s, got %s",
          item.name, fileinfo.src_path, declared, actual_hash)
      end
    else
      tofu = true
    end

    -- Stage the file. Note the parens around gsub: it returns two values
    -- and we want only the string, not the replacement count.
    local stage_path = pathkit.join(staging_dir, item.name,
      (string.gsub(fileinfo.dest_path, "^/", "")))
    local ok, write_err = pathkit.write_atomic(stage_path, body)
    if not ok then
      return nil, string.format("staging write failed: %s", write_err or "?")
    end

    table.insert(records, {
      src_path = fileinfo.src_path,
      dest_path = fileinfo.dest_path,
      dest_temp = stage_path,
      sha256 = actual_hash,
      tofu = tofu,
      kind = fileinfo.kind,
      dest_name = fileinfo.dest_name,
    })
  end

  return records
end

-- Move staged files to their final destinations. This is the point of no
-- return for a single package; if a move fails partway through, we attempt
-- to rollback what we already moved by deleting them.
local function commit_package(records)
  local moved = {}
  for _, r in ipairs(records) do
    local ok, err = pathkit.move(r.dest_temp, r.dest_path)
    if not ok then
      -- Rollback what we already moved.
      for _, m in ipairs(moved) do pathkit.delete(m.dest_path) end
      return nil, string.format("commit move failed for %s: %s", r.dest_path, err or "?")
    end
    table.insert(moved, r)
  end
  return moved
end

-- Build a lockfile entry for a package after successful install.
local function build_lock_entry(item, file_records)
  local files = {}
  for _, r in ipairs(file_records) do
    table.insert(files, {
      dest = r.dest_path,
      sha256 = r.sha256,
      tofu = r.tofu,
    })
  end

  local entry = {
    version = item.package.version or "0.0.0",
    description = item.package.description,
    source = item.source.id,
    manual = item.manual == true,
    pinned = item.pin_version ~= nil,
    files = files,
    dependencies = item.package.dependencies or {},
    dependents = {},
  }
  return entry
end

-- Install a resolved plan. Returns (results, err).
-- results is a list of { name, version, files_count, tofu_count }.
function M.install_plan(plan, lockfile, opts)
  opts = opts or {}
  if #plan == 0 then return {} end

  -- Set up staging area.
  pathkit.mkdir_p(M.TMP_ROOT)
  local staging_dir = pathkit.join(M.TMP_ROOT, "install-" .. rand_id())
  pathkit.mkdir_p(staging_dir)

  local cleanup_staging = function()
    pathkit.delete(staging_dir)
  end

  -- Phase 1: fetch + verify everything.
  log.info(string.format("Downloading %d package%s...",
    #plan, #plan == 1 and "" or "s"))

  local staged = {}
  for i, item in ipairs(plan) do
    local file_count = 0
    for _ in pairs(item.package.files or {}) do file_count = file_count + 1 end
    log.info(string.format("  [%d/%d] %s", i, #plan, item.name))
    local records, err = stage_package(item, staging_dir)
    if not records then
      cleanup_staging()
      return nil, err
    end
    staged[item.name] = records
  end

  log.info("Verified.")

  -- Phase 2: commit each package's files. We do this package-by-package
  -- so each package is fully present or fully absent.
  log.info("Installing files...")

  local committed = {}
  for _, item in ipairs(plan) do
    local moved, err = commit_package(staged[item.name])
    if not moved then
      -- Rollback all previously committed packages.
      for _, prev in ipairs(committed) do
        for _, f in ipairs(prev.files) do pathkit.delete(f.dest_path) end
      end
      cleanup_staging()
      return nil, err
    end
    table.insert(committed, { name = item.name, files = staged[item.name] })
  end

  -- Phase 3: update the lockfile.
  log.info("Updating lockfile...")

  for _, item in ipairs(plan) do
    local entry = build_lock_entry(item, staged[item.name])
    lockfile_mod.insert(lockfile, item.name, entry)
  end

  local ok, err = lockfile_mod.save(lockfile)
  if not ok then
    -- Rollback files. The lockfile didn't update so it's fine on disk.
    for _, prev in ipairs(committed) do
      for _, f in ipairs(prev.files) do pathkit.delete(f.dest_path) end
    end
    cleanup_staging()
    return nil, "lockfile write failed: " .. (err or "?")
  end

  cleanup_staging()

  -- Phase 4: hooks (if any). These run after lockfile is saved so they
  -- can call back into allay safely.
  -- TODO: hook execution is implemented in the CLI layer with user prompts.
  -- The installer just records that hooks exist; the CLI handles them.

  -- Build summary results.
  local results = {}
  for _, item in ipairs(plan) do
    local records = staged[item.name]
    local tofu_count = 0
    for _, r in ipairs(records) do
      if r.tofu then tofu_count = tofu_count + 1 end
    end
    table.insert(results, {
      name = item.name,
      version = item.package.version or "0.0.0",
      files_count = #records,
      tofu_count = tofu_count,
      manual = item.manual,
      has_hooks = item.package.hooks ~= nil,
      post_install_message = item.package.post_install_message,
    })
  end

  return results
end

-- Install a package by running its own installer in an observed env,
-- capturing every file the installer wrote, and recording the result as
-- a normal lockfile entry. The package becomes manageable through
-- `list`, `info`, `update`, and `remove` like any other.
--
-- opts must contain:
--   name              - package name to record in the lockfile
--   installer_src     - the installer's Lua source (string)
--   installer_path    - the installer's filename (for error messages)
--   source_id         - what to record as `source` (e.g. "gh:user/repo@ref")
--   version           - what to record as version (defaults to "0.0.0")
--   description       - optional, recorded as-is
--   manual            - whether the user requested this directly
--   inferred_deps     - list of dep names scout detected for the source repo
--
-- Returns (result, err) where result has { name, version, files_count,
-- tofu_count, post_install_message, has_hooks }.
function M.install_via_observed(lockfile, opts)
  local observe = require("observe")
  if not observe then
    return nil, "observe library not available"
  end

  local name = opts.name
  if not name then return nil, "install_via_observed: opts.name required" end

  local installer_src = opts.installer_src
  if not installer_src then return nil, "install_via_observed: opts.installer_src required" end

  log.info(string.format("Running %s under observe...", opts.installer_path or "installer"))

  -- Hook fs and run the installer.
  local session = observe.start()
  local fn, load_err = load(installer_src, opts.installer_path or "installer", "t", session.env)
  if not fn then
    return nil, "installer parse failed: " .. (load_err or "?")
  end

  local ok, run_err = pcall(fn)
  if not ok then
    return nil, "installer raised: " .. tostring(run_err)
  end

  local manifest = session:finish()

  -- Translate the observe manifest into a lockfile-shaped file list.
  -- We keep `tofu = true` for everything since installer-written files have
  -- no author-pinned hashes. Future updates re-run and detect drift.
  local files = {}
  for _, w in ipairs(manifest.writes) do
    table.insert(files, {
      dest = w.path,
      sha256 = w.sha256,
      tofu = true,
    })
  end

  if #files == 0 then
    return nil, "installer wrote no files (probably failed silently)"
  end

  -- Build the lockfile entry. Same shape as a regular install so list /
  -- info / remove / update don't need to special-case it.
  local entry = {
    version = opts.version or "0.0.0",
    description = opts.description,
    source = opts.source_id,
    manual = opts.manual == true,
    pinned = false,
    files = files,
    dependencies = opts.inferred_deps or {},
    dependents = {},
    -- Marks the package as installer-driven so update/remove know to
    -- re-run the installer rather than fetch files individually.
    installer = opts.installer_path,
  }

  lockfile_mod.insert(lockfile, name, entry)

  local ok2, save_err = lockfile_mod.save(lockfile)
  if not ok2 then
    return nil, "lockfile save failed: " .. (save_err or "?")
  end

  -- Count tofu (which is all of them for installer-driven).
  return {
    name = name,
    version = entry.version,
    files_count = #files,
    tofu_count = #files,
    manual = entry.manual,
    has_hooks = false,
    post_install_message =
      "installed via " .. (opts.installer_path or "installer")
      .. " — " .. #files .. " file(s) tracked. "
      .. "use `allay info " .. name .. "` to inspect.",
  }
end

-- Remove a package's files from disk and the lockfile.
-- Returns (ok, err).
function M.remove_package(lockfile, name)
  local entry = lockfile.packages[name]
  if not entry then
    return nil, "not installed: " .. name
  end

  -- Delete files.
  for _, f in ipairs(entry.files or {}) do
    pathkit.delete(f.dest)
    -- Try to clean up empty parent dir.
    local parent = pathkit.dirname(f.dest)
    if pathkit.exists(parent) and pathkit.is_dir(parent) then
      local listing = pathkit.list(parent)
      if #listing == 0 then pathkit.delete(parent) end
    end
  end

  lockfile_mod.remove(lockfile, name)
  local ok, err = lockfile_mod.save(lockfile)
  if not ok then return nil, "lockfile save failed: " .. (err or "?") end
  return true
end

return M
