local Morph = require 'tuis.morph'
local h = Morph.h
local components = require 'tuis.components'
local Table = components.Table
local TabBar = components.TabBar
local Help = components.Help
local utils = require 'tuis.utils'
local keymap = utils.keymap

local M = {}

--- @type string[]
local CLI_DEPENDENCIES = { 'curl', 'gh', 'git', 'rm' }

function M.is_enabled() return utils.check_clis_available(CLI_DEPENDENCIES, true) end

--[[
================================================================================
Plugin Store - A UI for browsing, searching, and installing Neovim plugins

This module provides a TUI interface to:
1. Browse plugins from awesome-neovim
2. Search GitHub for plugins
3. Install, update, and remove plugins to ~/.local/share/nvim/site/pack/tuis-store/opt

The narrative flow of this file:
- Types & Configuration
- Core Infrastructure (file I/O, caching, HTTP)
- Domain Logic (GitHub API, awesome-neovim parsing, plugin management)
- UI Components (building blocks, then views, then the App shell)
- Bootstrap (opens a new tab and mounts the UI)
================================================================================
--]]

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

--- @class ps.Plugin
--- @field owner string
--- @field repo string
--- @field full_name string
--- @field description string
--- @field category string|nil
--- @field source 'awesome'|'github'|'both'|'installed'
--- @field stars number|nil
--- @field updated_at string|nil
--- @field installed boolean
--- @field installed_ref string|nil
--- @field tags string[]|nil

--- @class ps.Category
--- @field name string
--- @field slug string
--- @field plugins ps.Plugin[]
--- @field collapsed boolean

--- @class ps.RateLimit
--- @field remaining number
--- @field reset number

--- @alias ps.Page 'browse'|'search'|'installed'|'detail'

--- @class ps.BrowseState
--- @field filter string

--- @class ps.SearchState
--- @field query string
--- @field results ps.Plugin[]
--- @field searching boolean

--- @class ps.InstalledState
--- @field plugins ps.Plugin[]

--- @class ps.DetailState
--- @field metadata table|nil
--- @field tags string[]
--- @field loading boolean

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

local STORE_PATH = vim.fs.joinpath(vim.fn.stdpath 'config', 'site/pack/tuis-store/opt')
local CACHE_PATH = vim.fs.joinpath(vim.fn.stdpath 'cache', 'tuis-store')
local CACHE_TTL_SECONDS = 86400 -- 24 hours
local AWESOME_NEOVIM_URL =
  'https://raw.githubusercontent.com/rockerBOO/awesome-neovim/main/README.md'
local GITHUB_API_BASE = 'https://api.github.com'

--------------------------------------------------------------------------------
-- Core Infrastructure: File I/O and Caching
--------------------------------------------------------------------------------

--- Ensure a directory exists, creating parent directories if needed
--- @param path string
local function ensure_directory_exists(path)
  if vim.fn.isdirectory(path) == 0 then vim.fn.mkdir(path, 'p') end
end

--- Read and parse a JSON file, returning nil on any failure
--- @param path string
--- @return table|nil
local function read_json_file(path)
  local file = io.open(path, 'r')
  if not file then return nil end

  local content = file:read '*a'
  file:close()

  local success, data = pcall(vim.json.decode, content)
  return success and data or nil
end

--- Write data as JSON to a file, creating parent directories if needed
--- @param path string
--- @param data table
local function write_json_file(path, data)
  ensure_directory_exists(vim.fs.dirname(path))

  local file = io.open(path, 'w')
  if not file then return end

  file:write(vim.json.encode(data))
  file:close()
end

--- Check if a cached file is still fresh (within TTL)
--- @param path string
--- @param ttl_seconds number
--- @return boolean
local function is_cache_fresh(path, ttl_seconds)
  local stat = vim.uv.fs_stat(path)
  if not stat then return false end

  local age_seconds = os.time() - stat.mtime.sec
  return age_seconds < ttl_seconds
end

--------------------------------------------------------------------------------
-- Core Infrastructure: Text Formatting
--------------------------------------------------------------------------------

--- Truncate a string to max length, adding ellipsis if needed
--- @param text string|nil
--- @param max_length number
--- @return string
local function truncate(text, max_length)
  if type(text) ~= 'string' then return '' end
  if #text <= max_length then return text end
  return text:sub(1, max_length - 3) .. '...'
end

--- Convert an ISO date string to a human-readable relative time
--- Examples: "today", "3d ago", "2w ago", "6mo ago", "1y ago"
--- @param iso_date string|nil
--- @return string
local function format_relative_time(iso_date)
  if not iso_date or iso_date == '' then return '' end

  local year, month, day = iso_date:match '(%d+)-(%d+)-(%d+)'
  if not year then
    -- Fallback: return the first 10 characters (YYYY-MM-DD)
    return iso_date:sub(1, 10)
  end

  local timestamp = os.time { year = tonumber(year), month = tonumber(month), day = tonumber(day) }
  local seconds_ago = os.time() - timestamp

  if seconds_ago < 0 then return 'just now' end

  -- Time thresholds in seconds
  local MINUTE, HOUR, DAY, WEEK, MONTH, YEAR = 60, 3600, 86400, 604800, 2592000, 31536000

  if seconds_ago < DAY then return 'today' end
  if seconds_ago < WEEK then return math.floor(seconds_ago / DAY) .. 'd ago' end
  if seconds_ago < MONTH then return math.floor(seconds_ago / WEEK) .. 'w ago' end
  if seconds_ago < YEAR then return math.floor(seconds_ago / MONTH) .. 'mo ago' end
  return math.floor(seconds_ago / YEAR) .. 'y ago'
end

--- Convert a category name to a URL-safe slug
--- @param name string
--- @return string
local function slugify(name) return name:lower():gsub('[^%w]+', '-'):gsub('^-', ''):gsub('-$', '') end

--------------------------------------------------------------------------------
-- Core Infrastructure: GitHub API with Rate Limiting
--------------------------------------------------------------------------------

--- @type ps.RateLimit|nil
local current_rate_limit = nil

local function is_rate_limited()
  if not current_rate_limit then return false end
  if current_rate_limit.remaining <= 5 and os.time() < current_rate_limit.reset then return true end
  return false
end

local function update_rate_limit(remaining, reset)
  if remaining and reset then current_rate_limit = { remaining = remaining, reset = reset } end
end

local function has_gh_cli() return vim.fn.executable 'gh' == 1 end

--- Fetch data from the GitHub API, using `gh` CLI if available, else `curl`
--- Handles rate limiting transparently.
--- @param endpoint string API endpoint path (e.g., "repos/owner/repo")
--- @param callback fun(data: table|nil, err: string|nil)
local function github_fetch(endpoint, callback)
  if is_rate_limited() then
    local reset_time = os.date('%H:%M', current_rate_limit.reset)
    vim.schedule(function() callback(nil, 'Rate limited. Resets at ' .. reset_time) end)
    return
  end

  local function handle_response(json_body, http_error)
    if http_error then
      callback(nil, http_error)
      return
    end

    local success, data = pcall(vim.json.decode, json_body or '{}')
    if not success then
      callback(nil, 'JSON parse error')
      return
    end

    callback(data, nil)
  end

  if has_gh_cli() then
    -- The gh CLI handles authentication automatically
    vim.system({ 'gh', 'api', endpoint }, { text = true }, function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          handle_response(nil, result.stderr or 'gh api failed')
        else
          handle_response(result.stdout, nil)
        end
      end)
    end)
  else
    -- Fallback to curl (unauthenticated, lower rate limits)
    local url = GITHUB_API_BASE .. '/' .. endpoint
    vim.system({ 'curl', '-s', '-w', '\n%{http_code}', url }, { text = true }, function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          handle_response(nil, 'curl failed')
          return
        end

        local lines = vim.split(result.stdout or '', '\n')
        local http_code = tonumber(table.remove(lines))
        local body = table.concat(lines, '\n')

        if http_code == 403 or http_code == 429 then
          update_rate_limit(0, os.time() + 3600)
          handle_response(nil, 'Rate limited')
        elseif http_code ~= 200 then
          handle_response(nil, 'HTTP ' .. (http_code or 'unknown'))
        else
          handle_response(body, nil)
        end
      end)
    end)
  end
end

--------------------------------------------------------------------------------
-- Domain: GitHub Repository Operations
--------------------------------------------------------------------------------

--- Fetch metadata for a GitHub repository
--- @param full_name string e.g., "nvim-telescope/telescope.nvim"
--- @param callback fun(metadata: table|nil)
local function fetch_repo_metadata(full_name, callback)
  github_fetch('repos/' .. full_name, function(data, err)
    if err or not data then
      callback(nil)
      return
    end

    callback {
      stars = data.stargazers_count,
      forks = data.forks_count,
      updated_at = data.pushed_at or data.updated_at,
      description = data.description,
      license = data.license and data.license.spdx_id,
      default_branch = data.default_branch,
    }
  end)
end

--- Fetch available tags for a GitHub repository
--- @param full_name string
--- @param callback fun(tags: string[])
local function fetch_repo_tags(full_name, callback)
  github_fetch('repos/' .. full_name .. '/tags?per_page=20', function(data, err)
    if err or not data then
      callback {}
      return
    end

    local tags = {}
    for _, tag in ipairs(data) do
      table.insert(tags, tag.name)
    end
    callback(tags)
  end)
end

--- Search GitHub for Neovim plugins matching a query
--- @param query string
--- @param callback fun(plugins: ps.Plugin[])
local function search_github_plugins(query, callback)
  local search_query = query .. ' neovim plugin in:name,description,readme'
  local endpoint = 'search/repositories?q=' .. vim.uri_encode(search_query) .. '&per_page=30'

  github_fetch(endpoint, function(data, err)
    if err or not data or not data.items then
      callback {}
      return
    end

    local plugins = {}
    for _, item in ipairs(data.items) do
      local owner, repo = item.full_name:match '([^/]+)/(.+)'
      if owner and repo then
        table.insert(plugins, {
          owner = owner,
          repo = repo,
          full_name = item.full_name,
          description = item.description or '',
          category = nil,
          source = 'github',
          stars = item.stargazers_count,
          updated_at = item.pushed_at,
          installed = false,
          installed_ref = nil,
          tags = nil,
        })
      end
    end
    callback(plugins)
  end)
end

--------------------------------------------------------------------------------
-- Domain: awesome-neovim Catalog
--------------------------------------------------------------------------------

-- Sections in the awesome-neovim README that are not plugin categories
local SKIP_SECTIONS = {
  ['Contents'] = true,
  ['Wishlist'] = true,
  ['Contributing'] = true,
  ['License'] = true,
}

--- Parse the awesome-neovim README.md into structured categories
--- @param content string Raw markdown content
--- @return ps.Category[]
local function parse_awesome_neovim(content)
  local categories = {}
  local current_category = nil

  for line in content:gmatch '[^\r\n]+' do
    -- Check for category header (## Something)
    local category_name = line:match '^##%s+(.+)$'
    if category_name and not SKIP_SECTIONS[category_name] and not category_name:match '^%[' then
      current_category = {
        name = category_name,
        slug = slugify(category_name),
        plugins = {},
        collapsed = false,
      }
      table.insert(categories, current_category)
    elseif current_category then
      -- Try to parse a plugin entry
      -- Pattern 1: - [owner/repo](url) - description
      local full_name, desc = line:match '%-%s*%[([%w%-_.]+/[%w%-_.]+)%]%([^)]+%)%s*%-%s*(.+)$'

      -- Pattern 2: - [repo](https://github.com/owner/repo) - description
      if not full_name then
        local _, url, desc2 =
          line:match '%-%s*%[([%w%-_.]+)%]%(https://github%.com/([^/]+/[^/)]+)[^)]*%)%s*%-%s*(.+)$'
        if url then
          full_name = url:gsub('%.git$', '')
          desc = desc2
        end
      end

      -- Pattern 3: - [owner/repo](url) description (no dash before description)
      if not full_name then
        full_name, desc = line:match '%-%s*%[([%w%-_.]+/[%w%-_.]+)%]%([^)]+%)%s+(.+)$'
      end

      if full_name then
        local owner, repo = full_name:match '([^/]+)/(.+)'
        if owner and repo then
          table.insert(current_category.plugins, {
            owner = owner,
            repo = repo,
            full_name = full_name,
            description = desc or '',
            category = current_category.name,
            source = 'awesome',
            stars = nil,
            updated_at = nil,
            installed = false,
            installed_ref = nil,
            tags = nil,
          })
        end
      end
    end
  end

  return categories
end

--- Fetch the awesome-neovim plugin catalog, using cache when available
--- @param callback fun(categories: ps.Category[])
local function fetch_awesome_neovim(callback)
  local cache_file = CACHE_PATH .. '/awesome-neovim.json'

  -- Try to use cached data if fresh
  if is_cache_fresh(cache_file, CACHE_TTL_SECONDS) then
    local cached = read_json_file(cache_file)
    if cached and cached.categories then
      -- Reset collapsed state to default
      for _, category in ipairs(cached.categories) do
        category.collapsed = false
      end
      callback(cached.categories)
      return
    end
  end

  -- Fetch fresh data
  vim.system({ 'curl', '-s', AWESOME_NEOVIM_URL }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 or not result.stdout then
        -- Fall back to stale cache
        local cached = read_json_file(cache_file)
        callback(cached and cached.categories or {})
        return
      end

      local categories = parse_awesome_neovim(result.stdout)

      -- Update cache
      write_json_file(cache_file, {
        fetched_at = os.time(),
        categories = categories,
      })

      callback(categories)
    end)
  end)
end

--------------------------------------------------------------------------------
-- Domain: Local Plugin Management
--------------------------------------------------------------------------------

--- Get a map of all installed plugin names
--- @return table<string, boolean>
local function get_installed_plugins()
  local installed = {}

  if vim.fn.isdirectory(STORE_PATH) == 0 then return installed end

  for name, entry_type in vim.fs.dir(STORE_PATH) do
    if entry_type == 'directory' then installed[name] = true end
  end

  return installed
end

--- Get the current git ref (tag or commit) for an installed plugin
--- @param repo_name string
--- @param callback fun(ref: string|nil)
local function get_installed_ref(repo_name, callback)
  local plugin_path = STORE_PATH .. '/' .. repo_name

  if vim.fn.isdirectory(plugin_path) == 0 then
    callback(nil)
    return
  end

  -- First, try to get an exact tag match
  vim.system(
    { 'git', '-C', plugin_path, 'describe', '--tags', '--exact-match' },
    { text = true },
    function(tag_result)
      vim.schedule(function()
        if tag_result.code == 0 and tag_result.stdout then
          callback(vim.trim(tag_result.stdout))
          return
        end

        -- Fall back to short commit hash
        vim.system(
          { 'git', '-C', plugin_path, 'rev-parse', '--short', 'HEAD' },
          { text = true },
          function(commit_result)
            vim.schedule(function()
              if commit_result.code == 0 and commit_result.stdout then
                callback(vim.trim(commit_result.stdout))
              else
                callback(nil)
              end
            end)
          end
        )
      end)
    end
  )
end

--- Install a plugin from GitHub
--- @param full_name string e.g., "nvim-telescope/telescope.nvim"
--- @param ref string|nil Tag or branch to checkout (nil = default branch)
--- @param callback fun(success: boolean, error_message: string|nil)
local function install_plugin(full_name, ref, callback)
  local repo = full_name:match '[^/]+/(.+)'
  if not repo then
    callback(false, 'Invalid plugin name')
    return
  end

  local destination = STORE_PATH .. '/' .. repo

  if vim.fn.isdirectory(destination) == 1 then
    callback(false, 'Already installed')
    return
  end

  ensure_directory_exists(STORE_PATH)

  local clone_url = 'https://github.com/' .. full_name .. '.git'
  local clone_cmd = { 'git', 'clone', '--depth', '1' }
  if ref then
    table.insert(clone_cmd, '--branch')
    table.insert(clone_cmd, ref)
  end
  table.insert(clone_cmd, clone_url)
  table.insert(clone_cmd, destination)

  vim.system(clone_cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(false, result.stderr or 'git clone failed')
        return
      end

      -- Generate helptags if the plugin has documentation
      local doc_path = destination .. '/doc'
      if vim.fn.isdirectory(doc_path) == 1 then pcall(vim.cmd.helptags, doc_path) end

      -- Load the plugin immediately
      pcall(vim.cmd.packadd, repo)

      callback(true, nil)
    end)
  end)
end

--- Update an installed plugin
--- @param repo_name string
--- @param ref string|nil Tag to checkout (nil = pull latest)
--- @param callback fun(success: boolean, error_message: string|nil)
local function update_plugin(repo_name, ref, callback)
  local plugin_path = STORE_PATH .. '/' .. repo_name

  if vim.fn.isdirectory(plugin_path) == 0 then
    callback(false, 'Not installed')
    return
  end

  -- Fetch the latest changes and tags
  vim.system(
    { 'git', '-C', plugin_path, 'fetch', '--tags', '--force' },
    { text = true },
    function(fetch_result)
      vim.schedule(function()
        if fetch_result.code ~= 0 then
          callback(false, 'git fetch failed')
          return
        end

        local update_cmd = ref and { 'git', '-C', plugin_path, 'checkout', ref }
          or { 'git', '-C', plugin_path, 'pull', '--ff-only' }

        vim.system(update_cmd, { text = true }, function(update_result)
          vim.schedule(function()
            if update_result.code ~= 0 then
              callback(false, update_result.stderr or 'git checkout/pull failed')
              return
            end

            -- Regenerate helptags
            local doc_path = plugin_path .. '/doc'
            if vim.fn.isdirectory(doc_path) == 1 then pcall(vim.cmd.helptags, doc_path) end

            callback(true, nil)
          end)
        end)
      end)
    end
  )
end

--- Remove an installed plugin
--- @param repo_name string
--- @param callback fun(success: boolean)
local function remove_plugin(repo_name, callback)
  local plugin_path = STORE_PATH .. '/' .. repo_name

  if vim.fn.isdirectory(plugin_path) == 0 then
    callback(false)
    return
  end

  vim.system({ 'rm', '-rf', plugin_path }, {}, function(result)
    vim.schedule(function() callback(result.code == 0) end)
  end)
end

--- Load all plugins installed via the Plugin Store (packadd each one)
local function load_all_plugins()
  if vim.fn.isdirectory(STORE_PATH) == 0 then return end

  for name, entry_type in vim.fs.dir(STORE_PATH) do
    if entry_type == 'directory' then pcall(vim.cmd.packadd, name) end
  end
end

--------------------------------------------------------------------------------
-- UI Helpers: Keymap Action Builder
--------------------------------------------------------------------------------

--- Create a keymap handler that schedules an action and returns empty string
--- This is the pattern used throughout morph for keymap handlers
--- @param action function
--- @return function
local function keymap_action(action)
  return function()
    vim.schedule(action)
    return ''
  end
end

--- Create a set of common keymaps for a plugin row (install, update, remove, open in browser)
--- @param plugin ps.Plugin
--- @param handlers { on_select: fun(p: ps.Plugin), on_install: fun(p: ps.Plugin), on_update: fun(p: ps.Plugin), on_remove: fun(p: ps.Plugin) }
--- @return table<string, function>
local function plugin_keymaps(plugin, handlers)
  return {
    ['<CR>'] = keymap_action(function() handlers.on_select(plugin) end),
    ['ga'] = keymap_action(function()
      if not plugin.installed then handlers.on_install(plugin) end
    end),
    ['gu'] = keymap_action(function()
      if plugin.installed then handlers.on_update(plugin) end
    end),
    ['gd'] = keymap_action(function()
      if plugin.installed then handlers.on_remove(plugin) end
    end),
    ['go'] = keymap_action(function() vim.ui.open('https://github.com/' .. plugin.full_name) end),
  }
end

--------------------------------------------------------------------------------
-- UI Components: Help Panel
--------------------------------------------------------------------------------

local HELP_KEYMAPS = {
  { '<CR>', 'View plugin details' },
  { 'ga', 'Add (install) plugin' },
  { 'gu', 'Update plugin' },
  { 'gd', 'Remove plugin' },
  { 'go', 'Open in browser' },
  { 'g1', 'Browse view' },
  { 'g2', 'Search view' },
  { 'g3', 'Installed view' },
  { '<C-o>', 'Go back' },
  { '<Leader>r', 'Refresh' },
  { 'g?', 'Toggle help' },
}

--- @param ctx morph.Ctx<{}>
local function PluginStoreHelp(ctx) return h(Help, { common_keymaps = HELP_KEYMAPS }) end

--------------------------------------------------------------------------------
-- UI Components: Navigation Tabs
--------------------------------------------------------------------------------

local NAV_TABS = {
  { key = 'g1', page = 'browse', label = 'Browse' },
  { key = 'g2', page = 'search', label = 'Search' },
  { key = 'g3', page = 'installed', label = 'Installed' },
}

--- Get the tab page that should be highlighted for a given page
--- @param page ps.Page
--- @return ps.Page
local function get_active_tab(page)
  -- 'detail' page should highlight 'browse' tab
  if page == 'detail' then return 'browse' end
  return page
end

--------------------------------------------------------------------------------
-- UI Components: Plugin Row (used in lists)
--------------------------------------------------------------------------------

--- @param ctx morph.Ctx<{ plugin: ps.Plugin, on_select: fun(p: ps.Plugin), on_install: fun(p: ps.Plugin), on_update: fun(p: ps.Plugin), on_remove: fun(p: ps.Plugin) }>
local function PluginRow(ctx)
  local plugin = ctx.props.plugin

  local installed_marker = plugin.installed and h.DiagnosticOk({}, '[*] ') or h.Comment({}, '[ ] ')

  local stars_display = plugin.stars
      and { '  ', h.Number({}, tostring(plugin.stars)), h.Comment({}, '*') }
    or nil

  local source_badge = plugin.source == 'github' and h.Comment({}, ' [G]') or nil

  return h('text', {
    nmap = plugin_keymaps(plugin, ctx.props),
  }, {
    installed_marker,
    h.String({}, plugin.full_name),
    stars_display,
    source_badge,
    '  ',
    h.Comment({}, truncate(plugin.description, 60)),
  })
end

--------------------------------------------------------------------------------
-- UI Views: Browse (main catalog view)
--------------------------------------------------------------------------------

--- @param ctx morph.Ctx<{ categories: ps.Category[], installed: table<string, boolean>, loading: boolean, on_select: fun(p: ps.Plugin), on_install: fun(p: ps.Plugin), on_update: fun(p: ps.Plugin), on_remove: fun(p: ps.Plugin), on_toggle_category: fun(slug: string) }, ps.BrowseState>
local function BrowseView(ctx)
  -- Initialize state on mount, or ensure defaults exist for re-renders
  if ctx.phase == 'mount' then
    ctx.state = { filter = '' }
  else
    ctx.state = ctx.state or {}
    ctx.state.filter = ctx.state.filter or ''
  end
  local state = ctx.state
  local filter_lower = state.filter:lower()

  -- Header
  local content = {
    h.RenderMarkdownH1({}, '# Plugin Store - Browse'),
    ctx.props.loading and h.NonText({}, ' (loading...)') or nil,
    '\n\n',

    -- Filter input
    h.Label({}, 'Filter: '),
    '[',
    h.String({
      on_change = function(event)
        state.filter = event.text
        ctx:update(state)
      end,
    }, state.filter),
    ']',
    state.filter == '' and h.Comment({}, ' type to filter') or nil,
    '\n\n',
  }

  -- Category list
  for _, category in ipairs(ctx.props.categories) do
    -- Filter plugins within category
    local visible_plugins = {}
    local matches_filter = utils.create_filter_fn(filter_lower)
    for _, plugin in ipairs(category.plugins) do
      plugin.installed = ctx.props.installed[plugin.repo] or false

      local passes = matches_filter(plugin.full_name)
        or (plugin.description and matches_filter(plugin.description))

      if passes then table.insert(visible_plugins, plugin) end
    end

    -- Show category if it has matching plugins or no filter is active
    if #visible_plugins > 0 or state.filter == '' then
      local collapse_icon = category.collapsed and '▶ ' or '▼ '

      -- Category header (clickable to toggle collapse)
      table.insert(
        content,
        h('text', {
          nmap = {
            ['<CR>'] = keymap_action(function() ctx.props.on_toggle_category(category.slug) end),
          },
        }, {
          h.Comment({}, collapse_icon .. ' '),
          h.RenderMarkdownH1({}, '## ' .. category.name),
          h.Comment({}, ' (' .. #category.plugins .. ')'),
        })
      )
      table.insert(content, '\n')

      -- Plugin rows (if not collapsed)
      if not category.collapsed then
        for _, plugin in ipairs(visible_plugins) do
          table.insert(
            content,
            h(PluginRow, {
              plugin = plugin,
              on_select = ctx.props.on_select,
              on_install = ctx.props.on_install,
              on_update = ctx.props.on_update,
              on_remove = ctx.props.on_remove,
            })
          )
          table.insert(content, '\n')
        end
      end
      table.insert(content, '\n')
    end
  end

  -- Empty state
  if #ctx.props.categories == 0 and not ctx.props.loading then
    table.insert(content, h.Comment({}, 'No plugins found. Press <Leader>r to refresh.'))
  end

  return content
end

--------------------------------------------------------------------------------
-- UI Views: Search
--------------------------------------------------------------------------------

--- @param ctx morph.Ctx<{ categories: ps.Category[], installed: table<string, boolean>, on_select: fun(p: ps.Plugin), on_install: fun(p: ps.Plugin), on_update: fun(p: ps.Plugin), on_remove: fun(p: ps.Plugin) }, ps.SearchState>
local function SearchView(ctx)
  -- Initialize state on mount, or ensure defaults exist for re-renders
  if ctx.phase == 'mount' then
    ctx.state = { query = '', results = {}, searching = false }
  else
    ctx.state = ctx.state or {}
    ctx.state.query = ctx.state.query or ''
    ctx.state.results = ctx.state.results or {}
    ctx.state.searching = ctx.state.searching or false
  end
  local state = ctx.state

  local function execute_search()
    if state.query == '' then
      state.results = {}
      ctx:update(state)
      return
    end

    state.searching = true
    ctx:update(state)

    local query_lower = state.query:lower()
    local results = {}
    local seen = {}

    -- First, search the local awesome-neovim catalog
    for _, category in ipairs(ctx.props.categories) do
      for _, plugin in ipairs(category.plugins) do
        local matches = plugin.full_name:lower():find(query_lower, 1, true)
          or (plugin.description and plugin.description:lower():find(query_lower, 1, true))

        if matches and not seen[plugin.full_name] then
          seen[plugin.full_name] = true
          local result = vim.tbl_extend('force', {}, plugin)
          result.installed = ctx.props.installed[plugin.repo] or false
          table.insert(results, result)
        end
      end
    end

    -- Then, augment with GitHub search results
    search_github_plugins(state.query, function(github_results)
      for _, plugin in ipairs(github_results) do
        if not seen[plugin.full_name] then
          seen[plugin.full_name] = true
          plugin.installed = ctx.props.installed[plugin.repo] or false
          table.insert(results, plugin)
        else
          -- Mark existing entries as 'both' sources and merge star counts
          for _, existing in ipairs(results) do
            if existing.full_name == plugin.full_name then
              existing.source = 'both'
              existing.stars = existing.stars or plugin.stars
              break
            end
          end
        end
      end

      -- Sort by star count descending
      table.sort(results, function(a, b) return (a.stars or 0) > (b.stars or 0) end)

      state.results = results
      state.searching = false
      ctx:update(state)
    end)
  end

  -- Header and search input
  local content = {
    h.RenderMarkdownH1({}, '# Plugin Store - Search'),
    '\n\n',
    h.Label({}, 'Search: '),
    '[',
    h.String({
      on_change = function(event) state.query = event.text end,
      nmap = {
        ['<CR>'] = keymap_action(execute_search),
      },
      imap = {
        ['<CR>'] = keymap_action(execute_search),
      },
    }, state.query),
    ']',
    h.Comment({}, ' (press Enter to search)'),
    '\n\n',
  }

  -- Results
  if state.searching then
    table.insert(content, h.Comment({}, 'Searching...'))
  elseif #state.results > 0 then
    table.insert(content, h.Comment({}, 'Found ' .. #state.results .. ' plugins:\n\n'))
    for _, plugin in ipairs(state.results) do
      table.insert(
        content,
        h(PluginRow, {
          plugin = plugin,
          on_select = ctx.props.on_select,
          on_install = ctx.props.on_install,
          on_update = ctx.props.on_update,
          on_remove = ctx.props.on_remove,
        })
      )
      table.insert(content, '\n')
    end
  elseif state.query ~= '' then
    table.insert(content, h.Comment({}, 'No results found.'))
  else
    table.insert(content, h.Comment({}, 'Enter a search query and press Enter.'))
  end

  return content
end

--------------------------------------------------------------------------------
-- UI Views: Installed Plugins
--------------------------------------------------------------------------------

--- @param ctx morph.Ctx<{ installed: table<string, boolean>, on_select: fun(p: ps.Plugin), on_update: fun(p: ps.Plugin), on_remove: fun(p: ps.Plugin) }, ps.InstalledState>
local function InstalledView(ctx)
  -- Build plugin list from installed plugins (on mount or if state is missing)
  local needs_init = ctx.phase == 'mount' or not ctx.state or not ctx.state.plugins

  if needs_init then
    local plugins = {}
    for repo_name in pairs(ctx.props.installed) do
      table.insert(plugins, {
        owner = '',
        repo = repo_name,
        full_name = repo_name, -- We don't know the owner without reading git remote
        description = '',
        category = nil,
        source = 'installed',
        stars = nil,
        updated_at = nil,
        installed = true,
        installed_ref = nil,
        tags = nil,
      })
    end
    table.sort(plugins, function(a, b) return a.repo < b.repo end)

    ctx.state = { plugins = plugins }

    -- Fetch git refs asynchronously
    for i, plugin in ipairs(plugins) do
      get_installed_ref(plugin.repo, function(ref)
        if ctx.state and ctx.state.plugins[i] then
          ctx.state.plugins[i].installed_ref = ref
          ctx:update(ctx.state)
        end
      end)
    end
  end

  local state = ctx.state

  local content = {
    h.RenderMarkdownH1({}, '# Plugin Store - Installed'),
    '\n\n',
  }

  if #state.plugins == 0 then
    table.insert(content, h.Comment({}, 'No plugins installed via Plugin Store.'))
    table.insert(content, '\n')
    table.insert(content, h.Comment({}, 'Install path: ' .. STORE_PATH))
    return content
  end

  table.insert(content, h.Comment({}, #state.plugins .. ' plugins installed:\n\n'))

  for _, plugin in ipairs(state.plugins) do
    table.insert(
      content,
      h('text', {
        nmap = {
          ['<CR>'] = keymap_action(function() ctx.props.on_select(plugin) end),
          ['gu'] = keymap_action(function() ctx.props.on_update(plugin) end),
          ['gd'] = keymap_action(function() ctx.props.on_remove(plugin) end),
          ['go'] = keymap_action(function()
            -- Fetch the remote URL from git
            local path = STORE_PATH .. '/' .. plugin.repo
            vim.system(
              { 'git', '-C', path, 'remote', 'get-url', 'origin' },
              { text = true },
              function(result)
                vim.schedule(function()
                  if result.code == 0 and result.stdout then
                    local url = vim.trim(result.stdout):gsub('%.git$', '')
                    vim.ui.open(url)
                  end
                end)
              end
            )
          end),
        },
      }, {
        h.DiagnosticOk({}, '[*] '),
        h.String({}, plugin.repo),
        plugin.installed_ref and { '  ', h.Comment({}, '@' .. plugin.installed_ref) } or nil,
      })
    )
    table.insert(content, '\n')
  end

  return content
end

--------------------------------------------------------------------------------
-- UI Views: Plugin Detail
--------------------------------------------------------------------------------

--- @param ctx morph.Ctx<{ plugin: ps.Plugin, installed: table<string, boolean>, on_install: fun(p: ps.Plugin), on_update: fun(p: ps.Plugin), on_remove: fun(p: ps.Plugin), on_back: fun() }, ps.DetailState>
local function PluginDetail(ctx)
  local plugin = ctx.props.plugin
  local is_installed = ctx.props.installed[plugin.repo] or false

  -- Initialize state on mount, or ensure defaults exist for re-renders
  if ctx.phase == 'mount' then
    ctx.state = { metadata = nil, tags = {}, loading = true }

    -- Fetch metadata if we have a full name
    if plugin.full_name:find '/' then
      fetch_repo_metadata(plugin.full_name, function(meta)
        if ctx.state then
          ctx.state.metadata = meta
          ctx.state.loading = false
          ctx:update(ctx.state)
        end
      end)

      fetch_repo_tags(plugin.full_name, function(tags)
        if ctx.state then
          ctx.state.tags = tags
          ctx:update(ctx.state)
        end
      end)
    else
      ctx.state.loading = false
    end

    -- Get current installed ref
    get_installed_ref(plugin.repo, function(ref)
      if ctx.state then
        plugin.installed_ref = ref
        ctx:update(ctx.state)
      end
    end)
  else
    -- Ensure defaults exist for re-renders
    ctx.state = ctx.state or {}
    ctx.state.tags = ctx.state.tags or {}
    ctx.state.loading = ctx.state.loading == nil and false or ctx.state.loading
  end

  local state = ctx.state
  local meta = state.metadata

  -- Build the detail view content
  local content = {
    h.Comment({}, '<C-o> to go back'),
    '\n\n',
    h.RenderMarkdownH1({}, '# ' .. plugin.full_name),
    '\n\n',
  }

  -- Status row
  table.insert(content, h.Comment({}, 'Status:    '))
  if is_installed then
    table.insert(content, h.DiagnosticOk({}, 'Installed'))
    if plugin.installed_ref then
      table.insert(content, h.Comment({}, ' @' .. plugin.installed_ref))
    end
  else
    table.insert(content, h.Comment({}, 'Not installed'))
  end
  table.insert(content, '\n')

  -- Source row
  table.insert(content, h.Comment({}, 'Source:    '))
  local source_labels = {
    awesome = 'awesome-neovim',
    github = 'GitHub search',
    both = 'awesome-neovim + GitHub',
  }
  table.insert(content, h.String({}, source_labels[plugin.source] or 'Local'))
  table.insert(content, '\n')

  -- Category row (if available)
  if plugin.category then
    table.insert(content, h.Comment({}, 'Category:  '))
    table.insert(content, h.String({}, plugin.category))
    table.insert(content, '\n')
  end

  -- Metadata from GitHub API
  if state.loading then
    table.insert(content, '\n')
    table.insert(content, h.Comment({}, 'Loading metadata...'))
  elseif meta then
    local metadata_fields = {
      { label = 'Stars:     ', value = meta.stars, type = 'Number' },
      { label = 'Forks:     ', value = meta.forks, type = 'Number' },
      { label = 'License:   ', value = meta.license, type = 'String' },
      {
        label = 'Updated:   ',
        value = meta.updated_at and format_relative_time(meta.updated_at),
        type = 'Normal',
      },
    }

    for _, field in ipairs(metadata_fields) do
      if field.value then
        table.insert(content, h.Comment({}, field.label))
        table.insert(content, h[field.type]({}, tostring(field.value)))
        table.insert(content, '\n')
      end
    end
  end

  -- Description section
  local description = (meta and meta.description) or plugin.description
  if description and description ~= '' then
    table.insert(content, '\n')
    table.insert(content, h.RenderMarkdownH1({}, '## Description'))
    table.insert(content, '\n')
    table.insert(content, h.Normal({}, description))
    table.insert(content, '\n')
  end

  -- Tags section
  if #state.tags > 0 then
    table.insert(content, '\n')
    table.insert(content, h.RenderMarkdownH1({}, '## Available Tags'))
    table.insert(content, '\n')

    local max_tags_to_show = 10
    for i, tag in ipairs(state.tags) do
      if i <= max_tags_to_show then
        table.insert(content, h.Comment({}, '  - '))
        table.insert(content, h.String({}, tag))
        table.insert(content, '\n')
      end
    end

    if #state.tags > max_tags_to_show then
      table.insert(
        content,
        h.Comment({}, '  ... and ' .. (#state.tags - max_tags_to_show) .. ' more')
      )
      table.insert(content, '\n')
    end
  end

  -- Actions section
  table.insert(content, '\n')
  table.insert(content, h.RenderMarkdownH1({}, '## Actions'))
  table.insert(content, '\n')

  if not is_installed then
    table.insert(
      content,
      h('text', {
        nmap = { ['<CR>'] = keymap_action(function() ctx.props.on_install(plugin) end) },
      }, { h.Title({}, '[gi] Install') })
    )
  else
    table.insert(
      content,
      h('text', {
        nmap = { ['<CR>'] = keymap_action(function() ctx.props.on_update(plugin) end) },
      }, { h.Title({}, '[gu] Update') })
    )
    table.insert(content, '  ')
    table.insert(
      content,
      h('text', {
        nmap = { ['<CR>'] = keymap_action(function() ctx.props.on_remove(plugin) end) },
      }, { h.DiagnosticError({}, '[gd] Remove') })
    )
  end

  table.insert(content, '  ')
  table.insert(
    content,
    h('text', {
      nmap = {
        ['<CR>'] = keymap_action(
          function() vim.ui.open('https://github.com/' .. plugin.full_name) end
        ),
      },
    }, { h.Comment({}, '[go] Open in Browser') })
  )
  table.insert(content, '\n')

  -- Wrap content with global keymaps for this view
  return h('text', {
    nmap = {
      ['gi'] = keymap_action(function()
        if not is_installed then ctx.props.on_install(plugin) end
      end),
      ['gu'] = keymap_action(function()
        if is_installed then ctx.props.on_update(plugin) end
      end),
      ['gd'] = keymap_action(function()
        if is_installed then ctx.props.on_remove(plugin) end
      end),
      ['go'] = keymap_action(function() vim.ui.open('https://github.com/' .. plugin.full_name) end),
      ['<C-o>'] = keymap_action(ctx.props.on_back),
    },
  }, content)
end

--------------------------------------------------------------------------------
-- UI: Main Application Shell
--------------------------------------------------------------------------------

--- @class ps.AppState
--- @field page ps.Page
--- @field page_history ps.Page[]
--- @field categories ps.Category[]
--- @field installed table<string, boolean>
--- @field selected_plugin ps.Plugin|nil
--- @field show_help boolean
--- @field loading boolean
--- @field status_msg string|nil

--- @param ctx morph.Ctx<any, ps.AppState>
local function App(ctx)
  --
  -- Action handlers (defined before mount so they're available to the UI)
  --

  local function refresh()
    local state = assert(ctx.state)
    state.loading = true
    state.status_msg = 'Loading...'
    ctx:update(state)

    state.installed = get_installed_plugins()

    fetch_awesome_neovim(function(categories)
      state.categories = categories
      state.loading = false
      state.status_msg = nil
      ctx:update(state)
    end)
  end

  local function navigate_to(page)
    local state = assert(ctx.state)
    if state.page ~= page then table.insert(state.page_history, state.page) end
    state.page = page
    ctx:update(state)
    vim.fn.winrestview { topline = 1, lnum = 1 }
  end

  local function navigate_back()
    local state = assert(ctx.state)
    if #state.page_history > 0 then
      state.page = table.remove(state.page_history)
      ctx:update(state)
      vim.fn.winrestview { topline = 1, lnum = 1 }
    end
  end

  local function install(plugin)
    local state = assert(ctx.state)
    state.status_msg = 'Installing ' .. plugin.full_name .. '...'
    ctx:update(state)

    fetch_repo_tags(plugin.full_name, function(tags)
      local ref = tags[1] -- Use latest tag, or nil for HEAD
      install_plugin(plugin.full_name, ref, function(success, err)
        if success then
          state.status_msg = 'Installed ' .. plugin.full_name .. (ref and ' @' .. ref or '')
          state.installed = get_installed_plugins()
          vim.notify('Installed ' .. plugin.full_name, vim.log.levels.INFO)
        else
          state.status_msg = 'Failed: ' .. (err or 'unknown error')
          vim.notify('Install failed: ' .. (err or 'unknown'), vim.log.levels.ERROR)
        end
        ctx:update(state)
      end)
    end)
  end

  local function update(plugin)
    local state = assert(ctx.state)
    state.status_msg = 'Updating ' .. plugin.repo .. '...'
    ctx:update(state)

    update_plugin(plugin.repo, nil, function(success, err)
      if success then
        state.status_msg = 'Updated ' .. plugin.repo
        vim.notify('Updated ' .. plugin.repo, vim.log.levels.INFO)
      else
        state.status_msg = 'Failed: ' .. (err or 'unknown error')
        vim.notify('Update failed: ' .. (err or 'unknown'), vim.log.levels.ERROR)
      end
      ctx:update(state)
    end)
  end

  local function remove(plugin)
    local state = assert(ctx.state)

    local choice = vim.fn.confirm('Remove ' .. plugin.repo .. '?', '&Yes\n&No', 2)
    if choice ~= 1 then return end

    state.status_msg = 'Removing ' .. plugin.repo .. '...'
    ctx:update(state)

    remove_plugin(plugin.repo, function(success)
      if success then
        state.status_msg = 'Removed ' .. plugin.repo
        state.installed = get_installed_plugins()
        vim.notify('Removed ' .. plugin.repo, vim.log.levels.INFO)
        if state.page == 'detail' then navigate_back() end
      else
        state.status_msg = 'Failed to remove ' .. plugin.repo
        vim.notify('Remove failed', vim.log.levels.ERROR)
      end
      ctx:update(state)
    end)
  end

  local function toggle_category(slug)
    local state = assert(ctx.state)
    for _, category in ipairs(state.categories) do
      if category.slug == slug then
        category.collapsed = not category.collapsed
        break
      end
    end
    ctx:update(state)
  end

  --
  -- Initialization
  --

  if ctx.phase == 'mount' then
    ctx.state = {
      page = 'browse',
      page_history = {},
      categories = {},
      installed = get_installed_plugins(),
      selected_plugin = nil,
      show_help = false,
      loading = true,
      status_msg = 'Loading awesome-neovim...',
    }
    vim.schedule(refresh)
  end

  local state = assert(ctx.state)

  --
  -- Page content routing
  --

  local function select_plugin(plugin)
    state.selected_plugin = plugin
    navigate_to 'detail'
  end

  local page_content

  if state.page == 'browse' then
    page_content = h(BrowseView, {
      categories = state.categories,
      installed = state.installed,
      loading = state.loading,
      on_select = select_plugin,
      on_install = install,
      on_update = update,
      on_remove = remove,
      on_toggle_category = toggle_category,
    })
  elseif state.page == 'search' then
    page_content = h(SearchView, {
      categories = state.categories,
      installed = state.installed,
      on_select = select_plugin,
      on_install = install,
      on_update = update,
      on_remove = remove,
    })
  elseif state.page == 'installed' then
    page_content = h(InstalledView, {
      installed = state.installed,
      on_select = select_plugin,
      on_update = update,
      on_remove = remove,
    })
  elseif state.page == 'detail' and state.selected_plugin then
    page_content = h(PluginDetail, {
      plugin = state.selected_plugin,
      installed = state.installed,
      on_install = install,
      on_update = update,
      on_remove = remove,
      on_back = navigate_back,
    })
  end

  --
  -- Render the application shell
  --

  return h('text', {
    nmap = {
      ['<Leader>r'] = keymap_action(refresh),
      ['g?'] = function()
        state.show_help = not state.show_help
        ctx:update(state)
        return ''
      end,
      ['<C-o>'] = keymap_action(navigate_back),
      ['g1'] = keymap_action(function() navigate_to 'browse' end),
      ['g2'] = keymap_action(function() navigate_to 'search' end),
      ['g3'] = keymap_action(function() navigate_to 'installed' end),
    },
  }, {
    -- Status bar
    h.RenderMarkdownH1({}, 'Plugin Store'),
    ' ',
    has_gh_cli() and h.DiagnosticOk({}, 'gh') or h.DiagnosticWarn({}, 'curl'),
    ' ',
    h.NonText({}, 'g? for help'),
    state.status_msg and { ' | ', h.String({}, state.status_msg) } or nil,
    '\n\n',

    -- Navigation tabs
    h(
      TabBar,
      { tabs = NAV_TABS, active_page = get_active_tab(state.page), on_select = navigate_to }
    ),

    -- Help panel (toggleable)
    state.show_help and { h(PluginStoreHelp, {}), '\n' },

    -- Current page content
    page_content,
  })
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

local M = {}

--- Load all plugins installed via the Plugin Store (packadd each one)
M.load_all = load_all_plugins

--- Path where plugins are installed
M.path = STORE_PATH

--- Check if a plugin is installed
--- @param name string Plugin name (repo name, not owner/repo)
--- @return boolean
function M.is_installed(name) return vim.fn.isdirectory(STORE_PATH .. '/' .. name) == 1 end

--------------------------------------------------------------------------------
-- Bootstrap: Open a new tab and mount UI
--------------------------------------------------------------------------------

function M.show()
  vim.cmd.tabnew()
  vim.bo.buftype = 'nofile'
  vim.bo.bufhidden = 'wipe'
  vim.b.completion = false
  vim.wo[0][0].list = false
  vim.api.nvim_buf_set_name(0, 'Plugin Store')

  Morph.new(0):mount(h(App))
end

return M
