-- Run every test file in this directory, plus the lualibs tests.
local tests = {
  -- foundation libs (lualibs/tests)
  { dir = "../../lualibs/tests", name = "hash_test" },
  { dir = "../../lualibs/tests", name = "pathkit_test" },
  { dir = "../../lualibs/tests", name = "log_test" },
  { dir = "../../lualibs/tests", name = "httpkit_test" },
  { dir = "../../lualibs/tests", name = "argparse_test" },
  -- allay-specific tests (this dir)
  { dir = ".", name = "schema_test" },
  { dir = ".", name = "lockfile_test" },
  { dir = ".", name = "source_test" },
  { dir = ".", name = "translator_test" },
  { dir = ".", name = "resolver_test" },
  { dir = ".", name = "installer_test" },
  { dir = ".", name = "cli_test" },
  { dir = ".", name = "github_test" },
}

local total_pass, total_fail = 0, 0

for _, t in ipairs(tests) do
  print("=== " .. t.name .. " ===")
  local cmd = string.format("cd %s && lua %s.lua 2>&1", t.dir, t.name)
  local h = io.popen(cmd)
  local out = h:read("*a")
  h:close()
  io.write(out)
  local pass, total = out:match("(%d+)/(%d+) tests passed")
  if pass and total then
    total_pass = total_pass + tonumber(pass)
    total_fail = total_fail + (tonumber(total) - tonumber(pass))
  end
  print()
end

print("=========================================")
print(string.format("ALL TESTS: %d passed, %d failed", total_pass, total_fail))
if total_fail > 0 then os.exit(1) end
