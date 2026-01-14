local Morph = require 'tuis.morph'
local h = Morph.h
local components = require 'tuis.components'
local Table = components.Table
local TabBar = components.TabBar
local Help = components.Help
local term = require 'tuis.term'
local term_emulator = require 'tuis.term_emulator'
local utils = require 'tuis.utils'
local keymap = utils.keymap
local create_scratch_buffer = utils.create_scratch_buffer

local M = {}

--- @type string[]
local CLI_DEPENDENCIES = { 'gcloud', 'jq' }

function M.is_enabled() return utils.check_clis_available(CLI_DEPENDENCIES, true) end

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

--- @type string?
local DEFAULT_PROJECT
local function get_default_project()
  if DEFAULT_PROJECT == nil then
    DEFAULT_PROJECT = vim.trim(
      vim.system({ 'gcloud', 'config', 'get', 'project' }, { text = true }):wait().stdout or ''
    )
  end
  return DEFAULT_PROJECT
end

--- @type string[]?
local AVAILABLE_PROJECTS
local function get_available_projects()
  if AVAILABLE_PROJECTS == nil then
    AVAILABLE_PROJECTS = vim
      .iter(
        vim.json.decode(
          vim
            .system({ 'gcloud', 'projects', 'list', '--format=json' }, { text = true })
            :wait().stdout or '[]'
        )
      )
      :map(function(project) return project.projectId end)
      :totable()
  end
  return AVAILABLE_PROJECTS
end

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

--- @alias gcloud.Page 'instances'|'instance_groups'|'secrets'

--- @class gcloud.Instance
--- @field name string
--- @field id string
--- @field zone string
--- @field status string
--- @field created string
--- @field raw unknown

--- @class gcloud.InstanceGroup
--- @field name string
--- @field id string
--- @field size number
--- @field target_size number
--- @field template string
--- @field status string
--- @field raw unknown

--- @class gcloud.Secret
--- @field name string
--- @field created string
--- @field updated string
--- @field replication string
--- @field raw unknown

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--- Show JSON in a vertical split
--- @param data unknown
local function show_json(data)
  vim.schedule(function()
    create_scratch_buffer('vnew', 'json')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(vim.json.encode(data), '\n'))
    vim.cmd [[%!jq .]]
  end)
end

--------------------------------------------------------------------------------
-- Help System
--------------------------------------------------------------------------------

local HELP_KEYMAPS = {
  instances = {
    { 'gi', 'Show instance details (JSON)' },
    { 'go', 'Open instance in GCP console' },
    { 'gx', 'SSH into instance' },
    { 'gX', 'SSH into instance in new tab' },
    { 'gs', 'View serial port output' },
    { 'gl', 'View instance logs in console' },
  },
  instance_groups = {
    { 'gi', 'Show instance group details (JSON)' },
    { 'go', 'Open instance group in GCP console' },
  },
  secrets = {
    { 'gi', 'Show secret details (JSON)' },
    { 'go', 'Open secret in GCP console' },
    { 'g"', 'Yank secret value to "' },
    { 'g+', 'Yank secret value to +' },
  },
}

local COMMON_KEYMAPS = {
  { 'g1-g3', 'Navigate tabs' },
  { '<Leader>r', 'Refresh' },
  { 'g?', 'Toggle help' },
}

--- @param ctx morph.Ctx<{ page: gcloud.Page }>
local function GcloudHelp(ctx)
  return h(Help, {
    page_keymaps = HELP_KEYMAPS[ctx.props.page],
    common_keymaps = COMMON_KEYMAPS,
  })
end

--------------------------------------------------------------------------------
-- Navigation Components
--------------------------------------------------------------------------------

--- @type { key: string, page: gcloud.Page, label: string }[]
local TABS = {
  { key = 'g1', page = 'instances', label = 'Compute Instances' },
  { key = 'g2', page = 'instance_groups', label = 'Instance Groups' },
  { key = 'g3', page = 'secrets', label = 'Secrets' },
}

--- @param ctx morph.Ctx<{ project: string, on_project_update: fun(project: string) }>
local function ProjectSelector(ctx)
  local function on_enter()
    vim.schedule(function()
      vim.ui.select(get_available_projects(), {}, function(choice)
        if choice then ctx.props.on_project_update(choice) end
      end)
    end)
  end

  return h('text', { nmap = { ['<CR>'] = keymap(on_enter) } }, {
    h.Comment({}, 'Project: '),
    h.Constant({}, ctx.props.project),
    h.Comment({}, ' (press Enter to change)'),
  })
end

--------------------------------------------------------------------------------
-- Data Fetching
--------------------------------------------------------------------------------

--- @param project string
--- @param callback fun(instances: gcloud.Instance[])
local function fetch_instances(project, callback)
  vim.system(
    { 'gcloud', 'compute', 'instances', '--project', project, 'list', '--format=json' },
    { text = true },
    function(out)
      vim.schedule(function()
        ---@type gcloud.Instance[]
        local instances = {}
        local raw_instances = vim.json.decode(out.stdout or '[]')
        for _, raw_inst in ipairs(raw_instances) do
          table.insert(instances, {
            name = raw_inst.name,
            id = raw_inst.id,
            zone = vim.fs.basename(raw_inst.zone),
            status = raw_inst.status,
            created = (raw_inst.creationTimestamp:gsub('%.%d+.+$', ''):gsub('T', ' ')),
            raw = raw_inst,
          })
        end
        table.sort(instances, function(a, b) return a.name < b.name end)
        callback(instances)
      end)
    end
  )
end

--- @param project string
--- @param callback fun(groups: gcloud.InstanceGroup[])
local function fetch_instance_groups(project, callback)
  vim.system({
    'gcloud',
    'compute',
    'instance-groups',
    'managed',
    'list',
    '--project',
    project,
    '--format=json',
  }, { text = true }, function(out)
    vim.schedule(function()
      ---@type gcloud.InstanceGroup[]
      local groups = {}
      local raw_groups = vim.json.decode(out.stdout or '[]')
      for _, raw_group in ipairs(raw_groups) do
        table.insert(groups, {
          name = raw_group.name,
          id = raw_group.id,
          size = raw_group.currentActions and raw_group.currentActions.none or 0,
          target_size = raw_group.targetSize or 0,
          template = vim.fs.basename(raw_group.instanceTemplate or ''),
          status = raw_group.status and raw_group.status.isStable and 'STABLE' or 'UPDATING',
          raw = raw_group,
        })
      end
      callback(groups)
    end)
  end)
end

--- @param project string
--- @param callback fun(secrets: gcloud.Secret[])
local function fetch_secrets(project, callback)
  vim.system(
    { 'gcloud', 'secrets', 'list', '--project', project, '--format=json' },
    { text = true },
    function(out)
      vim.schedule(function()
        ---@type gcloud.Secret[]
        local secrets = {}
        local raw_secrets = vim.json.decode(out.stdout or '[]')
        for _, raw_secret in ipairs(raw_secrets) do
          table.insert(secrets, {
            name = vim.fs.basename(raw_secret.name),
            created = (raw_secret.createTime:gsub('%.%d+.+$', ''):gsub('T', ' ')),
            updated = raw_secret.updateTime and (raw_secret.updateTime
              :gsub('%.%d+.+$', '')
              :gsub('T', ' ')) or 'N/A',
            replication = raw_secret.replication
                and raw_secret.replication.automatic
                and 'automatic'
              or 'user-managed',
            raw = raw_secret,
          })
        end
        table.sort(secrets, function(a, b) return a.name < b.name end)
        callback(secrets)
      end)
    end
  )
end

--------------------------------------------------------------------------------
-- Resource View Factory
--------------------------------------------------------------------------------

--- @class gcloud.ViewConfig
--- @field title string
--- @field columns string[]
--- @field filter_fn fun(item: any, filter: string): boolean
--- @field render_cells fun(item: any): morph.Tree[]
--- @field keymaps fun(item: any, project: string): table<string, fun(): string>

--- @param config gcloud.ViewConfig
--- @return fun(ctx: morph.Ctx): morph.Tree
local function create_resource_view(config)
  --- @param ctx morph.Ctx<{ items: any[], loading: boolean, project: string }, { filter: string }>
  return function(ctx)
    if ctx.phase == 'mount' then ctx.state = { filter = '' } end
    local state = assert(ctx.state)

    local header_cells = {}
    for _, col in ipairs(config.columns) do
      table.insert(header_cells, h.Constant({}, col))
    end
    local rows = { { cells = header_cells } }

    for _, item in ipairs(ctx.props.items or {}) do
      if config.filter_fn(item, state.filter or '') then
        table.insert(rows, {
          nmap = config.keymaps(item, ctx.props.project),
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
-- Compute Instances View
--------------------------------------------------------------------------------

local InstancesView = create_resource_view {
  title = 'Compute Instances',
  columns = { 'NAME', 'ZONE', 'CREATED', 'STATUS' },
  filter_fn = function(item, filter)
    local matches_filter = utils.create_filter_fn(filter)
    return matches_filter(item.name)
  end,

  render_cells = function(instance)
    local status_cell = instance.status == 'RUNNING' and h.DiagnosticOk({}, instance.status)
      or instance.status == 'TERMINATED' and h.DiagnosticError({}, instance.status)
      or h.DiagnosticWarn({}, instance.status)

    return {
      h.Constant({}, instance.name),
      h.String({}, instance.zone),
      h.Number({}, instance.created),
      status_cell,
    }
  end,

  keymaps = function(instance, project)
    local ssh_cmd = 'gcloud compute ssh --project '
      .. project
      .. ' --zone '
      .. instance.zone
      .. ' '
      .. instance.name

    return {
      ['gi'] = keymap(function() show_json(instance.raw) end),
      ['go'] = keymap(
        function()
          vim.ui.open(
            'https://console.cloud.google.com/compute/instancesDetail/zones/'
              .. instance.zone
              .. '/instances/'
              .. instance.id
              .. '?project='
              .. project
          )
        end
      ),
      ['gx'] = keymap(function()
        vim.schedule(function() term.open(ssh_cmd) end)
      end),
      ['gX'] = keymap(function()
        vim.schedule(function()
          vim.ui.select({ 'tmux', 'wezterm', 'ghostty' }, {}, function(choice)
            if choice then term_emulator.new_tab(ssh_cmd, choice) end
          end)
        end)
      end),
      ['gs'] = keymap(function()
        vim.schedule(
          function()
            term.open(
              'gcloud compute instances get-serial-port-output --port=1 --project '
                .. project
                .. ' --zone '
                .. instance.zone
                .. ' '
                .. instance.name
            )
          end
        )
      end),
      ['gl'] = keymap(function()
        local query = 'resource.labels.instance_id=' .. instance.id
        vim.ui.open(
          'https://console.cloud.google.com/logs/query;query=' .. query .. '?project=' .. project
        )
      end),
    }
  end,
}

--------------------------------------------------------------------------------
-- Instance Groups View
--------------------------------------------------------------------------------

local InstanceGroupsView = create_resource_view {
  title = 'Managed Instance Groups',
  columns = { 'NAME', 'SIZE', 'TEMPLATE', 'STATUS' },
  filter_fn = function(item, filter)
    local matches_filter = utils.create_filter_fn(filter)
    return matches_filter(item.name)
  end,

  render_cells = function(group)
    local status_cell = group.status == 'STABLE' and h.DiagnosticOk({}, group.status)
      or h.DiagnosticWarn({}, group.status)

    return {
      h.Constant({}, group.name),
      h.Number({}, group.size .. '/' .. group.target_size),
      h.Identifier({}, group.template),
      status_cell,
    }
  end,

  keymaps = function(group, project)
    return {
      ['gi'] = keymap(function() show_json(group.raw) end),
      ['go'] = keymap(function()
        local region = vim.fs.basename(group.raw.region)
        vim.ui.open(
          'https://console.cloud.google.com/compute/instance_groups/details/'
            .. region
            .. '/'
            .. group.name
            .. '?&project='
            .. project
        )
      end),
    }
  end,
}

--------------------------------------------------------------------------------
-- Secrets View
--------------------------------------------------------------------------------

local SecretsView = create_resource_view {
  title = 'Secrets',
  columns = { 'NAME', 'CREATED', 'UPDATED', 'REPLICATION' },
  filter_fn = function(item, filter)
    local matches_filter = utils.create_filter_fn(filter)
    return matches_filter(item.name)
  end,

  render_cells = function(secret)
    return {
      h.Constant({}, secret.name),
      h.Number({}, secret.created),
      h.Number({}, secret.updated),
      h.String({}, secret.replication),
    }
  end,

  keymaps = function(secret, project)
    local function yank_to(reg)
      vim.system(
        {
          'gcloud',
          'secrets',
          'versions',
          'access',
          'latest',
          '--secret',
          secret.name,
          '--project',
          project,
        },
        { text = true },
        vim.schedule_wrap(function(out)
          if out.code ~= 0 then
            vim.notify('Failed to access secret: ' .. (out.stderr or ''), vim.log.levels.ERROR)
            return
          end
          vim.fn.setreg(reg, out.stdout or '')
          vim.notify('Secret value yanked to ' .. reg, vim.log.levels.INFO)
        end)
      )
    end

    return {
      ['gi'] = keymap(function() show_json(secret.raw) end),
      ['go'] = keymap(
        function()
          vim.ui.open(
            'https://console.cloud.google.com/security/secret-manager/secret/'
              .. secret.name
              .. '/versions?project='
              .. project
          )
        end
      ),
      ['g"'] = keymap(function()
        vim.schedule(function() yank_to '"' end)
      end),
      ['g+'] = keymap(function()
        vim.schedule(function() yank_to '+' end)
      end),
    }
  end,
}

--------------------------------------------------------------------------------
-- Page Configuration
--------------------------------------------------------------------------------

--- @class gcloud.PageConfig
--- @field fetch fun(project: string, callback: fun(items: any[]))
--- @field state_key string
--- @field view function

--- @type table<gcloud.Page, gcloud.PageConfig>
local PAGE_CONFIGS = {
  instances = { fetch = fetch_instances, state_key = 'instances', view = InstancesView },
  instance_groups = {
    fetch = fetch_instance_groups,
    state_key = 'instance_groups',
    view = InstanceGroupsView,
  },
  secrets = { fetch = fetch_secrets, state_key = 'secrets', view = SecretsView },
}

--------------------------------------------------------------------------------
-- App Component
--------------------------------------------------------------------------------

--- @class gcloud.AppState
--- @field page gcloud.Page
--- @field project string
--- @field show_help boolean
--- @field loading boolean
--- @field instances gcloud.Instance[]
--- @field instance_groups gcloud.InstanceGroup[]
--- @field secrets gcloud.Secret[]

--- @param ctx morph.Ctx<any, gcloud.AppState>
local function App(ctx)
  local function refresh()
    local state = assert(ctx.state)
    state.loading = true
    ctx:update(state)

    --- @type gcloud.PageConfig
    local config = PAGE_CONFIGS[state.page]
    config.fetch(state.project, function(items)
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
      page = 'instances',
      project = get_default_project(),
      show_help = false,
      loading = true,
      instances = {},
      instance_groups = {},
      secrets = {},
    }
    vim.schedule(refresh)
  end

  local state = assert(ctx.state)

  -- Build navigation keymaps
  local nav_keymaps = {
    ['<Leader>r'] = keymap(function() vim.schedule(refresh) end),
    ['g?'] = keymap(function()
      state.show_help = not state.show_help
      ctx:update(state)
    end),
  }
  for _, tab in ipairs(TABS) do
    nav_keymaps[tab.key] = keymap(function()
      vim.schedule(function() go_to_page(tab.page) end)
    end)
  end

  -- Render current page
  --- @cast state.page gcloud.Page
  local page = state.page
  --- @type gcloud.PageConfig
  local config = PAGE_CONFIGS[page]
  local page_content = h(config.view, {
    items = state[config.state_key],
    loading = state.loading,
    project = state.project,
  })

  return h('text', { nmap = nav_keymaps }, {
    -- Header line
    h.RenderMarkdownH1({}, 'GCloud'),
    ' ',
    h.NonText({}, 'Project: '),
    h.Title({}, state.project),
    ' ',
    h.NonText({}, 'g? for help'),
    '\n\n',

    -- Tab navigation
    h(TabBar, { tabs = TABS, active_page = state.page, on_select = go_to_page }),

    -- Project selector
    h(ProjectSelector, {
      project = state.project,
      on_project_update = function(p)
        state.project = p
        ctx:update(state)
        refresh()
      end,
    }),
    '\n\n',

    -- Help panel (toggleable)
    state.show_help and { h(GcloudHelp, { page = state.page }), '\n' },

    -- Main content
    page_content,
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
  vim.api.nvim_buf_set_name(0, 'GCloud')

  Morph.new(0):mount(h(App))
end

return M
