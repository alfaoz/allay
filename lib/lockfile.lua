-- lockfile: reading and writing /var/allay/allay.lock.
--
-- The lockfile is the source of truth for what's installed. It records each
-- installed package's version, source, files (with hashes), dependencies,
-- and dependents. Writes are atomic.

local M = {}

local schema = require("schema")
local pathkit = require("pathkit")

M.LOCKFILE_PATH = "/var/allay/allay.lock"
M.SPEC = "allay/v1.0.0"

-- Build a fresh empty lockfile.
function M.empty()
  return {
    spec = M.SPEC,
    packages = {},
  }
end

-- Read the lockfile from disk. If missing, returns an empty lockfile.
-- Returns (lockfile, err).
function M.load(path)
  path = path or M.LOCKFILE_PATH
  if not pathkit.exists(path) then
    return M.empty()
  end
  local content, err = pathkit.read(path)
  if err then return nil, err end

  local fn, parse_err = load("return " .. content, "lockfile", "t", {})
  if not fn then
    return nil, "lockfile: parse error: " .. (parse_err or "?")
  end
  local ok, value = pcall(fn)
  if not ok or type(value) ~= "table" then
    return nil, "lockfile: did not parse to a table"
  end

  local valid, schema_err = schema.validate_lockfile(value)
  if not valid then return nil, schema_err end
  return value
end

-- Serialize a lockfile to a Lua table literal.
local function serialize_value(v, indent)
  indent = indent or ""
  local t = type(v)
  if t == "string" then
    return string.format("%q", v)
  elseif t == "number" or t == "boolean" or t == "nil" then
    return tostring(v)
  elseif t == "table" then
    local lines = { "{" }
    local inner = indent .. "  "

    -- Sort keys for stable output.
    local keys = {}
    for k, _ in pairs(v) do table.insert(keys, k) end
    table.sort(keys, function(a, b)
      if type(a) ~= type(b) then return type(a) < type(b) end
      return tostring(a) < tostring(b)
    end)

    -- Detect array-shaped tables (1..n consecutive integer keys).
    local is_array = #keys > 0
    for i, k in ipairs(keys) do
      if k ~= i then is_array = false; break end
    end

    for _, k in ipairs(keys) do
      local val = v[k]
      local key_str
      if is_array then
        key_str = ""
      elseif type(k) == "string" and k:match("^[%a_][%w_]*$") then
        key_str = k .. " = "
      else
        key_str = "[" .. serialize_value(k, inner) .. "] = "
      end
      table.insert(lines, inner .. key_str .. serialize_value(val, inner) .. ",")
    end
    table.insert(lines, indent .. "}")
    return table.concat(lines, "\n")
  end
  error("serialize: unsupported type: " .. t)
end

-- Write a lockfile to disk atomically.
function M.save(lockfile, path)
  path = path or M.LOCKFILE_PATH
  local valid, err = schema.validate_lockfile(lockfile)
  if not valid then return nil, err end
  local serialized = serialize_value(lockfile) .. "\n"
  return pathkit.write_atomic(path, serialized)
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

function M.is_installed(lockfile, name)
  return lockfile.packages[name] ~= nil
end

function M.installed_packages(lockfile)
  local list = {}
  for name, entry in pairs(lockfile.packages) do
    table.insert(list, { name = name, entry = entry })
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

-- Find all installed packages that are auto-installed (manual=false) and
-- have no remaining dependents. These are removal candidates after orphan
-- cleanup.
function M.orphans(lockfile)
  local orphans = {}
  for name, entry in pairs(lockfile.packages) do
    if entry.manual == false then
      local dependents = entry.dependents or {}
      if #dependents == 0 then
        table.insert(orphans, name)
      end
    end
  end
  table.sort(orphans)
  return orphans
end

-- Find which installed package owns a given destination path. Returns the
-- package name or nil.
function M.owner_of(lockfile, dest_path)
  for name, entry in pairs(lockfile.packages) do
    if entry.files then
      for _, f in ipairs(entry.files) do
        if f.dest == dest_path then return name end
      end
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Mutations
-- ---------------------------------------------------------------------------

-- Insert a package entry into the lockfile.
function M.insert(lockfile, name, entry)
  lockfile.packages[name] = entry
  -- Update dependents lists for each declared dep.
  for _, dep in ipairs(entry.dependencies or {}) do
    local dep_entry = lockfile.packages[dep]
    if dep_entry then
      dep_entry.dependents = dep_entry.dependents or {}
      local found = false
      for _, d in ipairs(dep_entry.dependents) do
        if d == name then found = true; break end
      end
      if not found then table.insert(dep_entry.dependents, name) end
    end
  end
  return lockfile
end

-- Remove a package from the lockfile and clean up reverse-dep entries.
function M.remove(lockfile, name)
  local entry = lockfile.packages[name]
  if not entry then return lockfile, "not installed: " .. name end

  for _, dep in ipairs(entry.dependencies or {}) do
    local dep_entry = lockfile.packages[dep]
    if dep_entry and dep_entry.dependents then
      local new_deps = {}
      for _, d in ipairs(dep_entry.dependents) do
        if d ~= name then table.insert(new_deps, d) end
      end
      dep_entry.dependents = new_deps
    end
  end

  lockfile.packages[name] = nil
  return lockfile
end

return M
