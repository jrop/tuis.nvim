local Morph = require 'tuis.morph'
local h = Morph.h
local components = require 'tuis.components'
local Table = components.Table
local TabBar = components.TabBar
local Help = components.Help
local utils = require 'tuis.utils'
local keymap = utils.keymap

local M = {}

function M.is_enabled() return true end

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

--- @alias hn.Page 'top'|'new'|'best'|'comments'|'users'

--- @class hn.Story
--- @field id number
--- @field title string
--- @field url string
--- @field by string
--- @field score number
--- @field time number
--- @field descendants number
--- @field kids number[]
--- @field raw unknown

--- @class hn.Comment
--- @field id number
--- @field by string
--- @field text string
--- @field time number
--- @field kids number[]
--- @field raw unknown
--- @field collapsed boolean

--- @class hn.User
--- @field id string
--- @field karma number
--- --- @field created number
--- @field raw unknown

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--- @param timestamp number
--- @return string
local function format_time(timestamp)
  local diff = os.time() - timestamp
  if diff < 60 then
    return 'just now'
  elseif diff < 3600 then
    return string.format('%dm ago', math.floor(diff / 60))
  elseif diff < 86400 then
    return string.format('%dh ago', math.floor(diff / 3600))
  else
    return string.format('%dd ago', math.floor(diff / 86400))
  end
end

--- @param callback fun(success: boolean, data: any)
local function fetch_top_stories(callback)
  vim.system(
    { 'curl', '-s', 'https://hacker-news.firebaseio.com/v0/topstories.json' },
    { text = true },
    function(out)
      vim.schedule(function()
        local ok, ids = pcall(vim.json.decode, out.stdout or '[]')
        if not ok or not ids then
          callback(false, {})
          return
        end
        callback(true, ids)
      end)
    end
  )
end

--- @param callback fun(success: boolean, data: any)
local function fetch_new_stories(callback)
  vim.system(
    { 'curl', '-s', 'https://hacker-news.firebaseio.com/v0/newstories.json' },
    { text = true },
    function(out)
      vim.schedule(function()
        local ok, ids = pcall(vim.json.decode, out.stdout or '[]')
        if not ok or not ids then
          callback(false, {})
          return
        end
        callback(true, ids)
      end)
    end
  )
end

--- @param callback fun(success: boolean, data: any)
local function fetch_best_stories(callback)
  vim.system(
    { 'curl', '-s', 'https://hacker-news.firebaseio.com/v0/beststories.json' },
    { text = true },
    function(out)
      vim.schedule(function()
        local ok, ids = pcall(vim.json.decode, out.stdout or '[]')
        if not ok or not ids then
          callback(false, {})
          return
        end
        callback(true, ids)
      end)
    end
  )
end

--- @param id number
--- @param callback fun(success: boolean, data: any)
local function fetch_item(id, callback)
  vim.system(
    { 'curl', '-s', 'https://hacker-news.firebaseio.com/v0/item/' .. id .. '.json' },
    { text = true },
    function(out)
      vim.schedule(function()
        local ok, item = pcall(vim.json.decode, out.stdout or 'null')
        if not ok or not item then
          callback(false, {})
          return
        end
        callback(true, item)
      end)
    end
  )
end

--- @param ids number[]
--- @param callback fun(stories: hn.Story[])
local function fetch_stories(ids, callback)
  local stories = {}
  local count = 0
  local total = math.min(#ids, 30)

  if total == 0 then
    callback {}
    return
  end

  for i = 1, total do
    fetch_item(ids[i], function(success, item)
      count = count + 1
      if success and item and item.type == 'story' then
        table.insert(stories, {
          id = item.id,
          title = item.title or '',
          url = item.url or '',
          by = item.by or 'anonymous',
          score = item.score or 0,
          time = item.time or 0,
          descendants = item.descendants or 0,
          kids = item.kids or {},
          raw = item,
        })
      end
      if count >= total then
        table.sort(stories, function(a, b) return a.score > b.score end)
        callback(stories)
      end
    end)
  end
end

--- Strip HTML tags from a string
--- @param text string
--- @return string
local function strip_html(text)
  if not text then return '' end
  text = text:gsub('&nbsp;', ' ')
  text = text:gsub('&lt;', '<')
  text = text:gsub('&gt;', '>')
  text = text:gsub('&amp;', '&')
  text = text:gsub('&quot;', '"')
  text = text:gsub('&apos;', "'")
  text = text:gsub('&#x(%x+);', function(n) return string.char(tonumber(n, 16)) end)
  text = text:gsub('&#(%d+);', function(n) return string.char(tonumber(n, 10)) end)
  return (text:gsub('<[^>]*>', ''))
end

--- Fetch a comment and its kids recursively into all_comments table
--- @param id number
--- @param all_comments table<number, hn.Comment>
--- @param callback fun()
local function fetch_tree_comment(id, all_comments, callback)
  fetch_item(id, function(success, item)
    if success and item and item.type == 'comment' then
      all_comments[id] = {
        id = item.id,
        by = item.by or 'anonymous',
        text = item.text or '',
        time = item.time or 0,
        kids = item.kids or {},
        collapsed = false,
        raw = item,
      }
    end

    local kids = all_comments[id] and all_comments[id].kids or {}
    if #kids == 0 then
      callback()
      return
    end

    local pending = #kids
    for _, kid_id in ipairs(kids) do
      fetch_tree_comment(kid_id, all_comments, function()
        pending = pending - 1
        if pending == 0 then callback() end
      end)
    end
  end)
end

--- @param comment hn.Comment
--- @param depth number
--- @param all_comments table<number, hn.Comment>
--- @param collapsed_comments table<number, boolean>
--- @return hn.Comment[]
local function get_comment_kids(comment, depth, all_comments, collapsed_comments)
  local result = {}
  local indent = string.rep('  ', depth)

  -- Check if this comment is collapsed
  local is_collapsed = collapsed_comments[comment.id] or false

  table.insert(result, {
    comment = comment,
    depth = depth,
    indent = indent,
    is_collapsed = is_collapsed,
  })

  -- Only process kids if not collapsed
  if not is_collapsed and comment.kids then
    for _, kid_id in ipairs(comment.kids) do
      local kid = all_comments[kid_id]
      if kid then
        local kids = get_comment_kids(kid, depth + 1, all_comments, collapsed_comments)
        for _, k in ipairs(kids) do
          table.insert(result, k)
        end
      end
    end
  end
  return result
end

--------------------------------------------------------------------------------
-- Help System
--------------------------------------------------------------------------------

local HELP_KEYMAPS = {
  top = {
    { '<CR>', 'Open story in browser' },
    { 'gi', 'View story details' },
    { 'gc', 'View comments' },
    { 'g+', 'Yank URL to +' },
    { 'g"', 'Yank URL to "' },
  },
  new = {
    { '<CR>', 'Open story in browser' },
    { 'gi', 'View story details' },
    { 'gc', 'View comments' },
    { 'g+', 'Yank URL to +' },
    { 'g"', 'Yank URL to "' },
  },
  best = {
    { '<CR>', 'Open story in browser' },
    { 'gi', 'View story details' },
    { 'gc', 'View comments' },
    { 'g+', 'Yank URL to +' },
    { 'g"', 'Yank URL to "' },
  },
  comments = {
    { 'gi', 'View comment as JSON' },
    { '<CR>', 'Open story in browser' },
    { 'go', 'Toggle expand/collapse comment' },
  },
}

local COMMON_KEYMAPS = {
  { 'g1-g3', 'Navigate tabs' },
  { '<Leader>r', 'Refresh' },
  { 'g?', 'Toggle help' },
}

--- @param ctx morph.Ctx<{ page: hn.Page }>
local function HackerNewsHelp(ctx)
  return h(Help, {
    page_keymaps = HELP_KEYMAPS[ctx.props.page],
    common_keymaps = COMMON_KEYMAPS,
  })
end

--------------------------------------------------------------------------------
-- Navigation
--------------------------------------------------------------------------------

--- @type { key: string, page: hn.Page, label: string }[]
local TABS = {
  { key = 'g1', page = 'top', label = 'Top' },
  { key = 'g2', page = 'new', label = 'New' },
  { key = 'g3', page = 'best', label = 'Best' },
}

--------------------------------------------------------------------------------
-- Comments View
--------------------------------------------------------------------------------

--- @param text string
--- @param width number
--- @return string[]
local function wrap_text(text, width)
  if not text or text == '' then return { '' } end
  local result = {}
  local remaining = text
  while #remaining > width do
    local break_pos = width
    for i = width, 1, -1 do
      if remaining:sub(i, i) == ' ' then
        break_pos = i
        break
      end
    end
    table.insert(result, remaining:sub(1, break_pos))
    remaining = remaining:sub(break_pos + 1):gsub('^%s+', '')
  end
  if #remaining > 0 then table.insert(result, remaining) end
  if #result == 0 then table.insert(result, '') end
  return result
end

--- @param ctx morph.Ctx<{ story_id: number, story: hn.Story|nil }>
local function CommentsView(ctx)
  if ctx.phase == 'mount' then
    ctx.state = {
      root_comments = {},
      all_comments = {},
      loading = true,
      error = nil,
      collapsed_comments = {},
    }

    local story_id = ctx.props.story_id
    if not story_id then
      ctx.state.loading = false
      ctx.state.error = 'No story ID'
    else
      fetch_item(story_id, function(success, item)
        if not success or not item then
          ctx.state.loading = false
          ctx.state.error = 'Failed to fetch story'
          ctx:update(ctx.state)
          return
        end

        local top_level_ids = item.kids or {}
        if #top_level_ids == 0 then
          ctx.state.loading = false
          ctx.state.root_comments = {}
          ctx.state.all_comments = {}
          ctx:update(ctx.state)
          return
        end

        local pending = #top_level_ids
        local all_comments = {}

        for _, id in ipairs(top_level_ids) do
          fetch_tree_comment(id, all_comments, function()
            pending = pending - 1
            if pending == 0 then
              ctx.state.loading = false
              ctx.state.all_comments = all_comments
              ctx.state.root_comments = top_level_ids
              ctx:update(ctx.state)
            end
          end)
        end
      end)
    end
  end

  local state = assert(ctx.state)
  local story = ctx.props.story

  if state.error then
    return {
      h.RenderMarkdownH1({}, '## Comments'),
      story and h.NonText({}, ' for: ' .. story.title) or nil,
      '\n\n',
      h.DiagnosticError({}, 'Error: ' .. state.error),
    }
  end

  local vim_width = vim.o.columns > 0 and vim.o.columns or 80
  local content_width = vim_width - 5
  local result = {
    h.RenderMarkdownH1({}, '## Comments'),
  }
  if story then table.insert(result, h.NonText({}, ' for: ' .. story.title)) end
  if state.loading then table.insert(result, h.NonText({}, ' (loading...)')) end
  table.insert(result, '\n\n')

  local rendered_lines = {}
  for _, id in ipairs(state.root_comments) do
    local comment = state.all_comments[id]
    if comment then
      local threaded = get_comment_kids(comment, 0, state.all_comments, state.collapsed_comments)
      for _, item in ipairs(threaded) do
        local c = item.comment
        local indent = item.indent
        local is_collapsed = item.is_collapsed
        local author = c.by or 'anonymous'
        local time_str = format_time(c.time)

        -- Add comment header with collapse indicator
        local collapse_indicator = is_collapsed and '▼' or '▲'
        local header_text
        if is_collapsed then
          header_text =
            string.format('%s%s [%s] • %s', indent, author, c.kids and #c.kids or 0, time_str)
        else
          header_text = string.format('%s%s %s', indent, author, time_str)
        end

        table.insert(rendered_lines, {
          '\n',
          h('text', {
            nmap = {
              ['go'] = keymap(function()
                state.collapsed_comments[c.id] = not state.collapsed_comments[c.id]
                ctx:update(state)
              end),
              ['gi'] = keymap(function()
                local json = vim.json.encode(c.raw or {}, { indent = true })
                vim.schedule(function()
                  vim.cmd.vnew()
                  vim.bo.buftype = 'nofile'
                  vim.bo.bufhidden = 'wipe'
                  vim.bo.buflisted = false
                  vim.cmd.setfiletype 'json'
                  vim.api.nvim_buf_set_lines(0, 0, -1, true, vim.split(json, '\n'))
                end)
              end),
            },
          }, string.format('%s %s', header_text, collapse_indicator)),
        })

        -- Only show comment text if not collapsed
        if not is_collapsed then
          local text = strip_html(c.text)
          local wrapped = wrap_text(text, content_width)
          for _i, line in ipairs(wrapped) do
            table.insert(rendered_lines, h('text', {}, indent .. line))
          end
        end
      end
    end
  end

  for i, line in ipairs(rendered_lines) do
    table.insert(result, line)
    if i < #rendered_lines then table.insert(result, '\n') end
  end

  if not state.loading and #state.root_comments == 0 then
    table.insert(result, h.NonText({}, 'No comments yet.'))
  end
  return result
end

--------------------------------------------------------------------------------
-- Stories View
--------------------------------------------------------------------------------

--- @param ctx morph.Ctx<{ stories: hn.Story[], loading: boolean, on_refresh: fun() }, { filter: string }>
local function StoriesView(ctx)
  if ctx.phase == 'mount' then ctx.state = { filter = '' } end
  local state = assert(ctx.state)

  local rows = {
    {
      cells = {
        h.Constant({}, 'SCORE'),
        h.Constant({}, 'TITLE'),
        h.Constant({}, 'BY'),
        h.Constant({}, 'AGE'),
        h.Constant({}, 'COMMENTS'),
      },
    },
  }

  for _, story in ipairs(ctx.props.stories or {}) do
    local matches_filter = utils.create_filter_fn(state.filter)
    local passes_filter = matches_filter(story.title)
    if passes_filter then
      table.insert(rows, {
        nmap = {
          ['<CR>'] = keymap(
            function()
              vim.ui.open(
                story.url ~= '' and story.url or 'https://news.ycombinator.com/item?id=' .. story.id
              )
            end
          ),
          ['gi'] = keymap(function()
            local url = story.url ~= '' and story.url
              or 'https://news.ycombinator.com/item?id=' .. story.id
            local msg = ('[%d] %s\n\nURL: %s\nBy: %s\nScore: %d\nComments: %d\n\nOpen: %s'):format(
              story.id,
              story.title,
              url,
              story.by,
              story.score,
              story.descendants,
              url
            )
            vim.notify(msg)
          end),
          ['gc'] = keymap(function()
            vim.cmd.tabnew()
            vim.bo.buftype = 'nofile'
            vim.bo.bufhidden = 'wipe'
            vim.bo.buflisted = false
            vim.wo[0][0].list = false
            Morph.new(0):mount(h(CommentsView, { story = story, story_id = story.id }))
          end),
          ['g+'] = keymap(function()
            local url = story.url ~= '' and story.url
              or 'https://news.ycombinator.com/item?id=' .. story.id
            vim.fn.setreg('+', url)
            vim.notify('Yanked to +: ' .. url)
          end),
          ['g"'] = keymap(function()
            local url = story.url ~= '' and story.url
              or 'https://news.ycombinator.com/item?id=' .. story.id
            vim.fn.setreg('"', url)
            vim.notify('Yanked to ": ' .. url)
          end),
        },
        cells = {
          h.DiagnosticOk({}, tostring(story.score)),
          h.String({}, story.title),
          h.Comment({}, story.by),
          h.Comment({}, format_time(story.time)),
          h.Number({}, tostring(story.descendants)),
        },
      })
    end
  end

  return {
    h.RenderMarkdownH1({}, '## Stories'),
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

--------------------------------------------------------------------------------
-- App State
--------------------------------------------------------------------------------

--- @class hn.AppState
--- @field page hn.Page
--- @field show_help boolean
--- @field loading boolean
--- @field top_stories hn.Story[]
--- @field new_stories hn.Story[]
--- @field best_stories hn.Story[]

--- @param ctx morph.Ctx<any, hn.AppState>
local function App(ctx)
  --- @param show_loading? boolean
  local function refresh(show_loading)
    local state = assert(ctx.state)
    if show_loading then
      state.loading = true
      ctx:update(state)
    end

    if state.page == 'top' then
      fetch_top_stories(function(success, ids)
        if success then
          fetch_stories(ids, function(stories)
            state.top_stories = stories
            state.loading = false
            ctx:update(state)
          end)
        else
          state.loading = false
          ctx:update(state)
        end
      end)
    elseif state.page == 'new' then
      fetch_new_stories(function(success, ids)
        if success then
          fetch_stories(ids, function(stories)
            state.new_stories = stories
            state.loading = false
            ctx:update(state)
          end)
        else
          state.loading = false
          ctx:update(state)
        end
      end)
    elseif state.page == 'best' then
      fetch_best_stories(function(success, ids)
        if success then
          fetch_stories(ids, function(stories)
            state.best_stories = stories
            state.loading = false
            ctx:update(state)
          end)
        else
          state.loading = false
          ctx:update(state)
        end
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
      page = 'top',
      show_help = false,
      loading = true,
      top_stories = {},
      new_stories = {},
      best_stories = {},
    } --- @type hn.AppState
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
  }
  for _, tab in ipairs(TABS) do
    nav_keymaps[tab.key] = keymap(function()
      vim.schedule(function() go_to_page(tab.page) end)
    end)
  end

  local page_content
  if state.page == 'top' then
    page_content = h(StoriesView, {
      stories = state.top_stories,
      loading = state.loading,
      on_refresh = refresh,
    })
  elseif state.page == 'new' then
    page_content = h(StoriesView, {
      stories = state.new_stories,
      loading = state.loading,
      on_refresh = refresh,
    })
  elseif state.page == 'best' then
    page_content = h(StoriesView, {
      stories = state.best_stories,
      loading = state.loading,
      on_refresh = refresh,
    })
  else
    page_content = {}
  end

  return h('text', { nmap = nav_keymaps }, {
    h.RenderMarkdownH1({}, 'Hacker News'),
    ' ',
    h.NonText({}, 'g? for help'),
    '\n\n',

    h(TabBar, { tabs = TABS, active_page = state.page, on_select = go_to_page }),

    state.show_help and { h(HackerNewsHelp, { page = state.page }), '\n' },

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
  vim.api.nvim_buf_set_name(0, 'Hacker News')

  Morph.new(0):mount(h(App))
end

return M
