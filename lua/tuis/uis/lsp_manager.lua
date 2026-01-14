local Morph = require 'tuis.morph'
local h = Morph.h
local components = require 'tuis.components'
local Table = components.Table
local Help = components.Help
local utils = require 'tuis.utils'

local M = {}

function M.is_enabled() return true end

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

--- @class morphui.lsp.LspClient
--- @field id integer
--- @field name string
--- @field root_dir string|nil
--- @field filetypes string[]
--- @field buffers integer[]
--- @field status string
--- @field raw vim.lsp.Client

--- @class morphui.lsp.AppState
--- @field loading boolean
--- @field clients morphui.lsp.LspClient[]
--- @field show_help boolean

--- @class morphui.lsp.ClientsState
--- @field filter string

--------------------------------------------------------------------------------
-- Helper Functions
--------------------------------------------------------------------------------

--- Get all LSP clients attached to buffers
--- @return morphui.lsp.LspClient[]
local function get_lsp_clients()
  local clients = {}
  local all_clients = vim.lsp.get_clients()

  for _, client in ipairs(all_clients) do
    --- @type morphui.lsp.LspClient
    local lsp_client = {
      id = client.id,
      name = client.name,
      root_dir = client.config.root_dir,
      ---@diagnostic disable-next-line: undefined-field
      filetypes = client.config.filetypes or {},
      buffers = vim.tbl_keys(client.attached_buffers),
      status = client:is_stopped() and 'stopped' or 'running',
      raw = client,
    }
    table.insert(clients, lsp_client)
  end

  table.sort(clients, function(a, b) return a.name < b.name end)
  return clients
end

--------------------------------------------------------------------------------
-- Components
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Help Component
--------------------------------------------------------------------------------

local HELP_KEYMAPS = {
  { 'gi', 'Show LSP client details (JSON)' },
  { 'gk', 'Stop LSP client' },
  { 'gl', 'Show LSP logs' },
  { '<Leader>r', 'Refresh LSP clients' },
  { 'g?', 'Toggle this help' },
}

--- @param ctx morph.Ctx<{ show_help: boolean }, any>
local function LspHelp(ctx)
  if not ctx.props.show_help then return {} end
  return h(Help, { common_keymaps = HELP_KEYMAPS })
end

--------------------------------------------------------------------------------
-- LSP Clients Component
--------------------------------------------------------------------------------

--- @param ctx morph.Ctx<{ refresh_clients: fun(), clients: morphui.lsp.LspClient[] }, morphui.lsp.ClientsState>
local function LspClients(ctx)
  if ctx.phase == 'mount' then ctx.state = { filter = '' } end
  local state = assert(ctx.state)

  local clients_h_table = {}

  table.insert(clients_h_table, {
    cells = {
      h.Constant({}, 'NAME'),
      h.Constant({}, 'STATUS'),
      h.Constant({}, 'ROOT DIR'),
      h.Constant({}, 'BUFFERS'),
    },
  })

  for _, client in ipairs(ctx.props.clients) do
    local matches_filter = utils.create_filter_fn(state.filter)
    local passes_filter = matches_filter(client.name)
    if passes_filter then
      table.insert(clients_h_table, {
        nmap = {
          ['gi'] = function()
            vim.schedule(function()
              vim.cmd.vnew()
              vim.cmd.setfiletype 'lua'
              vim.bo.buftype = 'nofile'
              vim.bo.bufhidden = 'wipe'
              vim.bo.buflisted = false
              vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(vim.inspect(client.raw), '\n'))
            end)
            return ''
          end,
          ['gk'] = function()
            vim.schedule(function()
              vim.lsp.stop_client(client.id, false)
              ctx.props.refresh_clients()
            end)
            return ''
          end,
          ['gl'] = function()
            vim.schedule(function() vim.cmd 'LspLog' end)
            return ''
          end,
        },
        cells = {
          h.Constant({}, client.name),
          client.status == 'running' and h.String({}, client.status) or h.Error({}, client.status),
          h.Directory({}, client.root_dir or 'N/A'),
          h.Number({
            nmap = {
              ['<CR>'] = function()
                if #client.buffers == 0 then return '' end
                vim.schedule(function()
                  local buffer_names = {}
                  for _, bufnr in ipairs(client.buffers) do
                    local name = vim.api.nvim_buf_get_name(bufnr)
                    if name == '' then
                      name = '[No Name] (buf ' .. bufnr .. ')'
                    else
                      name = vim.fn.fnamemodify(name, ':~:.')
                    end
                    table.insert(buffer_names, { name = name, bufnr = bufnr })
                  end

                  vim.ui.select(buffer_names, {
                    prompt = 'Select buffer to open in new tab:',
                    format_item = function(item) return item.name end,
                  }, function(choice)
                    if choice then
                      vim.cmd.tabnew()
                      vim.cmd.buffer(choice.bufnr)
                    end
                  end)
                end)
                return ''
              end,
            },
          }, tostring(#client.buffers)),
        },
      })
    end
  end

  return {
    h.RenderMarkdownH1(
      {},
      ('## Clients%s'):format(#state.filter > 0 and ' (filter: ' .. state.filter .. ')' or '')
    ),

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

    ctx.props.clients and '\n\n' or '',

    h(Table, {
      rows = clients_h_table,
      page_size = math.max(10, vim.o.lines - 10),
    }),
  }
end

--------------------------------------------------------------------------------
-- App Component
--------------------------------------------------------------------------------

--- @param ctx morph.Ctx<any, morphui.lsp.AppState>
local function App(ctx)
  --
  -- Helper: refresh_clients:
  local refresh_clients = vim.schedule_wrap(function()
    local state = assert(ctx.state)
    state.loading = true
    ctx:update(state)

    vim.defer_fn(function()
      local clients = get_lsp_clients()
      state.loading = false
      state.clients = clients
      ctx:update(state)
    end, 100)
  end)

  if ctx.phase == 'mount' then
    -- Initialize state:
    ctx.state = {
      loading = false,
      clients = {},
      show_help = false,
    }
    refresh_clients()
  end
  local state = assert(ctx.state)

  return h('text', {
    -- Global maps:
    nmap = {
      ['<Leader>r'] = function()
        refresh_clients()
        return ''
      end,
      ['g?'] = function()
        state.show_help = not state.show_help
        ctx:update(state)
        return ''
      end,
    },
  }, {
    -- Header line
    h.RenderMarkdownH1({}, 'LSP Manager'),
    ' ',
    h.NonText({}, 'g? for help'),
    '\n\n',

    --
    -- Help (if enabled)
    --
    state.show_help
      and {
        h(LspHelp, {
          show_help = state.show_help,
        }),
        '\n\n',
      },

    --
    -- List of LSP clients
    --
    {
      h(LspClients, {
        refresh_clients = refresh_clients,
        clients = state.clients,
      }),
    },
  })
end

--------------------------------------------------------------------------------
-- Buffer/Render
--------------------------------------------------------------------------------

function M.show()
  vim.cmd.tabnew()
  vim.bo.buftype = 'nofile'
  vim.bo.bufhidden = 'wipe'
  vim.b.completion = false
  vim.wo[0][0].list = false
  vim.api.nvim_buf_set_name(0, 'LSP Manager')

  Morph.new(0):mount(h(App))
end

return M
