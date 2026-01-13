local Morph = require 'tuis.morph'
local h = Morph.h
local components = require 'tuis.components'
local Table = components.Table
local TabBar = components.TabBar
local Help = components.Help
local term = require 'tuis.term'
local utils = require 'tuis.utils'
local keymap = utils.keymap

local M = {}

--- @type string[]
local CLI_DEPENDENCIES = { 'gh' }

function M.is_enabled() return utils.check_clis_available(CLI_DEPENDENCIES, true) end

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

--- @alias gh.Page 'repos'|'issues'|'prs'|'runs'|'pr_detail'|'issue_detail'|'run_detail'

--- @class gh.Comment
--- @field author string
--- @field body string
--- @field created_at string

--------------------------------------------------------------------------------
-- Utilities
--------------------------------------------------------------------------------

--- Safely get a table value (handles vim.NIL from JSON null)
--- @param v any
--- @return table
local function tbl(v)
  if type(v) == 'table' then return v end
  return {}
end

--- Parse relative time from ISO date
--- @param iso_date string
--- @return string
local function relative_time(iso_date)
  if type(iso_date) ~= 'string' or iso_date == '' then return '' end
  local result = vim
    .system({ 'date', '-j', '-f', '%Y-%m-%dT%H:%M:%SZ', iso_date, '+%s' }, { text = true })
    :wait()
  if result.code ~= 0 then return iso_date:sub(1, 10) end
  local timestamp = tonumber(vim.trim(result.stdout or ''))
  if not timestamp then return iso_date:sub(1, 10) end
  local diff = os.time() - timestamp
  if diff < 0 then return 'just now' end
  if diff < 60 then return 'just now' end
  if diff < 3600 then return math.floor(diff / 60) .. 'm ago' end
  if diff < 86400 then return math.floor(diff / 3600) .. 'h ago' end
  if diff < 604800 then return math.floor(diff / 86400) .. 'd ago' end
  if diff < 2592000 then return math.floor(diff / 604800) .. 'w ago' end
  if diff < 31536000 then return math.floor(diff / 2592000) .. 'mo ago' end
  return math.floor(diff / 31536000) .. 'y ago'
end

--- Status icons
local STATUS_ICONS = {
  success = '✓',
  failure = '✗',
  pending = '○',
  cancelled = '⊘',
  -- GitHub-specific
  APPROVED = '✓',
  CHANGES_REQUESTED = '✗',
  PENDING = '○',
  OPEN = '○',
  CLOSED = '●',
  MERGED = '●',
}

--- Get highlight for status/conclusion values
--- @param value string
--- @param success_values? string[]
--- @param error_values? string[]
--- @return function
local function status_hl(value, success_values, error_values)
  success_values = success_values or { 'success', 'SUCCESS', 'APPROVED' }
  error_values = error_values
    or { 'failure', 'FAILURE', 'CANCELLED', 'CLOSED', 'CHANGES_REQUESTED' }
  if vim.tbl_contains(success_values, value) then return h.DiagnosticOk end
  if vim.tbl_contains(error_values, value) then return h.DiagnosticError end
  return h.DiagnosticWarn
end

--- Get status icon
--- @param value string
--- @return string
local function status_icon(value) return STATUS_ICONS[value] or STATUS_ICONS[value:lower()] or '○' end

--- Get status with icon and highlight
--- @param value string
--- @param success_values? string[]
--- @param error_values? string[]
--- @return morph.Tree
local function status_with_icon(value, success_values, error_values)
  local hl_fn = status_hl(value, success_values, error_values)
  local icon = status_icon(value)
  return hl_fn({}, icon .. ' ' .. value)
end

--- Truncate string with ellipsis
--- @param s string
--- @param max number
--- @return string
local function truncate(s, max)
  if #s <= max then return s end
  return s:sub(1, max) .. '...'
end

--- Clean up markdown/text for display (remove control chars, normalize whitespace)
--- @param s string
--- @return string
local function clean_text(s)
  if type(s) ~= 'string' then return '' end
  -- Remove carriage returns
  s = s:gsub('\r', '')
  -- Collapse multiple newlines into max 2
  s = s:gsub('\n\n\n+', '\n\n')
  -- Trim leading/trailing whitespace
  s = vim.trim(s)
  return s
end

--- Format body text for display (clean + truncate)
--- @param s string
--- @param max_len number
--- @return string
local function format_body(s, max_len)
  local cleaned = clean_text(s)
  return truncate(cleaned, max_len)
end

--- Open URL in browser (cross-platform via gh)
--- @param url string
local function open_url(url)
  vim.schedule(function() vim.ui.open(url) end)
end

--- Yank to clipboard with notification
--- @param value string
--- @param msg string
local function yank(value, msg)
  vim.fn.setreg('+', value)
  vim.notify(msg)
end

--------------------------------------------------------------------------------
-- Data Fetching (Generic Helper)
--------------------------------------------------------------------------------

--- Generic gh CLI fetch helper
--- @generic T
--- @param cmd string[]
--- @param transform fun(data: any): T
--- @param callback fun(result: T)
--- @param default? T
local function gh_fetch(cmd, transform, callback, default)
  vim.system(cmd, { text = true }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then return callback(default) end
      local ok, data = pcall(vim.json.decode, out.stdout or '{}')
      if not ok then return callback(default) end
      callback(transform(data))
    end)
  end)
end

--- Extract labels array from gh response
--- @param items any[]
--- @return string[]
local function extract_labels(items)
  return vim.tbl_map(function(l) return l.name or '' end, items or {})
end

--- Extract comments array from gh response
--- @param items any[]
--- @return gh.Comment[]
local function extract_comments(items)
  return vim.tbl_map(
    function(c)
      return {
        author = tbl(c.author).login or '',
        body = c.body or '',
        created_at = c.createdAt or '',
      }
    end,
    items or {}
  )
end

--- Compute checks status from statusCheckRollup
--- @param checks any[]
--- @return string
local function compute_checks_status(checks)
  if #checks == 0 then return 'none' end
  local all_success, any_failure = true, false
  for _, c in ipairs(checks) do
    if c.conclusion == 'FAILURE' or c.conclusion == 'CANCELLED' then
      any_failure, all_success = true, false
    elseif c.conclusion ~= 'SUCCESS' and c.conclusion ~= 'SKIPPED' then
      all_success = false
    end
  end
  if any_failure then return 'failure' end
  if all_success then return 'success' end
  return 'pending'
end

local function get_current_repo()
  local r = vim
    .system({ 'gh', 'repo', 'view', '--json', 'nameWithOwner', '-q', '.nameWithOwner' }, { text = true })
    :wait()
  return r.code == 0 and vim.trim(r.stdout or '') or nil
end

local function get_current_user()
  local r = vim.system({ 'gh', 'api', 'user', '-q', '.login' }, { text = true }):wait()
  return r.code == 0 and vim.trim(r.stdout or '') or 'unknown'
end

--- Fetch user's organizations
--- @param callback fun(orgs: string[])
local function fetch_user_orgs(callback)
  vim.system({ 'gh', 'api', 'user/orgs', '--jq', '.[].login' }, { text = true }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then return callback {} end
      local orgs = {}
      for org in (out.stdout or ''):gmatch '[^\n]+' do
        table.insert(orgs, org)
      end
      callback(orgs)
    end)
  end)
end

--------------------------------------------------------------------------------
-- Fetch Functions (Using gh_fetch helper)
--------------------------------------------------------------------------------

--- Fetch repos for a specific owner (user or org)
--- @param owner string|nil Owner login name, or nil for authenticated user's repos
--- @param callback fun(repos: table[])
local function fetch_repos(owner, callback)
  local cmd = {
    'gh',
    'repo',
    'list',
  }
  if owner then table.insert(cmd, owner) end
  vim.list_extend(cmd, {
    '--json',
    'name,nameWithOwner,description,visibility,updatedAt,primaryLanguage,stargazerCount,forkCount,isFork',
    '--limit',
    '50',
  })

  gh_fetch(cmd, function(data)
    return vim.tbl_map(
      function(r)
        return {
          name = r.name or '',
          full_name = r.nameWithOwner or '',
          description = r.description or '',
          visibility = r.visibility or 'public',
          updated_at = r.updatedAt or '',
          language = tbl(r.primaryLanguage).name or '',
          stars = r.stargazerCount or 0,
          forks = r.forkCount or 0,
          is_fork = r.isFork or false,
        }
      end,
      data or {}
    )
  end, callback, {})
end

--- @class RepoFetchStatus
--- @field total number Total number of sources (user + orgs)
--- @field completed number Number of completed fetches
--- @field repos table[] All repos fetched so far

--- Fetch repos from all sources (user + orgs) with progressive loading
--- @param on_progress fun(status: RepoFetchStatus) Called after each source completes
--- @param on_complete fun(status: RepoFetchStatus) Called when all sources complete
--- @param existing_repos? table[] Existing repos to merge into (for non-disruptive refresh)
local function fetch_all_repos(on_progress, on_complete, existing_repos)
  -- Build index of existing repos by full_name for deduplication
  local seen = {}
  for _, repo in ipairs(existing_repos or {}) do
    seen[repo.full_name] = true
  end

  local status = { total = 1, completed = 0, repos = vim.deepcopy(existing_repos or {}) }

  local function merge_repos(new_repos)
    for _, repo in ipairs(new_repos) do
      if not seen[repo.full_name] then
        seen[repo.full_name] = true
        table.insert(status.repos, repo)
      else
        -- Update existing repo in place (may have new data)
        for i, existing in ipairs(status.repos) do
          if existing.full_name == repo.full_name then
            status.repos[i] = repo
            break
          end
        end
      end
    end
    -- Sort by updated_at descending (most recent first)
    table.sort(status.repos, function(a, b) return a.updated_at > b.updated_at end)
  end

  local function on_batch_complete(repos)
    status.completed = status.completed + 1
    merge_repos(repos)
    on_progress(status)
    if status.completed >= status.total then on_complete(status) end
  end

  -- Start fetching user's personal repos immediately
  fetch_repos(nil, on_batch_complete)

  -- Fetch org list, then fetch repos from each org
  fetch_user_orgs(function(orgs)
    status.total = status.total + #orgs
    -- If user has no orgs and personal repos already loaded, we're done
    if #orgs == 0 and status.completed >= status.total then
      on_complete(status)
      return
    end
    -- Update progress to show new total
    on_progress(status)
    -- Fire off parallel fetches for each org
    for _, org in ipairs(orgs) do
      fetch_repos(org, on_batch_complete)
    end
  end)
end

local function fetch_issues(repo, callback)
  gh_fetch({
    'gh',
    'issue',
    'list',
    '--repo',
    repo,
    '--json',
    'number,title,state,author,labels,createdAt,updatedAt,comments,url',
    '--limit',
    '50',
  }, function(data)
    return vim.tbl_map(
      function(i)
        return {
          number = i.number or 0,
          title = i.title or '',
          state = i.state or '',
          author = tbl(i.author).login or '',
          labels = extract_labels(i.labels),
          created_at = i.createdAt or '',
          updated_at = i.updatedAt or '',
          comments = #(i.comments or {}),
          url = i.url or '',
        }
      end,
      data or {}
    )
  end, callback, {})
end

local function fetch_prs(repo, callback)
  gh_fetch({
    'gh',
    'pr',
    'list',
    '--repo',
    repo,
    '--json',
    'number,title,state,author,headRefName,baseRefName,createdAt,updatedAt,reviewDecision,statusCheckRollup,mergeable,additions,deletions,url',
    '--limit',
    '50',
  }, function(data)
    return vim.tbl_map(
      function(p)
        return {
          number = p.number or 0,
          title = p.title or '',
          state = p.state or '',
          author = tbl(p.author).login or '',
          head = p.headRefName or '',
          base = p.baseRefName or '',
          created_at = p.createdAt or '',
          updated_at = p.updatedAt or '',
          reviews_status = p.reviewDecision or 'PENDING',
          checks_status = compute_checks_status(p.statusCheckRollup or {}),
          mergeable = p.mergeable or 'UNKNOWN',
          additions = p.additions or 0,
          deletions = p.deletions or 0,
          url = p.url or '',
        }
      end,
      data or {}
    )
  end, callback, {})
end

local function fetch_runs(repo, callback)
  gh_fetch({
    'gh',
    'run',
    'list',
    '--repo',
    repo,
    '--json',
    'databaseId,displayTitle,status,conclusion,event,headBranch,createdAt,url',
    '--limit',
    '30',
  }, function(data)
    return vim.tbl_map(
      function(r)
        return {
          id = r.databaseId or 0,
          name = r.displayTitle or '',
          status = r.status or '',
          conclusion = r.conclusion or '',
          event = r.event or '',
          branch = r.headBranch or '',
          created_at = r.createdAt or '',
          url = r.url or '',
        }
      end,
      data or {}
    )
  end, callback, {})
end

local function fetch_pr_detail(repo, pr_number, callback)
  gh_fetch({
    'gh',
    'pr',
    'view',
    tostring(pr_number),
    '--repo',
    repo,
    '--json',
    'number,title,body,state,author,headRefName,baseRefName,createdAt,updatedAt,mergedAt,mergedBy,reviews,statusCheckRollup,comments,additions,deletions,changedFiles,commits,url',
  }, function(p)
    return {
      number = p.number or 0,
      title = p.title or '',
      body = p.body or '',
      state = p.state or '',
      author = tbl(p.author).login or '',
      head = p.headRefName or '',
      base = p.baseRefName or '',
      created_at = p.createdAt or '',
      updated_at = p.updatedAt or '',
      merged_at = p.mergedAt,
      merged_by = tbl(p.mergedBy).login,
      reviews = vim.tbl_map(
        function(r)
          return {
            author = tbl(r.author).login or '',
            state = r.state or '',
            submitted_at = r.submittedAt or '',
          }
        end,
        p.reviews or {}
      ),
      checks = vim.tbl_map(
        function(c)
          return {
            name = c.name or c.context or '',
            status = c.status or '',
            conclusion = c.conclusion or '',
          }
        end,
        p.statusCheckRollup or {}
      ),
      comments = extract_comments(p.comments),
      additions = p.additions or 0,
      deletions = p.deletions or 0,
      changed_files = p.changedFiles or 0,
      commits = p.commits or 0,
      url = p.url or '',
    }
  end, callback, nil)
end

local function fetch_issue_detail(repo, issue_number, callback)
  gh_fetch({
    'gh',
    'issue',
    'view',
    tostring(issue_number),
    '--repo',
    repo,
    '--json',
    'number,title,body,state,author,labels,assignees,createdAt,updatedAt,closedAt,comments,url',
  }, function(i)
    return {
      number = i.number or 0,
      title = i.title or '',
      body = i.body or '',
      state = i.state or '',
      author = tbl(i.author).login or '',
      labels = extract_labels(i.labels),
      assignees = vim.tbl_map(function(a) return a.login or '' end, i.assignees or {}),
      created_at = i.createdAt or '',
      updated_at = i.updatedAt or '',
      closed_at = i.closedAt,
      comments = extract_comments(i.comments),
      url = i.url or '',
    }
  end, callback, nil)
end

local function fetch_run_detail(repo, run_id, callback)
  gh_fetch({
    'gh',
    'run',
    'view',
    tostring(run_id),
    '--repo',
    repo,
    '--json',
    'databaseId,displayTitle,status,conclusion,event,headBranch,createdAt,updatedAt,jobs,url',
  }, function(r)
    return {
      id = r.databaseId or 0,
      name = r.displayTitle or '',
      status = r.status or '',
      conclusion = r.conclusion or '',
      event = r.event or '',
      branch = r.headBranch or '',
      created_at = r.createdAt or '',
      updated_at = r.updatedAt or '',
      jobs = vim.tbl_map(
        function(j)
          return {
            id = j.databaseId or 0,
            name = j.name or '',
            status = j.status or '',
            conclusion = j.conclusion or '',
            started_at = j.startedAt or '',
            completed_at = j.completedAt or '',
          }
        end,
        r.jobs or {}
      ),
      url = r.url or '',
    }
  end, callback, nil)
end

--------------------------------------------------------------------------------
-- Shared Components
--------------------------------------------------------------------------------

--- Collapsible comments section (shared by PRDetail and IssueDetail)
--- @param comments gh.Comment[]
--- @param show boolean
--- @param on_toggle fun()
local function CommentsSection(comments, show, on_toggle)
  if #comments == 0 then return nil end

  local comment_items = {}
  for i, c in ipairs(comments) do
    local body = format_body(c.body, 300)
    table.insert(comment_items, {
      -- Separator line between comments (except first)
      i > 1
          and {
            h.Comment(
              {},
              '────────────────────────────────────────'
            ),
            '\n',
          }
        or nil,
      -- Author and timestamp on same line
      h.Constant({}, c.author),
      h.Comment({}, ' · ' .. relative_time(c.created_at)),
      '\n',
      -- Comment body (indented slightly for visual grouping)
      h.Normal({}, body),
      '\n',
    })
  end

  return {
    '\n',
    h('text', {
      nmap = {
        ['<CR>'] = function()
          on_toggle()
          return ''
        end,
      },
    }, {
      show and '▼ ' or '▶ ',
      h.RenderMarkdownH1({}, '## Comments (' .. #comments .. ')'),
    }),
    '\n\n',
    show and comment_items or nil,
  }
end

--- Description/body section
--- @param body string
--- @param max_len? number
local function BodySection(body, max_len)
  if body == '' or not body then return nil end
  local formatted = format_body(body, max_len or 500)
  if formatted == '' then return nil end
  return {
    '\n',
    h.RenderMarkdownH1({}, '## Description'),
    '\n',
    h.Normal({}, formatted),
    '\n',
  }
end

local HELP_KEYMAPS = {
  { '<CR>', 'Open/View details' },
  { '<C-o>', 'Go back' },
  { 'g1-g4', 'Navigate tabs' },
  { 'gw', 'Open in browser' },
  { 'gc', 'Checkout PR' },
  { 'gm', 'Merge PR' },
  { 'ga', 'Approve PR' },
  { 'gd', 'Show PR diff' },
  { 'gr', 'Rerun workflow' },
  { 'gl', 'View logs' },
  { 'g+', 'Yank URL to +' },
  { 'g"', 'Yank URL to "' },
  { 'g#', 'Yank number' },
  { '<Leader>r', 'Refresh' },
  { 'g?', 'Toggle help' },
}

--- Help component
--- @param ctx morph.Ctx<{}>
--- @return morph.Tree[]
local function GithubHelp(ctx) return h(Help, { common_keymaps = HELP_KEYMAPS }) end

--- Breadcrumb component for detail views
--- @param ctx morph.Ctx<{ page: gh.Page, repo: string|nil, selected_pr: number|nil, selected_issue: number|nil, selected_run: number|nil, on_back: fun() }>
--- @return morph.Tree[]|nil
local function Breadcrumb(ctx)
  local page = ctx.props.page
  local repo = ctx.props.repo
  local selected_pr = ctx.props.selected_pr
  local selected_issue = ctx.props.selected_issue
  local selected_run = ctx.props.selected_run

  -- Only show breadcrumb for detail views
  if page ~= 'pr_detail' and page ~= 'issue_detail' and page ~= 'run_detail' then return nil end

  local parts = {}

  -- Repo part (clickable to go back to list)
  if repo then
    table.insert(
      parts,
      h('text', {
        nmap = {
          ['<CR>'] = function()
            vim.schedule(function() ctx.props.on_back() end)
            return ''
          end,
        },
      }, { h.Comment({}, repo) })
    )
    table.insert(parts, h.Comment({}, ' > '))
  end

  -- Current detail item
  if page == 'pr_detail' and selected_pr then
    table.insert(parts, h.String({}, 'PR #' .. selected_pr))
  elseif page == 'issue_detail' and selected_issue then
    table.insert(parts, h.String({}, 'Issue #' .. selected_issue))
  elseif page == 'run_detail' and selected_run then
    table.insert(parts, h.String({}, 'Run #' .. selected_run))
  end

  table.insert(parts, h.Comment({}, '  (<C-o> to go back)'))

  return { parts, '\n\n' }
end

--- Navigation tabs
--- @type { key: string, page: gh.Page, label: string }[]
local TABS = {
  { key = 'g1', page = 'repos', label = 'Repos' },
  { key = 'g2', page = 'issues', label = 'Issues' },
  { key = 'g3', page = 'prs', label = 'PRs' },
  { key = 'g4', page = 'runs', label = 'Runs' },
}

--- Get the tab page that should be highlighted for a given page
--- @param page gh.Page
--- @return gh.Page
local function get_active_tab(page)
  for _, tab in ipairs(TABS) do
    -- Direct match or page contains the tab prefix (e.g., "issue" in "issue_detail" matches "issues")
    if page == tab.page or page:find(tab.page:sub(1, -2)) ~= nil then return tab.page end
  end
  return page
end

--------------------------------------------------------------------------------
-- List Components
--------------------------------------------------------------------------------

--- Generic filterable list wrapper
--- @param ctx morph.Ctx
--- @param opts { title: string, items: any[], loading: boolean, loading_status?: string, repo?: string, empty_msg: string, headers: string[], filter_fn: fun(item: any, filter: string): boolean, row_fn: fun(item: any): table }
--- @return morph.Tree[]
local function FilterableList(ctx, opts)
  if ctx.phase == 'mount' then ctx.state = { filter = '' } end
  local state = assert(ctx.state)
  local rows = { { cells = vim.tbl_map(function(h_) return h.Constant({}, h_) end, opts.headers) } }

  for _, item in ipairs(opts.items) do
    if state.filter == '' or opts.filter_fn(item, state.filter:lower()) then
      table.insert(rows, opts.row_fn(item))
    end
  end

  -- Build loading indicator
  local loading_indicator = nil
  if opts.loading then
    loading_indicator = opts.loading_status and (' ' .. opts.loading_status) or ' ...'
  end

  return {
    h.RenderMarkdownH1({}, '# ' .. opts.title),
    loading_indicator and h.NonText({}, loading_indicator) or nil,
    '\n',
    opts.repo and { h.NonText({}, 'Repo: ' .. opts.repo), '\n' } or nil,
    '\n',
    h.Label({}, 'Filter: '),
    '[',
    h.String({
      on_change = function(e)
        state.filter = e.text
        ctx:update(state)
      end,
    }, state.filter),
    ']',
    state.filter == '' and h.Comment({}, ' type to search') or nil,
    '\n\n',
    #opts.items == 0 and not opts.loading and h.Comment({}, opts.empty_msg) or h(Table, {
      rows = rows,
      header = true,
      header_separator = true,
      page_size = math.max(10, vim.o.lines - 10),
    }),
  }
end

--- @param ctx morph.Ctx<{ repos: table[], loading: boolean, fetch_status: table|nil, on_select: fun(repo: table), loading_status: string|nil }>
--- @return morph.Tree[]
local function ReposList(ctx)
  -- Build loading status message
  local loading_status = nil
  local fs = ctx.props.fetch_status
  if ctx.props.loading and fs then
    loading_status =
      string.format('(loading %d/%d sources, %d repos)', fs.completed, fs.total, #fs.repos)
  end

  return FilterableList(ctx, {
    title = 'Repositories',
    items = ctx.props.repos,
    loading = ctx.props.loading,
    loading_status = loading_status,
    empty_msg = 'No repositories found. Check your GitHub authentication with `gh auth status`.',
    headers = { 'REPO', 'VIS', 'LANG', 'STARS', 'FORKS', 'UPDATED' },
    filter_fn = function(r, f) return r.full_name:lower():find(f, 1, true) end,
    row_fn = function(repo)
      return {
        nmap = {
          ['<CR>'] = function()
            vim.schedule(function() ctx.props.on_select(repo) end)
            return ''
          end,
          ['gw'] = function()
            vim.schedule(
              function() vim.system { 'gh', 'repo', 'view', repo.full_name, '--web' } end
            )
            return ''
          end,
          ['g+'] = function()
            vim.fn.setreg('+', repo.full_name)
            vim.notify('Yanked to +: ' .. repo.full_name)
            return ''
          end,
          ['g"'] = function()
            vim.fn.setreg('"', repo.full_name)
            vim.notify('Yanked to ": ' .. repo.full_name)
            return ''
          end,
        },
        cells = {
          repo.is_fork and h.Comment({}, repo.full_name) or h.String({}, repo.full_name),
          repo.visibility == 'private' and h.DiagnosticWarn({}, 'priv') or h.Comment({}, 'pub'),
          repo.language ~= '' and h.Constant({}, repo.language) or h.Comment({}, '-'),
          repo.stars > 0 and h.Number({}, tostring(repo.stars)) or h.Comment({}, '0'),
          repo.forks > 0 and h.Number({}, tostring(repo.forks)) or h.Comment({}, '0'),
          h.Comment({}, relative_time(repo.updated_at)),
        },
      }
    end,
  })
end

--- @param ctx morph.Ctx<{ issues: table[], loading: boolean, repo: string, on_select: fun(issue: table) }>
--- @return morph.Tree[]
local function IssuesList(ctx)
  return FilterableList(ctx, {
    title = 'Issues',
    items = ctx.props.issues,
    loading = ctx.props.loading,
    repo = ctx.props.repo,
    empty_msg = 'No open issues. Press gw to view issues in browser.',
    headers = { '#', 'TITLE', 'AUTHOR', 'LABELS', 'COMMENTS', 'UPDATED' },
    filter_fn = function(i, f)
      return i.title:lower():find(f, 1, true) or tostring(i.number):find(f, 1, true)
    end,
    row_fn = function(issue)
      return {
        nmap = {
          ['<CR>'] = function()
            vim.schedule(function() ctx.props.on_select(issue) end)
            return ''
          end,
          ['gw'] = function()
            open_url(issue.url)
            return ''
          end,
          ['g+'] = function()
            vim.fn.setreg('+', issue.url)
            vim.notify('Yanked to +: ' .. issue.url)
            return ''
          end,
          ['g"'] = function()
            vim.fn.setreg('"', issue.url)
            vim.notify('Yanked to ": ' .. issue.url)
            return ''
          end,
          ['g#'] = function()
            yank(tostring(issue.number), 'Yanked: #' .. issue.number)
            return ''
          end,
        },
        cells = {
          h.Number({}, '#' .. issue.number),
          h.String({}, truncate(issue.title, 50)),
          h.Constant({}, issue.author),
          #issue.labels > 0 and h.Comment({}, truncate(table.concat(issue.labels, ', '), 20))
            or h.Comment({}, '-'),
          issue.comments > 0 and h.Number({}, tostring(issue.comments)) or h.Comment({}, '0'),
          h.Comment({}, relative_time(issue.updated_at)),
        },
      }
    end,
  })
end

--- TODO: `prs` needs a better type than just "table"
--- @param ctx morph.Ctx<{ prs: table[], loading: boolean, repo: string, on_select: fun(pr: table) }>
--- @return morph.Tree[]
local function PRsList(ctx)
  return FilterableList(ctx, {
    title = 'Pull Requests',
    items = ctx.props.prs,
    loading = ctx.props.loading,
    repo = ctx.props.repo,
    empty_msg = 'No open PRs. Press gw to view PRs in browser.',
    headers = { '#', 'TITLE', 'AUTHOR', 'BRANCH', 'CHECKS', 'REVIEW', '+/-', 'UPDATED' },
    filter_fn = function(p, f)
      return p.title:lower():find(f, 1, true)
        or tostring(p.number):find(f, 1, true)
        or p.head:lower():find(f, 1, true)
    end,
    row_fn = function(pr)
      return {
        nmap = {
          ['<CR>'] = function()
            vim.schedule(function() ctx.props.on_select(pr) end)
            return ''
          end,
          ['gw'] = function()
            open_url(pr.url)
            return ''
          end,
          ['gc'] = function()
            vim.schedule(
              function() term.open('gh pr checkout ' .. pr.number .. ' --repo ' .. ctx.props.repo) end
            )
            return ''
          end,
          ['g+'] = function()
            vim.fn.setreg('+', pr.url)
            vim.notify('Yanked to +: ' .. pr.url)
            return ''
          end,
          ['g"'] = function()
            vim.fn.setreg('"', pr.url)
            vim.notify('Yanked to ": ' .. pr.url)
            return ''
          end,
          ['g#'] = function()
            yank(tostring(pr.number), 'Yanked: #' .. pr.number)
            return ''
          end,
        },
        cells = {
          h.Number({}, '#' .. pr.number),
          h.String({}, truncate(pr.title, 40)),
          h.Constant({}, pr.author),
          h.Comment({}, truncate(pr.head, 20)),
          status_with_icon(pr.checks_status),
          status_with_icon(pr.reviews_status),
          { h.DiffAdd({}, '+' .. pr.additions), ' ', h.DiffDelete({}, '-' .. pr.deletions) },
          h.Comment({}, relative_time(pr.updated_at)),
        },
      }
    end,
  })
end

--- TODO: `runs` needs a better type than just "table"
--- @param ctx morph.Ctx<{ runs: table[], loading: boolean, repo: string, on_select: fun(run: table) }>
--- @return morph.Tree[]
local function RunsList(ctx)
  return FilterableList(ctx, {
    title = 'Workflow Runs',
    items = ctx.props.runs,
    loading = ctx.props.loading,
    repo = ctx.props.repo,
    empty_msg = 'No workflow runs. Does this repo have GitHub Actions configured?',
    headers = { 'STATUS', 'NAME', 'BRANCH', 'EVENT', 'STARTED' },
    filter_fn = function(r, f)
      return r.name:lower():find(f, 1, true) or r.branch:lower():find(f, 1, true)
    end,
    row_fn = function(run)
      local status_text = run.conclusion ~= '' and run.conclusion or run.status
      return {
        nmap = {
          ['<CR>'] = function()
            vim.schedule(function() ctx.props.on_select(run) end)
            return ''
          end,
          ['gw'] = function()
            open_url(run.url)
            return ''
          end,
          ['gr'] = function()
            vim.schedule(function()
              vim.system { 'gh', 'run', 'rerun', tostring(run.id), '--repo', ctx.props.repo }
              vim.notify('Rerunning ' .. run.id)
              ctx.props.on_refresh()
            end)
            return ''
          end,
          ['gl'] = function()
            vim.schedule(
              function()
                term.open('gh run view ' .. run.id .. ' --repo ' .. ctx.props.repo .. ' --log')
              end
            )
            return ''
          end,
          ['g+'] = function()
            vim.fn.setreg('+', run.url)
            vim.notify('Yanked to +: ' .. run.url)
            return ''
          end,
          ['g"'] = function()
            vim.fn.setreg('"', run.url)
            vim.notify('Yanked to ": ' .. run.url)
            return ''
          end,
          ['g#'] = function()
            yank(tostring(run.id), 'Yanked: ' .. run.id)
            return ''
          end,
        },
        cells = {
          status_with_icon(status_text),
          h.String({}, truncate(run.name, 40)),
          h.Constant({}, truncate(run.branch, 20)),
          h.Normal({}, run.event),
          h.Comment({}, relative_time(run.created_at)),
        },
      }
    end,
  })
end

--------------------------------------------------------------------------------
-- Detail Components
--------------------------------------------------------------------------------

--- @param ctx morph.Ctx<{ loading: boolean, detail: table|nil, repo: string, on_refresh: fun() }>
--- @return morph.Tree[]
local function PRDetail(ctx)
  if ctx.phase == 'mount' then ctx.state = { show_comments = false } end
  local state, detail = assert(ctx.state), ctx.props.detail

  if ctx.props.loading or not detail then
    return { h.RenderMarkdownH1({}, '# Pull Request'), '\n\n', h.Comment({}, 'Loading...') }
  end

  local checks_rows = { { cells = { h.Constant({}, 'CHECK'), h.Constant({}, 'STATUS') } } }
  for _, c in ipairs(detail.checks) do
    local check_status = c.conclusion ~= '' and c.conclusion or c.status
    table.insert(checks_rows, {
      cells = {
        h.String({}, truncate(c.name, 40)),
        status_with_icon(check_status),
      },
    })
  end

  local reviews_rows = { { cells = { h.Constant({}, 'REVIEWER'), h.Constant({}, 'STATE') } } }
  for _, r in ipairs(detail.reviews) do
    table.insert(reviews_rows, { cells = { h.Constant({}, r.author), status_with_icon(r.state) } })
  end

  return h('text', {
    nmap = {
      ['gw'] = function()
        open_url(detail.url)
        return ''
      end,
      ['gc'] = function()
        vim.schedule(
          function() term.open('gh pr checkout ' .. detail.number .. ' --repo ' .. ctx.props.repo) end
        )
        return ''
      end,
      ['gm'] = function()
        vim.schedule(function()
          vim.ui.select(
            { 'merge', 'squash', 'rebase', 'cancel' },
            { prompt = 'Merge method:' },
            function(choice)
              if choice and choice ~= 'cancel' then
                vim.system {
                  'gh',
                  'pr',
                  'merge',
                  tostring(detail.number),
                  '--repo',
                  ctx.props.repo,
                  '--' .. choice,
                }
                vim.notify('Merging PR #' .. detail.number)
                ctx.props.on_refresh()
              end
            end
          )
        end)
        return ''
      end,
      ['ga'] = function()
        vim.schedule(function()
          vim.system {
            'gh',
            'pr',
            'review',
            tostring(detail.number),
            '--repo',
            ctx.props.repo,
            '--approve',
          }
          vim.notify('Approved PR #' .. detail.number)
          ctx.props.on_refresh()
        end)
        return ''
      end,
      ['gd'] = function()
        vim.schedule(
          function() term.open('gh pr diff ' .. detail.number .. ' --repo ' .. ctx.props.repo) end
        )
        return ''
      end,
    },
  }, {
    h.RenderMarkdownH1({}, '# PR #' .. detail.number .. ': ' .. truncate(detail.title, 60)),
    '\n\n',
    -- Metadata section with aligned labels
    h.Comment({}, 'State:   '),
    status_with_icon(detail.state, { 'OPEN' }, { 'CLOSED', 'MERGED' }),
    '\n',
    h.Comment({}, 'Author:  '),
    h.Constant({}, detail.author),
    '\n',
    h.Comment({}, 'Branch:  '),
    h.String({}, detail.head),
    h.Comment({}, ' -> '),
    h.String({}, detail.base),
    '\n',
    h.Comment({}, 'Changes: '),
    h.DiffAdd({}, '+' .. detail.additions),
    ' ',
    h.DiffDelete({}, '-' .. detail.deletions),
    h.Comment({}, ' ('),
    h.Number({}, tostring(detail.changed_files)),
    h.Comment({}, ' files, '),
    h.Number({}, tostring(vim.tbl_count(detail.commits))),
    h.Comment({}, ' commits)'),
    '\n',
    h.Comment({}, 'Created: '),
    h.Normal({}, relative_time(detail.created_at)),
    '\n',
    detail.merged_at and {
      h.Comment({}, 'Merged:  '),
      h.Normal({}, relative_time(detail.merged_at)),
      h.Comment({}, ' by '),
      h.Constant({}, detail.merged_by or ''),
      '\n',
    } or nil,
    -- Description section
    BodySection(detail.body, 500),
        -- Checks section
    #detail.checks > 0
        and {
          '\n',
          h.RenderMarkdownH1({}, '## Checks'),
          '\n',
          h(Table, { rows = checks_rows, header = true, header_separator = true }),
          '\n',
        }
      or nil,
        -- Reviews section
    #detail.reviews > 0
        and {
          '\n',
          h.RenderMarkdownH1({}, '## Reviews'),
          '\n',
          h(Table, { rows = reviews_rows, header = true, header_separator = true }),
          '\n',
        }
      or nil,
    CommentsSection(detail.comments, state.show_comments, function()
      state.show_comments = not state.show_comments
      ctx:update(state)
    end),
  })
end

--- @param ctx morph.Ctx<{ loading: boolean, detail: table|nil, repo: string, on_refresh: fun() }>
--- @return morph.Tree[]
local function IssueDetail(ctx)
  if ctx.phase == 'mount' then ctx.state = { show_comments = false } end
  local state, detail = assert(ctx.state), ctx.props.detail

  if ctx.props.loading or not detail then
    return { h.RenderMarkdownH1({}, '# Issue'), '\n\n', h.Comment({}, 'Loading...') }
  end

  return h('text', {
    nmap = {
      ['gw'] = function()
        open_url(detail.url)
        return ''
      end,
      ['gx'] = function()
        vim.schedule(function()
          vim.ui.select({ 'close', 'reopen', 'cancel' }, { prompt = 'Action:' }, function(choice)
            if choice == 'close' then
              vim.system { 'gh', 'issue', 'close', tostring(detail.number), '--repo', ctx.props.repo }
              vim.notify('Closed issue #' .. detail.number)
              ctx.props.on_refresh()
            elseif choice == 'reopen' then
              vim.system {
                'gh',
                'issue',
                'reopen',
                tostring(detail.number),
                '--repo',
                ctx.props.repo,
              }
              vim.notify('Reopened issue #' .. detail.number)
              ctx.props.on_refresh()
            end
          end)
        end)
        return ''
      end,
    },
  }, {
    h.RenderMarkdownH1({}, '# Issue #' .. detail.number .. ': ' .. truncate(detail.title, 60)),
    '\n\n',
    -- Metadata section
    h.Comment({}, 'State:     '),
    status_with_icon(detail.state, { 'OPEN' }, { 'CLOSED' }),
    '\n',
    h.Comment({}, 'Author:    '),
    h.Constant({}, detail.author),
    '\n',
    h.Comment({}, 'Created:   '),
    h.Normal({}, relative_time(detail.created_at)),
    '\n',
    detail.closed_at and {
      h.Comment({}, 'Closed:    '),
      h.Normal({}, relative_time(detail.closed_at)),
      '\n',
    } or nil,
    #detail.labels > 0 and {
      h.Comment({}, 'Labels:    '),
      h.String({}, table.concat(detail.labels, ', ')),
      '\n',
    } or nil,
    #detail.assignees > 0 and {
      h.Comment({}, 'Assignees: '),
      h.Constant({}, table.concat(detail.assignees, ', ')),
      '\n',
    } or nil,
    -- Description section
    BodySection(detail.body, 600),
    -- Comments section
    CommentsSection(detail.comments, state.show_comments, function()
      state.show_comments = not state.show_comments
      ctx:update(state)
    end),
  })
end

--- @param ctx morph.Ctx<{ loading: boolean, detail: table|nil, repo: string, on_refresh: fun() }>
--- @return morph.Tree[]
local function RunDetail(ctx)
  local detail = ctx.props.detail
  if ctx.props.loading or not detail then
    return { h.RenderMarkdownH1({}, '# Workflow Run'), '\n\n', h.Comment({}, 'Loading...') }
  end

  local status_text = detail.conclusion ~= '' and detail.conclusion or detail.status
  local jobs_rows =
    { { cells = { h.Constant({}, 'JOB'), h.Constant({}, 'STATUS'), h.Constant({}, 'COMPLETED') } } }
  for _, job in ipairs(detail.jobs) do
    local job_status = job.conclusion ~= '' and job.conclusion or job.status
    table.insert(jobs_rows, {
      nmap = {
        ['gl'] = function()
          vim.schedule(
            function()
              term.open('gh run view --job ' .. job.id .. ' --repo ' .. ctx.props.repo .. ' --log')
            end
          )
          return ''
        end,
      },
      cells = {
        h.String({}, truncate(job.name, 40)),
        status_with_icon(job_status),
        h.Comment({}, relative_time(job.completed_at)),
      },
    })
  end

  return h('text', {
    nmap = {
      ['gw'] = function()
        open_url(detail.url)
        return ''
      end,
      ['gr'] = function()
        vim.schedule(function()
          vim.system { 'gh', 'run', 'rerun', tostring(detail.id), '--repo', ctx.props.repo }
          vim.notify('Rerunning ' .. detail.id)
          ctx.props.on_refresh()
        end)
        return ''
      end,
      ['gl'] = function()
        vim.schedule(
          function()
            term.open('gh run view ' .. detail.id .. ' --repo ' .. ctx.props.repo .. ' --log')
          end
        )
        return ''
      end,
      ['gx'] = function()
        vim.schedule(function()
          vim.ui.select({ 'cancel', 'keep' }, { prompt = 'Cancel this run?' }, function(choice)
            if choice == 'cancel' then
              vim.system { 'gh', 'run', 'cancel', tostring(detail.id), '--repo', ctx.props.repo }
              vim.notify('Cancelled ' .. detail.id)
              ctx.props.on_refresh()
            end
          end)
        end)
        return ''
      end,
    },
  }, {
    h.RenderMarkdownH1({}, '# Workflow: ' .. truncate(detail.name, 60)),
    '\n\n',
    -- Metadata section with aligned labels
    h.Comment({}, 'Status:  '),
    status_with_icon(status_text),
    '\n',
    h.Comment({}, 'Branch:  '),
    h.Constant({}, detail.branch),
    '\n',
    h.Comment({}, 'Event:   '),
    h.Normal({}, detail.event),
    '\n',
    h.Comment({}, 'Started: '),
    h.Normal({}, relative_time(detail.created_at)),
    '\n',
        -- Jobs section
    #detail.jobs > 0
        and {
          '\n',
          h.RenderMarkdownH1({}, '## Jobs'),
          '\n',
          h(Table, { rows = jobs_rows, header = true, header_separator = true }),
        }
      or nil,
  })
end

--------------------------------------------------------------------------------
-- App Component
--------------------------------------------------------------------------------

--- Page configuration for data-driven dispatch
local PAGE_CONFIG = {
  repos = {
    field = 'repos',
    component = ReposList,
    props = function(s) return { repos = s.repos, fetch_status = s.repos_fetch_status } end,
  },
  issues = {
    fetch = fetch_issues,
    field = 'issues',
    component = IssuesList,
    props = function(s) return { issues = s.issues, repo = s.repo } end,
  },
  prs = {
    fetch = fetch_prs,
    field = 'prs',
    component = PRsList,
    props = function(s) return { prs = s.prs, repo = s.repo } end,
  },
  runs = {
    fetch = fetch_runs,
    field = 'runs',
    component = RunsList,
    props = function(s) return { runs = s.runs, repo = s.repo } end,
  },
  pr_detail = {
    fetch = function(repo, cb, s) fetch_pr_detail(repo, s.selected_pr, cb) end,
    field = 'pr_detail',
    component = PRDetail,
    props = function(s) return { detail = s.pr_detail, repo = s.repo } end,
  },
  issue_detail = {
    fetch = function(repo, cb, s) fetch_issue_detail(repo, s.selected_issue, cb) end,
    field = 'issue_detail',
    component = IssueDetail,
    props = function(s) return { detail = s.issue_detail, repo = s.repo } end,
  },
  run_detail = {
    fetch = function(repo, cb, s) fetch_run_detail(repo, s.selected_run, cb) end,
    field = 'run_detail',
    component = RunDetail,
    props = function(s) return { detail = s.run_detail, repo = s.repo } end,
  },
}

local function App(ctx)
  local function refresh(show_loading)
    local state = assert(ctx.state)

    -- Special handling for repos page with progressive loading
    if state.page == 'repos' then
      -- Only show loading indicator if we have no data yet
      local is_initial_load = #state.repos == 0
      if show_loading and is_initial_load then
        state.loading = true
        state.repos_fetch_status = { total = 1, completed = 0, repos = {} }
        ctx:update(state)
      end

      -- Pass existing repos to merge into (avoids flash of empty content)
      fetch_all_repos(function(status)
        -- on_progress: update repos and status as batches complete
        state.repos = status.repos
        state.repos_fetch_status = is_initial_load and status or nil
        state.loading = is_initial_load and status.completed < status.total
        ctx:update(state)
      end, function(status)
        -- on_complete: final update
        state.repos = status.repos
        state.repos_fetch_status = nil
        state.loading = false
        ctx:update(state)
      end, state.repos)
      return
    end

    local config = PAGE_CONFIG[state.page]
    if not config then return end

    local has_data = state[config.field]
      and (
        type(state[config.field]) ~= 'table'
        or #state[config.field] > 0
        or state[config.field].number
        or state[config.field].id
      )
    if show_loading and not has_data then
      state.loading = true
      ctx:update(state)
    end

    local function on_done(data)
      state[config.field] = data
      state.loading = false
      ctx:update(state)
    end

    if state.repo then
      config.fetch(state.repo, on_done, state)
    else
      state.loading = false
      ctx:update(state)
    end
  end

  local function go_to_page(page)
    local state = assert(ctx.state)
    if state.page ~= page then table.insert(state.page_history, state.page) end
    state.page = page
    ctx:update(state)
    vim.fn.winrestview { topline = 1, lnum = 1 }
    refresh(true)
  end

  local function go_back()
    local state = assert(ctx.state)
    if #state.page_history > 0 then
      state.page = table.remove(state.page_history)
      ctx:update(state)
      vim.fn.winrestview { topline = 1, lnum = 1 }
      refresh(true)
    end
  end

  if ctx.phase == 'mount' then
    local repo = get_current_repo()
    ctx.state = {
      page = repo and 'prs' or 'repos',
      page_history = {},
      user = get_current_user(),
      repo = repo,
      loading = true,
      show_help = false,
      repos = {},
      repos_fetch_status = nil, --- @type RepoFetchStatus|nil
      issues = {},
      prs = {},
      runs = {},
      selected_pr = nil,
      selected_issue = nil,
      selected_run = nil,
      pr_detail = nil,
      issue_detail = nil,
      run_detail = nil,
      timer = assert(vim.uv.new_timer()),
    }

    -- Always load repos in background for fuzzy picker
    if ctx.state.page ~= 'repos' then
      fetch_all_repos(function(status)
        ctx.state.repos = status.repos
        if status.completed >= status.total then
          ctx.state.repos_fetch_status = nil
        else
          ctx.state.repos_fetch_status = status
        end
        ctx:update(ctx.state)
      end, function(status)
        ctx.state.repos = status.repos
        ctx.state.repos_fetch_status = nil
        ctx:update(ctx.state)
      end, ctx.state.repos)
    end

    vim.schedule(function() refresh(true) end)
    ctx.state.timer:start(30000, 30000, function() vim.schedule(refresh) end)
  end

  local state = assert(ctx.state)
  if ctx.phase == 'unmount' then
    state.timer:stop()
    state.timer:close()
  end

  -- Render page content using config
  local config = PAGE_CONFIG[state.page]
  local page_content = config
      and h(
        config.component,
        vim.tbl_extend('force', config.props(state), {
          loading = state.loading,
          on_select = function(item)
            if state.page == 'repos' then
              state.repo = item.full_name
              go_to_page 'prs'
            elseif state.page == 'issues' then
              state.selected_issue = item.number
              go_to_page 'issue_detail'
            elseif state.page == 'prs' then
              state.selected_pr = item.number
              go_to_page 'pr_detail'
            elseif state.page == 'runs' then
              state.selected_run = item.id
              go_to_page 'run_detail'
            end
          end,
          on_refresh = refresh,
          on_back = go_back,
        })
      )
    or nil

  return h('text', {
    nmap = {
      ['<Leader>r'] = function()
        vim.schedule(refresh)
        return ''
      end,
      ['g?'] = function()
        state.show_help = not state.show_help
        ctx:update(state)
        return ''
      end,
      ['<C-o>'] = function()
        vim.schedule(go_back)
        return ''
      end,
      ['g1'] = function()
        vim.schedule(function() go_to_page 'repos' end)
        return ''
      end,
      ['g2'] = function()
        vim.schedule(function() go_to_page 'issues' end)
        return ''
      end,
      ['g3'] = function()
        vim.schedule(function() go_to_page 'prs' end)
        return ''
      end,
      ['g4'] = function()
        vim.schedule(function() go_to_page 'runs' end)
        return ''
      end,
      ['<Leader>R'] = function()
        vim.schedule(function()
          local state = assert(ctx.state)
          if #state.repos == 0 then
            vim.notify('No repos loaded', vim.log.levels.WARN)
            return
          end
          local repo_names = vim.tbl_map(function(r) return r.full_name end, state.repos)
          table.sort(repo_names)
          vim.ui.select(repo_names, { prompt = 'Switch to repo:' }, function(choice)
            if not choice then return end
            state.repo = choice
            state.issues = {}
            state.prs = {}
            state.runs = {}
            state.selected_pr = nil
            state.selected_issue = nil
            state.selected_run = nil
            state.pr_detail = nil
            state.issue_detail = nil
            state.run_detail = nil
            ctx:update(state)
            vim.schedule(function() refresh(true) end)
          end)
        end)
        return ''
      end,
    },
  }, {
    h.RenderMarkdownH1({}, 'GitHub'),
    ' ',
    h.NonText({}, 'User: ' .. state.user),
    ' ',
    h.NonText({}, 'g? for help'),
    '\n\n',
    h(TabBar, { tabs = TABS, active_page = get_active_tab(state.page), on_select = go_to_page }),
    h(Breadcrumb, {
      page = state.page,
      repo = state.repo,
      selected_pr = state.selected_pr,
      selected_issue = state.selected_issue,
      selected_run = state.selected_run,
      on_back = go_back,
    }),
    state.show_help and { h(GithubHelp, {}), '\n' },
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
  vim.api.nvim_buf_set_name(0, 'GitHub')

  Morph.new(0):mount(h(App))
end

return M
