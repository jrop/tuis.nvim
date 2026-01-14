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
local CLI_DEPENDENCIES = { 'aws', 'jq' }

function M.is_enabled() return utils.check_clis_available(CLI_DEPENDENCIES, true) end

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local function get_default_region()
  --- @type string
  local r = vim.trim(
    vim.system({ 'aws', 'configure', 'get', 'region' }, { text = true }):wait().stdout or ''
  )
  if r == '' then r = 'us-east-1' end
  return r
end

--- @type string[]
local AVAILABLE_REGIONS = {
  'us-east-1',
  'us-east-2',
  'us-west-1',
  'us-west-2',
  'eu-west-1',
  'eu-west-2',
  'eu-west-3',
  'eu-central-1',
  'ap-southeast-1',
  'ap-southeast-2',
  'ap-northeast-1',
  'ap-northeast-2',
  'ap-south-1',
  'sa-east-1',
  'ca-central-1',
}

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

--- @alias aws.Page 'instances'|'lambdas'|'auto_scaling_groups'

--- @class aws.Instance
--- @field name string
--- @field id string
--- @field type string
--- @field state string
--- @field public_ip string?
--- @field private_ip string
--- @field raw unknown

--- @class aws.Lambda
--- @field name string
--- @field runtime string
--- @field memory integer
--- @field timeout integer
--- @field last_modified string
--- @field raw unknown

--- @class aws.AutoScalingGroup
--- @field name string
--- @field arn string
--- @field min_size number
--- @field max_size number
--- @field desired_capacity number
--- @field instances number
--- @field health_status string
--- @field launch_config_name string
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
    { 'go', 'Open instance in AWS console' },
    { 'gx', 'SSH into instance (SSM)' },
    { 'gX', 'SSH into instance in new tab' },
    { 'g+', 'Yank SSH command to +' },
    { 'g"', 'Yank SSH command to "' },
  },
  lambdas = {
    { 'gi', 'Show lambda details (JSON)' },
    { 'go', 'Open lambda in AWS console' },
    { 'gl', 'View lambda logs' },
    { 'g+', 'Yank log command to +' },
    { 'g"', 'Yank log command to "' },
  },
  auto_scaling_groups = {
    { 'gi', 'Show auto scaling group details (JSON)' },
    { 'go', 'Open auto scaling group in AWS console' },
    { 'gv', 'View instances in auto scaling group' },
  },
}

local COMMON_KEYMAPS = {
  { 'g1-g3', 'Navigate tabs' },
  { '<Leader>r', 'Refresh' },
  { 'g?', 'Toggle help' },
}

--- @param ctx morph.Ctx<{ page: aws.Page }>
local function AwsHelp(ctx)
  return h(Help, {
    page_keymaps = HELP_KEYMAPS[ctx.props.page],
    common_keymaps = COMMON_KEYMAPS,
  })
end

--------------------------------------------------------------------------------
-- Navigation Components
--------------------------------------------------------------------------------

--- @type { key: string, page: aws.Page, label: string }[]
local TABS = {
  { key = 'g1', page = 'instances', label = 'EC2 Instances' },
  { key = 'g2', page = 'lambdas', label = 'Lambda Functions' },
  { key = 'g3', page = 'auto_scaling_groups', label = 'Auto Scaling Groups' },
}

--- @param ctx morph.Ctx<{ region: string, on_region_update: fun(region: string) }>
local function RegionSelector(ctx)
  local function on_enter()
    vim.schedule(function()
      vim.ui.select(AVAILABLE_REGIONS, {}, function(choice)
        if choice then ctx.props.on_region_update(choice) end
      end)
    end)
  end

  return h('text', { nmap = { ['<CR>'] = keymap(on_enter) } }, {
    h.Comment({}, 'Region: '),
    h.Constant({}, ctx.props.region),
    h.Comment({}, ' (press Enter to change)'),
  })
end

--------------------------------------------------------------------------------
-- Data Fetching
--------------------------------------------------------------------------------

--- @param region string
--- @param callback fun(instances: aws.Instance[])
local function fetch_instances(region, callback)
  vim.system(
    { 'aws', 'ec2', 'describe-instances', '--region', region, '--output', 'json' },
    { text = true },
    function(out)
      vim.schedule(function()
        ---@type aws.Instance[]
        local instances = {}
        local raw_response = vim.json.decode(out.stdout or '{}')

        for _, reservation in ipairs(raw_response.Reservations or {}) do
          for _, raw_inst in ipairs(reservation.Instances or {}) do
            local name = raw_inst.InstanceId
            for _, tag in ipairs(raw_inst.Tags or {}) do
              if tag.Key == 'Name' then
                name = tag.Value
                break
              end
            end

            table.insert(instances, {
              name = name,
              id = raw_inst.InstanceId,
              type = raw_inst.InstanceType,
              state = raw_inst.State.Name,
              public_ip = raw_inst.PublicIpAddress,
              private_ip = raw_inst.PrivateIpAddress or '',
              raw = raw_inst,
            })
          end
        end
        table.sort(instances, function(a, b) return a.name < b.name end)
        callback(instances)
      end)
    end
  )
end

--- @param region string
--- @param callback fun(lambdas: aws.Lambda[])
local function fetch_lambdas(region, callback)
  vim.system(
    { 'aws', 'lambda', 'list-functions', '--region', region, '--output', 'json' },
    { text = true },
    function(out)
      vim.schedule(function()
        ---@type aws.Lambda[]
        local lambdas = {}
        local raw_response = vim.json.decode(out.stdout or '{}')

        for _, raw_func in ipairs(raw_response.Functions or {}) do
          table.insert(lambdas, {
            name = raw_func.FunctionName,
            runtime = raw_func.Runtime or 'unknown',
            memory = raw_func.MemorySize or 0,
            timeout = raw_func.Timeout or 0,
            last_modified = raw_func.LastModified or '',
            raw = raw_func,
          })
        end
        table.sort(lambdas, function(a, b) return a.name < b.name end)
        callback(lambdas)
      end)
    end
  )
end

--- @param region string
--- @param callback fun(groups: aws.AutoScalingGroup[])
local function fetch_auto_scaling_groups(region, callback)
  vim.system({
    'aws',
    'autoscaling',
    'describe-auto-scaling-groups',
    '--region',
    region,
    '--output',
    'json',
  }, { text = true }, function(out)
    vim.schedule(function()
      ---@type aws.AutoScalingGroup[]
      local groups = {}
      local raw_response = vim.json.decode(out.stdout or '{}')

      for _, raw_group in ipairs(raw_response.AutoScalingGroups or {}) do
        table.insert(groups, {
          name = raw_group.AutoScalingGroupName,
          arn = raw_group.AutoScalingGroupARN,
          min_size = raw_group.MinSize,
          max_size = raw_group.MaxSize,
          desired_capacity = raw_group.DesiredCapacity,
          instances = #(raw_group.Instances or {}),
          health_status = raw_group.HealthStatus or 'Unknown',
          launch_config_name = raw_group.LaunchConfigurationName or '(none)',
          raw = raw_group,
        })
      end
      callback(groups)
    end)
  end)
end

--------------------------------------------------------------------------------
-- Resource View Factory
--------------------------------------------------------------------------------

--- @class aws.ViewConfig
--- @field title string
--- @field columns string[]
--- @field filter_fn fun(item: any, filter: string): boolean
--- @field render_cells fun(item: any): morph.Tree[]
--- @field keymaps fun(item: any, region: string): table<string, fun(): string>

--- @param config aws.ViewConfig
--- @return fun(ctx: morph.Ctx): morph.Tree
local function create_resource_view(config)
  --- @param ctx morph.Ctx<{ items: any[], loading: boolean, region: string }, { filter: string }>
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
          nmap = config.keymaps(item, ctx.props.region),
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
-- EC2 Instances View
--------------------------------------------------------------------------------

local InstancesView = create_resource_view {
  title = 'EC2 Instances',
  columns = { 'NAME', 'ID', 'TYPE', 'STATE', 'PUBLIC IP' },
  filter_fn = function(item, filter)
    local matches_filter = utils.create_filter_fn(filter)
    return matches_filter(item.name)
  end,

  render_cells = function(instance)
    local state_cell = instance.state == 'running' and h.DiagnosticOk({}, instance.state)
      or instance.state == 'stopped' and h.DiagnosticError({}, instance.state)
      or h.DiagnosticWarn({}, instance.state)

    return {
      h.Constant({}, instance.name),
      h.Constant({}, instance.id),
      h.String({}, instance.type),
      state_cell,
      instance.public_ip and h.Number({}, instance.public_ip) or h.Comment({}, '(none)'),
    }
  end,

  keymaps = function(instance, region)
    local ssh_cmd = 'aws ssm start-session --region ' .. region .. ' --target ' .. instance.id
    return {
      ['gi'] = keymap(function() show_json(instance.raw) end),
      ['go'] = keymap(
        function()
          vim.ui.open(
            'https://console.aws.amazon.com/ec2/v2/home?region='
              .. region
              .. '#InstanceDetails:instanceId='
              .. instance.id
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
      ['g+'] = keymap(function()
        vim.schedule(function()
          vim.fn.setreg('+', ssh_cmd)
          vim.notify 'SSH command yanked to +'
        end)
      end),
      ['g"'] = keymap(function()
        vim.schedule(function()
          vim.fn.setreg('"', ssh_cmd)
          vim.notify 'SSH command yanked to "'
        end)
      end),
    }
  end,
}

--------------------------------------------------------------------------------
-- Lambda Functions View
--------------------------------------------------------------------------------

local LambdasView = create_resource_view {
  title = 'Lambda Functions',
  columns = { 'NAME', 'RUNTIME', 'MEMORY', 'TIMEOUT' },
  filter_fn = function(item, filter)
    local matches_filter = utils.create_filter_fn(filter)
    return matches_filter(item.name)
  end,

  render_cells = function(lambda)
    return {
      h.Constant({}, lambda.name),
      h.String({}, lambda.runtime),
      h.Number({}, lambda.memory .. 'MB'),
      h.Comment({}, lambda.timeout .. 's'),
    }
  end,

  keymaps = function(lambda, region)
    local log_cmd = 'aws logs tail /aws/lambda/' .. lambda.name .. ' --since 1m --follow'
    return {
      ['gi'] = keymap(function() show_json(lambda.raw) end),
      ['go'] = keymap(
        function()
          vim.ui.open(
            'https://console.aws.amazon.com/lambda/home?region='
              .. region
              .. '#/functions/'
              .. lambda.name
          )
        end
      ),
      ['gl'] = keymap(function()
        vim.schedule(function() term.open(log_cmd) end)
      end),
      ['g+'] = keymap(function()
        vim.schedule(function()
          vim.fn.setreg('+', log_cmd)
          vim.notify 'Log command yanked to +'
        end)
      end),
      ['g"'] = keymap(function()
        vim.schedule(function()
          vim.fn.setreg('"', log_cmd)
          vim.notify 'Log command yanked to "'
        end)
      end),
    }
  end,
}

--------------------------------------------------------------------------------
-- Auto Scaling Groups View
--------------------------------------------------------------------------------

local AutoScalingGroupsView = create_resource_view {
  title = 'Auto Scaling Groups',
  columns = { 'NAME', 'MIN/DESIRED/MAX', 'LAUNCH CONFIG', 'INSTANCES' },
  filter_fn = function(item, filter)
    local matches_filter = utils.create_filter_fn(filter)
    return matches_filter(item.name)
  end,

  render_cells = function(group)
    local instances_cell = group.instances == 0 and h.DiagnosticError({}, 'No instances')
      or group.instances < group.desired_capacity and h.DiagnosticWarn(
        {},
        group.instances .. ' instances'
      )
      or h.DiagnosticOk({}, group.instances .. ' instances')

    return {
      h.Constant({}, group.name),
      h.Number({}, group.min_size .. '/' .. group.desired_capacity .. '/' .. group.max_size),
      h.String({}, group.launch_config_name),
      instances_cell,
    }
  end,

  keymaps = function(group, region)
    return {
      ['gi'] = keymap(function() show_json(group.raw) end),
      ['go'] = keymap(
        function()
          vim.ui.open(
            'https://console.aws.amazon.com/ec2/home?region='
              .. region
              .. '#AutoScalingGroupDetails:id='
              .. group.name
              .. ';view=details'
          )
        end
      ),
      ['gv'] = keymap(function()
        vim.schedule(
          function()
            term.open(
              'aws autoscaling describe-auto-scaling-instances --region '
                .. region
                .. ' --query "AutoScalingInstances[?AutoScalingGroupName==\''
                .. group.name
                .. '\']" --output table'
            )
          end
        )
      end),
    }
  end,
}

--------------------------------------------------------------------------------
-- Page Configuration
--------------------------------------------------------------------------------

--- @class aws.PageConfig
--- @field fetch fun(region: string, callback: fun(items: any[]))
--- @field state_key string
--- @field view function

--- @type table<aws.Page, aws.PageConfig>
local PAGE_CONFIGS = {
  instances = { fetch = fetch_instances, state_key = 'instances', view = InstancesView },
  lambdas = { fetch = fetch_lambdas, state_key = 'lambdas', view = LambdasView },
  auto_scaling_groups = {
    fetch = fetch_auto_scaling_groups,
    state_key = 'auto_scaling_groups',
    view = AutoScalingGroupsView,
  },
}

--------------------------------------------------------------------------------
-- App Component
--------------------------------------------------------------------------------

--- @class aws.AppState
--- @field page aws.Page
--- @field region string
--- @field show_help boolean
--- @field loading boolean
--- @field instances aws.Instance[]
--- @field lambdas aws.Lambda[]
--- @field auto_scaling_groups aws.AutoScalingGroup[]

--- @param ctx morph.Ctx<any, aws.AppState>
local function App(ctx)
  local function refresh()
    local state = assert(ctx.state)
    state.loading = true
    ctx:update(state)

    --- @type aws.PageConfig
    local config = PAGE_CONFIGS[state.page]
    config.fetch(state.region, function(items)
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
      region = get_default_region(),
      show_help = false,
      loading = true,
      instances = {},
      lambdas = {},
      auto_scaling_groups = {},
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
  --- @cast state.page aws.Page
  local page = state.page
  --- @type aws.PageConfig
  local config = PAGE_CONFIGS[page]
  local page_content = h(config.view, {
    items = state[config.state_key],
    loading = state.loading,
    region = state.region,
  })

  return h('text', { nmap = nav_keymaps }, {
    -- Header line
    h.RenderMarkdownH1({}, 'AWS'),
    ' ',
    h.NonText({}, 'Region: '),
    h.Title({}, state.region),
    ' ',
    h.NonText({}, 'g? for help'),
    '\n\n',

    -- Tab navigation
    h(TabBar, { tabs = TABS, active_page = state.page, on_select = go_to_page }),

    -- Region selector
    h(RegionSelector, {
      region = state.region,
      on_region_update = function(r)
        state.region = r
        ctx:update(state)
        refresh()
      end,
    }),
    '\n\n',

    -- Help panel (toggleable)
    state.show_help and { h(AwsHelp, { page = state.page }), '\n' },

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
  vim.api.nvim_buf_set_name(0, 'AWS')

  Morph.new(0):mount(h(App))
end

return M
