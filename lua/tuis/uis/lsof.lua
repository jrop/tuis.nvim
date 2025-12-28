local Morph = require 'tuis.morph'
local h = Morph.h
local Table = require('tuis.components').Table
local utils = require 'tuis.utils'

local M = {}

--- @type string[]
local CLI_DEPENDENCIES = { 'lsof', 'kill' }

function M.is_enabled() return utils.check_clis_available(CLI_DEPENDENCIES, true) end

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

--- @class lsof.Connection
--- @field command string
--- @field pid number
--- @field user string
--- @field fd string
--- @field type string
--- @field device string
--- @field node string
--- @field name string

--------------------------------------------------------------------------------
-- Utilities
--------------------------------------------------------------------------------

--- Parse lsof output
--- @param output string
--- @return lsof.Connection[]
local function parse_lsof(output)
  local connections = {}
  local lines = vim.split(output, '\n')

  -- Skip header line
  for i = 2, #lines do
    local line = lines[i]
    if line ~= '' then
      -- lsof output format: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
      local parts = vim.split(line, '%s+')
      if #parts >= 9 then
        ---@type lsof.Connection
        local conn = {
          command = parts[1],
          pid = tonumber(parts[2]) or 0,
          user = parts[3],
          fd = parts[4],
          type = parts[5],
          device = parts[6],
          node = parts[8],
          name = table.concat(vim.list_slice(parts, 9), ' '),
        }
        table.insert(connections, conn)
      end
    end
  end

  return connections
end

--- Extract port from connection name (e.g., "*:8080" -> "8080")
--- @param name string
--- @return string
local function extract_port(name)
  local port = name:match ':(%d+)'
  return port or name
end

--------------------------------------------------------------------------------
-- Components
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Help Component
--------------------------------------------------------------------------------

--- @param ctx morph.Ctx<{ show_help: boolean }, any>
local function Help(ctx)
  if not ctx.props.show_help then return {} end

  local help_table = {}

  table.insert(help_table, {
    cells = {
      h.Constant({}, 'KEY'),
      h.Constant({}, 'ACTION'),
    },
  })

  local keymaps = {
    { 'gk', 'Kill process' },
    { 'g+', 'Yank port to +' },
    { 'g"', 'Yank port to "' },
    { 'gi', 'Show full lsof output for PID' },
    { '<Leader>r', 'Refresh connections' },
    { 'g?', 'Toggle this help' },
  }

  for _, keymap in ipairs(keymaps) do
    table.insert(help_table, {
      cells = {
        h.Title({}, keymap[1]),
        h.Normal({}, keymap[2]),
      },
    })
  end

  return {
    h.RenderMarkdownH1({}, '## Keybindings'),
    '\n\n',
    h(Table, { rows = help_table, header = true, header_separator = true }),
  }
end

--------------------------------------------------------------------------------
-- Connections Component
--------------------------------------------------------------------------------

--- @param ctx morph.Ctx<{ connections: lsof.Connection[], on_refresh: fun() }, { filter: string }>
local function Connections(ctx)
  if ctx.phase == 'mount' then ctx.state = { filter = '' } end
  local state = assert(ctx.state)

  local connections_table = {}

  table.insert(connections_table, {
    cells = {
      h.Constant({}, 'COMMAND'),
      h.Constant({}, 'PID'),
      h.Constant({}, 'USER'),
      h.Constant({}, 'TYPE'),
      h.Constant({}, 'NODE'),
      h.Constant({}, 'NAME'),
    },
  })

  for _, conn in ipairs(ctx.props.connections) do
    local passes_filter = state.filter == ''
      or conn.command:lower():find(state.filter:lower(), 1, true) ~= nil
      or conn.name:find(state.filter, 1, true) ~= nil
      or tostring(conn.pid):find(state.filter, 1, true) ~= nil

    if passes_filter then
      table.insert(connections_table, {
        nmap = {
          ['gk'] = function()
            vim.schedule(function()
              vim.ui.select({ 'SIGTERM', 'SIGKILL' }, {
                prompt = 'Kill process ' .. conn.pid .. ' (' .. conn.command .. ')?',
              }, function(signal)
                if signal then
                  local sig_num = signal == 'SIGTERM' and '15' or '9'
                  vim.system({ 'kill', '-' .. sig_num, tostring(conn.pid) }):wait()
                  vim.notify('Killed process ' .. conn.pid)
                  ctx.props.on_refresh()
                end
              end)
            end)
            return ''
          end,
          ['g+'] = function()
            vim.schedule(function()
              local port = extract_port(conn.name)
              vim.fn.setreg('+', port)
              vim.notify('Yanked to +: ' .. port)
            end)
            return ''
          end,
          ['g"'] = function()
            vim.schedule(function()
              local port = extract_port(conn.name)
              vim.fn.setreg('"', port)
              vim.notify('Yanked to ": ' .. port)
            end)
            return ''
          end,
          ['gi'] = function()
            vim.schedule(function()
              vim.cmd.new()
              vim.bo.buftype = 'nofile'
              vim.bo.bufhidden = 'wipe'
              vim.bo.buflisted = false
              local result = vim
                .system({ 'lsof', '-p', tostring(conn.pid) }, { text = true })
                :wait()
              vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(result.stdout or '', '\n'))
            end)
            return ''
          end,
        },
        cells = {
          h.Constant({}, conn.command),
          h.Number({}, tostring(conn.pid)),
          h.String({}, conn.user),
          h.Comment({}, conn.type),
          h.String({}, conn.node),
          h.Title({}, conn.name),
        },
      })
    end
  end

  return {
    h.RenderMarkdownH1(
      {},
      ('# Open Files & Connections%s'):format(
        #state.filter > 0 and ' (filter: ' .. state.filter .. ')' or ''
      )
    ),

    '\n\n',

    h.Label({}, 'Filter: '),
    '[',
    h.String({
      on_change = function(e)
        state.filter = e.text
        ctx:update(state)
      end,
    }, state.filter),
    ']',

    ctx.props.connections and '\n\n' or '',

    h(Table, { rows = connections_table }),
  }
end

--------------------------------------------------------------------------------
-- App Component
--------------------------------------------------------------------------------

--- @param ctx morph.Ctx<any, { connections: lsof.Connection[], show_help: boolean }>
local function App(ctx)
  --
  -- Helper: refresh_connections:
  local refresh_connections = vim.schedule_wrap(function()
    local state = assert(ctx.state)
    vim.system({ 'lsof', '-nP', '-i' }, { text = true }, function(out)
      if out.code ~= 0 then
        state.connections = {}
        ctx:update(state)
        return
      end

      local connections = parse_lsof(out.stdout or '')
      table.sort(connections, function(a, b)
        if a.command ~= b.command then return a.command < b.command end
        return a.pid < b.pid
      end)

      state.connections = connections
      ctx:update(state)
    end)
  end)

  if ctx.phase == 'mount' then
    -- Initialize state:
    ctx.state = {
      connections = {},
      show_help = false,
      timer = assert(vim.uv.new_timer()),
    }
    refresh_connections()
    ctx.state.timer:start(2000, 2000, function() vim.schedule(refresh_connections) end)
  end
  local state = assert(ctx.state)

  if ctx.phase == 'unmount' then
    state.timer:stop()
    state.timer:close()
  end

  return h('text', {
    -- Global maps:
    nmap = {
      ['<Leader>r'] = function()
        refresh_connections()
        return ''
      end,
      ['g?'] = function()
        state.show_help = not state.show_help
        ctx:update(state)
        return ''
      end,
    },
  }, {
    -- Header line
    h.RenderMarkdownH1({}, 'lsof'),
    ' ',
    h.NonText({}, 'g? for help'),
    '\n\n',

    --
    -- Help (if enabled)
    --
    state.show_help
      and {
        h(Help, {
          show_help = state.show_help,
        }),
        '\n\n',
      },

    --
    -- List of connections
    --
    {
      h(Connections, {
        connections = state.connections,
        on_refresh = refresh_connections,
      }),
    },
  })
end

--------------------------------------------------------------------------------
-- Buffer/Render
--------------------------------------------------------------------------------

function M.show()
  vim.cmd.tabnew()
  vim.bo.buftype = 'nofile'
  vim.bo.bufhidden = 'wipe'
  vim.b.completion = false
  vim.wo[0][0].list = false
  vim.api.nvim_buf_set_name(0, 'lsof')

  Morph.new(0):mount(h(App))
end

return M
