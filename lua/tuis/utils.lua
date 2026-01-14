local M = {}

--------------------------------------------------------------------------------
-- Keymap Helper
--------------------------------------------------------------------------------

--- Wrap a keymap handler to return '' (required by morph nmap callbacks)
--- @param fn fun()
--- @return fun(): string
function M.keymap(fn)
  return function()
    vim.schedule(fn)
    return ''
  end
end

--------------------------------------------------------------------------------
-- Scratch Buffer
--------------------------------------------------------------------------------

--- Create a scratch buffer with specific options
--- @param split 'vnew'|'new' The split command to use
--- @param filetype? string Optional filetype to set
function M.create_scratch_buffer(split, filetype)
  if split == 'vnew' then
    vim.cmd.vnew()
  else
    vim.cmd.new()
  end
  vim.bo.buftype = 'nofile'
  vim.bo.bufhidden = 'wipe'
  vim.bo.buflisted = false
  if filetype then vim.cmd.setfiletype(filetype) end
end

--------------------------------------------------------------------------------
-- CLI Availability
--------------------------------------------------------------------------------

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

--------------------------------------------------------------------------------
-- Filter
--------------------------------------------------------------------------------

--- Create a filter function that supports regex patterns
--- Falls back to plain string matching if the pattern is invalid regex
--- @param filter_term string
--- @return fun(text: string): boolean
function M.create_filter_fn(filter_term)
  filter_term = filter_term or ''
  local filter_re_ok, filter_re = pcall(vim.regex, filter_term)

  return function(text)
    if filter_term == '' then return true end
    if filter_re_ok then
      return filter_re:match_str(text) ~= nil
    else
      return text:find(filter_term, 1) ~= nil
    end
  end
end

return M
