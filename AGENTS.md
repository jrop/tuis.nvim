# Morph UI Development Pattern

This document outlines the standard pattern for creating UI modules in the tuis.nvim plugin.

## UI Module Structure

All UI modules should be located in `lua/tuis/uis/` and follow this pattern:

### Required Functions

Each UI module must implement these functions:

#### `M.is_enabled() -> boolean`

Returns whether this UI is available/enabled on the current system. Use this to check for:
- Operating system compatibility (e.g., macOS-only features)
- Required CLI tools availability
- Other system dependencies

Example:
```lua
function M.is_enabled()
  -- Check if running on macOS (launchd is macOS-specific)
  return vim.fn.has('mac') == 1 and utils.check_clis_available(CLI_DEPENDENCIES)
end
```

#### `M.show()`

Launches the UI. This should contain all the bootstrap code that was previously at the bottom of the file, including:
- Buffer creation and setup
- Component mounting
- Any other initialization code

Example:
```lua
function M.show()
  vim.cmd.tabnew()
  vim.bo.buftype = 'nofile'
  vim.bo.bufhidden = 'wipe'
  vim.bo.buflisted = false
  vim.b.completion = false
  vim.wo[0][0].list = false

  Morph.new(0):mount(h(App))
end
```

### Module Structure

```lua
local Morph = require 'tuis.morph'
local h = Morph.h
local utils = require 'tuis.utils'

local M = {}

-- Your CLI dependencies (optional)
local CLI_DEPENDENCIES = { 'required-tool', 'another-tool' }

function M.is_enabled()
  return utils.check_clis_available(CLI_DEPENDENCIES)
end

-- All your component definitions here...

function M.show()
  -- Buffer setup and component mounting
end

return M
```

## How It Works

1. **Discovery**: The main `init.lua` automatically discovers all UI modules in `lua/tuis/uis/`
2. **Filtering**: Only UIs that return `true` from `M.is_enabled()` are shown in the selection menu
3. **Execution**: When a UI is selected, `init.lua` calls `M.show()` to launch it

## Migration Guide

To migrate an existing UI file:

1. Move the file from `uis/` to `lua/tuis/uis/`
2. Add `local M = {}` at the top
3. Wrap the bootstrap code (bottom of file) in `M.show()`
4. Add `M.is_enabled()` function with appropriate checks
5. Add `return M` at the end
6. Remove any early returns based on CLI availability (let `M.is_enabled()` handle this)

## Examples

See `lua/tuis/uis/launchd_services.lua` for a complete example of this pattern.
