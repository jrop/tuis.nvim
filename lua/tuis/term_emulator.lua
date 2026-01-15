local M = {}

-- Detection functions
--- @return boolean
local function is_wsl2()
  local uname = vim.fn.system('uname -r'):lower()
  return uname:match 'microsoft' ~= nil
end

--- @return boolean
local function is_tmux() return vim.env.TMUX ~= nil end

--- @return boolean
local function is_wezterm()
  return vim.env.WEZTERM_EXECUTABLE ~= nil or vim.env.TERM_PROGRAM == 'WezTerm'
end

--- @return boolean
local function is_ghostty() return vim.env.TERM_PROGRAM == 'ghostty' end

-- Terminal emulator detection
--- @return string
local function detect_terminal()
  if is_tmux() then
    return 'tmux'
  elseif is_wezterm() then
    return 'wezterm'
  elseif is_ghostty() then
    return 'ghostty'
  else
    return 'unknown'
  end
end

--- @class tuis.term_emulator.TerminalInfo
--- @field terminal string The detected terminal type ('tmux', 'wezterm', 'ghostty', 'unknown')
--- @field is_wsl2 boolean Whether running in WSL2
--- @field is_tmux boolean Whether running in TMUX
--- @field is_wezterm boolean Whether running in WezTerm
--- @field is_ghostty boolean Whether running in Ghostty
--- @field wezterm_path string Path to WezTerm executable

--- @class tuis.term_emulator.Emulator
--- @field name string
local Emulator = {}
M.Emulator = Emulator
Emulator.__index = Emulator

--- Get emulator instance by kind, or currently detected if kind is nil
--- @param kind string?
--- @return tuis.term_emulator.Emulator?
function Emulator.get(kind)
  kind = kind or detect_terminal()

  if kind == 'tmux' then
    return M.Tmux:new()
  elseif kind == 'wezterm' then
    return M.WezTerm:new()
  elseif kind == 'ghostty' then
    return M.Ghostty:new()
  else
    return nil
  end
end

--- @param name string
--- @return tuis.term_emulator.Emulator
function Emulator:new(name) return setmetatable({ name = name }, self) end

--- @param _program string?
function Emulator:split_horizontal(_program)
  error('split_horizontal not implemented for ' .. self.name)
end

--- @param _program string?
function Emulator:split_vertical(_program) error('split_vertical not implemented for ' .. self.name) end

--- @param _program string?
function Emulator:new_window(_program) error('new_window not implemented for ' .. self.name) end

--- @param _program string?
function Emulator:new_tab(_program) error('new_tab not implemented for ' .. self.name) end

--- @param cmd string[]
function Emulator:_run(cmd)
  local proc = vim.system(cmd):wait()
  if proc.code ~= 0 then
    error(('error launching `%s`: %s'):format(vim.iter(cmd):join ' ', proc.stderr or '(no stderr)'))
  end
end

--------------------------------------------------------------------------------
-- WezTerm
--------------------------------------------------------------------------------

--- @class tuis.term_emulator.WezTerm : tuis.term_emulator.Emulator
local WezTerm = setmetatable({}, { __index = Emulator })
M.WezTerm = WezTerm
WezTerm.__index = WezTerm

--- @return string
function WezTerm.get_wezterm_path()
  if is_wsl2() then
    return '/mnt/c/Program Files/WezTerm/wezterm.exe'
  else
    return 'wezterm'
  end
end

--- @return tuis.term_emulator.WezTerm
function WezTerm:new() return setmetatable(Emulator.new(self, 'wezterm'), self) end

--- @param program string?
function WezTerm:split_horizontal(program)
  local wezterm_path = WezTerm.get_wezterm_path()
  local cmd = { wezterm_path, 'cli', 'split-pane', '--right' }
  if program then
    if is_wsl2() then
      vim.list_extend(cmd, { '--', 'wsl.exe', '--', '/usr/bin/env', 'bash', '-lc', program })
    else
      table.insert(cmd, '--')
      table.insert(cmd, program)
    end
  end
  self:_run(cmd)
end

--- @param program string?
function WezTerm:split_vertical(program)
  local wezterm_path = WezTerm.get_wezterm_path()
  local cmd = { wezterm_path, 'cli', 'split-pane', '--bottom' }
  if program then
    if is_wsl2() then
      vim.list_extend(cmd, { '--', 'wsl.exe', '--', '/usr/bin/env', 'bash', '-lc', program })
    else
      table.insert(cmd, '--')
      table.insert(cmd, program)
    end
  end
  self:_run(cmd)
end

--- @param program string?
function WezTerm:new_window(program)
  local wezterm_path = WezTerm.get_wezterm_path()
  local cmd = { wezterm_path, 'cli', 'spawn', '--new-window' }
  if program then
    if is_wsl2() then
      vim.list_extend(cmd, { '--', 'wsl.exe', '--', '/usr/bin/env', 'bash', '-lc', program })
    else
      table.insert(cmd, '--')
      table.insert(cmd, program)
    end
  end
  self:_run(cmd)
end

--- @param program string?
function WezTerm:new_tab(program)
  local wezterm_path = WezTerm.get_wezterm_path()
  local cmd = { wezterm_path, 'cli', 'spawn' }
  if program then
    if is_wsl2() then
      vim.list_extend(cmd, { '--', 'wsl.exe', '--', '/usr/bin/env', 'bash', '-lc', program })
    else
      table.insert(cmd, '--')
      table.insert(cmd, program)
    end
  end
  self:_run(cmd)
end

--------------------------------------------------------------------------------
-- Tmux
--------------------------------------------------------------------------------

--- @class tuis.term_emulator.Tmux : tuis.term_emulator.Emulator
local Tmux = setmetatable({}, { __index = Emulator })
M.Tmux = Tmux
Tmux.__index = Tmux

--- @return tuis.term_emulator.Tmux
function Tmux:new() return setmetatable(Emulator.new(self, 'tmux'), self) end

--- @param program string?
function Tmux:split_horizontal(program)
  local cmd = { 'tmux', 'split-window', '-h' }
  if program then table.insert(cmd, program) end
  self:_run(cmd)
end

--- @param program string?
function Tmux:split_vertical(program)
  local cmd = { 'tmux', 'split-window', '-v' }
  if program then table.insert(cmd, program) end
  self:_run(cmd)
end

--- @param program string?
function Tmux:new_window(program)
  local cmd = { 'tmux', 'new-window' }
  if program then table.insert(cmd, program) end
  self:_run(cmd)
end

--- @param program string?
function Tmux:new_tab(program)
  -- In tmux, tabs are windows
  self:new_window(program)
end

--------------------------------------------------------------------------------
-- Ghostty
--------------------------------------------------------------------------------

--- @class tuis.term_emulator.Ghostty : tuis.term_emulator.Emulator
local Ghostty = setmetatable({}, { __index = Emulator })
M.Ghostty = Ghostty
Ghostty.__index = Ghostty

--- @return tuis.term_emulator.Ghostty
function Ghostty:new() return setmetatable(Emulator.new(self, 'ghostty'), self) end

--- @param program string?
function Ghostty:split_horizontal(program)
  local cmd = { 'ghostty', '+split-right' }
  if program then
    table.insert(cmd, '-e')
    table.insert(cmd, program)
  end
  self:_run(cmd)
end

--- @param program string?
function Ghostty:split_vertical(program)
  local cmd = { 'ghostty', '+split-down' }
  if program then
    table.insert(cmd, '-e')
    table.insert(cmd, program)
  end
  self:_run(cmd)
end

--- @param program string?
function Ghostty:new_window(program)
  local cmd = { 'ghostty', '+new-window' }
  if program then
    table.insert(cmd, '-e')
    table.insert(cmd, program)
  end
  self:_run(cmd)
end

--- @param program string?
function Ghostty:new_tab(program)
  local cmd = { 'ghostty', '+new-tab' }
  if program then
    table.insert(cmd, '-e')
    table.insert(cmd, program)
  end
  self:_run(cmd)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--- Create a horizontal split
--- @param program string? Optional program to launch in the new split
--- @param emulator string? Optional emulator to force ('tmux', 'wezterm', 'ghostty')
function M.split_horizontal(program, emulator)
  local emu = Emulator.get(emulator)
  if not emu then
    vim.notify(
      'Unknown terminal emulator: ' .. (emulator or detect_terminal()),
      vim.log.levels.ERROR
    )
    return
  end
  emu:split_horizontal(program)
end

--- Create a vertical split
--- @param program string? Optional program to launch in the new split
--- @param emulator string? Optional emulator to force ('tmux', 'wezterm', 'ghostty')
function M.split_vertical(program, emulator)
  local emu = Emulator.get(emulator)
  if not emu then
    vim.notify(
      'Unknown terminal emulator: ' .. (emulator or detect_terminal()),
      vim.log.levels.ERROR
    )
    return
  end
  emu:split_vertical(program)
end

--- Create a new window
--- @param program string? Optional program to launch in the new window
--- @param emulator string? Optional emulator to force ('tmux', 'wezterm', 'ghostty')
function M.new_window(program, emulator)
  local emu = Emulator.get(emulator)
  if not emu then
    vim.notify(
      'Unknown terminal emulator: ' .. (emulator or detect_terminal()),
      vim.log.levels.ERROR
    )
    return
  end
  emu:new_window(program)
end

--- Create a new tab
--- @param program string? Optional program to launch in the new tab
--- @param emulator string? Optional emulator to force ('tmux', 'wezterm', 'ghostty')
function M.new_tab(program, emulator)
  local emu = Emulator.get(emulator)
  if not emu then
    vim.notify(
      'Unknown terminal emulator: ' .. (emulator or detect_terminal()),
      vim.log.levels.ERROR
    )
    return
  end
  emu:new_tab(program)
end

--- Get the currently detected emulator instance
--- @return tuis.term_emulator.Emulator?
function M.current() return Emulator.get() end

return M
