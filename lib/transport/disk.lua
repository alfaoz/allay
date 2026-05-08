-- disk:// transport.
--
-- A url like "disk://foo/path/to/file" is resolved by:
--   1. Looking through attached disk drives for one whose mount point
--      contains a file or marker matching "foo".
--   2. Reading "/<mount>/path/to/file" from the matched disk.
--
-- A disk is "named foo" if either:
--   - its mount root contains a file `disk_label` whose contents are "foo"
--     (after trim), OR
--   - its mount root is itself named "foo" (e.g., /disk/, /disk1/, etc.,
--     where the marker isn't present)

local M = {}

local function trim(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

-- Find a disk by name. Returns the absolute mount path or nil.
local function find_disk(name)
  if not _G.fs then return nil, "fs API not available" end
  if not _G.peripheral then return nil, "peripheral API not available" end

  -- Iterate disk peripherals. For each, get its mount path via disk.getMountPath
  -- (CC: Tweaked specific) or fall back to checking /disk, /disk1, etc.
  if _G.disk and _G.disk.getMountPath then
    for _, side in ipairs(_G.peripheral.getNames()) do
      if _G.peripheral.getType(side) == "drive" then
        local mount = _G.disk.getMountPath(side)
        if mount then
          local label_file = mount .. "/disk_label"
          if _G.fs.exists(label_file) then
            local f = _G.fs.open(label_file, "r")
            if f then
              local label = trim(f.readAll() or "")
              f.close()
              if label == name then return mount end
            end
          end
          -- Fallback: match on mount path basename.
          local base = mount:match("([^/]+)$")
          if base == name then return mount end
        end
      end
    end
  end

  -- Final fallback: scan likely root dirs.
  for _, candidate in ipairs({"/disk", "/disk1", "/disk2", "/disk3"}) do
    if _G.fs.exists(candidate) then
      local label_file = candidate .. "/disk_label"
      if _G.fs.exists(label_file) then
        local f = _G.fs.open(label_file, "r")
        if f then
          local label = trim(f.readAll() or "")
          f.close()
          if label == name then return candidate end
        end
      end
      local base = candidate:match("([^/]+)$")
      if base == name then return candidate end
    end
  end

  return nil, "no disk named " .. name
end

function M.fetch(url)
  local rest = url:match("^disk://(.+)$")
  if not rest then
    return nil, "disk: malformed url: " .. url
  end

  local name, path = rest:match("^([^/]+)/(.*)$")
  if not name then
    return nil, "disk: url must be disk://<name>/<path>"
  end

  local mount, err = find_disk(name)
  if not mount then return nil, err end

  local full = mount .. "/" .. path
  if not _G.fs.exists(full) then
    return nil, "disk: file not found: " .. full
  end

  local f = _G.fs.open(full, "r")
  if not f then
    return nil, "disk: cannot read: " .. full
  end
  local content = f.readAll()
  f.close()
  return content
end

-- Exposed for tests.
M._find_disk = find_disk

return M
