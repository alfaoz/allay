-- https/http transport. Thin adapter around httpkit so it conforms to the
-- transport interface.

local httpkit = require("httpkit")

local M = {}

function M.fetch(url)
  return httpkit.get(url)
end

return M
