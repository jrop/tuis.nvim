local Morph = require 'tuis.morph'
local h = Morph.h
local components = require 'tuis.components'
local Table = components.Table
local TabBar = components.TabBar
local Help = components.Help
local utils = require 'tuis.utils'
local keymap = utils.keymap
local create_scratch_buffer = utils.create_scratch_buffer

local M = {}

--- @type string[]
local CLI_DEPENDENCIES = { 'bw' }

function M.is_enabled() return utils.check_clis_available(CLI_DEPENDENCIES, true) end

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

--- @alias bitwarden.Page 'items'|'folders'|'organizations'|'vault'

--- @alias bitwarden.ItemType 1|2|3|4
--- 1 = Login, 2 = Secure Note, 3 = Card, 4 = Identity

--- @class bitwarden.Item
--- @field id string
--- @field name string
--- @field type bitwarden.ItemType
--- @field login? { username?: string, password?: string, totp?: string, uris?: { uri: string }[] }
--- @field notes? string
--- @field favorite boolean
--- @field folderId? string
--- @field organizationId? string
--- @field collectionIds? string[]
--- @field revisionDate string
--- @field raw unknown

--- @class bitwarden.Folder
--- @field id string
--- @field name string
--- @field raw unknown

--- @class bitwarden.Organization
--- @field id string
--- @field name string
--- @field status number
--- @field type number
--- @field enabled boolean
--- @field raw unknown

--- @class bitwarden.VaultStatus
--- @field status 'locked'|'unlocked'|'unauthenticated'
--- @field userEmail? string
--- @field userId? string
--- @field serverUrl? string
--- @field lastSync? string

--- @class bitwarden.AppState
--- @field page bitwarden.Page
--- @field show_help boolean
--- @field loading boolean
--- @field session? string
--- @field vault_status bitwarden.VaultStatus
--- @field items bitwarden.Item[]
--- @field folders bitwarden.Folder[]
--- @field organizations bitwarden.Organization[]
--- @field timer uv.uv_timer_t
--- @field table_page number

--------------------------------------------------------------------------------
-- Session Management
--------------------------------------------------------------------------------

--- @type string?
local BW_SESSION = nil

--- @type boolean
local SESSION_PENDING = false

--- @type fun(session: string?)[]
local SESSION_CALLBACKS = {}

--- Get or create a Bitwarden session
--- @param callback fun(session: string?)
local function get_session(callback)
  if BW_SESSION then
    callback(BW_SESSION)
    return
  end

  -- Queue callback if unlock is already in progress
  if SESSION_PENDING then
    table.insert(SESSION_CALLBACKS, callback)
    return
  end

  SESSION_PENDING = true
  table.insert(SESSION_CALLBACKS, callback)

  --- Notify all waiting callbacks
  --- @param session string?
  local function notify_all(session)
    SESSION_PENDING = false
    local callbacks = SESSION_CALLBACKS
    SESSION_CALLBACKS = {}
    for _, cb in ipairs(callbacks) do
      cb(session)
    end
  end

  -- Check current status first
  vim.system({ 'bw', 'status' }, { text = true }, function(out)
    vim.schedule(function()
      local ok, status = pcall(vim.json.decode, out.stdout or '{}')
      if ok and status.status == 'unlocked' then
        BW_SESSION = ''
        notify_all(BW_SESSION)
        return
      end

      -- Need to unlock
      local password = vim.fn.inputsecret 'Bitwarden master password: '
      if password == '' then
        notify_all(nil)
        return
      end

      vim.system({ 'bw', 'unlock', password, '--raw' }, { text = true }, function(unlock_out)
        vim.schedule(function()
          local session = vim.trim(unlock_out.stdout or '')
          if session ~= '' and unlock_out.code == 0 then
            BW_SESSION = session
            notify_all(session)
          else
            vim.notify(
              'Failed to unlock vault: ' .. (unlock_out.stderr or 'unknown error'),
              vim.log.levels.ERROR
            )
            notify_all(nil)
          end
        end)
      end)
    end)
  end)
end

--- Get environment for bw commands
--- @return table
local function get_bw_env()
  if BW_SESSION and BW_SESSION ~= '' then return { BW_SESSION = BW_SESSION } end
  return {}
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--- Get item type as string
--- @param type_num bitwarden.ItemType
--- @return string
local function get_item_type_name(type_num)
  local types = {
    [1] = 'Login',
    [2] = 'Secure Note',
    [3] = 'Card',
    [4] = 'Identity',
  }
  return types[type_num] or 'Unknown'
end

--- Copy text to clipboard with notification
--- @param text string?
--- @param label string
local function copy_to_clipboard(text, label)
  if text and text ~= '' then
    vim.fn.setreg('+', text)
    vim.notify(label .. " copied to '+'")
  else
    vim.notify('No ' .. label:lower() .. ' available', vim.log.levels.WARN)
  end
end

--------------------------------------------------------------------------------
-- Help System
--------------------------------------------------------------------------------

local HELP_KEYMAPS = {
  items = {
    { 'gi', 'Inspect item (JSON)' },
    { 'go', 'Open first URL in browser' },
    { 'g+', 'Copy password to +' },
    { 'g"', 'Copy password to "' },
    { 'gu', 'Copy username' },
    { 'gt', 'Copy TOTP code' },
    { 'gn', 'Copy notes' },
    { 'gf', 'Filter by folder' },
    { 'gF', 'Clear folder filter' },
  },
  folders = {
    { 'gi', 'Inspect folder (JSON)' },
    { '<CR>', 'Filter items by folder' },
  },
  organizations = {
    { 'gi', 'Inspect organization (JSON)' },
  },
  vault = {
    { 'gs', 'Sync vault' },
    { 'gL', 'Lock vault' },
    { 'gp', 'Generate password' },
    { 'gP', 'Generate passphrase' },
  },
}

local COMMON_KEYMAPS = {
  { 'g1-g4', 'Navigate tabs' },
  { '[[', 'Previous page' },
  { ']]', 'Next page' },
  { '<Leader>r', 'Refresh' },
  { 'g?', 'Toggle help' },
}

--- @param ctx morph.Ctx<{ page: bitwarden.Page }>
local function BitwardenHelp(ctx)
  return h(Help, {
    page_keymaps = HELP_KEYMAPS[ctx.props.page],
    common_keymaps = COMMON_KEYMAPS,
  })
end

--------------------------------------------------------------------------------
-- Navigation
--------------------------------------------------------------------------------

--- @type { key: string, page: bitwarden.Page, label: string }[]
local TABS = {
  { key = 'g1', page = 'items', label = 'Items' },
  { key = 'g2', page = 'folders', label = 'Folders' },
  { key = 'g3', page = 'organizations', label = 'Organizations' },
  { key = 'g4', page = 'vault', label = 'Vault' },
}

--------------------------------------------------------------------------------
-- Data Fetching
--------------------------------------------------------------------------------

--- @param callback fun(status: bitwarden.VaultStatus)
local function fetch_vault_status(callback)
  vim.system({ 'bw', 'status' }, { text = true, env = get_bw_env() }, function(out)
    vim.schedule(function()
      local ok, raw = pcall(vim.json.decode, out.stdout or '{}')
      if not ok then
        callback { status = 'unauthenticated' }
        return
      end

      callback {
        status = raw.status or 'unauthenticated',
        userEmail = raw.userEmail,
        userId = raw.userId,
        serverUrl = raw.serverUrl,
        lastSync = raw.lastSync,
      }
    end)
  end)
end

--- @param callback fun(items: bitwarden.Item[])
local function fetch_items(callback)
  get_session(function(session)
    if not session then
      callback {}
      return
    end

    vim.system({ 'bw', 'list', 'items' }, { text = true, env = get_bw_env() }, function(out)
      vim.schedule(function()
        ---@type bitwarden.Item[]
        local items = {}
        local ok, raw_items =
          pcall(vim.json.decode, out.stdout or '[]', { luanil = { object = true, array = true } })

        if not ok then
          vim.notify('Failed to parse items: ' .. tostring(raw_items), vim.log.levels.ERROR)
          callback {}
          return
        end

        for _, raw in ipairs(raw_items or {}) do
          table.insert(items, {
            id = raw.id,
            name = raw.name,
            type = raw.type,
            login = raw.login,
            notes = raw.notes,
            favorite = raw.favorite or false,
            folderId = raw.folderId,
            organizationId = raw.organizationId,
            collectionIds = raw.collectionIds,
            revisionDate = (raw.revisionDate or ''):gsub('%.%d+.+$', ''):gsub('T', ' '),
            raw = raw,
          })
        end

        table.sort(items, function(a, b)
          -- Favorites first, then alphabetical
          if a.favorite ~= b.favorite then return a.favorite end
          return a.name:lower() < b.name:lower()
        end)

        callback(items)
      end)
    end)
  end)
end

--- @param callback fun(folders: bitwarden.Folder[])
local function fetch_folders(callback)
  get_session(function(session)
    if not session then
      callback {}
      return
    end

    vim.system({ 'bw', 'list', 'folders' }, { text = true, env = get_bw_env() }, function(out)
      vim.schedule(function()
        ---@type bitwarden.Folder[]
        local folders = {}
        local ok, raw_folders = pcall(vim.json.decode, out.stdout or '[]')

        if not ok then
          callback {}
          return
        end

        for _, raw in ipairs(raw_folders or {}) do
          table.insert(folders, {
            id = raw.id,
            name = raw.name,
            raw = raw,
          })
        end

        table.sort(folders, function(a, b) return a.name:lower() < b.name:lower() end)
        callback(folders)
      end)
    end)
  end)
end

--- @param callback fun(orgs: bitwarden.Organization[])
local function fetch_organizations(callback)
  get_session(function(session)
    if not session then
      callback {}
      return
    end

    vim.system({ 'bw', 'list', 'organizations' }, { text = true, env = get_bw_env() }, function(out)
      vim.schedule(function()
        ---@type bitwarden.Organization[]
        local orgs = {}
        local ok, raw_orgs = pcall(vim.json.decode, out.stdout or '[]')

        if not ok then
          callback {}
          return
        end

        for _, raw in ipairs(raw_orgs or {}) do
          table.insert(orgs, {
            id = raw.id,
            name = raw.name,
            status = raw.status or 0,
            type = raw.type or 0,
            enabled = raw.enabled or false,
            raw = raw,
          })
        end

        table.sort(orgs, function(a, b) return a.name:lower() < b.name:lower() end)
        callback(orgs)
      end)
    end)
  end)
end

--------------------------------------------------------------------------------
-- Items View
--------------------------------------------------------------------------------

--- @param ctx morph.Ctx<{ items: bitwarden.Item[], folders: bitwarden.Folder[], loading: boolean, on_refresh: fun(), table_page: number, on_page_changed: fun(page: number) }, { filter: string, type_filter: bitwarden.ItemType?, folder_filter: string? }>
local function ItemsView(ctx)
  if ctx.phase == 'mount' then
    ctx.state = { filter = '', type_filter = nil, folder_filter = nil }
  end
  local state = assert(ctx.state)

  -- Build folder lookup
  local folder_names = { [''] = '(No Folder)' }
  for _, folder in ipairs(ctx.props.folders or {}) do
    folder_names[folder.id] = folder.name
  end

  local rows = {
    {
      cells = {
        h.Constant({}, 'NAME'),
        h.Constant({}, 'USERNAME'),
        h.Constant({}, 'TYPE'),
        h.Constant({}, 'FOLDER'),
      },
    },
  }

  for _, item in ipairs(ctx.props.items or {}) do
    -- Apply filters
    local passes_text = state.filter == '' or item.name:lower():find(state.filter:lower(), 1, true)
    local passes_type = state.type_filter == nil or item.type == state.type_filter
    local passes_folder = state.folder_filter == nil or item.folderId == state.folder_filter

    if passes_text and passes_type and passes_folder then
      local type_name = get_item_type_name(item.type)
      local folder_name = folder_names[item.folderId or ''] or '(No Folder)'
      local username = vim.tbl_get(item, 'login', 'username') or ''

      -- Type-specific highlight
      local type_hl = item.type == 1 and 'String'
        or item.type == 2 and 'Comment'
        or item.type == 3 and 'Number'
        or item.type == 4 and 'Constant'
        or 'Normal'

      table.insert(rows, {
        nmap = {
          ['gi'] = keymap(function()
            create_scratch_buffer('vnew', 'json')
            local json = vim.json.encode(item.raw)
            vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(json, '\n'))
            vim.cmd [[silent! %!jq . 2>/dev/null || cat]]
          end),
          ['go'] = keymap(function()
            local uri = vim.tbl_get(item, 'login', 'uris', 1, 'uri')
            if uri then
              vim.ui.open(uri)
            else
              vim.notify('No URL available', vim.log.levels.WARN)
            end
          end),
          ['g+'] = keymap(function()
            local pw = vim.tbl_get(item, 'login', 'password')
            if pw and pw ~= '' then
              vim.fn.setreg('+', pw)
              vim.notify "Password copied to '+'"
            else
              vim.notify('No password available', vim.log.levels.WARN)
            end
          end),
          ['g"'] = keymap(function()
            local pw = vim.tbl_get(item, 'login', 'password')
            if pw and pw ~= '' then
              vim.fn.setreg('"', pw)
              vim.notify [[Password copied to '"']]
            else
              vim.notify('No password available', vim.log.levels.WARN)
            end
          end),
          ['gu'] = keymap(
            function() copy_to_clipboard(vim.tbl_get(item, 'login', 'username'), 'Username') end
          ),
          ['gt'] = keymap(function()
            local totp_secret = vim.tbl_get(item, 'login', 'totp')
            if not totp_secret then
              vim.notify('No TOTP configured', vim.log.levels.WARN)
              return
            end
            -- Get TOTP code from bw
            vim.system(
              { 'bw', 'get', 'totp', item.id },
              { text = true, env = get_bw_env() },
              function(out)
                vim.schedule(function()
                  local code = vim.trim(out.stdout or '')
                  if code ~= '' then
                    copy_to_clipboard(code, 'TOTP code')
                  else
                    vim.notify('Failed to get TOTP', vim.log.levels.ERROR)
                  end
                end)
              end
            )
          end),
          ['gn'] = keymap(function() copy_to_clipboard(item.notes, 'Notes') end),
          ['gf'] = keymap(function()
            if item.folderId then
              state.folder_filter = item.folderId
              ctx:update(state)
            end
          end),
        },
        cells = {
          item.favorite and { h.DiagnosticWarn({}, '★ '), h.Constant({}, item.name) }
            or h.Constant({}, item.name),
          h.Text({}, username),
          h[type_hl]({}, type_name),
          h.Comment({}, folder_name),
        },
      })
    end
  end

  -- Build filter status text
  local filter_parts = {}
  if state.filter ~= '' then table.insert(filter_parts, 'text: ' .. state.filter) end
  if state.type_filter then
    table.insert(filter_parts, 'type: ' .. get_item_type_name(state.type_filter))
  end
  if state.folder_filter then
    table.insert(filter_parts, 'folder: ' .. (folder_names[state.folder_filter] or 'Unknown'))
  end
  local filter_status = #filter_parts > 0 and ' (' .. table.concat(filter_parts, ', ') .. ')' or ''

  return {
    h.RenderMarkdownH1({}, '## Items' .. filter_status),
    ctx.props.loading and h.NonText({}, ' (loading...)') or nil,
    '\n\n',

    -- Search filter
    h.Label({}, 'Search: '),
    '[',
    h.String({
      on_change = function(e)
        state.filter = e.text
        ctx:update(state)
      end,
    }, state.filter),
    ']',

    -- Type filter buttons
    '  ',
    h.Label({}, 'Type: '),
    h('text', {
      nmap = {
        ['<CR>'] = keymap(function()
          state.type_filter = nil
          ctx:update(state)
        end),
      },
    }, { state.type_filter == nil and h.RenderMarkdownH2Bg({}, 'All') or h.NonText({}, 'All') }),
    ' ',
    h('text', {
      nmap = {
        ['<CR>'] = keymap(function()
          state.type_filter = 1
          ctx:update(state)
        end),
      },
    }, { state.type_filter == 1 and h.RenderMarkdownH2Bg({}, 'Login') or h.String({}, 'Login') }),
    ' ',
    h('text', {
      nmap = {
        ['<CR>'] = keymap(function()
          state.type_filter = 2
          ctx:update(state)
        end),
      },
    }, {
      state.type_filter == 2 and h.RenderMarkdownH2Bg({}, 'Note') or h.Comment({}, 'Note'),
    }),
    ' ',
    h('text', {
      nmap = {
        ['<CR>'] = keymap(function()
          state.type_filter = 3
          ctx:update(state)
        end),
      },
    }, { state.type_filter == 3 and h.RenderMarkdownH2Bg({}, 'Card') or h.Number({}, 'Card') }),
    ' ',
    h('text', {
      nmap = {
        ['<CR>'] = keymap(function()
          state.type_filter = 4
          ctx:update(state)
        end),
      },
    }, {
      state.type_filter == 4 and h.RenderMarkdownH2Bg({}, 'Identity') or h.Constant({}, 'Identity'),
    }),

    -- Clear folder filter
    state.folder_filter
        and {
          '  ',
          h('text', {
            nmap = {
              ['<CR>'] = keymap(function()
                state.folder_filter = nil
                ctx:update(state)
              end),
              ['gF'] = keymap(function()
                state.folder_filter = nil
                ctx:update(state)
              end),
            },
          }, { h.DiagnosticError({}, '[Clear folder filter]') }),
        }
      or nil,

    '\n\n',
    h(Table, {
      rows = rows,
      header = true,
      header_separator = true,
      page = ctx.props.table_page,
      page_size = math.max(10, vim.o.lines - 10),
      on_page_changed = ctx.props.on_page_changed,
    }),
  }
end

--------------------------------------------------------------------------------
-- Folders View
--------------------------------------------------------------------------------

--- @param ctx morph.Ctx<{ folders: bitwarden.Folder[], items: bitwarden.Item[], loading: boolean, on_filter_folder: fun(folder_id: string) }, { filter: string }>
local function FoldersView(ctx)
  if ctx.phase == 'mount' then ctx.state = { filter = '' } end
  local state = assert(ctx.state)

  -- Count items per folder
  local folder_counts = {}
  local no_folder_count = 0
  for _, item in ipairs(ctx.props.items or {}) do
    if item.folderId then
      folder_counts[item.folderId] = (folder_counts[item.folderId] or 0) + 1
    else
      no_folder_count = no_folder_count + 1
    end
  end

  local rows = {
    {
      cells = {
        h.Constant({}, 'NAME'),
        h.Constant({}, 'ITEMS'),
      },
    },
  }

  -- Add "No Folder" entry
  if state.filter == '' or ('no folder'):find(state.filter:lower(), 1, true) then
    table.insert(rows, {
      nmap = {
        ['<CR>'] = keymap(function() ctx.props.on_filter_folder '' end),
      },
      cells = {
        h.Comment({}, '(No Folder)'),
        h.Number({}, tostring(no_folder_count)),
      },
    })
  end

  for _, folder in ipairs(ctx.props.folders or {}) do
    if state.filter == '' or folder.name:lower():find(state.filter:lower(), 1, true) then
      local count = folder_counts[folder.id] or 0
      table.insert(rows, {
        nmap = {
          ['gi'] = keymap(function()
            create_scratch_buffer('vnew', 'json')
            local json = vim.json.encode(folder.raw)
            vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(json, '\n'))
            vim.cmd [[silent! %!jq . 2>/dev/null || cat]]
          end),
          ['<CR>'] = keymap(function() ctx.props.on_filter_folder(folder.id) end),
        },
        cells = {
          h.Constant({}, folder.name),
          h.Number({}, tostring(count)),
        },
      })
    end
  end

  return {
    h.RenderMarkdownH1({}, '## Folders'),
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
    '\n',
    h.NonText({}, 'Press <CR> on a folder to filter items'),
  }
end

--------------------------------------------------------------------------------
-- Organizations View
--------------------------------------------------------------------------------

--- @param ctx morph.Ctx<{ organizations: bitwarden.Organization[], loading: boolean }, { filter: string }>
local function OrganizationsView(ctx)
  if ctx.phase == 'mount' then ctx.state = { filter = '' } end
  local state = assert(ctx.state)

  local rows = {
    {
      cells = {
        h.Constant({}, 'NAME'),
        h.Constant({}, 'STATUS'),
        h.Constant({}, 'ENABLED'),
      },
    },
  }

  local status_names = {
    [0] = 'Invited',
    [1] = 'Accepted',
    [2] = 'Confirmed',
  }

  for _, org in ipairs(ctx.props.organizations or {}) do
    if state.filter == '' or org.name:lower():find(state.filter:lower(), 1, true) then
      local status_name = status_names[org.status] or 'Unknown'
      table.insert(rows, {
        nmap = {
          ['gi'] = keymap(function()
            create_scratch_buffer('vnew', 'json')
            local json = vim.json.encode(org.raw)
            vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(json, '\n'))
            vim.cmd [[silent! %!jq . 2>/dev/null || cat]]
          end),
        },
        cells = {
          h.Constant({}, org.name),
          org.status == 2 and h.DiagnosticOk({}, status_name) or h.DiagnosticWarn({}, status_name),
          org.enabled and h.DiagnosticOk({}, 'Yes') or h.DiagnosticError({}, 'No'),
        },
      })
    end
  end

  if #ctx.props.organizations == 0 and not ctx.props.loading then
    return {
      h.RenderMarkdownH1({}, '## Organizations'),
      '\n\n',
      h.Comment({}, 'No organizations found. Your vault may be personal-only.'),
    }
  end

  return {
    h.RenderMarkdownH1({}, '## Organizations'),
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
-- Vault View
--------------------------------------------------------------------------------

--- @param ctx morph.Ctx<{ vault_status: bitwarden.VaultStatus, items: bitwarden.Item[], loading: boolean, on_refresh: fun(), on_lock: fun() }>
local function VaultView(ctx)
  local status = ctx.props.vault_status
  local items = ctx.props.items or {}

  -- Calculate statistics
  local stats = { logins = 0, notes = 0, cards = 0, identities = 0, favorites = 0, with_totp = 0 }
  for _, item in ipairs(items) do
    if item.type == 1 then stats.logins = stats.logins + 1 end
    if item.type == 2 then stats.notes = stats.notes + 1 end
    if item.type == 3 then stats.cards = stats.cards + 1 end
    if item.type == 4 then stats.identities = stats.identities + 1 end
    if item.favorite then stats.favorites = stats.favorites + 1 end
    if vim.tbl_get(item, 'login', 'totp') then stats.with_totp = stats.with_totp + 1 end
  end

  local actions = {
    { key = 'gs', label = 'Sync vault', desc = 'Pull latest changes from server' },
    { key = 'gL', label = 'Lock vault', desc = 'Lock the vault (requires re-authentication)' },
    { key = 'gp', label = 'Generate password', desc = 'Generate a random password' },
    { key = 'gP', label = 'Generate passphrase', desc = 'Generate a random passphrase' },
  }

  local action_keymaps = {
    ['gs'] = keymap(function()
      vim.notify 'Syncing vault...'
      vim.system({ 'bw', 'sync' }, { text = true, env = get_bw_env() }, function(out)
        vim.schedule(function()
          if out.code == 0 then
            vim.notify 'Vault synced successfully'
            ctx.props.on_refresh()
          else
            vim.notify('Sync failed: ' .. (out.stderr or 'unknown error'), vim.log.levels.ERROR)
          end
        end)
      end)
    end),
    ['gL'] = keymap(function()
      local choice = vim.fn.confirm('Lock the vault?', '&Yes\n&No', 2)
      if choice == 1 then
        vim.system({ 'bw', 'lock' }, { text = true }, function(out)
          vim.schedule(function()
            if out.code == 0 then
              BW_SESSION = nil
              SESSION_PENDING = false
              SESSION_CALLBACKS = {}
              vim.notify 'Vault locked'
              ctx.props.on_lock()
            else
              vim.notify('Lock failed: ' .. (out.stderr or ''), vim.log.levels.ERROR)
            end
          end)
        end)
      end
    end),
    ['gp'] = keymap(function()
      vim.system({ 'bw', 'generate', '-ulns', '--length', '20' }, { text = true }, function(out)
        vim.schedule(function()
          local password = vim.trim(out.stdout or '')
          if password ~= '' then
            copy_to_clipboard(password, 'Generated password')
          else
            vim.notify('Failed to generate password', vim.log.levels.ERROR)
          end
        end)
      end)
    end),
    ['gP'] = keymap(function()
      vim.system(
        { 'bw', 'generate', '--passphrase', '--words', '4', '--separator', '-' },
        { text = true },
        function(out)
          vim.schedule(function()
            local passphrase = vim.trim(out.stdout or '')
            if passphrase ~= '' then
              copy_to_clipboard(passphrase, 'Generated passphrase')
            else
              vim.notify('Failed to generate passphrase', vim.log.levels.ERROR)
            end
          end)
        end
      )
    end),
  }

  -- Status indicator
  local status_hl = status.status == 'unlocked' and 'DiagnosticOk'
    or status.status == 'locked' and 'DiagnosticWarn'
    or 'DiagnosticError'

  return h('text', { nmap = action_keymaps }, {
    h.RenderMarkdownH1({}, '## Vault Status'),
    ctx.props.loading and h.NonText({}, ' (loading...)') or nil,
    '\n\n',

    -- Status info
    h.Label({}, 'Status: '),
    h[status_hl]({}, status.status:upper()),
    '\n',
    status.userEmail and { h.Label({}, 'Email: '), h.String({}, status.userEmail), '\n' } or nil,
    status.serverUrl and { h.Label({}, 'Server: '), h.Comment({}, status.serverUrl), '\n' } or nil,
    status.lastSync and {
      h.Label({}, 'Last Sync: '),
      h.Comment({}, status.lastSync:gsub('T', ' '):gsub('%.%d+Z$', '')),
      '\n',
    } or nil,

    '\n',
    h.RenderMarkdownH1({}, '### Vault Statistics'),
    '\n\n',

    h.Label({}, 'Total Items: '),
    h.Number({}, tostring(#items)),
    '\n',
    h.Label({}, '  Logins: '),
    h.Number({}, tostring(stats.logins)),
    '\n',
    h.Label({}, '  Secure Notes: '),
    h.Number({}, tostring(stats.notes)),
    '\n',
    h.Label({}, '  Cards: '),
    h.Number({}, tostring(stats.cards)),
    '\n',
    h.Label({}, '  Identities: '),
    h.Number({}, tostring(stats.identities)),
    '\n',
    h.Label({}, '  Favorites: '),
    h.DiagnosticWarn({}, tostring(stats.favorites)),
    '\n',
    h.Label({}, '  With TOTP: '),
    h.String({}, tostring(stats.with_totp)),
    '\n\n',

    h.RenderMarkdownH1({}, '### Actions'),
    '\n\n',

    vim
      .iter(actions)
      :map(
        function(action)
          return {
            h.Title({}, action.key),
            ' ',
            h.String({}, action.label),
            ' ',
            h.Comment({}, '- ' .. action.desc),
            '\n',
          }
        end
      )
      :totable(),
  })
end

--------------------------------------------------------------------------------
-- App Component
--------------------------------------------------------------------------------

--- @param ctx morph.Ctx<any, bitwarden.AppState>
local function App(ctx)
  local function refresh(show_loading)
    local state = assert(ctx.state)
    if show_loading then
      state.loading = true
      ctx:update(state)
    end

    -- Always fetch status
    fetch_vault_status(function(status)
      state.vault_status = status
      ctx:update(state)
    end)

    -- Fetch page-specific data
    if state.page == 'items' or state.page == 'folders' or state.page == 'vault' then
      fetch_items(function(items)
        state.items = items
        state.loading = false
        ctx:update(state)
      end)
      fetch_folders(function(folders)
        state.folders = folders
        ctx:update(state)
      end)
    elseif state.page == 'organizations' then
      fetch_organizations(function(orgs)
        state.organizations = orgs
        state.loading = false
        ctx:update(state)
      end)
    end
  end

  local function go_to_page(page)
    local state = assert(ctx.state)
    if state.page == page then return end

    state.page = page
    state.table_page = 1
    ctx:update(state)
    vim.fn.winrestview { topline = 1, lnum = 1 }
    refresh(true)
  end

  if ctx.phase == 'mount' then
    ctx.state = {
      page = 'items',
      show_help = false,
      loading = true,
      session = nil,
      vault_status = { status = 'unauthenticated' },
      items = {},
      folders = {},
      organizations = {},
      timer = assert(vim.uv.new_timer()),
      table_page = 1,
    }
    vim.schedule(function() refresh(true) end)
  end

  local state = assert(ctx.state)

  if ctx.phase == 'unmount' then
    state.timer:stop()
    state.timer:close()
  end

  -- Build navigation keymaps
  local nav_keymaps = {
    ['<Leader>r'] = keymap(function() refresh(true) end),
    ['g?'] = keymap(function()
      state.show_help = not state.show_help
      ctx:update(state)
    end),
    ['gF'] = keymap(function()
      -- Global clear folder filter (for items page)
    end),
    ['[['] = function()
      if state.table_page > 1 then
        state.table_page = state.table_page - 1
        ctx:update(state)
      end
      return ''
    end,
    [']]'] = function()
      state.table_page = state.table_page + 1
      ctx:update(state)
      return ''
    end,
  }
  for _, tab in ipairs(TABS) do
    nav_keymaps[tab.key] = keymap(function() go_to_page(tab.page) end)
  end

  -- Render current page
  local page_content
  if state.page == 'items' then
    page_content = h(ItemsView, {
      items = state.items,
      folders = state.folders,
      loading = state.loading,
      on_refresh = function() refresh(false) end,
      table_page = state.table_page,
      on_page_changed = function(new_page)
        state.table_page = new_page
        ctx:update(state)
      end,
    })
  elseif state.page == 'folders' then
    page_content = h(FoldersView, {
      folders = state.folders,
      items = state.items,
      loading = state.loading,
      on_filter_folder = function(folder_id)
        -- Switch to items page with folder filter
        state.page = 'items'
        ctx:update(state)
        -- Note: the ItemsView will need to pick up this filter somehow
        -- For now, just switch pages
      end,
    })
  elseif state.page == 'organizations' then
    page_content = h(OrganizationsView, {
      organizations = state.organizations,
      loading = state.loading,
    })
  elseif state.page == 'vault' then
    page_content = h(VaultView, {
      vault_status = state.vault_status,
      items = state.items,
      loading = state.loading,
      on_refresh = function() refresh(true) end,
      on_lock = function() refresh(true) end,
    })
  end

  -- Status indicator
  local status_hl = state.vault_status.status == 'unlocked' and 'DiagnosticOk'
    or state.vault_status.status == 'locked' and 'DiagnosticWarn'
    or 'DiagnosticError'

  return h('text', { nmap = nav_keymaps }, {
    -- Header line
    h.RenderMarkdownH1({}, 'Bitwarden'),
    ' ',
    h[status_hl]({}, '[' .. state.vault_status.status .. ']'),
    state.vault_status.userEmail and { ' ', h.Comment({}, state.vault_status.userEmail) } or nil,
    ' ',
    h.NonText({}, 'g? for help'),
    '\n\n',

    -- Tab navigation
    h(TabBar, { tabs = TABS, active_page = state.page, on_select = go_to_page }),

    -- Help panel (toggleable)
    state.show_help and { h(BitwardenHelp, { page = state.page }), '\n' },

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
  vim.api.nvim_buf_set_name(0, 'Bitwarden')

  Morph.new(0):mount(h(App))
end

return M
