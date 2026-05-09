-- schema: validators for the three allay file formats.
--
-- Returns (true) on valid input or (false, err) on the first violation found.
-- Validators are deliberately permissive about extra fields (forward compat)
-- and strict about types of declared fields.

local M = {}

local VALID_FILE_KINDS = {
  lib = true, bin = true, startup = true, etc = true,
  share = true, libexec = true, loadapi = true, help = true,
  raw = true,  -- used by translators for unknown unicornpkg paths
  translator = true,  -- used by translator extension packages
  provider = true,    -- used by provider extension packages
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function is_string(v) return type(v) == "string" end
local function is_table(v)  return type(v) == "table" end
local function is_list_of_strings(v)
  if type(v) ~= "table" then return false end
  for i, item in ipairs(v) do
    if type(item) ~= "string" then return false end
  end
  -- Reject keyed tables.
  local count = 0
  for _ in pairs(v) do count = count + 1 end
  return count == #v
end

-- ---------------------------------------------------------------------------
-- Package definition (allay.lua)
-- ---------------------------------------------------------------------------

function M.validate_package(pkg)
  if not is_table(pkg) then
    return false, "package: must return a table"
  end

  if not is_string(pkg.name) or pkg.name == "" then
    return false, "package: missing or invalid 'name'"
  end
  if pkg.name:find("[^%w%-_%.]") then
    return false, "package: name has invalid characters: " .. pkg.name
  end

  if not is_string(pkg.base_url) or pkg.base_url == "" then
    return false, "package: missing or invalid 'base_url'"
  end

  if not is_table(pkg.files) then
    return false, "package: missing or invalid 'files'"
  end

  local has_any_file = false
  for kind, group in pairs(pkg.files) do
    if not VALID_FILE_KINDS[kind] then
      return false, "package: unknown file kind: " .. tostring(kind)
    end
    if not is_table(group) then
      return false, string.format("package: files.%s must be a table", kind)
    end
    for src_path, dest_name in pairs(group) do
      if not is_string(src_path) then
        return false, string.format(
          "package: files.%s keys must be strings", kind)
      end
      -- A file value is either:
      --   * a string (the dest_name; content fetched from base_url + src_path)
      --   * a table { dest = "name", inline = "content" } (inline content;
      --     no fetch). Inline content is for tiny synthesized files like
      --     wrapper init.lua's that set up package.path before delegating.
      if is_string(dest_name) then
        -- ok
      elseif is_table(dest_name) then
        if not is_string(dest_name.dest) then
          return false, string.format(
            "package: files.%s.%s.dest must be a string", kind, src_path)
        end
        if not is_string(dest_name.inline) then
          return false, string.format(
            "package: files.%s.%s.inline must be a string", kind, src_path)
        end
      else
        return false, string.format(
          "package: files.%s.%s must be a dest string or { dest, inline } table",
          kind, src_path)
      end
      has_any_file = true
    end
  end

  if not has_any_file then
    return false, "package: must declare at least one file"
  end

  -- hashes: optional but recommended (TOFU otherwise)
  if pkg.hashes ~= nil then
    if not is_table(pkg.hashes) then
      return false, "package: hashes must be a table"
    end
    for src_path, hash in pairs(pkg.hashes) do
      if not is_string(src_path) or not is_string(hash) then
        return false, "package: hashes must map source paths to hex strings"
      end
      if #hash ~= 64 or hash:find("[^%x]") then
        return false, "package: hash must be 64 hex chars: " .. tostring(hash)
      end
    end
  end

  -- Optional metadata fields.
  if pkg.version ~= nil and not is_string(pkg.version) then
    return false, "package: version must be a string"
  end
  if pkg.description ~= nil and not is_string(pkg.description) then
    return false, "package: description must be a string"
  end
  if pkg.author ~= nil and not is_string(pkg.author) then
    return false, "package: author must be a string"
  end
  if pkg.license ~= nil and not is_string(pkg.license) then
    return false, "package: license must be a string"
  end

  if pkg.dependencies ~= nil and not is_list_of_strings(pkg.dependencies) then
    return false, "package: dependencies must be a list of strings"
  end
  if pkg.conflicts ~= nil and not is_list_of_strings(pkg.conflicts) then
    return false, "package: conflicts must be a list of strings"
  end

  if pkg.hooks ~= nil then
    if not is_table(pkg.hooks) then
      return false, "package: hooks must be a table"
    end
    if pkg.hooks.post_install ~= nil and not is_string(pkg.hooks.post_install) then
      return false, "package: hooks.post_install must be a string path"
    end
    if pkg.hooks.pre_remove ~= nil and not is_string(pkg.hooks.pre_remove) then
      return false, "package: hooks.pre_remove must be a string path"
    end
  end

  if pkg.post_install_message ~= nil
     and not is_string(pkg.post_install_message) then
    return false, "package: post_install_message must be a string"
  end

  return true
end

-- ---------------------------------------------------------------------------
-- Source index (index.lua)
-- ---------------------------------------------------------------------------

function M.validate_index(idx)
  if not is_table(idx) then
    return false, "index: must return a table"
  end

  if not is_string(idx.spec) or not idx.spec:match("^allay/") then
    return false, "index: missing or invalid 'spec' (must start with 'allay/')"
  end

  if idx.format ~= nil and not is_string(idx.format) then
    return false, "index: format must be a string"
  end

  if idx.name ~= nil and not is_string(idx.name) then
    return false, "index: name must be a string"
  end

  if not is_table(idx.packages) then
    return false, "index: packages must be a table"
  end

  for pkg_name, entry in pairs(idx.packages) do
    if not is_string(pkg_name) then
      return false, "index: package names must be strings"
    end
    if not is_table(entry) then
      return false, "index: each package entry must be a table"
    end
    if entry.version ~= nil and not is_string(entry.version) then
      return false, "index: package version must be a string"
    end
    if entry.description ~= nil and not is_string(entry.description) then
      return false, "index: package description must be a string"
    end
    if entry.file ~= nil and not is_string(entry.file) then
      return false, "index: package file path must be a string"
    end
  end

  return true
end

-- ---------------------------------------------------------------------------
-- Lockfile (allay.lock)
-- ---------------------------------------------------------------------------

function M.validate_lockfile(lock)
  if not is_table(lock) then
    return false, "lockfile: must be a table"
  end

  if not is_string(lock.spec) or not lock.spec:match("^allay/") then
    return false, "lockfile: missing or invalid 'spec'"
  end

  if not is_table(lock.packages) then
    return false, "lockfile: packages must be a table"
  end

  for name, entry in pairs(lock.packages) do
    if not is_string(name) then
      return false, "lockfile: package names must be strings"
    end
    if not is_table(entry) then
      return false, "lockfile: package entries must be tables"
    end
    if not is_string(entry.version) then
      return false, "lockfile: " .. name .. ": version must be a string"
    end
    if entry.description ~= nil and not is_string(entry.description) then
      return false, "lockfile: " .. name .. ": description must be a string"
    end
    if entry.source ~= nil and not is_string(entry.source) then
      return false, "lockfile: " .. name .. ": source must be a string"
    end
    if entry.manual ~= nil and type(entry.manual) ~= "boolean" then
      return false, "lockfile: " .. name .. ": manual must be a boolean"
    end
    if entry.pinned ~= nil and type(entry.pinned) ~= "boolean" then
      return false, "lockfile: " .. name .. ": pinned must be a boolean"
    end
    if entry.files ~= nil then
      if not is_table(entry.files) then
        return false, "lockfile: " .. name .. ": files must be a list"
      end
      for _, f in ipairs(entry.files) do
        if not is_table(f) or not is_string(f.dest) then
          return false, "lockfile: " .. name .. ": file entries malformed"
        end
        if f.sha256 ~= nil and not is_string(f.sha256) then
          return false, "lockfile: " .. name .. ": file sha256 must be string"
        end
      end
    end
    if entry.dependencies ~= nil and not is_list_of_strings(entry.dependencies) then
      return false, "lockfile: " .. name .. ": dependencies must be string list"
    end
    if entry.dependents ~= nil and not is_list_of_strings(entry.dependents) then
      return false, "lockfile: " .. name .. ": dependents must be string list"
    end
  end

  return true
end

return M
