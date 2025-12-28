local M = {}

--- @param clis string[]
--- @param silent? boolean Whether to suppress warnings
function M.check_clis_available(clis, silent)
  --- @type string[]
  local missing = {}
  for _, cli in ipairs(clis) do
    if vim.fn.executable(cli) ~= 1 then table.insert(missing, cli) end
  end
  if #missing > 0 and not silent then
    vim.api.nvim_echo({
      { 'tuis: missing CLI dependencies: ', 'ErrorMsg' },
      { table.concat(missing, ', '), 'WarningMsg' },
      { '\n' },
    }, true, {})
  end
  return #missing == 0
end

return M
