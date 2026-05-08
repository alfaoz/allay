-- resolver: finds packages across sources and walks dependency graphs.
--
-- Strategy:
--   1. For each requested package, walk the dependency graph.
--   2. For each name in the graph, find it in the first source that has
--      it (sources are tried in their configured order).
--   3. Stop recursion when a package is already installed (skip), is
--      already in the resolution set (already pulled), or is being
--      currently resolved (cycle).
--   4. Return the resolved list in topological order (deps first).

local M = {}

local source_mod = require("source")
local index_mod = require("index")
local transport = require("transport")
local pkg_mod = require("pkg")

-- Find a package in a list of sources. Returns (pkg_def, source, err).
-- The package def is parsed and validated; ready for use.
local function find_package(name, sources, opts)
  opts = opts or {}
  local errors = {}

  -- Synthesized packages (e.g. gh: bundles built outside the source layer)
  -- short-circuit the lookup. Caller pre-populates opts.synthesized so the
  -- resolver can produce plans involving bundled packages.
  if opts.synthesized and opts.synthesized[name] then
    local entry = opts.synthesized[name]
    return entry.pkg, entry.source
  end

  -- If a source qualifier was given (alfaoz:hash), restrict to that source.
  local qualified_source, plain_name = name:match("^([^:]+):(.+)$")
  local search_sources = sources
  if qualified_source then
    search_sources = {}
    for _, s in ipairs(sources) do
      if s.id == qualified_source or s.url == qualified_source then
        table.insert(search_sources, s)
        break
      end
    end
    if #search_sources == 0 then
      return nil, nil, "source not configured: " .. qualified_source
    end
    name = plain_name
  end

  for _, source in ipairs(search_sources) do
    -- Try the index first.
    local idx, idx_err = index_mod.fetch(source)
    local file_path

    if idx then
      local entry = index_mod.lookup(idx, name)
      if entry then
        file_path = entry.file or (name .. ".lua")
      else
        -- Indexed source without this package; skip.
        goto continue
      end
    elseif idx_err == "blind" then
      -- Blind source: try by filename directly.
      file_path = name .. ".lua"
    else
      table.insert(errors, string.format("%s: %s", source.id, idx_err or "unknown error"))
      goto continue
    end

    do
      local body, fetch_err = transport.fetch(source_mod.file_url(source, file_path))
      if body then
        local pkg, parse_err = pkg_mod.load_string(body, name)
        if pkg then
          return pkg, source
        else
          table.insert(errors, string.format("%s: parse error in %s: %s",
            source.id, file_path, parse_err))
        end
      else
        if fetch_err and not fetch_err:find("404") and not fetch_err:find("not found") then
          table.insert(errors, string.format("%s: %s", source.id, fetch_err))
        end
        -- 404 from a blind source = just not here, try next source.
      end
    end

    ::continue::
  end

  if #errors > 0 then
    return nil, nil, "package not found: " .. name .. " (" .. table.concat(errors, "; ") .. ")"
  end
  return nil, nil, "package not found in any source: " .. name
end

M.find_package = find_package

-- Resolve a set of requested packages into a flat installation plan.
-- requested: list of package names (may include @version for pinning,
--            though we don't enforce version constraints here).
-- lockfile:  current lockfile (for skipping already-installed)
-- sources:   list of sources to search
-- opts:
--   reinstall: if true, include already-installed packages in the plan
--   force_reresolve_deps: include deps even if installed (for upgrades)
--
-- Returns (plan, err) where plan is a list of:
--   { name, package, source, requested_by, manual }
-- in topological order (deps before dependents).
function M.resolve(requested, lockfile, sources, opts)
  opts = opts or {}
  local plan = {}              -- list (ordered)
  local seen = {}              -- name -> position in plan (or "in-progress")
  local installed = lockfile and lockfile.packages or {}

  local function visit(name, requested_by, is_manual)
    -- Strip @version pin for resolution; pinning is recorded in the plan.
    local plain_name, pin_version = name:match("^(.-)@(.+)$")
    if not plain_name then plain_name = name end

    if seen[plain_name] == "in-progress" then
      return nil, "dependency cycle detected at: " .. plain_name
    end
    if seen[plain_name] then
      -- Already in plan; mark as also-manual if this top-level invocation marks it.
      if is_manual then plan[seen[plain_name]].manual = true end
      return true
    end

    -- Skip if installed and we're not reinstalling.
    if installed[plain_name] and not opts.reinstall then
      if is_manual then
        -- User explicitly asked for an already-installed package; just
        -- promote to manual if it was previously auto.
        if installed[plain_name].manual == false then
          installed[plain_name].manual = true
        end
      end
      return true
    end

    seen[plain_name] = "in-progress"

    local pkg, source, err = find_package(plain_name, sources, opts)
    if not pkg then return nil, err end

    -- Visit dependencies first.
    for _, dep_name in ipairs(pkg.dependencies or {}) do
      local ok, dep_err = visit(dep_name, plain_name, false)
      if not ok then return nil, dep_err end
    end

    -- Now add this package to the plan. Pull through the optional
    -- fetch_cache from synthesized entries (gh: bundle path) so the
    -- installer doesn't re-fetch what we already pulled during scan.
    local fetch_cache
    if opts.synthesized and opts.synthesized[plain_name] then
      fetch_cache = opts.synthesized[plain_name].fetch_cache
    end

    table.insert(plan, {
      name = plain_name,
      package = pkg,
      source = source,
      requested_by = requested_by,
      manual = is_manual,
      pin_version = pin_version,
      fetch_cache = fetch_cache,
    })
    seen[plain_name] = #plan
    return true
  end

  for _, name in ipairs(requested) do
    local ok, err = visit(name, nil, true)
    if not ok then return nil, err end
  end

  return plan
end

-- Check that no packages in the plan conflict with each other (declared
-- conflicts) or with currently installed packages.
function M.check_conflicts(plan, lockfile)
  local in_plan = {}
  for _, item in ipairs(plan) do in_plan[item.name] = true end

  local installed = (lockfile and lockfile.packages) or {}

  for _, item in ipairs(plan) do
    for _, conflict in ipairs(item.package.conflicts or {}) do
      if in_plan[conflict] then
        return false, string.format(
          "%s conflicts with %s (both in install plan)",
          item.name, conflict)
      end
      if installed[conflict] then
        return false, string.format(
          "%s conflicts with installed package %s",
          item.name, conflict)
      end
    end
  end

  -- File path conflicts.
  local owners = {}
  for name, entry in pairs(installed) do
    if entry.files then
      for _, f in ipairs(entry.files) do owners[f.dest] = name end
    end
  end
  for _, item in ipairs(plan) do
    if not in_plan[item.name] then  -- shouldn't happen
    else
      local pkg = item.package
      for _, fileinfo in ipairs(pkg_mod.iter_files(pkg)) do
        local existing = owners[fileinfo.dest_path]
        if existing and existing ~= item.name then
          return false, string.format(
            "%s would install %s, owned by %s",
            item.name, fileinfo.dest_path, existing)
        end
        owners[fileinfo.dest_path] = item.name
      end
    end
  end

  return true
end

return M
