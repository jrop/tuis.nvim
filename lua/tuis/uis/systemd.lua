local Morph = require 'tuis.morph'
local h = Morph.h
local components = require 'tuis.components'
local Table = components.Table
local TabBar = components.TabBar
local Help = components.Help
local term = require 'tuis.term'
local utils = require 'tuis.utils'
local keymap = utils.keymap
local create_scratch_buffer = utils.create_scratch_buffer

local M = {}

--- @type string[]
local CLI_DEPENDENCIES = { 'systemctl', 'sudo', 'journalctl' }

function M.is_enabled() return utils.check_clis_available(CLI_DEPENDENCIES, true) end

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

--- @alias systemd.Page 'service'|'timer'|'socket'|'path'|'mount'|'target'|'slice'|'scope'|'device'

--- @class systemd.UnitInfo
--- @field unit string
--- @field description string
--- @field load string
--- @field active string
--- @field sub string
--- @field main_pid? string
--- @field active_enter_timestamp? string
--- @field inactive_exit_timestamp? string
--- @field result? string
--- @field next_run? string
--- @field last_run? string
--- @field triggered_by? string
--- @field raw unknown

--- @class systemd.TimerInfo
--- @field unit string
--- @field description string
--- @field load string
--- @field active string
--- @field sub string
--- @field next_run string
--- @field last_run string
--- @field triggered_by string
--- @field raw unknown

--- @class systemd.AppState
--- @field page systemd.Page
--- @field show_help boolean
--- @field loading boolean
--- @field namespace 'system'|'user'
--- @field current_page_units systemd.UnitInfo[]
--- @field services systemd.UnitInfo[]
--- @field timers systemd.TimerInfo[]
--- @field sockets systemd.UnitInfo[]
--- @field paths systemd.UnitInfo[]
--- @field mounts systemd.UnitInfo[]
--- @field targets systemd.UnitInfo[]
--- @field slices systemd.UnitInfo[]
--- @field scopes systemd.UnitInfo[]
--- @field devices systemd.UnitInfo[]

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--- @param page systemd.Page
--- @return string
local function get_unit_type(page)
  local mapping = {
    service = 'service',
    timer = 'timer',
    socket = 'socket',
    path = 'path',
    mount = 'mount',
    target = 'target',
    slice = 'slice',
    scope = 'scope',
    device = 'device',
  }
  return mapping[page] or 'service'
end

--- @param namespace 'system'|'user'
--- @param page systemd.Page
--- @return string[]
local function make_list_command(namespace, page)
  local unit_type = get_unit_type(page)
  if namespace == 'user' then
    return { 'systemctl', '--user', 'list-units', '--type=' .. unit_type, '--all', '--output=json' }
  else
    return { 'systemctl', 'list-units', '--type=' .. unit_type, '--all', '--output=json' }
  end
end

--- @param namespace 'system'|'user'
--- @param unit string
--- @param action string
--- @return string
local function make_action_command(namespace, unit, action)
  if namespace == 'user' then
    return 'systemctl --user ' .. action .. ' ' .. unit
  else
    return 'sudo systemctl ' .. action .. ' ' .. unit
  end
end

--- @param namespace 'system'|'user'
--- @param unit string
--- @return string
local function make_logs_command(namespace, unit)
  if namespace == 'user' then
    return 'journalctl --user -u ' .. unit .. ' -f'
  else
    return 'sudo journalctl -u ' .. unit .. ' -f'
  end
end

--- @param namespace 'system'|'user'
--- @param unit string
local function show_inspect(namespace, unit)
  vim.schedule(function()
    local cmd = namespace == 'user' and { 'systemctl', '--user', 'show', unit, '--output=json' }
      or { 'systemctl', 'show', unit, '--output=json' }

    vim.system(cmd, { text = true }, function(result)
      vim.schedule(function()
        create_scratch_buffer('vnew', 'json')
        local json = vim.trim(result.stdout or '{}')
        vim.api.nvim_buf_set_lines(0, 0, -1, true, vim.split(json, '\n'))
      end)
    end)
  end)
end

--------------------------------------------------------------------------------
-- Help System
--------------------------------------------------------------------------------

local HELP_KEYMAPS = {
  service = {
    { 'gi', 'Inspect unit (status)' },
    { 'gs', 'Start unit' },
    { 'gS', 'Stop unit' },
    { 'gr', 'Restart unit' },
    { 'ga', 'Enable unit' },
    { 'gd', 'Disable unit' },
    { 'gl', 'View unit logs' },
  },
  timer = {
    { 'gi', 'Show timer details (JSON)' },
    { 'gr', 'Run timer now' },
    { 'gs', 'Start timer' },
    { 'gS', 'Stop timer' },
    { 'gl', 'View timer logs' },
  },
  socket = {
    { 'gi', 'Show socket details (JSON)' },
    { 'gs', 'Start socket' },
    { 'gS', 'Stop socket' },
    { 'gr', 'Restart socket' },
    { 'gl', 'View socket logs' },
  },
  path = {
    { 'gi', 'Show path details (JSON)' },
    { 'gs', 'Start path' },
    { 'gS', 'Stop path' },
    { 'gl', 'View path logs' },
  },
  mount = {
    { 'gi', 'Show mount details (JSON)' },
    { 'gs', 'Start mount' },
    { 'gS', 'Stop mount' },
    { 'gl', 'View mount logs' },
  },
  target = {
    { 'gi', 'Inspect target (JSON)' },
    { 'gs', 'Start (isolate) target' },
    { 'gl', 'View target logs' },
  },
  slice = {},
  scope = {
    { 'gi', 'Show scope details (JSON)' },
    { 'gk', 'Kill scope' },
    { 'gl', 'View scope logs' },
  },
  device = {},
}

local COMMON_KEYMAPS = {
  { 'g1-g9', 'Navigate unit types' },
  { '<Leader>r', 'Refresh' },
  { '<Leader>s', 'Switch to system namespace' },
  { '<Leader>u', 'Switch to user namespace' },
  { 'g?', 'Toggle help' },
}

--- @param ctx morph.Ctx<{ page: systemd.Page }>
local function SystemdHelp(ctx)
  return h(Help, {
    page_keymaps = HELP_KEYMAPS[ctx.props.page],
    common_keymaps = COMMON_KEYMAPS,
  })
end

--------------------------------------------------------------------------------
-- Navigation Components
--------------------------------------------------------------------------------

--- @type { key: string, page: systemd.Page, label: string }[]
local TABS = {
  { key = 'g1', page = 'service', label = 'Services' },
  { key = 'g2', page = 'timer', label = 'Timers' },
  { key = 'g3', page = 'socket', label = 'Sockets' },
  { key = 'g4', page = 'path', label = 'Paths' },
  { key = 'g5', page = 'mount', label = 'Mounts' },
  { key = 'g6', page = 'target', label = 'Targets' },
  { key = 'g7', page = 'slice', label = 'Slices' },
  { key = 'g8', page = 'scope', label = 'Scopes' },
  { key = 'g9', page = 'device', label = 'Devices' },
}

--------------------------------------------------------------------------------
-- Data Fetching
--------------------------------------------------------------------------------

--- @param callback fun(units: systemd.UnitInfo[])
local function fetch_units(namespace, page, callback)
  local cmd = make_list_command(namespace, page)

  vim.system(cmd, { text = true }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then
        callback {}
        return
      end

      ---@type systemd.UnitInfo[]
      local units = {}
      local ok, raw_units = pcall(vim.json.decode, out.stdout or '[]')
      if not ok then raw_units = {} end

      for _, raw in ipairs(raw_units) do
        ---@type systemd.UnitInfo
        local unit = {
          unit = raw.unit or '',
          description = raw.description or '',
          load = raw.load or '',
          active = raw.active or '',
          sub = raw.sub or '',
          main_pid = raw.main_pid,
          active_enter_timestamp = raw.active_enter_timestamp,
          inactive_exit_timestamp = raw.inactive_exit_timestamp,
          result = raw.result,
          next_run = raw.next_run,
          last_run = raw.last_run,
          triggered_by = raw.triggered_by,
          raw = raw,
        }
        table.insert(units, unit)
      end

      table.sort(units, function(a, b) return a.unit < b.unit end)
      callback(units)
    end)
  end)
end

--- @param callback fun(units: systemd.TimerInfo[])
local function fetch_timers(namespace, callback)
  local cmd = make_list_command(namespace, 'timer')

  vim.system(cmd, { text = true }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then
        callback {}
        return
      end

      ---@type systemd.TimerInfo[]
      local timers = {}
      local ok, raw_units = pcall(vim.json.decode, out.stdout or '[]')
      if not ok then raw_units = {} end

      for _, raw in ipairs(raw_units) do
        ---@type systemd.TimerInfo
        local timer = {
          unit = raw.unit or '',
          description = raw.description or '',
          load = raw.load or '',
          active = raw.active or '',
          sub = raw.sub or '',
          next_run = raw.next_run or '',
          last_run = raw.last_run or '',
          triggered_by = raw.triggered_by or '',
          raw = raw,
        }
        table.insert(timers, timer)
      end

      table.sort(timers, function(a, b) return a.unit < b.unit end)
      callback(timers)
    end)
  end)
end

--------------------------------------------------------------------------------
-- Resource View Factory
--------------------------------------------------------------------------------

--- @class systemd.ViewConfig
--- @field title string
--- @field columns string[]
--- @field filter_fn fun(item: any, filter: string): boolean
--- @field render_cells fun(item: any): morph.Tree[]
--- @field keymaps fun(item: any, on_refresh: fun(), namespace: 'system'|'user'): table<string, fun(): string>

--- @param config systemd.ViewConfig
--- @return fun(ctx: morph.Ctx): morph.Tree
local function create_resource_view(config)
  --- @param ctx morph.Ctx<{ items: any[], loading: boolean, on_refresh: fun(), namespace: 'system'|'user' }, { filter: string }>
  return function(ctx)
    if ctx.phase == 'mount' then ctx.state = { filter = '' } end
    local state = assert(ctx.state)

    local header_cells = {}
    for _, col in ipairs(config.columns) do
      table.insert(header_cells, h.Constant({}, col))
    end
    local rows = { { cells = header_cells } }

    for _, item in ipairs(ctx.props.items or {}) do
      if config.filter_fn(item, state.filter) then
        table.insert(rows, {
          nmap = config.keymaps(item, ctx.props.on_refresh, ctx.props.namespace),
          cells = config.render_cells(item),
        })
      end
    end

    return {
      h.RenderMarkdownH1({}, '## ' .. config.title),
      ctx.props.loading and h.NonText({}, ' (loading...)') or nil,
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
      '\n\n',
      h(Table, {
        rows = rows,
        header = true,
        header_separator = true,
        page_size = math.max(10, vim.o.lines - 10),
      }),
    }
  end
end

--------------------------------------------------------------------------------
-- Unit Views
--------------------------------------------------------------------------------

local ServicesView = create_resource_view {
  title = 'Services',
  columns = { 'UNIT', 'DESCRIPTION', 'LOADED', 'ACTIVE', 'SUB' },

  filter_fn = function(unit, filter)
    local matches_filter = utils.create_filter_fn(filter)
    return matches_filter(unit.unit) or matches_filter(unit.description)
  end,

  render_cells = function(unit)
    return {
      h.Constant({}, unit.unit),
      h.String(
        {},
        #unit.description > 40 and unit.description:sub(1, 37) .. '...' or unit.description
      ),
      unit.load == 'loaded' and h.DiagnosticOk({}, unit.load) or h.DiagnosticWarn({}, unit.load),
      unit.active == 'active' and h.DiagnosticOk({}, unit.active)
        or h.DiagnosticError({}, unit.active),
      h.Number({}, unit.sub),
    }
  end,

  keymaps = function(unit, on_refresh, namespace)
    return {
      ['gi'] = keymap(
        function() term.open(make_action_command(namespace, unit.unit, 'status')) end
      ),
      ['gs'] = keymap(function()
        term.open(make_action_command(namespace, unit.unit, 'start'))
        vim.schedule(on_refresh)
      end),
      ['gS'] = keymap(function()
        term.open(make_action_command(namespace, unit.unit, 'stop'))
        vim.schedule(on_refresh)
      end),
      ['gr'] = keymap(function()
        term.open(make_action_command(namespace, unit.unit, 'restart'))
        vim.schedule(on_refresh)
      end),
      ['ga'] = keymap(function()
        term.open(make_action_command(namespace, unit.unit, 'enable'))
        vim.schedule(on_refresh)
      end),
      ['gd'] = keymap(function()
        term.open(make_action_command(namespace, unit.unit, 'disable'))
        vim.schedule(on_refresh)
      end),
      ['gl'] = keymap(function() term.open(make_logs_command(namespace, unit.unit)) end),
    }
  end,
}

local TimersView = create_resource_view {
  title = 'Timers',
  columns = { 'UNIT', 'DESCRIPTION', 'ACTIVE', 'NEXT', 'LAST', 'TRIGGERED BY' },

  filter_fn = function(timer, filter)
    local matches_filter = utils.create_filter_fn(filter)
    return matches_filter(timer.unit) or matches_filter(timer.description)
  end,

  render_cells = function(timer)
    return {
      h.Constant({}, timer.unit),
      h.String(
        {},
        #timer.description > 40 and timer.description:sub(1, 37) .. '...' or timer.description
      ),
      timer.active == 'active' and h.DiagnosticOk({}, timer.active)
        or h.DiagnosticWarn({}, timer.active),
      h.Number({}, timer.next_run),
      h.Number({}, timer.last_run),
      h.Comment({}, timer.triggered_by),
    }
  end,

  keymaps = function(timer, on_refresh, namespace)
    return {
      ['gi'] = keymap(function() show_inspect(namespace, timer.unit) end),
      ['gr'] = keymap(function()
        term.open(make_action_command(namespace, timer.unit, 'run-start-interval'))
        vim.schedule(on_refresh)
      end),
      ['gs'] = keymap(function()
        term.open(make_action_command(namespace, timer.unit, 'start'))
        vim.schedule(on_refresh)
      end),
      ['gS'] = keymap(function()
        term.open(make_action_command(namespace, timer.unit, 'stop'))
        vim.schedule(on_refresh)
      end),
      ['gl'] = keymap(function() term.open(make_logs_command(namespace, timer.unit)) end),
    }
  end,
}

local SocketsView = create_resource_view {
  title = 'Sockets',
  columns = { 'UNIT', 'DESCRIPTION', 'ACTIVE', 'SUB', 'LISTEN' },

  filter_fn = function(unit, filter)
    local matches_filter = utils.create_filter_fn(filter)
    return matches_filter(unit.unit)
  end,

  render_cells = function(unit)
    local listen = unit.raw.listen or '-'
    return {
      h.Constant({}, unit.unit),
      h.String(
        {},
        #unit.description > 40 and unit.description:sub(1, 37) .. '...' or unit.description
      ),
      unit.active == 'active' and h.DiagnosticOk({}, unit.active)
        or h.DiagnosticWarn({}, unit.active),
      h.Number({}, unit.sub),
      h.Comment({}, listen),
    }
  end,

  keymaps = function(unit, on_refresh, namespace)
    return {
      ['gi'] = keymap(function() show_inspect(namespace, unit.unit) end),
      ['gs'] = keymap(function()
        term.open(make_action_command(namespace, unit.unit, 'start'))
        vim.schedule(on_refresh)
      end),
      ['gS'] = keymap(function()
        term.open(make_action_command(namespace, unit.unit, 'stop'))
        vim.schedule(on_refresh)
      end),
      ['gr'] = keymap(function()
        term.open(make_action_command(namespace, unit.unit, 'restart'))
        vim.schedule(on_refresh)
      end),
      ['gl'] = keymap(function() term.open(make_logs_command(namespace, unit.unit)) end),
    }
  end,
}

local PathsView = create_resource_view {
  title = 'Paths',
  columns = { 'UNIT', 'DESCRIPTION', 'ACTIVE', 'SUB' },

  filter_fn = function(unit, filter)
    local matches_filter = utils.create_filter_fn(filter)
    return matches_filter(unit.unit)
  end,

  render_cells = function(unit)
    return {
      h.Constant({}, unit.unit),
      h.String(
        {},
        #unit.description > 40 and unit.description:sub(1, 37) .. '...' or unit.description
      ),
      unit.active == 'active' and h.DiagnosticOk({}, unit.active)
        or h.DiagnosticWarn({}, unit.active),
      h.Number({}, unit.sub),
    }
  end,

  keymaps = function(unit, on_refresh, namespace)
    return {
      ['gi'] = keymap(function() show_inspect(namespace, unit.unit) end),
      ['gs'] = keymap(function()
        term.open(make_action_command(namespace, unit.unit, 'start'))
        vim.schedule(on_refresh)
      end),
      ['gS'] = keymap(function()
        term.open(make_action_command(namespace, unit.unit, 'stop'))
        vim.schedule(on_refresh)
      end),
      ['gl'] = keymap(function() term.open(make_logs_command(namespace, unit.unit)) end),
    }
  end,
}

local MountsView = create_resource_view {
  title = 'Mounts',
  columns = { 'UNIT', 'DESCRIPTION', 'ACTIVE', 'SUB', 'WHERE' },

  filter_fn = function(unit, filter)
    local matches_filter = utils.create_filter_fn(filter)
    return matches_filter(unit.unit)
  end,

  render_cells = function(unit)
    local where = unit.raw.where or '-'
    return {
      h.Constant({}, unit.unit),
      h.String(
        {},
        #unit.description > 40 and unit.description:sub(1, 37) .. '...' or unit.description
      ),
      unit.active == 'active' and h.DiagnosticOk({}, unit.active)
        or h.DiagnosticWarn({}, unit.active),
      h.Number({}, unit.sub),
      h.Comment({}, where),
    }
  end,

  keymaps = function(unit, on_refresh, namespace)
    return {
      ['gi'] = keymap(function() show_inspect(namespace, unit.unit) end),
      ['gs'] = keymap(function()
        term.open(make_action_command(namespace, unit.unit, 'start'))
        vim.schedule(on_refresh)
      end),
      ['gS'] = keymap(function()
        term.open(make_action_command(namespace, unit.unit, 'stop'))
        vim.schedule(on_refresh)
      end),
      ['gl'] = keymap(function() term.open(make_logs_command(namespace, unit.unit)) end),
    }
  end,
}

local TargetsView = create_resource_view {
  title = 'Targets',
  columns = { 'UNIT', 'DESCRIPTION', 'ACTIVE', 'SUB' },

  filter_fn = function(unit, filter)
    local matches_filter = utils.create_filter_fn(filter)
    return matches_filter(unit.unit)
  end,

  render_cells = function(unit)
    return {
      h.Constant({}, unit.unit),
      h.String(
        {},
        #unit.description > 40 and unit.description:sub(1, 37) .. '...' or unit.description
      ),
      unit.active == 'active' and h.DiagnosticOk({}, unit.active)
        or h.DiagnosticWarn({}, unit.active),
      h.Number({}, unit.sub),
    }
  end,

  keymaps = function(unit, on_refresh, namespace)
    return {
      ['gi'] = keymap(function() show_inspect(namespace, unit.unit) end),
      ['gs'] = keymap(function()
        term.open(make_action_command(namespace, unit.unit, 'isolate'))
        vim.schedule(on_refresh)
      end),
      ['gl'] = keymap(function() term.open(make_logs_command(namespace, unit.unit)) end),
    }
  end,
}

local SlicesView = create_resource_view {
  title = 'Slices',
  columns = { 'UNIT', 'DESCRIPTION', 'ACTIVE', 'SUB', 'MEMORY' },

  filter_fn = function(unit, filter)
    local matches_filter = utils.create_filter_fn(filter)
    return matches_filter(unit.unit)
  end,

  render_cells = function(unit)
    local memory = unit.raw.memory_current or '-'
    return {
      h.Constant({}, unit.unit),
      h.String(
        {},
        #unit.description > 40 and unit.description:sub(1, 37) .. '...' or unit.description
      ),
      unit.active == 'active' and h.DiagnosticOk({}, unit.active)
        or h.DiagnosticWarn({}, unit.active),
      h.Number({}, unit.sub),
      h.Comment({}, memory),
    }
  end,

  keymaps = function(unit, _on_refresh, namespace)
    return {
      ['gi'] = keymap(function() show_inspect(namespace, unit.unit) end),
    }
  end,
}

local ScopesView = create_resource_view {
  title = 'Scopes',
  columns = { 'UNIT', 'DESCRIPTION', 'ACTIVE', 'SUB', 'PID' },

  filter_fn = function(unit, filter)
    local matches_filter = utils.create_filter_fn(filter)
    return matches_filter(unit.unit)
  end,

  render_cells = function(unit)
    return {
      h.Constant({}, unit.unit),
      h.String(
        {},
        #unit.description > 40 and unit.description:sub(1, 37) .. '...' or unit.description
      ),
      unit.active == 'active' and h.DiagnosticOk({}, unit.active)
        or h.DiagnosticWarn({}, unit.active),
      h.Number({}, unit.sub),
      h.Number({}, unit.main_pid or '-'),
    }
  end,

  keymaps = function(unit, on_refresh, namespace)
    return {
      ['gi'] = keymap(function() show_inspect(namespace, unit.unit) end),
      ['gk'] = keymap(function()
        if unit.main_pid and unit.main_pid ~= '' then
          term.open('sudo kill ' .. unit.main_pid)
          vim.schedule(on_refresh)
        end
      end),
      ['gl'] = keymap(function() term.open(make_logs_command(namespace, unit.unit)) end),
    }
  end,
}

local DevicesView = create_resource_view {
  title = 'Devices',
  columns = { 'UNIT', 'DESCRIPTION', 'ACTIVE', 'SUB' },

  filter_fn = function(unit, filter)
    local matches_filter = utils.create_filter_fn(filter)
    return matches_filter(unit.unit)
  end,

  render_cells = function(unit)
    return {
      h.Constant({}, unit.unit),
      h.String(
        {},
        #unit.description > 40 and unit.description:sub(1, 37) .. '...' or unit.description
      ),
      unit.active == 'active' and h.DiagnosticOk({}, unit.active)
        or h.DiagnosticWarn({}, unit.active),
      h.Number({}, unit.sub),
    }
  end,

  keymaps = function(unit, _on_refresh, namespace)
    return {
      ['gi'] = keymap(function() show_inspect(namespace, unit.unit) end),
    }
  end,
}

--------------------------------------------------------------------------------
-- Page Configuration
--------------------------------------------------------------------------------

--- @type table<systemd.Page, { fetch: fun(callback: fun(any)), state_key: string, view: function }>
local PAGE_CONFIGS = {
  service = {
    fetch = function(cb) fetch_units('system', 'service', cb) end,
    state_key = 'services',
    view = ServicesView,
  },
  timer = {
    fetch = function(cb) fetch_timers('system', cb) end,
    state_key = 'timers',
    view = TimersView,
  },
  socket = {
    fetch = function(cb) fetch_units('system', 'socket', cb) end,
    state_key = 'sockets',
    view = SocketsView,
  },
  path = {
    fetch = function(cb) fetch_units('system', 'path', cb) end,
    state_key = 'paths',
    view = PathsView,
  },
  mount = {
    fetch = function(cb) fetch_units('system', 'mount', cb) end,
    state_key = 'mounts',
    view = MountsView,
  },
  target = {
    fetch = function(cb) fetch_units('system', 'target', cb) end,
    state_key = 'targets',
    view = TargetsView,
  },
  slice = {
    fetch = function(cb) fetch_units('system', 'slice', cb) end,
    state_key = 'slices',
    view = SlicesView,
  },
  scope = {
    fetch = function(cb) fetch_units('system', 'scope', cb) end,
    state_key = 'scopes',
    view = ScopesView,
  },
  device = {
    fetch = function(cb) fetch_units('system', 'device', cb) end,
    state_key = 'devices',
    view = DevicesView,
  },
}

--------------------------------------------------------------------------------
-- App Component
--------------------------------------------------------------------------------

--- @param ctx morph.Ctx<any, systemd.AppState>
local function App(ctx)
  local function refresh(show_loading)
    local state = assert(ctx.state)
    if show_loading then
      state.loading = true
      ctx:update(state)
    end

    local config = assert(PAGE_CONFIGS[state.page])

    local fetch_fn = state.namespace == 'user'
        and function(cb)
          if state.page == 'timer' then
            fetch_timers('user', cb)
          else
            fetch_units('user', state.page, cb)
          end
        end
      or function(cb)
        if state.page == 'timer' then
          fetch_timers('system', cb)
        else
          fetch_units('system', state.page, cb)
        end
      end

    fetch_fn(function(items)
      state[config.state_key] = items
      state.loading = false
      ctx:update(state)
    end)
  end

  local function go_to_page(page)
    local state = assert(ctx.state)
    if state.page == page then return end

    state.page = page
    ctx:update(state)
    vim.fn.winrestview { topline = 1, lnum = 1 }
    refresh()
  end

  if ctx.phase == 'mount' then
    ctx.state = {
      page = 'service',
      show_help = false,
      loading = true,
      namespace = 'system',
      services = {},
      timers = {},
      sockets = {},
      paths = {},
      mounts = {},
      targets = {},
      slices = {},
      scopes = {},
      devices = {},
    } --- @type systemd.AppState
    vim.schedule(refresh)
  end

  local state = assert(ctx.state)

  local nav_keymaps = {
    ['<Leader>r'] = keymap(function()
      vim.schedule(function() refresh(true) end)
    end),
    ['g?'] = keymap(function()
      state.show_help = not state.show_help
      ctx:update(state)
    end),
    ['<Leader>s'] = keymap(function()
      state.namespace = 'system'
      ctx:update(state)
      refresh(true)
    end),
    ['<Leader>u'] = keymap(function()
      state.namespace = 'user'
      ctx:update(state)
      refresh(true)
    end),
  }

  for _, tab in ipairs(TABS) do
    nav_keymaps[tab.key] = keymap(function()
      vim.schedule(function() go_to_page(tab.page) end)
    end)
  end

  local page = assert(state.page)
  local config = assert(PAGE_CONFIGS[page])
  local current_items = state[config.state_key] or {}

  local page_view = h(config.view, {
    items = current_items,
    loading = state.loading,
    on_refresh = refresh,
    namespace = state.namespace,
  })

  return h('text', { nmap = nav_keymaps }, {
    h.RenderMarkdownH1({}, 'Systemd'),
    ' ',
    h.NonText({}, 'ns: '),
    h.Title({}, state.namespace),
    ' ',
    h.NonText({}, 'g? for help'),
    '\n\n',

    h(TabBar, { tabs = TABS, active_page = state.page, on_select = go_to_page, wrap_at = 5 }),

    state.show_help and { h(SystemdHelp, { page = state.page }), '\n' },

    page_view,
  })
end

--------------------------------------------------------------------------------
-- Bootstrap
--------------------------------------------------------------------------------

function M.show()
  vim.cmd.tabnew()
  vim.bo.buftype = 'nofile'
  vim.bo.bufhidden = 'wipe'
  vim.b.completion = false
  vim.wo[0][0].list = false
  vim.api.nvim_buf_set_name(0, 'Systemd')

  Morph.new(0):mount(h(App))
end

return M
