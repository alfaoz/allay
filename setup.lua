-- allay setup helper.
--
-- Returns the package.path prefix that puts allay-installed libraries
-- and unicornpkg-translated libraries on the search path. Use:
--
--     package.path = dofile("/usr/allay/setup.lua") .. package.path
--     local hash    = require("hash")
--     local Pine3D  = require("pine3d.Pine3D")
--     local ecnet   = require("ecnet2")
--
-- Why this shape: CC: Tweaked sandboxes dofile-loaded chunks in their own
-- env where `package` is nil, so a direct `package.path = ...` inside this
-- file would fail. Returning a string keeps the caller in charge of
-- mutating their own package.path with a value of our choosing.

return "/usr/allay/lib/?.lua;/usr/allay/lib/?/init.lua;"
    .. "/lib/?.lua;/lib/?/init.lua;"
