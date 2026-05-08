-- github: greedy bundle install for arbitrary GitHub repos.
--
-- For when no source has packaged something but a user just wants to
-- install it. We walk the upstream repo via the GitHub trees API,
-- categorize files heuristically, scan for `require()` calls to detect
-- declared dependencies, and synthesize an allay package definition that
-- the normal installer pipeline can consume.
--
-- This is a pragmatic fallback. It is not as good as a hand-curated
-- package definition: dep detection is a regex over source text, and
-- file categorization follows directory name conventions. The output
-- is always shown to the user before any files are written.

local M = {}

local transport = require("transport")

-- Default identifier prefix for the synthetic source we attach to bundled
-- packages. Used so the lockfile can record where a package came from and
-- so updates re-fetch from the same origin.
M.SCHEME = "gh:"

-- ---------------------------------------------------------------------------
-- Parsing
-- ---------------------------------------------------------------------------

-- Parse "gh:user/repo[@ref]", "user/repo[@ref]", or a full URL.
-- Returns { user = ..., repo = ..., ref = ... } on success.
function M.parse(spec)
  if type(spec) ~= "string" or spec == "" then
    return nil, "github: empty spec"
  end

  -- Strip the gh: prefix if present.
  if spec:sub(1, 3) == "gh:" then
    spec = spec:sub(4)
  end

  -- user/repo@ref form.
  local user, repo, ref = spec:match("^([%w%-%.]+)/([%w%-%._]+)@([%w%-%./]+)$")
  if user then
    return { user = user, repo = repo, ref = ref }
  end

  -- user/repo (no ref) — caller will probe default branches.
  user, repo = spec:match("^([%w%-%.]+)/([%w%-%._]+)$")
  if user then
    return { user = user, repo = repo, ref = nil }
  end

  return nil, "github: cannot parse: " .. spec
end

-- ---------------------------------------------------------------------------
-- Tree fetching
-- ---------------------------------------------------------------------------

-- Build the GitHub trees API URL for recursive listing.
function M.tree_url(user, repo, ref)
  return string.format(
    "https://api.github.com/repos/%s/%s/git/trees/%s?recursive=1",
    user, repo, ref or "main")
end

-- Build the raw.githubusercontent.com URL prefix for a repo at a given ref.
function M.raw_base(user, repo, ref)
  return string.format(
    "https://raw.githubusercontent.com/%s/%s/%s",
    user, repo, ref or "main")
end

-- Lightweight extractor for the trees API JSON response.
-- We don't pull in a full JSON parser. The response shape is:
--   { "tree": [ { "path": "...", "type": "blob"|"tree", "size": N }, ... ],
--     "truncated": true|false }
-- We pull each entry's path/type/size with regex. Returns (entries, truncated).
local function parse_tree_response(body)
  local entries = {}
  for entry in body:gmatch('{[^}]-"path"%s*:[^}]-}') do
    local path = entry:match('"path"%s*:%s*"([^"]+)"')
    local entry_type = entry:match('"type"%s*:%s*"([^"]+)"')
    local size = tonumber(entry:match('"size"%s*:%s*(%d+)'))
    if path and entry_type then
      table.insert(entries, {
        path = path,
        type = entry_type,
        size = size or 0,
      })
    end
  end
  -- Detect the "truncated" flag at the top level. GitHub sets it when the
  -- tree is too large to return in full (>100k entries or >7MB). For our
  -- use case this is unrecoverable: a partial bundle would be wrong.
  local truncated = body:match('"truncated"%s*:%s*true') ~= nil
  return entries, truncated
end

-- Inspect a tree-API failure response for a clear error. GitHub's rate
-- limit returns HTTP 403 with a body explaining the cause; we look for it
-- so users get a useful message instead of just "HTTP 403".
local function rate_limit_hint(err)
  if not err then return nil end
  local s = tostring(err)
  if s:find("rate limit") or s:find("API rate") then
    return "github: API rate limit exceeded (60/hr unauthenticated). "
        .. "Wait or set GITHUB_TOKEN env var."
  end
  return nil
end

-- Fetch the file tree of a repo. Returns (entries, ref, err).
-- If `ref` was nil, probes "main" then "master".
function M.fetch_tree(user, repo, ref)
  local refs_to_try = ref and { ref } or { "main", "master" }
  local last_err
  for _, try_ref in ipairs(refs_to_try) do
    local body, err = transport.fetch(M.tree_url(user, repo, try_ref))
    if body then
      local entries, truncated = parse_tree_response(body)
      if truncated then
        return nil, nil,
          "github: trees response was truncated (repo too large). "
          .. "Hand-package this one instead of using gh: bundle install."
      end
      if #entries > 0 then
        return entries, try_ref
      end
      last_err = "github: empty tree (wrong ref?)"
    else
      local hint = rate_limit_hint(err)
      if hint then return nil, nil, hint end
      last_err = err
    end
  end
  local hint = rate_limit_hint(last_err)
  if hint then return nil, nil, hint end
  return nil, nil, last_err or "github: failed to fetch tree"
end

-- ---------------------------------------------------------------------------
-- Builtin name tables
-- ---------------------------------------------------------------------------

-- CC: Tweaked global APIs. require() of these means "use the CC built-in".
local CC_BUILTINS = {
  turtle = true, peripheral = true, fs = true, term = true,
  colors = true, colours = true, paintutils = true, parallel = true,
  http = true, redstone = true, rs = true, rednet = true, settings = true,
  textutils = true, vector = true, window = true, gps = true, disk = true,
  keys = true, multishell = true, os = true, shell = true, help = true,
  commands = true, pocket = true, exception = true, expect = true,
  io = true, write = true, read = true,
}

-- Lua standard library modules.
local LUA_BUILTINS = {
  string = true, table = true, math = true, io = true, os = true,
  coroutine = true, debug = true, package = true,
  bit32 = true, bit = true, utf8 = true,
}

-- The cc.* namespace (cc.expect, cc.audio, cc.completion, etc.) ships
-- with CC: Tweaked. Detect by prefix.
local function is_cc_module(name)
  return name == "cc" or name:sub(1, 3) == "cc."
end

function M.is_cc_builtin(name)
  return CC_BUILTINS[name] == true or is_cc_module(name)
end

function M.is_lua_builtin(name)
  return LUA_BUILTINS[name] == true
end

-- ---------------------------------------------------------------------------
-- Require scanning
-- ---------------------------------------------------------------------------

-- Scan a Lua source string for require/dofile/os.loadAPI calls.
-- Returns a list of unique referenced names.
function M.scan_requires(source)
  local seen, refs = {}, {}
  local function add(name)
    if not name or name == "" then return end
    -- Normalize to top-level module (strip trailing .submodule).
    local top = name:match("^([^.]+)") or name
    -- Skip dynamic-require placeholders (like the libFolder pattern).
    -- Names with all-uppercase or with concat chars suggest variables.
    if top:find("[^%w%-_%.]") then return end
    if not seen[top] then
      seen[top] = true
      table.insert(refs, top)
    end
  end

  -- require("name") / require('name') with optional whitespace and parens.
  for name in source:gmatch('require%s*%(?%s*["\']([^"\']+)["\']') do
    add(name)
  end
  -- require "name" without parens.
  for name in source:gmatch('require%s+["\']([^"\']+)["\']') do
    add(name)
  end
  -- dofile("path") — only takes the basename for matching purposes.
  for path in source:gmatch('dofile%s*%(?%s*["\']([^"\']+)["\']') do
    local base = path:match("([^/]+)%.lua$") or path:match("([^/]+)$")
    if base then add(base) end
  end
  -- os.loadAPI("path") — same idea.
  for path in source:gmatch('os%.loadAPI%s*%(?%s*["\']([^"\']+)["\']') do
    local base = path:match("([^/]+)%.lua$") or path:match("([^/]+)$")
    if base then add(base) end
  end

  return refs
end

-- ---------------------------------------------------------------------------
-- File categorization
-- ---------------------------------------------------------------------------

-- Classify a single file path as a kind (lib/bin/startup/share) or "skip".
-- The repo_name is the lowercase package name we're synthesizing for.
function M.categorize(path, repo_name)
  local lower = path:lower()

  -- Skip clutter.
  if lower:match("readme") or lower:match("license") or lower:match("changelog") then
    return "skip"
  end
  if lower:match("%.md$") or lower:match("%.txt$") or lower:match("%.rst$") then
    return "skip"
  end
  if lower:match("^%.") or lower:match("^%.vscode/") or lower:match("^%.github/") then
    return "skip"
  end
  if lower:match("/test[s]?/") or lower:match("^test[s]?/") or lower:match("_test%.") then
    return "skip"
  end
  if lower:match("/spec[s]?/") or lower:match("^spec[s]?/") or lower:match("_spec%.") then
    return "skip"
  end
  if lower:match("/example[s]?/") or lower:match("^example[s]?/") then
    return "skip"
  end
  if lower:match("/build[s]?/") or lower:match("^build[s]?/") then
    return "skip"
  end
  if lower:match("/minified/") or lower:match("^minified/")
     or lower:match("%-minified%.lua$") then
    return "skip"
  end
  if lower:match("howlfile") or lower:match("makefile") then
    return "skip"
  end

  -- Bin scripts.
  if lower:match("^bin/") then return "bin" end

  -- Startup scripts.
  if lower:match("^startup/") then return "startup" end

  -- Lua source files default to lib.
  if lower:match("%.lua$") then return "lib" end

  -- Images and data files go to share.
  if lower:match("%.nfp$") or lower:match("%.nft$") or lower:match("%.bimg$")
     or lower:match("%.png$") then
    return "share"
  end

  -- Anything else: skip.
  return "skip"
end

-- Build the dest_name for a file based on its kind and source path.
-- For lib files, we preserve the relative path so internal requires work.
local function dest_name_for(kind, src_path)
  if kind == "bin" then
    -- bin/foo.lua → foo
    return (src_path:match("^bin/(.+)%.lua$")) or src_path
  end
  if kind == "startup" then
    return (src_path:match("^startup/(.+)$")) or src_path
  end
  -- lib / share: preserve relative path under the package's dir.
  return src_path
end

-- ---------------------------------------------------------------------------
-- Synthesize an allay package definition
-- ---------------------------------------------------------------------------

-- Walk a tree, classify each file, and produce an allay package table
-- ready to feed to the installer. Optionally, scan source content for
-- require() to detect external dependencies.
--
-- `external_resolver(name)` is an optional function that returns true if
-- `name` is a known package in any configured source. Names returned true
-- are added to the synthesized package's dependencies.
--
-- Returns (pkg, info) where info has counters and unresolved-deps list.
-- info.fetch_cache is a {src_path -> body} map of every .lua file we
-- fetched during scanning, so callers can avoid re-fetching during install.
function M.synthesize(user, repo, ref, tree, opts)
  opts = opts or {}
  local pkg_name = opts.name or repo:lower():gsub("[^%w%-_%.]", "-")
  local base_url = M.raw_base(user, repo, ref)

  -- 1. Detect the "files inside <pkgname>/ subdir" pattern. Many CC libs
  -- organize their module files under a subdirectory matching the lib's
  -- name (ccryptolib/random.lua, etc.). If the dominant Lua subdir matches
  -- our package name, strip that prefix when building dest_names so files
  -- land at /usr/allay/lib/<pkg>/random.lua instead of
  -- /usr/allay/lib/<pkg>/<pkg>/random.lua.
  local subdir_counts = {}
  local total_lua = 0
  for _, entry in ipairs(tree) do
    if entry.type == "blob" and entry.path:lower():match("%.lua$") then
      local subdir = entry.path:match("^([^/]+)/")
      if subdir then
        subdir_counts[subdir:lower()] = (subdir_counts[subdir:lower()] or 0) + 1
        total_lua = total_lua + 1
      end
    end
  end
  local strip_prefix = nil
  local matches = subdir_counts[pkg_name:lower()] or 0
  if total_lua > 0 and matches / total_lua > 0.5 then
    -- Find the actual case-preserved prefix to strip.
    for _, entry in ipairs(tree) do
      local subdir = entry.path:match("^([^/]+)/")
      if subdir and subdir:lower() == pkg_name:lower() then
        strip_prefix = subdir .. "/"
        break
      end
    end
  end

  -- 2. Categorize files.
  local kinds = { lib = {}, bin = {}, startup = {}, share = {} }
  local skipped = {}
  local lua_blobs = {}  -- src_path → kind, for require-scanning

  for _, entry in ipairs(tree) do
    if entry.type == "blob" then
      local kind = M.categorize(entry.path, pkg_name)
      if kind == "skip" then
        table.insert(skipped, entry.path)
      else
        local dest = dest_name_for(kind, entry.path)
        if strip_prefix and kind == "lib"
           and entry.path:sub(1, #strip_prefix) == strip_prefix then
          dest = entry.path:sub(#strip_prefix + 1)
        end
        kinds[kind][entry.path] = dest
        if entry.path:lower():match("%.lua$") then
          lua_blobs[entry.path] = kind
        end
      end
    end
  end

  -- 2. Optionally scan content for require() calls. We cache every fetched
  -- body so the caller can hand the bodies to the installer and skip the
  -- second fetch pass.
  local fetch_cache = {}
  local detected_deps, unresolved = {}, {}
  if opts.scan_requires and opts.fetch_file then
    local sibling_names = {}
    for src in pairs(lua_blobs) do
      local base = src:match("([^/]+)%.lua$")
      if base then sibling_names[base] = true end
    end

    local seen_refs = {}
    for src in pairs(lua_blobs) do
      local body = opts.fetch_file(src)
      if body then
        fetch_cache[src] = body
        for _, name in ipairs(M.scan_requires(body)) do
          if not seen_refs[name] then
            seen_refs[name] = true
            if M.is_cc_builtin(name) or M.is_lua_builtin(name) then
              -- Skip.
            elseif sibling_names[name] then
              -- Internal, already bundled.
            elseif name == pkg_name then
              -- Self.
            else
              if opts.external_resolver and opts.external_resolver(name) then
                table.insert(detected_deps, name)
              else
                table.insert(unresolved, name)
              end
            end
          end
        end
      end
    end
  end

  -- 4. Drop empty kind tables; allay's schema requires at least one file.
  local files_out = {}
  for kind, group in pairs(kinds) do
    if next(group) then files_out[kind] = group end
  end

  local total_files = 0
  for _, group in pairs(files_out) do
    for _ in pairs(group) do total_files = total_files + 1 end
  end

  local pkg = {
    name = pkg_name,
    version = ref or "main",
    description = string.format("Bundled from %s/%s@%s via allay's gh: greedy installer.",
      user, repo, ref or "main"),
    base_url = base_url,
    files = files_out,
    hashes = {},
  }
  if #detected_deps > 0 then
    pkg.dependencies = detected_deps
  end

  local info = {
    total_files = total_files,
    skipped = skipped,
    detected_deps = detected_deps,
    unresolved = unresolved,
    bundled = true,
    repo = string.format("%s/%s", user, repo),
    ref = ref or "main",
    fetch_cache = fetch_cache,
  }

  return pkg, info
end

-- ---------------------------------------------------------------------------
-- High-level: spec → synthesized package + source
-- ---------------------------------------------------------------------------

-- Take a "gh:user/repo[@ref]" spec and produce a synthesized package + source
-- ready to feed to the resolver/installer.
--
-- known_packages: a set of names → true that should be treated as resolvable
--                 external dependencies (typically: every package name across
--                 the user's configured sources).
--
-- Returns (pkg, source, info, err).
function M.bundle(spec, known_packages)
  local parsed, perr = M.parse(spec)
  if not parsed then return nil, nil, nil, perr end

  local entries, ref, fetch_err = M.fetch_tree(
    parsed.user, parsed.repo, parsed.ref)
  if not entries then return nil, nil, nil, fetch_err end

  known_packages = known_packages or {}
  local pkg, info = M.synthesize(parsed.user, parsed.repo, ref, entries, {
    scan_requires = true,
    fetch_file = function(p)
      local url = M.raw_base(parsed.user, parsed.repo, ref) .. "/" .. p
      return (transport.fetch(url))
    end,
    external_resolver = function(n)
      return known_packages[n] == true
    end,
  })

  local source = {
    id = M.SCHEME .. parsed.user .. "/" .. parsed.repo,
    url = M.raw_base(parsed.user, parsed.repo, ref),
    bundle = true,
  }
  return pkg, source, info
end

return M
