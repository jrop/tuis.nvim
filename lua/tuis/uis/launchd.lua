local Morph = require 'tuis.morph'
local h = Morph.h
local components = require 'tuis.components'
local Table = components.Table
local TabBar = components.TabBar
local Help = components.Help
local sudo = require 'tuis.sudo'
local utils = require 'tuis.utils'
local keymap = utils.keymap

local M = {}

--- @type string[]
local CLI_DEPENDENCIES = { 'launchctl', 'ls', 'sudo' }

function M.is_enabled()
  return vim.fn.has 'mac' == 1 and utils.check_clis_available(CLI_DEPENDENCIES, true)
end

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

--- @alias launchd.Page 'service'|'agent'|'daemon'|'limit'

--- @class morphui.launchd.LaunchdService
--- @field name string
--- @field pid string
--- @field status string

--- @class morphui.launchd.AgentInfo
--- @field label string
--- @field program string
--- @field run_at_load boolean
--- @field keep_alive boolean
--- @field path string

--- @class morphui.launchd.DaemonInfo
--- @field label string
--- @field program string
--- @field run_at_load boolean
--- @field keep_alive boolean
--- @field path string

--- @class morphui.launchd.LimitInfo
--- @field domain string
--- @field item string
--- @field cur number
--- @field max number

--- @class morphui.launchd.AppState
--- @field page launchd.Page
--- @field show_help boolean
--- @field loading boolean
--- @field namespace 'system'|'user'
--- @field services morphui.launchd.LaunchdService[]
--- @field agents morphui.launchd.AgentInfo[]
--- @field daemons morphui.launchd.DaemonInfo[]
--- @field limits morphui.launchd.LimitInfo[]

--- @class morphui.launchd.SystemOpts extends vim.SystemOpts
--- @field root? boolean

--- @param cmd string[]
--- @param opts? morphui.launchd.SystemOpts
--- @param on_exit? fun(out: vim.SystemCompleted)
--- @return vim.SystemObj
local function run(cmd, opts, on_exit)
  local function do_cmd()
    return vim.system(cmd, opts --[[@as vim.SystemOpts]], on_exit)
  end

  if not opts or not opts.root then return do_cmd() end

  table.insert(cmd, 1, 'sudo')
  sudo.with_sudo(function() do_cmd() end)
end

--------------------------------------------------------------------------------
-- Navigation Components
--------------------------------------------------------------------------------

--- @type { key: string, page: launchd.Page, label: string }[]
local TABS = {
  { key = 'g1', page = 'service', label = 'Services' },
  { key = 'g2', page = 'agent', label = 'Agents' },
  { key = 'g3', page = 'daemon', label = 'Daemons' },
  { key = 'g4', page = 'limit', label = 'Limits' },
}

--------------------------------------------------------------------------------
-- Help System
--------------------------------------------------------------------------------

local HELP_KEYMAPS = {
  service = {
    { 'gi', 'Show service details' },
    { 'gs', 'Start service (load)' },
    { 'gS', 'Stop service (bootout)' },
  },
  agent = {
    { 'gi', 'Show agent plist' },
    { 'gs', 'Enable/load agent' },
    { 'gS', 'Disable/unload agent' },
    { 'ge', 'Edit agent plist' },
  },
  daemon = {
    { 'gi', 'Show daemon plist' },
    { 'gs', 'Enable/load daemon' },
    { 'gS', 'Disable/unload daemon' },
    { 'ge', 'Edit daemon plist' },
  },
  limit = {
    { 'gi', 'Show limit details' },
    { 'gs', 'Increase soft limit' },
    { 'gS', 'Increase hard limit' },
  },
}

local COMMON_KEYMAPS = {
  { 'g1-g4', 'Navigate tabs' },
  { '<Leader>r', 'Refresh' },
  { '<Leader>s', 'Switch to system namespace' },
  { '<Leader>u', 'Switch to user namespace' },
  { 'g?', 'Toggle help' },
}

--- @param ctx morph.Ctx<{ page: launchd.Page }>
local function LaunchdHelp(ctx)
  return h(Help, {
    page_keymaps = HELP_KEYMAPS[ctx.props.page],
    common_keymaps = COMMON_KEYMAPS,
  })
end

--------------------------------------------------------------------------------
-- Data Fetching
--------------------------------------------------------------------------------

--- @param callback fun(services: morphui.launchd.LaunchdService[])
local function fetch_services(namespace, callback)
  run(
    { 'launchctl', 'list' },
    {
      root = namespace == 'system',
      text = true,
    },
    vim.schedule_wrap(function(result)
      local services = {}
      vim.iter(vim.split(result.stdout or '', '\n')):skip(1):each(
        --- @param line string
        function(line)
          local pid, status, name = line:match '^(%S+)%s+(%S+)%s+(%S+)$'
          if not pid or not status or not name then return end
          table.insert(services, {
            name = name,
            pid = pid,
            status = status,
          })
        end
      )

      table.sort(services, function(a, b) return a.name < b.name end)
      callback(services)
    end)
  )
end

--- @param callback fun(agents: morphui.launchd.AgentInfo[])
local function fetch_agents(namespace, callback)
  local base_dir = namespace == 'system' and '/Library/LaunchAgents/'
    or vim.env.HOME .. '/Library/LaunchAgents/'

  vim.system(
    { 'find', base_dir, '-name', '*.plist', '-maxdepth', '1' },
    { text = true },
    vim.schedule_wrap(function(find_result)
      if find_result.code ~= 0 then
        callback {}
        return
      end

      local plist_files = vim.split(find_result.stdout or '', '\n')
      if #plist_files == 1 and plist_files[1] == '' then
        callback {}
        return
      end

      local agents = {}
      local pending = 0

      for _, path in ipairs(plist_files) do
        if path == '' then
        else
          pending = pending + 1

          vim.system(
            { 'defaults', 'read', path, 'Label' },
            { text = true },
            vim.schedule_wrap(function(label_result)
              if label_result.code ~= 0 then
                pending = pending - 1
                if pending == 0 then
                  table.sort(agents, function(a, b) return a.label < b.label end)
                  callback(agents)
                end
              else
                vim.system(
                  { 'defaults', 'read', path, 'Program' },
                  { text = true },
                  vim.schedule_wrap(function(program_result)
                    local program = program_result.code == 0
                        and vim.trim(program_result.stdout or '')
                      or ''

                    table.insert(agents, {
                      label = vim.trim(label_result.stdout or ''),
                      program = program,
                      run_at_load = false,
                      keep_alive = false,
                      path = path,
                    })

                    pending = pending - 1
                    if pending == 0 then
                      table.sort(agents, function(a, b) return a.label < b.label end)
                      callback(agents)
                    end
                  end)
                )
              end
            end)
          )
        end
      end

      if pending == 0 then callback {} end
    end)
  )
end

--- @param callback fun(daemons: morphui.launchd.DaemonInfo[])
local function fetch_daemons(namespace, callback)
  local base_dir = '/Library/LaunchDaemons/'

  vim.system(
    { 'find', base_dir, '-name', '*.plist', '-maxdepth', '1' },
    { text = true },
    vim.schedule_wrap(function(find_result)
      if find_result.code ~= 0 then
        callback {}
        return
      end

      local plist_files = vim.split(find_result.stdout or '', '\n')
      if #plist_files == 1 and plist_files[1] == '' then
        callback {}
        return
      end

      local daemons = {}
      local pending = 0

      for _, path in ipairs(plist_files) do
        if path == '' then
        else
          pending = pending + 1

          vim.system(
            { 'defaults', 'read', path, 'Label' },
            { text = true },
            vim.schedule_wrap(function(label_result)
              if label_result.code ~= 0 then
                pending = pending - 1
                if pending == 0 then
                  table.sort(daemons, function(a, b) return a.label < b.label end)
                  callback(daemons)
                end
              else
                vim.system(
                  { 'defaults', 'read', path, 'Program' },
                  { text = true },
                  vim.schedule_wrap(function(program_result)
                    local program = program_result.code == 0
                        and vim.trim(program_result.stdout or '')
                      or ''

                    table.insert(daemons, {
                      label = vim.trim(label_result.stdout or ''),
                      program = program,
                      run_at_load = false,
                      keep_alive = false,
                      path = path,
                    })

                    pending = pending - 1
                    if pending == 0 then
                      table.sort(daemons, function(a, b) return a.label < b.label end)
                      callback(daemons)
                    end
                  end)
                )
              end
            end)
          )
        end
      end

      if pending == 0 then callback {} end
    end)
  )
end

--- @param callback fun(limits: morphui.launchd.LimitInfo[])
local function fetch_limits(namespace, callback)
  run(
    { 'launchctl', 'limit' },
    { text = true },
    vim.schedule_wrap(function(result)
      local limits = {}
      vim.iter(vim.split(result.stdout or '', '\n')):each(function(line)
        line = vim.trim(line)
        local domain, cur, max = line:match '^(%S+)%s+(%S+)%s+(%S+)$'
        if not domain or not cur then return end
        table.insert(limits, {
          domain = domain,
          item = 'limit',
          cur = cur,
          max = max,
        })
      end)
      callback(limits)
    end)
  )
end

--------------------------------------------------------------------------------
-- View Components
--------------------------------------------------------------------------------

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
        page_size = math.floor(vim.o.lines * 0.8),
      }),
    }
  end
end

local ServicesView = create_resource_view {
  title = 'Services',
  columns = { 'NAME', 'PID', 'STATUS' },

  filter_fn = function(service, filter)
    if filter == '' then return true end
    return service.name:find(filter, 1, true) ~= nil
  end,

  render_cells = function(service)
    return {
      h.Constant({}, service.name),
      h.Number({}, service.pid),
      tonumber(service.status) < 0 and h.DiagnosticError({}, service.status)
        or h.DiagnosticOk({}, service.status),
    }
  end,

  keymaps = function(service, on_refresh, namespace)
    return {
      ['gi'] = keymap(function()
        vim.schedule(function()
          vim.cmd.vnew()
          vim.bo.buftype = 'nofile'
          vim.bo.bufhidden = 'wipe'
          vim.bo.buflisted = false

          local prefix = namespace == 'system' and 'system/' or 'gui/501/'
          run(
            { 'launchctl', 'print', prefix .. service.name },
            { root = namespace == 'system', text = true },
            vim.schedule_wrap(
              function(result)
                vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(result.stdout or '', '\n'))
              end
            )
          )
        end)
      end),
      ['gs'] = keymap(
        function()
          run(
            { 'launchctl', 'load', service.name },
            { root = namespace == 'system', text = true },
            vim.schedule_wrap(on_refresh)
          )
        end
      ),
      ['gS'] = keymap(
        function()
          run({
            'launchctl',
            'bootout',
            (namespace == 'system' and 'system/' or '') .. service.name,
          }, { root = namespace == 'system', text = true }, vim.schedule_wrap(on_refresh))
        end
      ),
    }
  end,
}

local AgentsView = create_resource_view {
  title = 'LaunchAgents',
  columns = { 'LABEL', 'PROGRAM', 'PATH' },

  filter_fn = function(agent, filter)
    if filter == '' then return true end
    return agent.label:find(filter, 1, true) ~= nil or agent.program:find(filter, 1, true) ~= nil
  end,

  render_cells = function(agent)
    return {
      h.Constant({}, agent.label),
      h.String({}, agent.program),
      h.Comment({}, agent.path),
    }
  end,

  keymaps = function(agent, on_refresh, namespace)
    return {
      ['gi'] = keymap(function()
        vim.cmd.vnew()
        vim.bo.buftype = 'nofile'
        vim.bo.bufhidden = 'wipe'
        vim.bo.buflisted = false
        vim.cmd.setfiletype 'plist'
        vim.system({ 'cat', agent.path }, { text = true }, function(result)
          vim.schedule(
            function()
              vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(result.stdout or '', '\n'))
            end
          )
        end)
      end),
      ['gs'] = keymap(
        function()
          run({ 'launchctl', 'load', agent.path }, { text = true }, vim.schedule_wrap(on_refresh))
        end
      ),
      ['gS'] = keymap(
        function()
          run({ 'launchctl', 'unload', agent.path }, { text = true }, vim.schedule_wrap(on_refresh))
        end
      ),
      ['ge'] = keymap(function()
        vim.schedule(function() vim.cmd.edit(agent.path) end)
      end),
    }
  end,
}

local DaemonsView = create_resource_view {
  title = 'LaunchDaemons',
  columns = { 'LABEL', 'PROGRAM', 'PATH' },

  filter_fn = function(daemon, filter)
    if filter == '' then return true end
    return daemon.label:find(filter, 1, true) ~= nil or daemon.program:find(filter, 1, true) ~= nil
  end,

  render_cells = function(daemon)
    return {
      h.Constant({}, daemon.label),
      h.String({}, daemon.program),
      h.Comment({}, daemon.path),
    }
  end,

  keymaps = function(daemon, on_refresh, namespace)
    return {
      ['gi'] = keymap(function()
        vim.cmd.vnew()
        vim.bo.buftype = 'nofile'
        vim.bo.bufhidden = 'wipe'
        vim.bo.buflisted = false
        vim.cmd.setfiletype 'plist'
        vim.system({ 'cat', daemon.path }, { text = true }, function(result)
          vim.schedule(
            function()
              vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(result.stdout or '', '\n'))
            end
          )
        end)
      end),
      ['gs'] = keymap(
        function()
          run(
            { 'launchctl', 'load', daemon.path },
            { root = true, text = true },
            vim.schedule_wrap(on_refresh)
          )
        end
      ),
      ['gS'] = keymap(
        function()
          run(
            { 'launchctl', 'unload', daemon.path },
            { root = true, text = true },
            vim.schedule_wrap(on_refresh)
          )
        end
      ),
      ['ge'] = keymap(function()
        vim.schedule(function() vim.cmd.edit(daemon.path) end)
      end),
    }
  end,
}

local LimitsView = create_resource_view {
  title = 'Resource Limits',
  columns = { 'DOMAIN', 'SOFT', 'HARD' },

  filter_fn = function(limit, filter)
    if filter == '' then return true end
    return limit.domain:find(filter, 1, true) ~= nil
  end,

  render_cells = function(limit)
    return {
      h.Constant({}, limit.domain),
      h.String({}, limit.cur),
      h.String({}, limit.max),
    }
  end,

  keymaps = function(limit, on_refresh, namespace)
    local function to_number(s)
      local n = tonumber(s)
      return n or 0
    end
    return {
      ['gi'] = keymap(
        function()
          vim.notify(
            limit.domain .. ': soft=' .. limit.cur .. ', hard=' .. limit.max,
            vim.log.levels.INFO
          )
        end
      ),
      ['gs'] = keymap(function()
        local cur_val = to_number(limit.cur)
        if cur_val == 0 then return end
        local max_val = limit.max ~= 'unlimited' and tonumber(limit.max) or cur_val * 2
        local new_limit = tostring(math.min(max_val, cur_val * 2))
        run(
          { 'launchctl', 'limit', limit.domain, new_limit, limit.max },
          { root = namespace == 'system', text = true },
          vim.schedule_wrap(on_refresh)
        )
      end),
      ['gS'] = keymap(function()
        local max_val = to_number(limit.max)
        if max_val == 0 then return end
        local new_max = tostring(max_val * 2)
        run(
          { 'launchctl', 'limit', limit.domain, limit.cur, new_max },
          { root = namespace == 'system', text = true },
          vim.schedule_wrap(on_refresh)
        )
      end),
    }
  end,
}

--------------------------------------------------------------------------------
-- Page Configuration
--------------------------------------------------------------------------------

--- @type table<launchd.Page, { fetch: fun(callback: fun(any)), state_key: string, view: function }>
local PAGE_CONFIGS = {
  service = {
    fetch = function(namespace, cb) fetch_services(namespace, cb) end,
    state_key = 'services',
    view = ServicesView,
  },
  agent = {
    fetch = function(namespace, cb) fetch_agents(namespace, cb) end,
    state_key = 'agents',
    view = AgentsView,
  },
  daemon = {
    fetch = function(namespace, cb) fetch_daemons(namespace, cb) end,
    state_key = 'daemons',
    view = DaemonsView,
  },
  limit = {
    fetch = function(namespace, cb) fetch_limits(namespace, cb) end,
    state_key = 'limits',
    view = LimitsView,
  },
}

--------------------------------------------------------------------------------
-- App Component
--------------------------------------------------------------------------------

--- @param ctx morph.Ctx<any, morphui.launchd.AppState>
local function App(ctx)
  local function refresh(show_loading)
    local state = assert(ctx.state)
    if show_loading then
      state.loading = true
      ctx:update(state)
    end

    local config = PAGE_CONFIGS[state.page]
    config.fetch(state.namespace, function(items)
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
      namespace = 'user',
      services = {},
      agents = {},
      daemons = {},
      limits = {},
    } --- @type morphui.launchd.AppState
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

  local config = PAGE_CONFIGS[state.page]
  local current_items = state[config.state_key] or {}

  local page_view = h(config.view, {
    items = current_items,
    loading = state.loading,
    on_refresh = refresh,
    namespace = state.namespace,
  })

  return h('text', { nmap = nav_keymaps }, {
    h.RenderMarkdownH1({}, 'Launchd'),
    ' ',
    h.NonText({}, 'ns: '),
    h.Title({}, state.namespace),
    ' ',
    h.NonText({}, 'g? for help'),
    '\n\n',

    h(TabBar, { tabs = TABS, active_page = state.page, on_select = go_to_page, wrap_at = 5 }),

    state.show_help and { h(LaunchdHelp, { page = state.page }), '\n' },

    page_view,
  })
end

function M.show()
  vim.cmd.tabnew()
  vim.bo.buftype = 'nofile'
  vim.bo.bufhidden = 'wipe'
  vim.b.completion = false
  vim.wo[0][0].list = false
  vim.api.nvim_buf_set_name(0, 'Launchd')

  Morph.new(0):mount(h(App))
end

return M
