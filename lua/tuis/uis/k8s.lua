local Morph = require 'tuis.morph'
local h = Morph.h
local Table = require('tuis.components').Table
local TabBar = require('tuis.components').TabBar
local term = require 'tuis.term'
local utils = require 'tuis.utils'

local M = {}

--- @type string[]
local CLI_DEPENDENCIES = { 'kubectl' }

function M.is_enabled() return utils.check_clis_available(CLI_DEPENDENCIES, true) end

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

--- @alias k8s.Page 'pods'|'deployments'|'services'|'nodes'|'events'

--- @class k8s.Pod
--- @field name string
--- @field namespace string
--- @field ready string
--- @field status string
--- @field restarts number
--- @field age string
--- @field node string
--- @field raw unknown

--- @class k8s.Deployment
--- @field name string
--- @field namespace string
--- @field ready string
--- @field up_to_date number
--- @field available number
--- @field age string
--- @field raw unknown

--- @class k8s.Service
--- @field name string
--- @field namespace string
--- @field type string
--- @field cluster_ip string
--- @field external_ip string
--- @field ports string
--- @field age string
--- @field raw unknown

--- @class k8s.Node
--- @field name string
--- @field status string
--- @field roles string
--- @field age string
--- @field version string
--- @field internal_ip string
--- @field external_ip string
--- @field os_image string
--- @field kernel_version string
--- @field container_runtime string
--- @field raw unknown

--- @class k8s.Event
--- @field last_seen string
--- @field last_seen_raw string
--- @field type string
--- @field reason string
--- @field object string
--- @field message string
--- @field count number
--- @field raw unknown

--------------------------------------------------------------------------------
-- Kubectl Helpers
--
-- These helpers encapsulate the common patterns for interacting with kubectl
-- and displaying output in Neovim buffers.
--------------------------------------------------------------------------------

--- Run kubectl and return the result synchronously
--- @param args string[]
--- @return vim.SystemCompleted
local function kubectl(args)
  return vim.system(vim.list_extend({ 'kubectl' }, args), { text = true }):wait()
end

--- Run kubectl asynchronously with a callback
--- @param args string[]
--- @param callback fun(result: vim.SystemCompleted)
local function kubectl_async(args, callback)
  vim.system(vim.list_extend({ 'kubectl' }, args), { text = true }, callback)
end

--- Create a scratch buffer with specific options
--- @param split 'vnew'|'new' The split command to use
--- @param filetype? string Optional filetype to set
local function create_scratch_buffer(split, filetype)
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

--- Show kubectl output in a new buffer
--- @param args string[]
--- @param opts { split: 'vnew'|'new', filetype?: string }
local function show_kubectl_output(args, opts)
  vim.schedule(function()
    create_scratch_buffer(opts.split, opts.filetype)
    local result = kubectl(args)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(result.stdout or '', '\n'))
  end)
end

--- Show resource description in a horizontal split (the 'gd' action)
--- @param resource_type string
--- @param name string
--- @param namespace? string
local function show_describe(resource_type, name, namespace)
  local args = { 'describe', resource_type, name }
  if namespace then vim.list_extend(args, { '-n', namespace }) end
  show_kubectl_output(args, { split = 'new' })
end

--- Ask for confirmation before running a dangerous action
--- @param prompt string
--- @param on_confirm fun()
local function confirm_action(prompt, on_confirm)
  local choice = vim.fn.confirm(prompt, '&Yes\n&No', 2)
  if choice == 1 then vim.schedule(on_confirm) end
end

--- Wrap a keymap handler to return '' (required by morph nmap callbacks)
--- @param fn fun()
--- @return fun(): string
local function keymap(fn)
  return function()
    vim.schedule(fn)
    return ''
  end
end

--------------------------------------------------------------------------------
-- Utilities
--------------------------------------------------------------------------------

--- @return string
local function get_current_context()
  local result = kubectl { 'config', 'current-context' }
  return vim.trim(result.stdout or 'unknown')
end

--- @return string[]
local function get_namespaces()
  local result = kubectl { 'get', 'namespaces', '-o', 'jsonpath={.items[*].metadata.name}' }
  if result.code ~= 0 then return { 'default' } end
  return vim.split(vim.trim(result.stdout or 'default'), '%s+')
end

--- @param s string
--- @param max integer
--- @return string
local function truncate(s, max)
  if not s then return '' end
  if #s <= max then return s end
  return s:sub(1, max - 3) .. '...'
end

--------------------------------------------------------------------------------
-- Help System
--------------------------------------------------------------------------------

local HELP_KEYMAPS = {
  pods = {
    { 'gi', 'Inspect pod (YAML/describe)' },
    { 'gl', 'Stream logs' },
    { 'gx', 'Exec into pod (/bin/sh)' },
    { 'gk', 'Delete pod' },
  },
  deployments = {
    { 'gi', 'Inspect deployment (YAML/describe)' },
    { 'gs', 'Scale deployment (replicas)' },
    { 'gr', 'Restart deployment (rollout restart)' },
    { 'gv', 'View pods for deployment' },
  },
  services = {
    { 'gi', 'Inspect service (YAML/describe)' },
    { 'gp', 'Port-forward to service' },
    { 'gv', 'View pods for service' },
  },
  nodes = {
    { 'gi', 'Inspect node (YAML/describe)' },
    { 'gc', 'Cordon node' },
    { 'gu', 'Uncordon node' },
    { 'gD', 'Drain node' },
  },
  events = {
    { 'gi', 'Inspect event (YAML/details)' },
  },
}

--- @param ctx morph.Ctx<{ show: boolean, page: k8s.Page }>
local function Help(ctx)
  if not ctx.props.show then return {} end

  local page_keymaps = HELP_KEYMAPS[ctx.props.page] or {}
  local common_keymaps = {
    { 'g1-g5', 'Navigate tabs' },
    { '<Leader>r', 'Refresh' },
    { 'g?', 'Toggle help' },
  }

  local rows = { { cells = { h.Constant({}, 'KEY'), h.Constant({}, 'ACTION') } } }
  for _, km in ipairs(page_keymaps) do
    table.insert(rows, { cells = { h.Title({}, km[1]), h.Normal({}, km[2]) } })
  end
  for _, km in ipairs(common_keymaps) do
    table.insert(rows, { cells = { h.Title({}, km[1]), h.Normal({}, km[2]) } })
  end

  return {
    h.RenderMarkdownH1({}, '## Keybindings'),
    '\n\n',
    h(Table, { rows = rows, header = true, header_separator = true }),
    '\n',
  }
end

--------------------------------------------------------------------------------
-- Navigation Components
--------------------------------------------------------------------------------

--- @type { key: string, page: k8s.Page, label: string }[]
local TABS = {
  { key = 'g1', page = 'pods', label = 'Pods' },
  { key = 'g2', page = 'deployments', label = 'Deployments' },
  { key = 'g3', page = 'services', label = 'Services' },
  { key = 'g4', page = 'nodes', label = 'Nodes' },
  { key = 'g5', page = 'events', label = 'Events' },
}

--- @param ctx morph.Ctx<{ namespace: string, namespaces: string[], on_namespace_update: fun(namespace: string) }>
local function NamespaceSelector(ctx)
  local function on_enter()
    vim.schedule(function()
      vim.ui.select(ctx.props.namespaces, {}, function(choice)
        if choice then ctx.props.on_namespace_update(choice) end
      end)
    end)
  end

  return h('text', { nmap = { ['<CR>'] = keymap(on_enter) } }, {
    h.Comment({}, 'Namespace: '),
    h.Constant({}, ctx.props.namespace),
    h.Comment({}, ' (press Enter to change)'),
  })
end

--------------------------------------------------------------------------------
-- Data Fetching
--
-- Each fetch function retrieves Kubernetes resources via kubectl and transforms
-- the raw JSON into structured types for display.
--------------------------------------------------------------------------------

--- @param namespace string
--- @param callback fun(pods: k8s.Pod[])
local function fetch_pods(namespace, callback)
  kubectl_async({ 'get', 'pods', '-n', namespace, '-o', 'json' }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then return callback {} end

      local pods = {}
      local response = vim.json.decode(out.stdout or '{}')

      for _, raw in ipairs(response.items or {}) do
        local ready, total, restarts = 0, 0, 0
        for _, status in ipairs(raw.status.containerStatuses or {}) do
          total = total + 1
          if status.ready then ready = ready + 1 end
          restarts = restarts + (status.restartCount or 0)
        end

        table.insert(pods, {
          name = raw.metadata.name,
          namespace = raw.metadata.namespace,
          ready = ready .. '/' .. total,
          status = raw.status.phase or 'Unknown',
          restarts = restarts,
          age = raw.metadata.creationTimestamp or '',
          node = raw.spec.nodeName or 'N/A',
          raw = raw,
        })
      end

      table.sort(pods, function(a, b) return a.name < b.name end)
      callback(pods)
    end)
  end)
end

--- @param namespace string
--- @param callback fun(deployments: k8s.Deployment[])
local function fetch_deployments(namespace, callback)
  kubectl_async({ 'get', 'deployments', '-n', namespace, '-o', 'json' }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then return callback {} end

      local deployments = {}
      local response = vim.json.decode(out.stdout or '{}')

      for _, raw in ipairs(response.items or {}) do
        local replicas = raw.spec.replicas or 0
        local ready_replicas = raw.status.readyReplicas or 0

        table.insert(deployments, {
          name = raw.metadata.name,
          namespace = raw.metadata.namespace,
          ready = ready_replicas .. '/' .. replicas,
          up_to_date = raw.status.updatedReplicas or 0,
          available = raw.status.availableReplicas or 0,
          age = raw.metadata.creationTimestamp or '',
          raw = raw,
        })
      end

      table.sort(deployments, function(a, b) return a.name < b.name end)
      callback(deployments)
    end)
  end)
end

--- @param namespace string
--- @param callback fun(services: k8s.Service[])
local function fetch_services(namespace, callback)
  kubectl_async({ 'get', 'services', '-n', namespace, '-o', 'json' }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then return callback {} end

      local services = {}
      local response = vim.json.decode(out.stdout or '{}')

      for _, raw in ipairs(response.items or {}) do
        -- Build port strings (e.g., "80:30080/TCP")
        local ports = {}
        for _, port in ipairs(raw.spec.ports or {}) do
          local s = tostring(port.port)
          if port.nodePort then s = s .. ':' .. port.nodePort end
          s = s .. '/' .. (port.protocol or 'TCP')
          table.insert(ports, s)
        end

        -- Determine external IP based on service type
        local external_ip = '<none>'
        if raw.spec.type == 'LoadBalancer' then
          local ingress = raw.status.loadBalancer and raw.status.loadBalancer.ingress
          if ingress and ingress[1] then
            external_ip = ingress[1].ip or ingress[1].hostname or '<pending>'
          else
            external_ip = '<pending>'
          end
        elseif raw.spec.externalIPs and #raw.spec.externalIPs > 0 then
          external_ip = table.concat(raw.spec.externalIPs, ',')
        end

        table.insert(services, {
          name = raw.metadata.name,
          namespace = raw.metadata.namespace,
          type = raw.spec.type or 'ClusterIP',
          cluster_ip = raw.spec.clusterIP or 'None',
          external_ip = external_ip,
          ports = table.concat(ports, ','),
          age = raw.metadata.creationTimestamp or '',
          raw = raw,
        })
      end

      table.sort(services, function(a, b) return a.name < b.name end)
      callback(services)
    end)
  end)
end

--- @param callback fun(nodes: k8s.Node[])
local function fetch_nodes(callback)
  kubectl_async({ 'get', 'nodes', '-o', 'json' }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then return callback {} end

      local nodes = {}
      local response = vim.json.decode(out.stdout or '{}')

      for _, raw in ipairs(response.items or {}) do
        -- Find the Ready condition to determine node status
        local status = 'Unknown'
        for _, cond in ipairs(raw.status.conditions or {}) do
          if cond.type == 'Ready' then
            status = cond.status == 'True' and 'Ready' or 'NotReady'
            break
          end
        end

        -- Extract roles from labels (e.g., node-role.kubernetes.io/control-plane)
        local roles = {}
        for label in pairs(raw.metadata.labels or {}) do
          local role = label:match '^node%-role%.kubernetes%.io/(.+)'
          if role then table.insert(roles, role) end
        end

        -- Extract IP addresses
        local internal_ip, external_ip = 'N/A', '<none>'
        for _, addr in ipairs(raw.status.addresses or {}) do
          if addr.type == 'InternalIP' then internal_ip = addr.address end
          if addr.type == 'ExternalIP' then external_ip = addr.address end
        end

        local info = raw.status.nodeInfo or {}
        table.insert(nodes, {
          name = raw.metadata.name,
          status = status,
          roles = #roles > 0 and table.concat(roles, ',') or '<none>',
          age = raw.metadata.creationTimestamp or '',
          version = info.kubeletVersion or 'N/A',
          internal_ip = internal_ip,
          external_ip = external_ip,
          os_image = info.osImage or 'N/A',
          kernel_version = info.kernelVersion or 'N/A',
          container_runtime = info.containerRuntimeVersion or 'N/A',
          raw = raw,
        })
      end

      table.sort(nodes, function(a, b) return a.name < b.name end)
      callback(nodes)
    end)
  end)
end

--- @param namespace string
--- @param callback fun(events: k8s.Event[])
local function fetch_events(namespace, callback)
  kubectl_async({ 'get', 'events', '-n', namespace, '-o', 'json' }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then return callback {} end

      local events = {}
      local response = vim.json.decode(out.stdout or '{}')

      for _, raw in ipairs(response.items or {}) do
        -- Determine last seen timestamp (events have multiple timestamp fields)
        local last_seen = raw.lastTimestamp
        if not last_seen and raw.eventTime then
          last_seen = type(raw.eventTime) == 'table' and raw.eventTime.time or raw.eventTime
        end
        last_seen = last_seen or raw.metadata.creationTimestamp or ''

        -- Build object reference string (e.g., "Pod/my-pod")
        local obj = raw.involvedObject or {}
        local object = (obj.kind or '') .. '/' .. (obj.name or '')

        table.insert(events, {
          last_seen = last_seen,
          last_seen_raw = last_seen,
          type = raw.type or 'Normal',
          reason = raw.reason or 'Unknown',
          object = object,
          message = raw.message or '',
          count = raw.count or 1,
          raw = raw,
        })
      end

      -- Most recent events first
      table.sort(events, function(a, b)
        local a_ts = a.last_seen_raw or ''
        local b_ts = b.last_seen_raw or ''
        if a_ts == '' then return false end
        if b_ts == '' then return true end
        return a_ts > b_ts
      end)

      callback(events)
    end)
  end)
end

--------------------------------------------------------------------------------
-- Resource View Factory
--
-- Instead of 5 nearly-identical view components, we define each view's unique
-- characteristics (columns, row rendering, keymaps) as configuration, then use
-- a single factory to create the components.
--------------------------------------------------------------------------------

--- @class k8s.ViewConfig
--- @field title string
--- @field columns string[]
--- @field filter_fn fun(item: any, filter: string): boolean
--- @field render_cells fun(item: any): morph.Tree[]
--- @field keymaps fun(item: any, on_refresh: fun()): table<string, fun(): string>

--- @param config k8s.ViewConfig
--- @return fun(ctx: morph.Ctx): morph.Tree
local function create_resource_view(config)
  --- @param ctx morph.Ctx<{ items: any[], loading: boolean, on_refresh: fun() }, { filter: string }>
  return function(ctx)
    if ctx.phase == 'mount' then ctx.state = { filter = '' } end
    local state = assert(ctx.state)

    -- Build header row
    local header_cells = {}
    for _, col in ipairs(config.columns) do
      table.insert(header_cells, h.Constant({}, col))
    end
    local rows = { { cells = header_cells } }

    -- Build data rows for items that pass the filter
    for _, item in ipairs(ctx.props.items or {}) do
      if config.filter_fn(item, state.filter or '') then
        table.insert(rows, {
          nmap = config.keymaps(item, ctx.props.on_refresh),
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
      h(Table, { rows = rows, header = true, header_separator = true }),
    }
  end
end

--- Simple name-based filter (used by most views)
--- @param item { name: string }
--- @param filter string
--- @return boolean
local function filter_by_name(item, filter)
  return filter == '' or item.name:find(filter, 1, true) ~= nil
end

--------------------------------------------------------------------------------
-- Pod View
--------------------------------------------------------------------------------

local PodsView = create_resource_view {
  title = 'Pods',
  columns = { 'NAME', 'READY', 'STATUS', 'RESTARTS', 'AGE', 'NODE' },
  filter_fn = filter_by_name,

  render_cells = function(pod)
    local status_cell = pod.status == 'Running' and h.DiagnosticOk({}, pod.status)
      or pod.status == 'Pending' and h.DiagnosticWarn({}, pod.status)
      or h.DiagnosticError({}, pod.status)

    local restarts_cell = pod.restarts > 0 and h.DiagnosticWarn({}, tostring(pod.restarts))
      or h.Number({}, tostring(pod.restarts))

    return {
      h.Constant({}, pod.name),
      h.Number({}, pod.ready),
      status_cell,
      restarts_cell,
      h.Comment({}, pod.age),
      h.String({}, pod.node),
    }
  end,

  keymaps = function(pod, on_refresh)
    return {
      ['gi'] = keymap(function() show_describe('pod', pod.name, pod.namespace) end),
      ['gl'] = keymap(function()
        vim.schedule(
          function() term.open('kubectl logs -f ' .. pod.name .. ' -n ' .. pod.namespace) end
        )
      end),
      ['gx'] = keymap(function()
        vim.schedule(
          function()
            term.open('kubectl exec -it ' .. pod.name .. ' -n ' .. pod.namespace .. ' -- /bin/sh')
          end
        )
      end),
      ['gk'] = keymap(function()
        confirm_action('Delete pod ' .. pod.name .. '?', function()
          kubectl { 'delete', 'pod', pod.name, '-n', pod.namespace }
          on_refresh()
        end)
      end),
    }
  end,
}

--------------------------------------------------------------------------------
-- Deployment View
--------------------------------------------------------------------------------

local DeploymentsView = create_resource_view {
  title = 'Deployments',
  columns = { 'NAME', 'READY', 'UP-TO-DATE', 'AVAILABLE', 'AGE' },
  filter_fn = filter_by_name,

  render_cells = function(dep)
    local available_cell = dep.available > 0 and h.DiagnosticOk({}, tostring(dep.available))
      or h.DiagnosticError({}, tostring(dep.available))

    return {
      h.Constant({}, dep.name),
      h.Number({}, dep.ready),
      h.Number({}, tostring(dep.up_to_date)),
      available_cell,
      h.Comment({}, dep.age),
    }
  end,

  keymaps = function(dep, on_refresh)
    return {
      ['gi'] = keymap(function() show_describe('deployment', dep.name, dep.namespace) end),
      ['gs'] = keymap(function()
        vim.schedule(function()
          vim.ui.input({ prompt = 'Scale to how many replicas? ' }, function(replicas)
            if not replicas then return end
            kubectl {
              'scale',
              'deployment',
              dep.name,
              '-n',
              dep.namespace,
              '--replicas=' .. replicas,
            }
            on_refresh()
          end)
        end)
      end),
      ['gr'] = keymap(function()
        vim.schedule(function()
          kubectl { 'rollout', 'restart', 'deployment', dep.name, '-n', dep.namespace }
          vim.notify('Deployment ' .. dep.name .. ' restarted')
          on_refresh()
        end)
      end),
      ['gv'] = keymap(function()
        vim.schedule(
          function()
            term.open(
              'kubectl get pods -n ' .. dep.namespace .. ' -l app=' .. dep.name .. ' --watch'
            )
          end
        )
      end),
    }
  end,
}

--------------------------------------------------------------------------------
-- Service View
--------------------------------------------------------------------------------

local ServicesView = create_resource_view {
  title = 'Services',
  columns = { 'NAME', 'TYPE', 'CLUSTER-IP', 'EXTERNAL-IP', 'PORT(S)', 'AGE' },
  filter_fn = filter_by_name,

  render_cells = function(svc)
    local type_cell = svc.type == 'ClusterIP' and h.String({}, svc.type)
      or svc.type == 'LoadBalancer' and h.Title({}, svc.type)
      or svc.type == 'NodePort' and h.Number({}, svc.type)
      or h.Normal({}, svc.type)

    local external_ip_cell = svc.external_ip ~= '<none>' and h.DiagnosticOk({}, svc.external_ip)
      or h.Comment({}, svc.external_ip)

    return {
      h.Constant({}, svc.name),
      type_cell,
      h.Comment({}, svc.cluster_ip),
      external_ip_cell,
      h.Number({}, svc.ports),
      h.Comment({}, svc.age),
    }
  end,

  keymaps = function(svc, _on_refresh)
    return {
      ['gi'] = keymap(function() show_describe('service', svc.name, svc.namespace) end),
      ['go'] = keymap(
        function()
          show_kubectl_output(
            { 'get', 'endpoints', svc.name, '-n', svc.namespace },
            { split = 'new' }
          )
        end
      ),
      ['gp'] = keymap(function()
        vim.schedule(function()
          local first_port = svc.ports:match '%d+'
          if not first_port then
            vim.notify('No port found for service ' .. svc.name, vim.log.levels.WARN)
            return
          end
          vim.ui.input({ prompt = 'Local port (default: ' .. first_port .. '): ' }, function(input)
            local local_port = (input and input ~= '') and input or first_port
            term.open(
              'kubectl port-forward -n '
                .. svc.namespace
                .. ' service/'
                .. svc.name
                .. ' '
                .. local_port
                .. ':'
                .. first_port
            )
          end)
        end)
      end),
      ['gv'] = keymap(function()
        vim.schedule(function()
          local selector = svc.raw.spec.selector
          if not selector then
            vim.notify('Service ' .. svc.name .. ' has no selector', vim.log.levels.WARN)
            return
          end
          local label_parts = {}
          for k, v in pairs(selector) do
            table.insert(label_parts, k .. '=' .. v)
          end
          term.open(
            'kubectl get pods -n '
              .. svc.namespace
              .. ' -l '
              .. table.concat(label_parts, ',')
              .. ' --watch'
          )
        end)
      end),
    }
  end,
}

--------------------------------------------------------------------------------
-- Node View
--------------------------------------------------------------------------------

local NodesView = create_resource_view {
  title = 'Nodes',
  columns = { 'NAME', 'STATUS', 'ROLES', 'AGE', 'VERSION', 'INTERNAL-IP', 'EXTERNAL-IP' },
  filter_fn = filter_by_name,

  render_cells = function(node)
    local status_cell = node.status == 'Ready' and h.DiagnosticOk({}, node.status)
      or node.status == 'NotReady' and h.DiagnosticError({}, node.status)
      or h.DiagnosticWarn({}, node.status)

    return {
      h.Constant({}, node.name),
      status_cell,
      h.Title({}, node.roles),
      h.Comment({}, node.age),
      h.Number({}, node.version),
      h.String({}, node.internal_ip),
      h.String({}, node.external_ip),
    }
  end,

  keymaps = function(node, on_refresh)
    return {
      ['gi'] = keymap(function() show_describe('node', node.name, nil) end),
      ['gc'] = keymap(function()
        confirm_action('Cordon node ' .. node.name .. '?', function()
          kubectl { 'cordon', node.name }
          on_refresh()
        end)
      end),
      ['gu'] = keymap(function()
        confirm_action('Uncordon node ' .. node.name .. '?', function()
          kubectl { 'uncordon', node.name }
          on_refresh()
        end)
      end),
      ['gD'] = keymap(function()
        confirm_action(
          'Drain node ' .. node.name .. '? (--ignore-daemonsets --delete-emptydir-data)',
          function()
            term.open(
              'kubectl drain ' .. node.name .. ' --ignore-daemonsets --delete-emptydir-data'
            )
            vim.defer_fn(on_refresh, 1000)
          end
        )
      end),
    }
  end,
}

--------------------------------------------------------------------------------
-- Events View
--------------------------------------------------------------------------------

local EventsView = create_resource_view {
  title = 'Events',
  columns = { 'LAST SEEN', 'TYPE', 'REASON', 'OBJECT', 'MESSAGE' },

  filter_fn = function(event, filter)
    if filter == '' then return true end
    local lower_filter = filter:lower()
    return event.reason:lower():find(lower_filter, 1, true)
      or event.object:lower():find(lower_filter, 1, true)
      or event.message:lower():find(lower_filter, 1, true)
  end,

  render_cells = function(event)
    local type_cell = event.type == 'Normal' and h.DiagnosticOk({}, event.type)
      or event.type == 'Warning' and h.DiagnosticWarn({}, event.type)
      or h.DiagnosticError({}, event.type)

    local reason_cell = event.type == 'Normal' and h.String({}, event.reason)
      or h.DiagnosticWarn({}, event.reason)

    return {
      h.Comment({}, event.last_seen),
      type_cell,
      reason_cell,
      h.Constant({}, event.object),
      h.Normal({}, truncate(event.message, 80)),
    }
  end,

  keymaps = function(event, _on_refresh)
    return {
      ['gi'] = keymap(function()
        vim.schedule(function()
          create_scratch_buffer('new', 'markdown')
          local lines = {
            '# Event Details',
            '',
            '**Type:** ' .. event.type,
            '**Reason:** ' .. event.reason,
            '**Object:** ' .. event.object,
            '**Count:** ' .. tostring(event.count),
            '**Last Seen:** ' .. event.last_seen,
            '',
            '## Message',
            '',
            event.message,
          }
          vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
        end)
      end),
    }
  end,
}

--------------------------------------------------------------------------------
-- Page Configuration
--
-- This table centralizes the configuration for each page, mapping page names
-- to their fetch functions, state keys, view components, and whether they
-- require a namespace.
--------------------------------------------------------------------------------

--- @class k8s.PageConfig
--- @field fetch fun(namespace: string, callback: fun(items: any[])) | fun(callback: fun(items: any[]))
--- @field state_key string
--- @field view function
--- @field needs_namespace boolean

--- @type table<k8s.Page, k8s.PageConfig>
local PAGE_CONFIGS = {
  pods = { fetch = fetch_pods, state_key = 'pods', view = PodsView, needs_namespace = true },
  deployments = {
    fetch = fetch_deployments,
    state_key = 'deployments',
    view = DeploymentsView,
    needs_namespace = true,
  },
  services = {
    fetch = fetch_services,
    state_key = 'services',
    view = ServicesView,
    needs_namespace = true,
  },
  nodes = { fetch = fetch_nodes, state_key = 'nodes', view = NodesView, needs_namespace = false },
  events = { fetch = fetch_events, state_key = 'events', view = EventsView, needs_namespace = true },
}

--------------------------------------------------------------------------------
-- App Component
--------------------------------------------------------------------------------

--- @class k8s.AppState
--- @field page k8s.Page
--- @field context string
--- @field namespace string
--- @field namespaces string[]
--- @field show_help boolean
--- @field loading boolean
--- @field pods k8s.Pod[]
--- @field deployments k8s.Deployment[]
--- @field services k8s.Service[]
--- @field nodes k8s.Node[]
--- @field events k8s.Event[]
--- @field timer uv.uv_timer_t

--- @param ctx morph.Ctx<any, k8s.AppState>
local function App(ctx)
  --- @param show_loading? boolean
  local function refresh(show_loading)
    local state = assert(ctx.state)
    if show_loading then
      state.loading = true
      ctx:update(state)
    end

    --- @type k8s.PageConfig
    local config = PAGE_CONFIGS[state.page]
    local function on_data(items)
      state[config.state_key] = items
      state.loading = false
      ctx:update(state)
    end

    if config.needs_namespace then
      config.fetch(state.namespace, on_data)
    else
      config.fetch(on_data)
    end
  end

  local function go_to_page(page)
    local state = assert(ctx.state)
    if state.page == page then return end

    state.page = page
    ctx:update(state)
    vim.fn.winrestview { topline = 1, lnum = 1 }
    refresh()
  end

  -- Initialize state on mount
  if ctx.phase == 'mount' then
    ctx.state = {
      page = 'pods',
      context = get_current_context(),
      namespace = 'default',
      namespaces = get_namespaces(),
      show_help = false,
      loading = true,
      pods = {},
      deployments = {},
      services = {},
      nodes = {},
      events = {},
      timer = assert(vim.uv.new_timer()),
    }
    vim.schedule(refresh)
    ctx.state.timer:start(5000, 5000, function()
      vim.schedule(function() refresh(false) end)
    end)
  end

  local state = assert(ctx.state)

  -- Cleanup timer on unmount
  if ctx.phase == 'unmount' then
    state.timer:stop()
    state.timer:close()
  end

  -- Build navigation keymaps programmatically
  local nav_keymaps = {
    ['<Leader>r'] = keymap(function()
      vim.schedule(function() refresh(true) end)
    end),
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
  --- @cast state.page k8s.Page
  local page = state.page
  --- @type k8s.PageConfig
  local config = PAGE_CONFIGS[page]
  local page_content = h(config.view, {
    items = state[config.state_key],
    loading = state.loading,
    on_refresh = refresh,
  })

  return h('text', { nmap = nav_keymaps }, {
    -- Header line
    h.RenderMarkdownH1({}, 'Kubernetes'),
    ' ',
    h.NonText({}, 'Context: '),
    h.Title({}, state.context),
    ' ',
    h.NonText({}, 'g? for help'),
    '\n\n',

    -- Tab navigation
    h(TabBar, { tabs = TABS, active_page = state.page, on_select = go_to_page }),

    -- Namespace selector (not shown for cluster-scoped resources like nodes)
    config.needs_namespace
        and {
          h(NamespaceSelector, {
            namespace = state.namespace,
            namespaces = state.namespaces,
            on_namespace_update = function(ns)
              state.namespace = ns
              ctx:update(state)
              refresh()
            end,
          }),
          '\n\n',
        }
      or nil,

    -- Help panel (toggleable)
    state.show_help and { h(Help, { show = true, page = state.page }), '\n' } or nil,

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
  vim.api.nvim_buf_set_name(0, 'Kubernetes')

  Morph.new(0):mount(h(App))
end

return M
