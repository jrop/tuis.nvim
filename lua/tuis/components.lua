local Morph = require 'tuis.morph'
local h = Morph.h

local M = {}

--- @param s string
local function strdisplaywidth(s)
  local ok, w = pcall(vim.fn.strdisplaywidth, s)
  return ok and w or #s
end

--  __  __      _
-- |  \/  | ___| |_ ___ _ __
-- | |\/| |/ _ \ __/ _ \ '__|
-- | |  | |  __/ ||  __/ |
-- |_|  |_|\___|\__\___|_|

--- Unicode block characters for smooth horizontal progress display
local METER_BLOCKS = { ' ', '▏', '▎', '▍', '▌', '▋', '▊', '▉', '█' }

--- Unicode block characters for vertical sparkline display
local SPARKLINE_BLOCKS = { ' ', '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█' }

--- @alias morph.MeterProps {
---   value: number,
---   max: number,
---   width: number,
---   hl?: string
--- }

--- A progress bar/meter component with smooth Unicode block rendering
--- @param ctx morph.Ctx<morph.MeterProps>
function M.Meter(ctx)
  local value = ctx.props.value or 0
  local max = ctx.props.max or 100
  local width = ctx.props.width or 10
  local hl = ctx.props.hl

  -- Calculate percentage (handle edge cases)
  --- @type number
  local percent = 0.0
  if max > 0 then percent = math.max(0, math.min(100, (value / max) * 100)) end

  -- Build the meter string with smooth partial blocks
  local result = {}
  local per_char = 100 / width
  for i = 1, width do
    local char_start = (i - 1) * per_char
    local char_end = i * per_char
    if percent >= char_end then
      table.insert(result, '█')
    elseif percent <= char_start then
      table.insert(result, ' ')
    else
      local frac = (percent - char_start) / per_char
      local idx = math.floor(frac * 8) + 1
      table.insert(result, METER_BLOCKS[idx] or ' ')
    end
  end

  local meter_str = table.concat(result)
  return h('text', { hl = hl }, meter_str)
end

--  ____                   _    _ _
-- / ___| _ __   __ _ _ __| | _| (_)_ __   ___
-- \___ \| '_ \ / _` | '__| |/ / | | '_ \ / _ \
--  ___) | |_) | (_| | |  |   <| | | | | |  __/
-- |____/| .__/ \__,_|_|  |_|\_\_|_|_| |_|\___|
--       |_|

--- @alias morph.SparklineProps {
---   values: number[],
---   width: number,
---   hl?: string
--- }

--- A sparkline component showing historical values as a mini graph
--- @param ctx morph.Ctx<morph.SparklineProps>
function M.Sparkline(ctx)
  local values = ctx.props.values or {}
  local width = ctx.props.width or 20
  local hl = ctx.props.hl

  local result = {}

  -- Find max value for scaling (auto-scale)
  local max_val = 0
  for _, v in ipairs(values) do
    if v > max_val then max_val = v end
  end
  if max_val == 0 then
    max_val = 1 -- Avoid division by zero
  end

  -- Pad left with spaces if fewer values than width
  local num_values = math.min(#values, width)
  local padding = width - num_values
  for _ = 1, padding do
    table.insert(result, ' ')
  end

  -- Take the last 'width' values (most recent on the right)
  local start_idx = math.max(1, #values - width + 1)
  for i = start_idx, #values do
    local val = values[i]
    if val == 0 then
      table.insert(result, ' ')
    else
      local normalized = val / max_val
      local block_idx = math.max(1, math.min(8, math.ceil(normalized * 8)))
      table.insert(result, SPARKLINE_BLOCKS[block_idx + 1] or '█')
    end
  end

  local sparkline_str = table.concat(result)
  return h('text', { hl = hl }, sparkline_str)
end

--  _____     _     _
-- |_   _|_ _| |__ | | ___
--   | |/ _` | '_ \| |/ _ \
--   | | (_| | |_) | |  __/
--   |_|\__,_|_.__/|_|\___|

--- @alias morph.TableBorderStyle 'none'|'single'|'double'|'rounded'|'ascii'

--- @class morph.TableBorderChars
--- @field top_left string
--- @field top string
--- @field top_mid string
--- @field top_right string
--- @field left string
--- @field mid string
--- @field mid_mid string
--- @field right string
--- @field bottom_left string
--- @field bottom string
--- @field bottom_mid string
--- @field bottom_right string
--- @field header_left string
--- @field header_mid string
--- @field header_right string
--- @field header string

--- @type table<morph.TableBorderStyle, morph.TableBorderChars>
local border_styles = {
  single = {
    top_left = '┌',
    top = '─',
    top_mid = '┬',
    top_right = '┐',
    left = '│',
    mid = ' ',
    mid_mid = '│',
    right = '│',
    bottom_left = '└',
    bottom = '─',
    bottom_mid = '┴',
    bottom_right = '┘',
    header_left = '├',
    header_mid = '┼',
    header_right = '┤',
    header = '─',
  },
  double = {
    top_left = '╔',
    top = '═',
    top_mid = '╦',
    top_right = '╗',
    left = '║',
    mid = ' ',
    mid_mid = '║',
    right = '║',
    bottom_left = '╚',
    bottom = '═',
    bottom_mid = '╩',
    bottom_right = '╝',
    header_left = '╠',
    header_mid = '╬',
    header_right = '╣',
    header = '═',
  },
  rounded = {
    top_left = '╭',
    top = '─',
    top_mid = '┬',
    top_right = '╮',
    left = '│',
    mid = ' ',
    mid_mid = '│',
    right = '│',
    bottom_left = '╰',
    bottom = '─',
    bottom_mid = '┴',
    bottom_right = '╯',
    header_left = '├',
    header_mid = '┼',
    header_right = '┤',
    header = '─',
  },
  ascii = {
    top_left = '+',
    top = '-',
    top_mid = '+',
    top_right = '+',
    left = '|',
    mid = ' ',
    mid_mid = '|',
    right = '|',
    bottom_left = '+',
    bottom = '-',
    bottom_mid = '+',
    bottom_right = '+',
    header_left = '+',
    header_mid = '+',
    header_right = '+',
    header = '-',
  },
}

--- @alias morph.TableProps {
---   rows: ({ cells: morph.Tree[] } & morph.TagAttributes)[],
---   border?: boolean|morph.TableBorderStyle,
---   header?: boolean,
---   header_separator?: boolean,
---   page?: number,
---   page_size?: number,
---   on_page_changed?: fun(page: number)
--- }

--- @param ctx morph.Ctx<morph.TableProps>
--- @return morph.Tree[]
function M.Table(ctx)
  local props = ctx.props
  local all_rows = props.rows
  if #all_rows == 0 then return {} end

  -- Resolve border style
  local border = props.border == true and border_styles.single
    or type(props.border) == 'string' and props.border ~= 'none' and border_styles[props.border]
    or nil

  -- Split header from data rows, apply pagination
  local header_row = props.header and all_rows[1] or nil
  local data_rows = props.header and vim.list_slice(all_rows, 2) or all_rows
  local total_data = #data_rows
  local page_size = props.page_size

  -- Determine if pagination is enabled and whether controlled or uncontrolled
  local is_controlled = props.page ~= nil
  local total_pages = (page_size and page_size > 0)
      and math.max(1, math.ceil(total_data / page_size))
    or 1

  -- Uncontrolled pagination: page_size provided but no page prop, and more than one page
  local is_uncontrolled = not is_controlled and page_size and total_pages > 1

  -- Initialize internal state for uncontrolled mode (morph requires state assignment at mount)
  if is_uncontrolled then
    if ctx.phase == 'mount' then ctx.state = { page = 1 } end
    -- Ensure state exists (might be nil on first render before mount completes)
    ctx.state = ctx.state or { page = 1 }
  end

  -- Use controlled page or internal state
  local page = is_controlled and props.page or (is_uncontrolled and ctx.state.page) or 1
  local current_page = math.max(1, math.min(page, total_pages))
  local paginated = total_pages > 1

  if paginated then
    local start_idx = (current_page - 1) * page_size + 1
    data_rows = vim.list_slice(data_rows, start_idx, math.min(current_page * page_size, total_data))
  end

  -- Assemble visible rows
  local rows = header_row and { header_row } or {}
  vim.list_extend(rows, data_rows)
  if #rows == 0 then return {} end

  local num_cols = #rows[1].cells

  -- Measure all cells and compute column widths
  local cell_widths, col_widths = {}, {}
  for ri, row in ipairs(rows) do
    cell_widths[ri] = {}
    for ci, cell in ipairs(row.cells) do
      cell_widths[ri][ci] = strdisplaywidth(Morph.markup_to_string { tree = cell })
      col_widths[ci] = math.max((col_widths[ci] or 0), cell_widths[ri][ci] + 1)
    end
  end

  -- Helper: sum column widths + border overhead
  local function table_width()
    local w = 0.0
    for _, cw in ipairs(col_widths) do
      w = w + cw
    end
    return border and (w + num_cols + 1) or w
  end

  -- Helper: build horizontal border line
  local function hline(left, fill, mid, right)
    local parts = { left }
    for ci, cw in ipairs(col_widths) do
      parts[#parts + 1] = string.rep(fill, cw)
      if ci < num_cols then parts[#parts + 1] = mid end
    end
    parts[#parts + 1] = right
    return table.concat(parts)
  end

  -- Pagination bar setup
  local pag_text, display_width
  if paginated then
    local rs = (current_page - 1) * page_size + 1
    local re = math.min(current_page * page_size, total_data)
    pag_text = string.format(
      '◀ [[ Page %d of %d ]] ▶    %d items    (%d-%d of %d)',
      current_page,
      total_pages,
      #data_rows,
      rs,
      re,
      total_data
    )
    local pag_width = strdisplaywidth(pag_text)
    -- Expand last column if pagination bar is wider than table
    local tw = table_width()
    if pag_width > tw then col_widths[num_cols] = col_widths[num_cols] + (pag_width - tw) end
    display_width = math.max(table_width(), pag_width)
  end

  -- Helper: centered pagination bar
  local function pag_bar()
    local bar = {}
    local w = strdisplaywidth(pag_text)
    local lpad = math.floor((display_width - w) / 2)
    if lpad > 0 then bar[#bar + 1] = string.rep(' ', lpad) end
    bar[#bar + 1] = h.Whitespace({}, pag_text)
    local rpad = display_width - w - lpad
    if rpad > 0 then bar[#bar + 1] = string.rep(' ', rpad) end
    return bar
  end

  local function pag_sep()
    return h.Whitespace({}, string.rep(border and border.top or '─', display_width))
  end

  -- Build output
  local result = {}
  local function add(...)
    for _, v in ipairs { ... } do
      result[#result + 1] = v
    end
  end
  local function add_list(t)
    for _, v in ipairs(t) do
      result[#result + 1] = v
    end
  end

  if paginated then
    add_list(pag_bar())
    add('\n', pag_sep(), '\n')
  end
  if border then add(hline(border.top_left, border.top, border.top_mid, border.top_right), '\n') end

  for ri, row in ipairs(rows) do
    if border then add(border.left) end

    for ci, cell in ipairs(row.cells) do
      add(h('text', row, cell))
      local pad = col_widths[ci] - cell_widths[ri][ci]
      if pad > 0 and (border or ci < num_cols) then add(h('text', row, string.rep(' ', pad))) end
      if border then add(ci < num_cols and border.mid_mid or border.right) end
    end

    local is_header = props.header and ri == 1
    if is_header and border then
      add('\n', hline(border.header_left, border.header, border.header_mid, border.header_right))
    elseif is_header and props.header_separator then
      add('\n', h.Whitespace({}, string.rep('─', table_width())))
    end

    if ri < #rows then
      add '\n'
    elseif border then
      add('\n', hline(border.bottom_left, border.bottom, border.bottom_mid, border.bottom_right))
    end
  end

  if paginated then
    add('\n', pag_sep(), '\n')
    add_list(pag_bar())
  end

  -- Attach pagination keymaps (for both controlled and uncontrolled modes)
  if paginated then
    local function nav(delta)
      return function(e)
        e.bubble_up = false
        -- Read current page fresh from state for uncontrolled mode (closure would be stale)
        local effective_page = is_uncontrolled and ctx.state.page or current_page
        local target = vim.v.count > 0 and math.max(1, math.min(vim.v.count, total_pages))
          or (effective_page + delta)
        if target ~= effective_page and target >= 1 and target <= total_pages then
          if is_uncontrolled then
            -- Uncontrolled mode: update internal state
            ctx.state.page = target
            ctx:update(ctx.state)
            -- Still call callback if provided (for notification purposes)
            if props.on_page_changed then props.on_page_changed(target) end
          else
            -- Controlled mode: delegate to parent via callback
            if props.on_page_changed then props.on_page_changed(target) end
          end
        end
        return ''
      end
    end
    return h('text', { nmap = { ['[['] = nav(-1), [']]'] = nav(1) } }, result)
  end

  return result
end

--  _____     _     ____
-- |_   _|_ _| |__ | __ )  __ _ _ __
--   | |/ _` | '_ \|  _ \ / _` | '__|
--   | | (_| | |_) | |_) | (_| | |
--   |_|\__,_|_.__/|____/ \__,_|_|

--- @class morph.TabBarTab
--- @field key string
--- @field page string
--- @field label string

--- @alias morph.TabBarProps {
---   tabs: morph.TabBarTab[],
---   active_page: string,
---   on_select?: fun(page: string),
---   wrap_at?: number,
---   separator?: string
--- }

--- Wrap a keymap handler to return '' (required by morph nmap callbacks)
--- @param fn fun()
--- @return fun(): string
local function tab_keymap(fn)
  return function()
    vim.schedule(fn)
    return ''
  end
end

--- A tab bar component with optional line wrapping
--- @param ctx morph.Ctx<morph.TabBarProps>
--- @return morph.Tree[]
function M.TabBar(ctx)
  local props = ctx.props
  local tabs = props.tabs or {}
  local wrap_at = props.wrap_at or #tabs
  local separator = props.separator or ' | '

  local result = {}
  local tabs_on_current_line = 0

  for i, tab in ipairs(tabs) do
    local is_active = props.active_page == tab.page

    if i > 1 then
      if tabs_on_current_line >= wrap_at then
        table.insert(result, '\n')
        tabs_on_current_line = 0
      else
        table.insert(result, separator)
      end
    end

    local tab_content = {
      is_active and h.RenderMarkdownH2Bg({}, tab.label) or h.RenderMarkdownH2({}, tab.label),
      h.NonText({}, ' ' .. tab.key),
    }

    local keymaps = {}
    if props.on_select then
      keymaps['<CR>'] = tab_keymap(function() props.on_select(tab.page) end)
    end

    table.insert(result, h('text', { nmap = keymaps }, tab_content))
    tabs_on_current_line = tabs_on_current_line + 1
  end

  return { result, '\n\n' }
end

return M
