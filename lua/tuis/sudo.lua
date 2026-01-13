local M = {}

--- Check if sudo password is currently cached
--- @return boolean true if password is cached, false otherwise
function M.is_password_cached()
  local result = vim.system({ 'sudo', '-n', 'true' }, { text = true }):wait()
  return result.code == 0
end

--- Cache the sudo password by validating it
--- @param password string The sudo password to cache
--- @return boolean success true if password was accepted, false if rejected
--- @return string|nil error Optional error message if password was rejected
function M.cache_password(password)
  local result = vim.system({ 'sudo', '-S', '-v' }, { stdin = password, text = true }):wait()
  if result.code == 0 then
    return true, nil
  else
    return false, vim.trim(result.stderr or 'Unknown error')
  end
end

--- @param callback fun(err?: any)
function M.with_sudo(callback)
  if M.is_password_cached() then return callback() end

  local password = vim.fn.inputsecret 'sudo password: '
  M.cache_password(password)
  return callback()
end

return M
