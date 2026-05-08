-- package: loading and parsing allay.lua files.
--
-- A package definition is a Lua file that returns a table. We sandbox the
-- evaluation so a malicious package can't reach into our state during load.

local M = {}

local schema = require("schema")
local pathkit = require("pathkit")

-- Sandboxed environment for loading package files. Only safe built-ins.
local function sandbox_env()
  return {
    -- Allow basic data construction.
    string = string,
    table = table,
    math = math,
    -- pcall/error are useful for packages that compute things at load time.
    pcall = pcall,
    error = error,
    type = type,
    tostring = tostring,
    tonumber = tonumber,
    pairs = pairs,
    ipairs = ipairs,
    next = next,
    select = select,
  }
end

-- Load a package definition from raw Lua source. Returns (pkg, err).
function M.load_string(source, name)
  local fn, parse_err = load(source, name or "package", "t", sandbox_env())
  if not fn then
    return nil, "package: parse error: " .. (parse_err or "?")
  end
  local ok, value = pcall(fn)
  if not ok then
    return nil, "package: eval error: " .. tostring(value)
  end
  if type(value) ~= "table" then
    return nil, "package: must return a table"
  end
  local valid, err = schema.validate_package(value)
  if not valid then return nil, err end
  return value
end

-- Load a package definition from a file path.
function M.load_file(path)
  local content, err = pathkit.read(path)
  if not content then return nil, err end
  return M.load_string(content, path)
end

-- Compute the destination path on disk for a package's file given its
-- declared kind and dest name.
function M.dest_path(pkg_name, kind, dest_name)
  if kind == "lib" then
    return "/usr/allay/lib/" .. pkg_name .. "/" .. dest_name
  elseif kind == "bin" then
    return "/bin/" .. dest_name .. ".lua"
  elseif kind == "startup" then
    return "/startup/" .. pkg_name .. "_" .. dest_name
  elseif kind == "etc" then
    return "/etc/" .. pkg_name .. "/" .. dest_name
  elseif kind == "share" then
    return "/usr/share/" .. pkg_name .. "/" .. dest_name
  elseif kind == "libexec" then
    return "/usr/libexec/" .. pkg_name .. "/" .. dest_name
  elseif kind == "loadapi" then
    return "/usr/libLoadAPI/" .. pkg_name .. "/" .. dest_name
  elseif kind == "help" then
    return "/usr/share/help/" .. pkg_name .. "/" .. dest_name
  elseif kind == "translator" then
    return "/usr/allay/translators/" .. dest_name
  elseif kind == "provider" then
    return "/usr/allay/providers/" .. dest_name
  elseif kind == "raw" then
    -- raw paths are absolute, declared by the package
    return dest_name:sub(1, 1) == "/" and dest_name or ("/" .. dest_name)
  end
  error("package.dest_path: unknown kind: " .. tostring(kind))
end

-- Iterate over all file entries in a package.
-- Each entry has: kind, src_path, dest_name, dest_path, inline (or nil).
-- A nil `inline` means fetch from base_url; a string means use the inline
-- content directly (for synthesized wrappers).
function M.iter_files(pkg)
  local entries = {}
  for kind, group in pairs(pkg.files) do
    for src_path, value in pairs(group) do
      local dest_name, inline
      if type(value) == "string" then
        dest_name = value
      else
        dest_name = value.dest
        inline = value.inline
      end
      table.insert(entries, {
        kind = kind,
        src_path = src_path,
        dest_name = dest_name,
        dest_path = M.dest_path(pkg.name, kind, dest_name),
        inline = inline,
      })
    end
  end
  table.sort(entries, function(a, b) return a.dest_path < b.dest_path end)
  return entries
end

return M
