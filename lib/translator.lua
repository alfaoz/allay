-- translator: load and apply format translators for non-allay sources.
--
-- A translator is a Lua module installed at /usr/allay/translators/<id>.lua
-- that exports:
--   M.format_name        -- the source.format string this translator handles
--   M.translate(raw)     -- (translated_pkg, err)
--
-- Sources that declare a non-allay `format` field route fetched package
-- definitions through the matching translator before allay's schema
-- validator runs. This is how unicornpkg packages install through allay
-- without a separate codepath in the resolver.

local M = {}

M.TRANSLATOR_DIR = "/usr/allay/translators"

local cache = {}

-- The translator file name comes from the part of the format string before
-- the first slash, so "unicornpkg/v1.0.0" maps to unicornpkg.lua.
local function translator_path(format)
  local short = format:match("^([^/]+)") or format
  return M.TRANSLATOR_DIR .. "/" .. short .. ".lua"
end

-- Load a translator by format string. Returns (translator, err).
function M.load(format)
  if cache[format] then return cache[format] end

  local path = translator_path(format)
  if _G.fs and _G.fs.exists and not _G.fs.exists(path) then
    return nil, "translator not installed for format: " .. format
      .. " (expected at " .. path .. ")"
  end

  local fn, load_err = loadfile(path)
  if not fn then
    return nil, "translator load failed: " .. (load_err or "?")
  end

  local ok, value = pcall(fn)
  if not ok then
    return nil, "translator eval failed: " .. tostring(value)
  end
  if type(value) ~= "table" or type(value.translate) ~= "function" then
    return nil, "translator invalid: " .. path .. " missing M.translate"
  end

  cache[format] = value
  return value
end

-- Translate a raw package table for a given format.
-- Returns (translated, err).
function M.translate(format, raw)
  local t, err = M.load(format)
  if not t then return nil, err end
  return t.translate(raw)
end

-- Reset the in-process cache. Used by tests.
function M.reset()
  cache = {}
end

return M
