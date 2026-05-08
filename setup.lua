-- allay setup helper.
--
-- Add allay-installed libraries and unicornpkg-translated libraries to the
-- caller's package.path. Use it as the first line of any program (or REPL
-- session) that requires libraries installed via allay:
--
--     dofile("/usr/allay/setup.lua")
--     local hash    = require("hash")
--     local Pine3D  = require("pine3d.Pine3D")
--     local ecnet   = require("ecnet2")
--
-- Why dofile and not require: CC: Tweaked builds a fresh package table for
-- each program, so a global package.path patch can't propagate. dofile runs
-- the file in the calling program's environment, so the path mutation is
-- local to the caller and is picked up by subsequent require() calls.

package.path = "/usr/allay/lib/?.lua;/usr/allay/lib/?/init.lua;"
            .. "/lib/?.lua;/lib/?/init.lua;"
            .. package.path
