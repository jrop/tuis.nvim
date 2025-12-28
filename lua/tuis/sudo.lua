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

--- @param callback fun(pw?: string)
M.prompt_for_password = vim.schedule_wrap(function(callback)
  local WIDTH, HEIGHT = 40, 1
  local E_WIDTH, E_HEIGHT = vim.o.columns, vim.o.lines

  local b = vim.api.nvim_create_buf(false, true)
  local w = vim.api.nvim_open_win(b, true, {
    title = 'Enter Password',
    relative = 'editor',
    row = math.floor((E_HEIGHT - HEIGHT) / 2),
    col = math.floor((E_WIDTH - WIDTH) / 2),
    width = WIDTH,
    height = HEIGHT,
  })
  local function setup_win()
    vim.bo[b].buftype = 'prompt'
    vim.bo[b].bufhidden = 'wipe'
    vim.wo[w].conceallevel = 2
    vim.wo[w].concealcursor = 'nvic'
    vim.wo[w].number = false
    vim.wo[w].relativenumber = false
    vim.wo[w].list = false
    vim.fn.prompt_setprompt(b, '')

    -- Conceal every character with '*'
    vim.fn.matchadd('Conceal', '.', 10, -1, { window = w, conceal = '*' })

    local function cleanup()
      pcall(vim.api.nvim_win_close, w, true)
      pcall(vim.api.nvim_buf_delete, b, { force = true, unload = true })
    end
    vim.keymap.set('i', '<Esc>', function()
      cleanup()
      callback(nil)
    end, { buffer = b })
    vim.keymap.set('i', '<CR>', function()
      local password = vim.iter(vim.api.nvim_buf_get_lines(b, 0, -1, false)):join '\n'
      cleanup()
      callback(password)
    end, { buffer = b })

    vim.cmd.startinsert()
  end

  local check_win_successes = 0
  local function check_win()
    if vim.api.nvim_get_current_win() ~= w then
      check_win_successes = 0
    else
      check_win_successes = check_win_successes + 1
    end

    vim.api.nvim_set_current_win(w)

    if check_win_successes < 10 then
      -- check again:
      vim.defer_fn(check_win, 10)
    else
      setup_win()
    end
  end
  check_win()
end)

--- @param callback fun(err?: any)
function M.with_sudo(callback)
  if M.is_password_cached() then return callback() end

  M.prompt_for_password(function(password)
    if password == nil then return callback 'password entry cancelled' end
    M.cache_password(password)
    return callback()
  end)
end

return M
