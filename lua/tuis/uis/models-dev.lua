local Morph = require 'tuis.morph'
local h = Morph.h
local components = require 'tuis.components'
local Table = components.Table
local Help = components.Help
local utils = require 'tuis.utils'
local keymap = utils.keymap
local create_scratch_buffer = utils.create_scratch_buffer

local M = {}

--- @type string[]
local CLI_DEPENDENCIES = { 'curl', 'jq' }

function M.is_enabled() return utils.check_clis_available(CLI_DEPENDENCIES, true) end

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

--- @class models.Modalities
--- @field input string[]
--- @field output string[]

--- @class models.Cost
--- @field input number
--- @field output number
--- @field cache_read? number
--- @field cache_write? number

--- @class models.Limit
--- @field context number
--- @field output number

--- @class models.Model
--- @field id string
--- @field name string
--- @field family string
--- @field provider string
--- @field attachment boolean
--- @field reasoning boolean
--- @field tool_call boolean
--- @field temperature boolean
--- @field knowledge string
--- @field release_date string
--- @field last_updated string
--- @field modalities models.Modalities
--- @field open_weights boolean
--- @field cost models.Cost
--- @field limit models.Limit
--- @field structured_output? boolean
--- @field interleaved? boolean
--- @field status? string
--- @field raw unknown

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--- Format cost in dollars per million tokens
--- @param cost number
--- @return string
local function format_cost(cost)
  if cost == 0 then return 'free' end
  if cost < 0.01 then return string.format('$%.4f', cost) end
  if cost < 1 then return string.format('$%.2f', cost) end
  return string.format('$%.1f', cost)
end

--- Format context limit in K or M tokens
--- @param limit number
--- @return string
local function format_context(limit)
  if limit >= 1000000 then
    return string.format('%.1fM', limit / 1000000)
  elseif limit >= 1000 then
    return string.format('%dK', math.floor(limit / 1000))
  end
  return tostring(limit)
end

--- Build capability badges string
--- @param model models.Model
--- @return morph.Tree[]
local function capability_badges(model)
  local badges = {}
  if model.reasoning then table.insert(badges, h.DiagnosticHint({}, '🧠')) end
  if model.tool_call then table.insert(badges, h.DiagnosticInfo({}, '🔧')) end
  if model.attachment then table.insert(badges, h.DiagnosticOk({}, '📎')) end
  if model.open_weights then table.insert(badges, h.String({}, '🔓')) end
  if model.status == 'deprecated' then table.insert(badges, h.DiagnosticError({}, '⚠')) end
  return badges
end

--------------------------------------------------------------------------------
-- Data Fetching
--------------------------------------------------------------------------------

local API_URL = 'https://models.dev/api.json'

--- @param callback fun(models: models.Model[], error?: string)
local function fetch_models(callback)
  vim.system({ 'curl', '-s', API_URL }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback({}, 'Failed to fetch: ' .. (result.stderr or 'unknown error'))
        return
      end

      local ok, data = pcall(vim.json.decode, result.stdout or '{}')
      if not ok then
        callback({}, 'Failed to parse JSON')
        return
      end

      --- @type models.Model[]
      local models = {}

      -- API returns { provider_id: { models: { model_id: {...} } } }
      for provider_id, provider in pairs(data) do
        local provider_name = provider.name or provider_id
        local provider_models = provider.models or {}

        for _, item in pairs(provider_models) do
          table.insert(models, {
            id = item.id or '',
            name = item.name or item.id or '',
            family = item.family or '',
            provider = provider_name,
            attachment = item.attachment or false,
            reasoning = item.reasoning or false,
            tool_call = item.tool_call or false,
            temperature = item.temperature or false,
            knowledge = item.knowledge or '',
            release_date = item.release_date or '',
            last_updated = item.last_updated or '',
            modalities = item.modalities or { input = {}, output = {} },
            open_weights = item.open_weights or false,
            cost = item.cost or { input = 0, output = 0 },
            limit = item.limit or { context = 0, output = 0 },
            structured_output = item.structured_output,
            interleaved = item.interleaved,
            status = item.status,
            raw = item,
          })
        end
      end

      -- Sort by provider then name
      table.sort(models, function(a, b)
        if a.provider == b.provider then return a.name < b.name end
        return a.provider < b.provider
      end)

      callback(models)
    end)
  end)
end

--------------------------------------------------------------------------------
-- Help Keymaps
--------------------------------------------------------------------------------

local PAGE_KEYMAPS = {
  { 'gi', 'Inspect model (JSON)' },
}

local COMMON_KEYMAPS = {
  { '[[', 'Previous page' },
  { ']]', 'Next page' },
  { '<Leader>r', 'Refresh' },
  { 'g?', 'Toggle help' },
}

--- @param ctx morph.Ctx<{}>
--- @return morph.Tree[]
local function ModelsHelp(ctx)
  return {
    h(Help, { page_keymaps = PAGE_KEYMAPS, common_keymaps = COMMON_KEYMAPS }),
    '\n',
    h.RenderMarkdownH1({}, '## Legend'),
    '\n',
    '🧠 Reasoning  🔧 Tools  📎 Attachments  🔓 Open weights  ⚠ Deprecated',
    '\n',
  }
end

--------------------------------------------------------------------------------
-- App Component
--------------------------------------------------------------------------------

--- @class models.AppState
--- @field show_help boolean
--- @field loading boolean
--- @field error? string
--- @field models models.Model[]
--- @field filter string
--- @field page number

--- @param ctx morph.Ctx<any, models.AppState>
local function App(ctx)
  local function refresh()
    local state = assert(ctx.state)
    state.loading = true
    state.error = nil
    ctx:update(state)

    fetch_models(function(models, err)
      state.models = models
      state.loading = false
      state.error = err
      ctx:update(state)
    end)
  end

  if ctx.phase == 'mount' then
    ctx.state = {
      show_help = false,
      loading = true,
      models = {},
      filter = '',
      page = 1,
    }
    vim.schedule(refresh)
  end

  local state = assert(ctx.state)

  -- Filter models
  local filter_term = vim.trim(state.filter or ''):lower()
  local filtered = vim
    .iter(state.models)
    :filter(function(model)
      if filter_term == '' then return true end
      return model.name:lower():find(filter_term, 1, true) ~= nil
        or model.provider:lower():find(filter_term, 1, true) ~= nil
        or model.id:lower():find(filter_term, 1, true) ~= nil
    end)
    :totable()

  -- Build table rows
  local rows = {
    {
      cells = {
        h.Constant({}, 'NAME'),
        h.Constant({}, 'PROVIDER'),
        h.Constant({}, 'CONTEXT'),
        h.Constant({}, 'IN'),
        h.Constant({}, 'OUT'),
        h.Constant({}, 'CAPS'),
      },
    },
  }

  for _, model in ipairs(filtered) do
    local name_hl = model.status == 'deprecated' and 'Comment' or 'Constant'
    table.insert(rows, {
      nmap = {
        ['gi'] = keymap(function()
          local json = vim.fn.json_encode(model.raw)
          local formatted = vim.fn.system({ 'jq', '.' }, json)
          create_scratch_buffer('vnew', 'json')
          vim.api.nvim_buf_set_lines(0, 0, -1, true, vim.split(formatted, '\n'))
        end),
      },
      cells = {
        h[name_hl]({}, model.name),
        h.String({}, model.provider),
        h.Number({}, format_context(model.limit.context)),
        h.Comment({}, format_cost(model.cost.input)),
        h.Comment({}, format_cost(model.cost.output)),
        capability_badges(model),
      },
    })
  end

  local page_size = math.max(10, vim.o.lines * 2)

  return h('text', {
    nmap = {
      ['<Leader>r'] = keymap(refresh),
      ['g?'] = keymap(function()
        state.show_help = not state.show_help
        ctx:update(state)
      end),
      ['[['] = function()
        local page = state.page
        if page and page > 1 then
          state.page = page - 1
          ctx:update(state)
        end
        return ''
      end,
      [']]'] = function()
        state.page = (state.page or 1) + 1
        ctx:update(state)
        return ''
      end,
    },
  }, {
    -- Header
    h.RenderMarkdownH1({}, 'AI Models'),
    ' ',
    h.NonText({}, 'models.dev'),
    ' ',
    h.NonText({}, 'g? for help'),
    '\n\n',

    -- Help panel
    state.show_help and h(ModelsHelp, {}),

    -- Error display
    state.error and { h.DiagnosticError({}, state.error), '\n\n' },

    -- Filter input
    h.Label({}, 'Filter: '),
    '[',
    h.String({
      on_change = function(e)
        state.filter = e.text
        state.page = 1
        ctx:update(state)
      end,
    }, state.filter),
    ']',
    ' ',
    state.loading and h.NonText({}, '(loading...)')
      or h.Comment({}, string.format('(%d models)', #filtered)),
    '\n\n',

    -- Table
    h(Table, {
      rows = rows,
      header = true,
      header_separator = true,
      page = state.page,
      page_size = page_size,
      on_page_changed = function(new_page)
        state.page = new_page
        ctx:update(state)
      end,
    }),
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
  vim.api.nvim_buf_set_name(0, 'models.dev')

  Morph.new(0):mount(h(App))
end

return M
