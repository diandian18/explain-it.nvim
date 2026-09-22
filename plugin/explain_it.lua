-- Autoload entry: commands are primarily registered via require("explain_it").setup().
-- This file ensures the plugin path is on runtimepath when installed as a package.
if vim.g.loaded_explain_it_nvim then
  return
end
vim.g.loaded_explain_it_nvim = true
