local M = {}

-- "@/PATH/TO/SCRIPT/init.lua"
local source = debug.getinfo(1, 'S').source
M.__dirname = vim.fs.dirname(source:sub(2))
M.__uidir = vim.fs.normalize(vim.fs.joinpath(M.__dirname, 'uis'))

function M.list()
  --- @type string[]
  local uis = {}
  for f_name, f_type in vim.fs.dir(M.__uidir) do
    local display_name = f_name:match '^([^.]+)[.]lua$'
    if f_type == 'file' and display_name then
      -- Check if UI is enabled
      local ui_module = require('tuis.uis.' .. display_name)
      if ui_module.is_enabled and ui_module.is_enabled() then table.insert(uis, display_name) end
    end
  end
  return uis
end

--- @param name string
function M.run(name)
  package.loaded['tuis.uis.' .. name] = nil
  local ui_module = require('tuis.uis.' .. name)
  if not ui_module then
    vim.notify('UI not found: ' .. name, vim.log.levels.ERROR)
    return
  end
  if ui_module.show then
    ui_module.show()
  else
    vim.notify('UI does not have show function: ' .. name, vim.log.levels.ERROR)
  end
end

function M.choose()
  vim.ui.select(M.list(), {}, function(item)
    if item == nil then return end
    M.run(item)
  end)
end

local STORE_PATH = vim.fs.joinpath(vim.fn.stdpath 'config', 'site/pack/tuis-store/opt')
M.plugin_store = {
  load_all = function()
    if vim.fn.isdirectory(STORE_PATH) == 0 then return end
    for name, entry_type in vim.fs.dir(STORE_PATH) do
      if entry_type == 'directory' then pcall(vim.cmd.packadd, name) end
    end
  end,
}

return M
