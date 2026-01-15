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
local CLI_DEPENDENCIES = { 'docker' }

function M.is_enabled() return utils.check_clis_available(CLI_DEPENDENCIES, true) end

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

--- @alias docker.Page 'containers'|'images'|'volumes'|'networks'|'stats'|'compose'|'system'|'contexts'|'hub'

--- @class docker.Container
--- @field id string
--- @field name string
--- @field image string
--- @field status string
--- @field ports string
--- @field created string
--- @field raw unknown

--- @class docker.Image
--- @field id string
--- @field repository string
--- @field tag string
--- @field created string
--- @field size string
--- @field raw unknown

--- @class docker.Volume
--- @field name string
--- @field driver string
--- @field mountpoint string
--- @field created string
--- @field raw unknown

--- @class docker.Network
--- @field id string
--- @field name string
--- @field driver string
--- @field scope string
--- @field raw unknown

--- @class docker.ContainerStats
--- @field id string
--- @field name string
--- @field cpu_percent number
--- @field mem_usage string
--- @field mem_limit string
--- @field mem_percent number
--- @field net_io_rx string
--- @field net_io_tx string
--- @field block_io_read string
--- @field block_io_write string
--- @field pids number

--- @class docker.ComposeProject
--- @field name string
--- @field status string
--- @field config_files string
--- @field raw unknown

--- @class docker.SystemDiskUsage
--- @field type string
--- @field total_count number
--- @field active number
--- @field size string
--- @field reclaimable string
--- @field reclaimable_percent number

--- @class docker.SystemInfo
--- @field server_version string
--- @field storage_driver string
--- @field containers_running number
--- @field containers_paused number
--- @field containers_stopped number
--- @field images number

--- @class docker.Context
--- @field name string
--- @field description string
--- @field docker_endpoint string
--- @field current boolean
--- @field error string

--- @class docker.HubSearchResult
--- @field name string
--- @field namespace string
--- @field description string
--- @field star_count number
--- @field pull_count number
--- @field is_official boolean
--- @field is_automated boolean

--- @class docker.HubTag
--- @field name string
--- @field last_updated string
--- @field full_size number
--- @field digest string

--- @class docker.HubRepositoryDetail
--- @field name string
--- @field namespace string
--- @field description string
--- @field full_description string
--- @field star_count number
--- @field pull_count number
--- @field is_official boolean
--- @field tags docker.HubTag[]
--- @field last_updated string

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--- Show docker inspect output in a vertical split
--- @param type string e.g., 'container', 'image', 'volume', 'network'
--- @param id string
local function show_inspect(type, id)
  vim.schedule(function()
    local cmd = type == 'container' and { 'docker', 'inspect', id }
      or type == 'image' and { 'docker', 'image', 'inspect', id }
      or type == 'volume' and { 'docker', 'volume', 'inspect', id }
      or type == 'network' and { 'docker', 'network', 'inspect', id }
      or { 'docker', 'inspect', id }

    vim.system(cmd, { text = true }, function(result)
      vim.schedule(function()
        local json = vim.trim(result.stdout or '[]')
        create_scratch_buffer('vnew', 'json')
        vim.api.nvim_buf_set_lines(0, 0, -1, true, vim.split(json, '\n'))
      end)
    end)
  end)
end

--- Ask for confirmation before running a dangerous action
--- @param _prompt string
--- @param on_confirm fun()
local function confirm_action(_prompt, on_confirm)
  local choice = vim.fn.confirm('Are you sure?', '&Yes\n&No', 2)
  if choice == 1 then vim.schedule(on_confirm) end
end

--- Get the current docker context name
--- @return string
local function get_current_context()
  local result = vim.system({ 'docker', 'context', 'show' }, { text = true }):wait()
  return vim.trim(result.stdout or 'default')
end

--------------------------------------------------------------------------------
-- Help System
--------------------------------------------------------------------------------

local HELP_KEYMAPS = {
  containers = {
    { 'gi', 'Inspect container (JSON)' },
    { 'gl', 'View container logs' },
    { 'gx', 'Execute shell in container' },
    { 'gs', 'Start/stop container' },
    { 'r', 'Rename container' },
    { 'gk', 'Kill container' },
    { 'gd', 'Remove container' },
  },
  images = {
    { 'gi', 'Inspect image (JSON)' },
    { 'gR', 'Run container from image' },
    { 'gt', 'Tag image' },
    { 'gp', 'Push image' },
    { 'gd', 'Remove image' },
    { 'gD', 'Force remove image' },
  },
  volumes = {
    { 'gi', 'Inspect volume (JSON)' },
    { 'gd', 'Remove volume' },
  },
  networks = {
    { 'gi', 'Inspect network (JSON)' },
    { 'gd', 'Remove network' },
  },
  stats = {
    { 'gi', 'Inspect container (JSON)' },
    { 'gl', 'View container logs' },
    { 'gx', 'Execute shell in container' },
  },
  compose = {
    { 'gi', 'Show compose config (YAML)' },
    { 'gu', 'docker compose up -d' },
    { 'gd', 'docker compose down' },
    { 'gr', 'docker compose restart' },
    { 'gl', 'View compose logs' },
    { 'gp', 'docker compose pull' },
  },
  system = {
    { 'gp', 'Prune unused (safe)' },
    { 'gP', 'Prune ALL unused images' },
    { 'gv', 'Prune unused volumes' },
    { 'gb', 'Prune build cache' },
  },
  contexts = {
    { '<CR>', 'Switch to context' },
    { 'gi', 'Inspect context (JSON)' },
    { 'gn', 'Create new context' },
    { 'gd', 'Remove context' },
  },
  hub = {
    { '<CR>', 'View repository details' },
    { '<C-o>', 'Go back' },
    { 'g"', 'Yank pull command to "' },
    { 'gw', 'Open in browser' },
  },
}

local COMMON_KEYMAPS = {
  { 'g1-g8', 'Navigate tabs' },
  { '<Leader>r', 'Refresh' },
  { 'g?', 'Toggle help' },
}

--- @param ctx morph.Ctx<{ page: docker.Page }>
local function DockerHelp(ctx)
  return h(Help, {
    page_keymaps = HELP_KEYMAPS[ctx.props.page],
    common_keymaps = COMMON_KEYMAPS,
  })
end

--------------------------------------------------------------------------------
-- Tabs Configuration
--------------------------------------------------------------------------------

--- @type { key: string, page: docker.Page, label: string }[]
local TABS = {
  { key = 'g1', page = 'containers', label = 'Containers' },
  { key = 'g2', page = 'images', label = 'Images' },
  { key = 'g3', page = 'volumes', label = 'Volumes' },
  { key = 'g4', page = 'networks', label = 'Networks' },
  { key = 'g5', page = 'stats', label = 'Stats' },
  { key = 'g6', page = 'compose', label = 'Compose' },
  { key = 'g7', page = 'system', label = 'System' },
  { key = 'g8', page = 'contexts', label = 'Contexts' },
  { key = 'g9', page = 'hub', label = 'Hub' },
}

--------------------------------------------------------------------------------
-- Data Fetching
--------------------------------------------------------------------------------

--- @param callback fun(containers: docker.Container[])
local function fetch_containers(callback)
  vim.system({ 'docker', 'ps', '--format', 'json', '--all' }, { text = true }, function(out)
    vim.schedule(function()
      ---@type docker.Container[]
      local containers = {}
      local lines = vim
        .iter(vim.split(out.stdout or '', '\n'))
        :filter(function(l) return l ~= '' end)
        :totable()

      for _, line in ipairs(lines) do
        local raw = vim.json.decode(line)
        table.insert(containers, {
          id = raw.ID or '',
          name = raw.Names or '',
          image = raw.Image or '',
          status = raw.Status or '',
          ports = raw.Ports or '',
          created = raw.CreatedAt or '',
          raw = raw,
        })
      end

      table.sort(containers, function(a, b) return a.name < b.name end)
      callback(containers)
    end)
  end)
end

--- @param callback fun(images: docker.Image[])
local function fetch_images(callback)
  vim.system({ 'docker', 'images', '--format', 'json' }, { text = true }, function(out)
    vim.schedule(function()
      ---@type docker.Image[]
      local images = {}
      local lines = vim
        .iter(vim.split(out.stdout or '', '\n'))
        :filter(function(l) return l ~= '' end)
        :totable()

      for _, line in ipairs(lines) do
        local raw = vim.json.decode(line)
        table.insert(images, {
          id = raw.ID or '',
          repository = raw.Repository or '',
          tag = raw.Tag or '',
          created = raw.CreatedAt or raw.CreatedSince or '',
          size = raw.Size or '',
          raw = raw,
        })
      end

      table.sort(images, function(a, b)
        if a.repository == b.repository then return a.tag < b.tag end
        return a.repository < b.repository
      end)
      callback(images)
    end)
  end)
end

--- @param callback fun(volumes: docker.Volume[])
local function fetch_volumes(callback)
  vim.system({ 'docker', 'volume', 'ls', '--format', 'json' }, { text = true }, function(out)
    vim.schedule(function()
      ---@type docker.Volume[]
      local volumes = {}
      local lines = vim
        .iter(vim.split(out.stdout or '', '\n'))
        :filter(function(l) return l ~= '' end)
        :totable()

      for _, line in ipairs(lines) do
        local raw = vim.json.decode(line)
        table.insert(volumes, {
          name = raw.Name or '',
          driver = raw.Driver or '',
          mountpoint = raw.Mountpoint or '',
          created = raw.CreatedAt or '',
          raw = raw,
        })
      end

      table.sort(volumes, function(a, b) return a.name < b.name end)
      callback(volumes)
    end)
  end)
end

--- @param callback fun(networks: docker.Network[])
local function fetch_networks(callback)
  vim.system({ 'docker', 'network', 'ls', '--format', 'json' }, { text = true }, function(out)
    vim.schedule(function()
      ---@type docker.Network[]
      local networks = {}
      local lines = vim
        .iter(vim.split(out.stdout or '', '\n'))
        :filter(function(l) return l ~= '' end)
        :totable()

      for _, line in ipairs(lines) do
        local raw = vim.json.decode(line)
        table.insert(networks, {
          id = raw.ID or '',
          name = raw.Name or '',
          driver = raw.Driver or '',
          scope = raw.Scope or '',
          raw = raw,
        })
      end

      table.sort(networks, function(a, b) return a.name < b.name end)
      callback(networks)
    end)
  end)
end

--- @param callback fun(stats: docker.ContainerStats[])
local function fetch_container_stats(callback)
  vim.system(
    { 'docker', 'stats', '--no-stream', '--format', 'json' },
    { text = true },
    function(out)
      vim.schedule(function()
        ---@type docker.ContainerStats[]
        local stats = {}
        local lines = vim
          .iter(vim.split(out.stdout or '', '\n'))
          :filter(function(l) return l ~= '' end)
          :totable()

        for _, line in ipairs(lines) do
          local raw = vim.json.decode(line)
          local cpu_str = (raw.CPUPerc or ''):gsub('%%', '')
          local mem_pct_str = (raw.MemPerc or ''):gsub('%%', '')
          local cpu_pct = tonumber(cpu_str) or 0
          local mem_pct = tonumber(mem_pct_str) or 0
          local mem_usage, mem_limit = (raw.MemUsage or ''):match '([%d%.%a]+)%s*/%s*([%d%.%a]+)'
          local net_rx, net_tx = (raw.NetIO or ''):match '([%d%.%a]+)%s*/%s*([%d%.%a]+)'
          local blk_read, blk_write = (raw.BlockIO or ''):match '([%d%.%a]+)%s*/%s*([%d%.%a]+)'

          table.insert(stats, {
            id = raw.ID or '',
            name = raw.Name or '',
            cpu_percent = cpu_pct,
            mem_usage = mem_usage or '0B',
            mem_limit = mem_limit or '0B',
            mem_percent = mem_pct,
            net_io_rx = net_rx or '0B',
            net_io_tx = net_tx or '0B',
            block_io_read = blk_read or '0B',
            block_io_write = blk_write or '0B',
            pids = tonumber(raw.PIDs) or 0,
          })
        end

        table.sort(stats, function(a, b) return a.name < b.name end)
        callback(stats)
      end)
    end
  )
end

--- @param callback fun(projects: docker.ComposeProject[])
local function fetch_compose_projects(callback)
  vim.system({ 'docker', 'compose', 'ls', '--format', 'json' }, { text = true }, function(out)
    vim.schedule(function()
      ---@type docker.ComposeProject[]
      local projects = {}
      local ok, raw = pcall(vim.json.decode, out.stdout or '[]')
      if not ok then raw = {} end

      for _, item in ipairs(raw) do
        table.insert(projects, {
          name = item.Name or '',
          status = item.Status or '',
          config_files = item.ConfigFiles or '',
          raw = item,
        })
      end

      table.sort(projects, function(a, b) return a.name < b.name end)
      callback(projects)
    end)
  end)
end

--- @param callback fun(disk_usage: docker.SystemDiskUsage[], info: docker.SystemInfo)
local function fetch_system_info(callback)
  local disk_usage = {} ---@type docker.SystemDiskUsage[]
  local info = {} ---@type docker.SystemInfo
  local pending = 2

  local function check_done()
    pending = pending - 1
    if pending == 0 then callback(disk_usage, info) end
  end

  vim.system({ 'docker', 'system', 'df', '--format', 'json' }, { text = true }, function(out)
    vim.schedule(function()
      local lines = vim
        .iter(vim.split(out.stdout or '', '\n'))
        :filter(function(l) return l ~= '' end)
        :totable()

      for _, line in ipairs(lines) do
        local raw = vim.json.decode(line)
        local pct = tonumber((raw.Reclaimable or ''):match '%((%d+)%%%)') or 0

        table.insert(disk_usage, {
          type = raw.Type or '',
          total_count = tonumber(raw.TotalCount) or 0,
          active = tonumber(raw.Active) or 0,
          size = raw.Size or '0B',
          reclaimable = raw.Reclaimable or '0B',
          reclaimable_percent = pct,
        })
      end
      check_done()
    end)
  end)

  vim.system({ 'docker', 'info', '--format', 'json' }, { text = true }, function(out)
    vim.schedule(function()
      local ok, raw = pcall(vim.json.decode, out.stdout or '{}')
      if ok then
        info = {
          server_version = raw.ServerVersion or 'unknown',
          storage_driver = raw.Driver or 'unknown',
          containers_running = raw.ContainersRunning or 0,
          containers_paused = raw.ContainersPaused or 0,
          containers_stopped = raw.ContainersStopped or 0,
          images = raw.Images or 0,
        }
      end
      check_done()
    end)
  end)
end

--- @param callback fun(contexts: docker.Context[])
local function fetch_contexts(callback)
  vim.system({ 'docker', 'context', 'ls', '--format', 'json' }, { text = true }, function(out)
    vim.schedule(function()
      ---@type docker.Context[]
      local contexts = {}
      local lines = vim
        .iter(vim.split(out.stdout or '', '\n'))
        :filter(function(l) return l ~= '' end)
        :totable()

      for _, line in ipairs(lines) do
        local raw = vim.json.decode(line)
        table.insert(contexts, {
          name = raw.Name or '',
          description = raw.Description or '',
          docker_endpoint = raw.DockerEndpoint or '',
          current = raw.Current or false,
          error = raw.Error or '',
        })
      end

      table.sort(contexts, function(a, b)
        if a.current ~= b.current then return a.current end
        return a.name < b.name
      end)
      callback(contexts)
    end)
  end)
end

--- @param query string
--- @param callback fun(results: docker.HubSearchResult[])
local function fetch_hub_search(query, callback)
  local url = 'https://hub.docker.com/v2/search/repositories?query='
    .. vim.uri_encode(query)
    .. '&page_size=25'
  local cmd = { 'curl', '-s', '-H', 'Accept: application/json', url }
  vim.system(cmd, { text = true }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then
        callback {}
        return
      end
      ---@type docker.HubSearchResult[]
      local results = {}
      local ok, data = pcall(vim.json.decode, out.stdout or '{}')
      if not ok or not data.results then
        callback {}
        return
      end

      for _, item in ipairs(data.results or {}) do
        -- API returns repo_name, short_description, repo_owner
        local repo_name = item.repo_name or ''
        local namespace = item.repo_owner or ''
        if namespace == '' and repo_name:find '/' then
          namespace, repo_name = repo_name:match '^([^/]+)/(.+)$'
        end
        if namespace == '' then namespace = 'library' end
        table.insert(results, {
          name = repo_name,
          namespace = namespace,
          description = item.short_description or '',
          star_count = tonumber(item.star_count) or 0,
          pull_count = tonumber(item.pull_count) or 0,
          is_official = item.is_official or false,
          is_automated = item.is_automated or false,
        })
      end
      callback(results)
    end)
  end)
end

--- @param namespace string
--- @param name string
--- @param callback fun(detail: docker.HubRepositoryDetail | nil, tags: docker.HubTag[])
local function fetch_hub_repo_detail(namespace, name, callback)
  local detail = nil ---@type docker.HubRepositoryDetail
  local tags = {} ---@type docker.HubTag[]
  local pending = 2

  local function check_done()
    pending = pending - 1
    if pending == 0 then callback(detail, tags) end
  end

  local detail_cmd = {
    'curl',
    '-s',
    '-H',
    'Accept: application/json',
    'https://hub.docker.com/v2/namespaces/' .. namespace .. '/repositories/' .. name,
  }
  vim.system(detail_cmd, { text = true }, function(out)
    vim.schedule(function()
      if out.code == 0 then
        local ok, data = pcall(vim.json.decode, out.stdout or '{}')
        if ok and data then
          detail = {
            name = data.name or name,
            namespace = data.namespace or namespace,
            description = data.description or '',
            full_description = data.full_description or '',
            star_count = tonumber(data.star_count) or 0,
            pull_count = tonumber(data.pull_count) or 0,
            is_official = data.is_official or false,
            tags = {},
            last_updated = data.last_updated or '',
          }
        end
      end
      check_done()
    end)
  end)

  local tags_cmd = {
    'curl',
    '-s',
    '-H',
    'Accept: application/json',
    'https://hub.docker.com/v2/namespaces/'
      .. namespace
      .. '/repositories/'
      .. name
      .. '/tags?page_size=100',
  }
  vim.system(tags_cmd, { text = true }, function(out)
    vim.schedule(function()
      if out.code == 0 then
        local ok, data = pcall(vim.json.decode, out.stdout or '{}')
        if ok and data.results then
          for _, tag in ipairs(data.results or {}) do
            table.insert(tags, {
              name = tag.name or '',
              last_updated = tag.last_updated or '',
              full_size = tonumber(tag.full_size) or 0,
              digest = tag.digest or '',
            })
          end
        end
      end
      check_done()
    end)
  end)
end

--------------------------------------------------------------------------------
-- Resource View Factory
--------------------------------------------------------------------------------

--- @class docker.ViewConfig
--- @field title string
--- @field columns string[]
--- @field filter_fn fun(item: any, filter: string): boolean
--- @field render_cells fun(item: any): morph.Tree[]
--- @field keymaps fun(item: any, on_refresh: fun()): table<string, fun(): string>

--- @param config docker.ViewConfig
--- @return fun(ctx: morph.Ctx): morph.Tree
local function create_resource_view(config)
  --- @param ctx morph.Ctx<{ items: any[], loading: boolean, on_refresh: fun() }, { filter: string }>
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
-- Containers View
--------------------------------------------------------------------------------

local ContainersView = create_resource_view {
  title = 'Containers',
  columns = { 'NAME', 'IMAGE', 'ID', 'STATUS', 'PORTS' },

  filter_fn = function(container, filter)
    local matches_filter = utils.create_filter_fn(filter)
    return matches_filter(container.name)
      or matches_filter(container.image)
      or matches_filter(container.id)
  end,

  render_cells = function(container)
    local is_running = container.status:find 'Up'
    return {
      h.Constant({}, container.name),
      h.String({}, container.image),
      h.Comment({}, container.id:sub(1, 12)),
      is_running and h.DiagnosticOk({}, container.status)
        or h.DiagnosticError({}, container.status),
      h.Comment({}, container.ports),
    }
  end,

  keymaps = function(container, on_refresh)
    --- @cast container docker.Container
    --- @cast on_refresh fun()
    local is_running = container.status:find 'Up'
    return {
      ['gi'] = keymap(function() show_inspect('container', container.id) end),
      ['gl'] = keymap(function() term.open('docker logs --since 5m -f ' .. container.id) end),
      ['gx'] = keymap(function() term.open('docker exec -it ' .. container.id .. ' sh') end),
      ['gs'] = keymap(function()
        if is_running then
          term.open('docker stop ' .. container.id)
        else
          term.open('docker start ' .. container.id)
        end
      end),
      ['r'] = keymap(function()
        vim.schedule(function()
          vim.ui.input(
            { prompt = 'New container name: ', default = container.name },
            function(new_name)
              if not new_name or new_name == '' then return end
              vim.system({ 'docker', 'rename', container.id, new_name }, {}, function(out)
                vim.schedule(function()
                  if out.code == 0 then
                    vim.notify('Renamed ' .. container.name .. ' to ' .. new_name)
                    on_refresh()
                  else
                    vim.notify('Failed to rename: ' .. (out.stderr or ''), vim.log.levels.ERROR)
                  end
                end)
              end)
            end
          )
        end)
      end),
      ['gk'] = keymap(function()
        confirm_action('Kill container ' .. container.name .. '?', function()
          vim.system(
            { 'docker', 'kill', container.id },
            {},
            function() vim.schedule(on_refresh) end
          )
        end)
      end),
      ['gd'] = keymap(function()
        confirm_action('Remove container ' .. container.name .. '?', function()
          vim.system({ 'docker', 'rm', container.id }, {}, function() vim.schedule(on_refresh) end)
        end)
      end),
    }
  end,
}

--------------------------------------------------------------------------------
-- Images View
--------------------------------------------------------------------------------

local ImagesView = create_resource_view {
  title = 'Images',
  columns = { 'REPOSITORY', 'TAG', 'ID', 'CREATED', 'SIZE' },

  filter_fn = function(image, filter)
    local matches_filter = utils.create_filter_fn(filter)
    return matches_filter(image.repository) or matches_filter(image.tag) or matches_filter(image.id)
  end,

  render_cells = function(image)
    local is_dangling = image.repository == '<none>'
    return {
      is_dangling and h.DiagnosticWarn({}, image.repository) or h.Constant({}, image.repository),
      h.String({}, image.tag),
      h.Comment({}, image.id:sub(1, 12)),
      h.Comment({}, image.created),
      h.Number({}, image.size),
    }
  end,

  keymaps = function(image, on_refresh)
    local full_name = image.repository .. ':' .. image.tag
    return {
      ['gi'] = keymap(function() show_inspect('image', image.id) end),
      ['gR'] = keymap(function()
        vim.schedule(function()
          vim.ui.input({ prompt = 'Container name (optional): ' }, function(name)
            local cmd = 'docker run -it'
            if name and name ~= '' then cmd = cmd .. ' --name ' .. name end
            cmd = cmd .. ' ' .. full_name
            term.open(cmd)
          end)
        end)
      end),
      ['gt'] = keymap(function()
        vim.schedule(function()
          vim.ui.input({ prompt = 'New tag (repository:tag): ' }, function(new_tag)
            if not new_tag or new_tag == '' then return end
            vim.system({ 'docker', 'tag', image.id, new_tag }, {}, function(out)
              vim.schedule(function()
                if out.code == 0 then
                  vim.notify('Tagged ' .. image.id:sub(1, 12) .. ' as ' .. new_tag)
                  on_refresh()
                else
                  vim.notify('Failed to tag: ' .. (out.stderr or ''), vim.log.levels.ERROR)
                end
              end)
            end)
          end)
        end)
      end),
      ['gp'] = keymap(function()
        vim.schedule(function() term.open('docker push ' .. full_name) end)
      end),
      ['gd'] = keymap(function()
        confirm_action('Remove image ' .. full_name .. '?', function()
          vim.system({ 'docker', 'rmi', image.id }, {}, function(out)
            vim.schedule(function()
              if out.code == 0 then
                on_refresh()
              else
                vim.notify('Failed to remove: ' .. (out.stderr or ''), vim.log.levels.ERROR)
              end
            end)
          end)
        end)
      end),
      ['gD'] = keymap(function()
        confirm_action('Force remove image ' .. full_name .. '?', function()
          vim.system({ 'docker', 'rmi', '-f', image.id }, {}, function(out)
            vim.schedule(function()
              if out.code == 0 then
                on_refresh()
              else
                vim.notify('Failed to remove: ' .. (out.stderr or ''), vim.log.levels.ERROR)
              end
            end)
          end)
        end)
      end),
    }
  end,
}

--------------------------------------------------------------------------------
-- Volumes View
--------------------------------------------------------------------------------

local VolumesView = create_resource_view {
  title = 'Volumes',
  columns = { 'NAME', 'DRIVER', 'MOUNTPOINT' },

  filter_fn = function(volume, filter)
    local matches_filter = utils.create_filter_fn(filter)
    return matches_filter(volume.name)
  end,

  render_cells = function(volume)
    return {
      h.Constant({}, volume.name),
      h.String({}, volume.driver),
      h.Comment({}, volume.mountpoint),
    }
  end,

  keymaps = function(volume, on_refresh)
    return {
      ['gi'] = keymap(function() show_inspect('volume', volume.name) end),
      ['gd'] = keymap(function()
        confirm_action('Remove volume ' .. volume.name .. '?', function()
          vim.system({ 'docker', 'volume', 'rm', volume.name }, {}, function(out)
            vim.schedule(function()
              if out.code == 0 then
                on_refresh()
              else
                vim.notify('Failed to remove: ' .. (out.stderr or ''), vim.log.levels.ERROR)
              end
            end)
          end)
        end)
      end),
    }
  end,
}

--------------------------------------------------------------------------------
-- Networks View
--------------------------------------------------------------------------------

local NetworksView = create_resource_view {
  title = 'Networks',
  columns = { 'NAME', 'ID', 'DRIVER', 'SCOPE' },

  filter_fn = function(network, filter)
    local matches_filter = utils.create_filter_fn(filter)
    return matches_filter(network.name)
  end,

  render_cells = function(network)
    local is_builtin = network.name == 'bridge' or network.name == 'host' or network.name == 'none'
    return {
      is_builtin and h.Title({}, network.name) or h.Constant({}, network.name),
      h.Comment({}, network.id:sub(1, 12)),
      h.String({}, network.driver),
      h.Comment({}, network.scope),
    }
  end,

  keymaps = function(network, on_refresh)
    local is_builtin = network.name == 'bridge' or network.name == 'host' or network.name == 'none'
    return {
      ['gi'] = keymap(function() show_inspect('network', network.id) end),
      ['gd'] = keymap(function()
        if is_builtin then
          vim.schedule(
            function() vim.notify('Cannot remove built-in network', vim.log.levels.WARN) end
          )
          return
        end
        confirm_action('Remove network ' .. network.name .. '?', function()
          vim.system({ 'docker', 'network', 'rm', network.id }, {}, function(out)
            vim.schedule(function()
              if out.code == 0 then
                on_refresh()
              else
                vim.notify('Failed to remove: ' .. (out.stderr or ''), vim.log.levels.ERROR)
              end
            end)
          end)
        end)
      end),
    }
  end,
}

--------------------------------------------------------------------------------
-- Stats View
--------------------------------------------------------------------------------

--- Render a simple text-based meter bar
--- @param value number Current value (0-100)
--- @param width number Width in characters
--- @return string
local function render_meter(value, width)
  local filled = math.floor((value / 100) * width)
  local empty = width - filled
  return string.rep('█', filled) .. string.rep('░', empty)
end

local StatsView = create_resource_view {
  title = 'Live Stats',
  columns = { 'NAME', 'CPU', 'MEMORY', 'NET I/O', 'BLOCK I/O', 'PIDS' },

  filter_fn = function(stat, filter)
    local matches_filter = utils.create_filter_fn(filter)
    return matches_filter(stat.name)
  end,

  render_cells = function(stat)
    local cpu_hl = stat.cpu_percent > 80 and 'DiagnosticError'
      or stat.cpu_percent > 50 and 'DiagnosticWarn'
      or 'DiagnosticOk'

    local mem_hl = stat.mem_percent > 80 and 'DiagnosticError'
      or stat.mem_percent > 50 and 'DiagnosticWarn'
      or 'DiagnosticOk'

    return {
      h.Constant({}, stat.name),
      {
        h[cpu_hl]({}, render_meter(stat.cpu_percent, 10)),
        ' ',
        h[cpu_hl]({}, string.format('%5.1f%%', stat.cpu_percent)),
      },
      {
        h[mem_hl]({}, render_meter(stat.mem_percent, 10)),
        ' ',
        h.Number({}, stat.mem_usage .. '/' .. stat.mem_limit),
      },
      h.Comment({}, stat.net_io_rx .. ' / ' .. stat.net_io_tx),
      h.Comment({}, stat.block_io_read .. ' / ' .. stat.block_io_write),
      h.Number({}, tostring(stat.pids)),
    }
  end,

  keymaps = function(stat, _on_refresh)
    return {
      ['gi'] = keymap(function() show_inspect('container', stat.id) end),
      ['gl'] = keymap(function() term.open('docker logs --since 5m -f ' .. stat.id) end),
      ['gx'] = keymap(function() term.open('docker exec -it ' .. stat.id .. ' sh') end),
    }
  end,
}

--------------------------------------------------------------------------------
-- Compose View
--------------------------------------------------------------------------------

local ComposeView = create_resource_view {
  title = 'Compose Projects',
  columns = { 'PROJECT', 'STATUS', 'CONFIG FILES' },

  filter_fn = function(project, filter)
    local matches_filter = utils.create_filter_fn(filter)
    return matches_filter(project.name)
  end,

  render_cells = function(project)
    local is_running = project.status:find 'running'
    return {
      h.Constant({}, project.name),
      is_running and h.DiagnosticOk({}, project.status) or h.DiagnosticWarn({}, project.status),
      h.Comment({}, project.config_files),
    }
  end,

  keymaps = function(project, _on_refresh)
    return {
      ['gi'] = keymap(function()
        vim.schedule(function()
          vim.system(
            { 'docker', 'compose', '-p', project.name, 'config' },
            { text = true },
            function(result)
              vim.schedule(function()
                create_scratch_buffer('vnew', 'yaml')
                vim.api.nvim_buf_set_lines(0, 0, -1, true, vim.split(result.stdout or '', '\n'))
              end)
            end
          )
        end)
      end),
      ['gu'] = keymap(function() term.open('docker compose -p ' .. project.name .. ' up -d') end),
      ['gd'] = keymap(function()
        confirm_action(
          'Stop and remove ' .. project.name .. '?',
          function() term.open('docker compose -p ' .. project.name .. ' down') end
        )
      end),
      ['gr'] = keymap(function() term.open('docker compose -p ' .. project.name .. ' restart') end),
      ['gl'] = keymap(
        function() term.open('docker compose -p ' .. project.name .. ' logs -f --tail=100') end
      ),
      ['gp'] = keymap(function() term.open('docker compose -p ' .. project.name .. ' pull') end),
    }
  end,
}

--------------------------------------------------------------------------------
-- System View
--------------------------------------------------------------------------------

--- @param ctx morph.Ctx<{ disk_usage: docker.SystemDiskUsage[], info: docker.SystemInfo, loading: boolean, on_refresh: fun() }, { filter: string }>
local function SystemView(ctx)
  if ctx.phase == 'mount' then ctx.state = { filter = '' } end

  local info = ctx.props.info or {}
  local disk_usage = ctx.props.disk_usage or {}

  local disk_rows = {
    {
      cells = {
        h.Constant({}, 'TYPE'),
        h.Constant({}, 'COUNT'),
        h.Constant({}, 'ACTIVE'),
        h.Constant({}, 'SIZE'),
        h.Constant({}, 'RECLAIMABLE'),
      },
    },
  }

  for _, item in ipairs(disk_usage) do
    local reclaimable_hl = item.reclaimable_percent > 50 and 'DiagnosticWarn' or 'Comment'
    table.insert(disk_rows, {
      cells = {
        h.Title({}, item.type),
        h.Number({}, tostring(item.total_count)),
        h.Number({}, tostring(item.active)),
        h.Number({}, item.size),
        h[reclaimable_hl]({}, item.reclaimable),
      },
    })
  end

  local prune_actions = {
    { key = 'gp', label = 'Prune unused (safe)', cmd = 'docker system prune -f' },
    { key = 'gP', label = 'Prune ALL unused images', cmd = 'docker system prune -af' },
    { key = 'gv', label = 'Prune unused volumes', cmd = 'docker volume prune -f' },
    { key = 'gb', label = 'Prune build cache', cmd = 'docker builder prune -f' },
  }

  -- Build keymaps for prune actions
  local prune_keymaps = {}
  local prune_items = {}
  for _, action in ipairs(prune_actions) do
    prune_keymaps[action.key] = keymap(function()
      confirm_action('Run: ' .. action.cmd .. '?', function() term.open(action.cmd) end)
    end)
    table.insert(prune_items, {
      h.Title({}, action.key),
      ' ',
      h.String({}, action.label),
      '\n',
    })
  end

  return h('text', { nmap = prune_keymaps }, {
    h.RenderMarkdownH1({}, '## System Overview'),
    ctx.props.loading and h.NonText({}, ' (loading...)') or nil,
    '\n\n',

    h.RenderMarkdownH1({}, '### Docker Info'),
    '\n',
    h.Label({}, 'Server Version: '),
    h.Number({}, info.server_version or 'N/A'),
    '\n',
    h.Label({}, 'Storage Driver: '),
    h.String({}, info.storage_driver or 'N/A'),
    '\n',
    h.Label({}, 'Containers: '),
    h.DiagnosticOk({}, tostring(info.containers_running or 0) .. ' running'),
    ' / ',
    h.DiagnosticWarn({}, tostring(info.containers_paused or 0) .. ' paused'),
    ' / ',
    h.DiagnosticError({}, tostring(info.containers_stopped or 0) .. ' stopped'),
    '\n',
    h.Label({}, 'Images: '),
    h.Number({}, tostring(info.images or 0)),
    '\n\n',

    h.RenderMarkdownH1({}, '### Disk Usage'),
    '\n\n',
    h(Table, { rows = disk_rows, header = true, header_separator = true }),
    '\n\n',

    h.RenderMarkdownH1({}, '### Cleanup Actions'),
    '\n\n',
    prune_items,
  })
end

--------------------------------------------------------------------------------
-- Contexts View
--------------------------------------------------------------------------------

local ContextsView = create_resource_view {
  title = 'Docker Contexts',
  columns = { 'NAME', 'DESCRIPTION', 'ENDPOINT', 'STATUS' },

  filter_fn = function(context, filter)
    local matches_filter = utils.create_filter_fn(filter)
    return matches_filter(context.name)
  end,

  render_cells = function(context)
    local status_cell = context.current and h.DiagnosticOk({}, 'ACTIVE')
      or context.error ~= '' and h.DiagnosticError({}, 'ERROR')
      or h.Comment({}, '-')

    return {
      context.current and h.Title({}, context.name .. ' *') or h.Constant({}, context.name),
      h.String({}, context.description),
      h.Comment({}, context.docker_endpoint),
      status_cell,
    }
  end,

  keymaps = function(context, on_refresh)
    return {
      ['<CR>'] = keymap(function()
        if context.current then
          vim.notify('Already using context: ' .. context.name)
          return
        end
        vim.system({ 'docker', 'context', 'use', context.name }, {}, function(out)
          vim.schedule(function()
            if out.code == 0 then
              vim.notify('Switched to context: ' .. context.name)
              on_refresh()
            else
              vim.notify('Failed to switch context: ' .. (out.stderr or ''), vim.log.levels.ERROR)
            end
          end)
        end)
      end),
      ['gi'] = keymap(function()
        vim.schedule(function()
          vim.system(
            { 'docker', 'context', 'inspect', context.name },
            { text = true },
            function(result)
              vim.schedule(function()
                create_scratch_buffer('vnew', 'json')
                vim.api.nvim_buf_set_lines(0, 0, -1, true, vim.split(result.stdout or '', '\n'))
              end)
            end
          )
        end)
      end),
      ['gn'] = keymap(function()
        vim.schedule(function()
          vim.ui.input({ prompt = 'Context name: ' }, function(name)
            if not name or name == '' then return end
            vim.ui.input({ prompt = 'Docker host (e.g., ssh://user@host): ' }, function(host)
              if not host or host == '' then return end
              vim.system(
                { 'docker', 'context', 'create', name, '--docker', 'host=' .. host },
                {},
                function(out)
                  vim.schedule(function()
                    if out.code == 0 then
                      vim.notify('Created context: ' .. name)
                      on_refresh()
                    else
                      vim.notify('Failed to create: ' .. (out.stderr or ''), vim.log.levels.ERROR)
                    end
                  end)
                end
              )
            end)
          end)
        end)
      end),
      ['gd'] = keymap(function()
        if context.current then
          vim.notify('Cannot remove active context', vim.log.levels.WARN)
          return
        end
        confirm_action('Remove context ' .. context.name .. '?', function()
          vim.system({ 'docker', 'context', 'rm', context.name }, {}, function(out)
            vim.schedule(function()
              if out.code == 0 then
                vim.notify('Removed context: ' .. context.name)
                on_refresh()
              else
                vim.notify('Failed to remove: ' .. (out.stderr or ''), vim.log.levels.ERROR)
              end
            end)
          end)
        end)
      end),
    }
  end,
}

--------------------------------------------------------------------------------
-- Hub View
--------------------------------------------------------------------------------

--- @class docker.HubViewState
--- @field query string
--- @field results docker.HubSearchResult[]

--- @class docker.HubViewProps
--- @field results docker.HubSearchResult[]
--- @field loading boolean
--- @field detail docker.HubRepositoryDetail | nil
--- @field detail_tags docker.HubTag[]
--- @field detail_loading boolean
--- @field on_search fun(query: string)
--- @field on_select fun(result: docker.HubSearchResult)
--- @field on_back fun()

--- @param ctx morph.Ctx<docker.HubViewProps, docker.HubViewState>
local function HubView(ctx)
  if ctx.phase == 'mount' then ctx.state = { query = '', results = {} } end
  local state = assert(ctx.state)

  local function search()
    if state.query and state.query ~= '' then ctx.props.on_search(state.query) end
  end

  local function go_back() ctx.props.on_back() end

  local detail = ctx.props.detail
  local detail_tags = ctx.props.detail_tags or {}
  local results = ctx.props.results or {}

  if detail then
    local full_name = detail.namespace .. '/' .. detail.name
    local tag_rows = {
      { cells = { h.Constant({}, 'TAG'), h.Constant({}, 'UPDATED'), h.Constant({}, 'SIZE') } },
    }
    for _, tag in ipairs(detail_tags) do
      local size_str = tag.full_size >= 1048576
          and string.format('%.1fGB', tag.full_size / 1073741824)
        or tag.full_size >= 1024 and string.format('%.1fMB', tag.full_size / 1048576)
        or string.format('%.1fKB', tag.full_size / 1024)
      local pull_cmd_with_tag = 'docker pull ' .. full_name .. ':' .. tag.name
      table.insert(tag_rows, {
        nmap = {
          ['g"'] = keymap(function()
            vim.fn.setreg('"', pull_cmd_with_tag)
            vim.notify('Yanked: ' .. pull_cmd_with_tag)
          end),
        },
        cells = {
          h.String({}, tag.name),
          h.Comment({}, tag.last_updated and tag.last_updated:sub(1, 10) or ''),
          h.Number({}, size_str),
        },
      })
    end

    if ctx.props.detail_loading then
      return {
        h.RenderMarkdownH1({}, '## Docker Hub'),
        '\n\n',
        h.NonText({}, 'Loading...'),
      }
    end

    local pull_cmd = 'docker pull ' .. full_name
    local hub_url = detail.is_official and ('https://hub.docker.com/_/' .. detail.name)
      or ('https://hub.docker.com/r/' .. full_name)
    local detail_content = {
      h.RenderMarkdownH1({}, '## ' .. full_name),
      detail.is_official and { ' ', h.DiagnosticOk({}, '[official]') } or nil,
      '\n\n',
      h.Label({}, 'Stars: '),
      h.Number({}, tostring(detail.star_count)),
      '  ',
      h.Label({}, 'Pulls: '),
      h.Number({}, tostring(detail.pull_count)),
      '\n\n',
      detail.full_description and {
        h.RenderMarkdownH1({}, '### Description'),
        '\n',
        h.Normal(
          {},
          detail.full_description:gsub('\\n', '\n'):sub(1, 500)
            .. (detail.full_description:len() > 500 and '...' or '')
        ),
        '\n\n',
      } or nil,
      h.RenderMarkdownH1({}, '### Pull Command'),
      '\n',
      h.String({}, pull_cmd),
      '\n\n',
      h.RenderMarkdownH1({}, '### Tags'),
      '\n\n',
      h(Table, {
        rows = tag_rows,
        header = true,
        header_separator = true,
        page_size = 20,
      }),
    }

    local page_keymaps = {
      ['<C-o>'] = keymap(go_back),
      ['g"'] = keymap(function()
        vim.fn.setreg('"', pull_cmd)
        vim.notify('Yanked: ' .. pull_cmd)
      end),
      ['gw'] = keymap(function() vim.ui.open(hub_url) end),
    }
    return h('text', { nmap = page_keymaps }, detail_content)
  end

  local results_rows = {
    {
      cells = {
        h.Constant({}, 'NAME'),
        h.Constant({}, 'DESCRIPTION'),
        h.Constant({}, 'STARS'),
        h.Constant({}, 'PULLS'),
      },
    },
  }
  for _, result in ipairs(results) do
    local full_name = result.namespace .. '/' .. result.name
    local pull_cmd = 'docker pull ' .. full_name
    local hub_url = result.is_official and ('https://hub.docker.com/_/' .. result.name)
      or ('https://hub.docker.com/r/' .. full_name)
    local name_cell = h[result.is_official and 'DiagnosticOk' or 'Constant']({}, full_name)
    local description = vim.trim(result.description)
    table.insert(results_rows, {
      nmap = {
        ['<CR>'] = keymap(function() ctx.props.on_select(result) end),
        ['g"'] = keymap(function()
          vim.fn.setreg('"', pull_cmd)
          vim.notify('Yanked: ' .. pull_cmd)
        end),
        ['gw'] = keymap(function() vim.ui.open(hub_url) end),
      },
      cells = {
        name_cell,
        h.Comment({}, description:sub(1, 60) .. (description:len() > 60 and '...' or '')),
        h.Number({}, tostring(result.star_count)),
        h.Number({}, tostring(result.pull_count)),
      },
    })
  end

  return {
    h.RenderMarkdownH1({}, '## Docker Hub'),
    '\n\n',
    h.Label({}, 'Search: '),
    '[',
    h.String({
      nmap = { ['<CR>'] = keymap(search) },
      imap = { ['<CR>'] = keymap(search) },
      on_change = function(e)
        state.query = e.text
        ctx:update(state)
      end,
    }, state.query or ''),
    ']',
    '\n\n',
    ctx.props.loading and h.NonText({}, ' (searching...)') or nil,
    (#results == 0 and state.query ~= '' and not ctx.props.loading)
        and h.NonText({}, 'No results found')
      or nil,
    (state.query == '' and #results == 0) and {
      h.NonText({}, 'Enter a search term and press <CR>'),
      '\n\n',
      h.Comment({}, 'Example: ubuntu, nginx, python, alpine'),
    } or nil,
    #results > 0 and {
      '\n',
      h(Table, { rows = results_rows, header = true, header_separator = true }),
    } or nil,
  }
end

--------------------------------------------------------------------------------
-- Page Configuration
--------------------------------------------------------------------------------

--- @class docker.PageConfig
--- @field fetch fun(callback: fun(items: any[], ...))
--- @field state_key string
--- @field view function
--- @field custom? boolean

--- @type table<docker.Page, docker.PageConfig>
local PAGE_CONFIGS = {
  containers = { fetch = fetch_containers, state_key = 'containers', view = ContainersView },
  images = { fetch = fetch_images, state_key = 'images', view = ImagesView },
  volumes = { fetch = fetch_volumes, state_key = 'volumes', view = VolumesView },
  networks = { fetch = fetch_networks, state_key = 'networks', view = NetworksView },
  stats = { fetch = fetch_container_stats, state_key = 'stats', view = StatsView },
  compose = { fetch = fetch_compose_projects, state_key = 'compose_projects', view = ComposeView },
  system = { fetch = fetch_system_info, state_key = 'disk_usage', view = SystemView, custom = true },
  contexts = { fetch = fetch_contexts, state_key = 'contexts', view = ContextsView },
  hub = { state_key = 'hub', view = HubView, custom = true },
}

--------------------------------------------------------------------------------
-- App Component
--------------------------------------------------------------------------------

--- @class docker.AppState
--- @field page docker.Page
--- @field show_help boolean
--- @field loading boolean
--- @field current_context string
--- @field containers docker.Container[]
--- @field images docker.Image[]
--- @field volumes docker.Volume[]
--- @field networks docker.Network[]
--- @field stats docker.ContainerStats[]
--- @field compose_projects docker.ComposeProject[]
--- @field disk_usage docker.SystemDiskUsage[]
--- @field system_info docker.SystemInfo
--- @field contexts docker.Context[]
--- @field timer uv.uv_timer_t
--- @field hub_query string
--- @field hub_results docker.HubSearchResult[]
--- @field hub_selected number
--- @field hub_detail docker.HubRepositoryDetail | nil
--- @field hub_detail_tags docker.HubTag[]
--- @field hub_detail_loading boolean
--- @field hub_selected_tag number

--- @param ctx morph.Ctx<any, docker.AppState>
local function App(ctx)
  --- @param show_loading? boolean
  local function refresh(show_loading)
    local state = assert(ctx.state)
    if show_loading then
      state.loading = true
      ctx:update(state)
    end

    local page = assert(state.page)
    local config = assert(PAGE_CONFIGS[page])
    if config.custom and state.page == 'system' then
      -- System page returns two values: disk_usage and info
      config.fetch(function(disk_usage, info)
        state.disk_usage = disk_usage
        state.system_info = info
        state.loading = false
        ctx:update(state)
      end)
    elseif page == 'contexts' then
      -- Contexts page also updates header context display
      config.fetch(function(items)
        state[config.state_key] = items
        state.current_context = get_current_context()
        state.loading = false
        ctx:update(state)
      end)
    elseif page == 'hub' then
      state.loading = false
      ctx:update(state)
    else
      config.fetch(function(items)
        state[config.state_key] = items
        state.loading = false
        ctx:update(state)
      end)
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

  if ctx.phase == 'mount' then
    ctx.state = {
      page = 'containers',
      show_help = false,
      loading = true,
      current_context = get_current_context(),
      containers = {},
      images = {},
      volumes = {},
      networks = {},
      stats = {},
      compose_projects = {},
      disk_usage = {},
      system_info = {},
      contexts = {},
      timer = assert(vim.uv.new_timer()),
      hub_query = '',
      hub_results = {},
      hub_selected = 1,
      hub_detail = nil,
      hub_detail_tags = {},
      hub_detail_loading = false,
      hub_selected_tag = 1,
    } --- @type docker.AppState
    vim.schedule(refresh)
    -- Auto-refresh every 2 seconds for containers and stats pages
    ctx.state.timer:start(2000, 2000, function()
      vim.schedule(function()
        if ctx.state and (ctx.state.page == 'containers' or ctx.state.page == 'stats') then
          refresh(false)
        end
      end)
    end)
  end

  local state = assert(ctx.state)
  if ctx.phase == 'unmount' then
    assert(state.timer):stop()
    assert(state.timer):close()
  end

  -- Build navigation keymaps
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
  local page = assert(state.page)
  local config = assert(PAGE_CONFIGS[page])
  local page_content
  if config.custom and page == 'system' then
    page_content = h(config.view, {
      disk_usage = state.disk_usage,
      info = state.system_info,
      loading = state.loading,
      on_refresh = refresh,
    })
  elseif state.page == 'hub' then
    page_content = h(config.view, {
      results = state.hub_results,
      loading = state.loading,
      detail = state.hub_detail,
      detail_tags = state.hub_detail_tags,
      detail_loading = state.hub_detail_loading,
      on_search = function(query)
        state.hub_results = {}
        state.hub_detail = nil
        state.loading = true
        ctx:update(state)
        fetch_hub_search(query, function(results)
          state.hub_results = results
          state.loading = false
          ctx:update(state)
        end)
      end,
      on_select = function(result)
        if result then
          state.hub_detail_loading = true
          ctx:update(state)
          fetch_hub_repo_detail(result.namespace, result.name, function(detail, tags)
            state.hub_detail = detail
            state.hub_detail_tags = tags
            state.hub_detail_loading = false
            ctx:update(state)
          end)
        end
      end,
      on_back = function()
        state.hub_detail = nil
        state.hub_detail_tags = {}
        ctx:update(state)
      end,
    })
  else
    page_content = h(config.view, {
      items = state[config.state_key],
      loading = state.loading,
      on_refresh = refresh,
    })
  end

  return h('text', { nmap = nav_keymaps }, {
    -- Header line
    h.RenderMarkdownH1({}, 'Docker'),
    ' ',
    h.NonText({}, 'ctx: '),
    h.Title({}, state.current_context),
    ' ',
    h.NonText({}, 'g? for help'),
    '\n\n',

    -- Tab navigation
    h(TabBar, {
      tabs = TABS,
      active_page = state.page,
      on_select = go_to_page,
      wrap_at = 5,
    }),

    -- Help panel (toggleable)
    state.show_help and { h(DockerHelp, { page = state.page }), '\n' },

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
  vim.api.nvim_buf_set_name(0, 'Docker')

  Morph.new(0):mount(h(App))
end

return M
