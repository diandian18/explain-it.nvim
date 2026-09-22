local config = require("explain_it.config")
local commands = require("explain_it.commands")

local M = {}

---@param opts ExplainItConfig|nil
function M.setup(opts)
  config.setup(opts)
  commands.setup_commands()
  commands.setup_keymaps()
end

M.explain = function(...)
  return commands.explain(...)
end

M.translate = function(...)
  return commands.translate(...)
end

M.ask = function(...)
  return commands.ask(...)
end

return M
