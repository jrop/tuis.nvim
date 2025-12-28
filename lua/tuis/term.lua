local M = {}

--- Open a terminal with the given command
--- @param cmd string The command to run in the terminal
function M.open(cmd)
  vim.cmd.new()
  vim.cmd.wincmd 'J'
  vim.fn.jobstart(cmd, { term = true })
  vim.cmd.startinsert()
end

return M
