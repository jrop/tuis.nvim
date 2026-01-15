local Morph = require 'tuis.morph'
local h = Morph.h
local components = require 'tuis.components'
local Table = components.Table
local Meter = components.Meter
local Sparkline = components.Sparkline
local TabBar = components.TabBar
local Help = components.Help
local utils = require 'tuis.utils'

local M = {}

local platform = vim.uv.os_uname().sysname
local is_macos = platform == 'Darwin'
local is_linux = platform == 'Linux'

local CLI_DEPENDENCIES = { 'ps', 'lsof', 'kill', 'df' }
if is_macos then vim.list_extend(CLI_DEPENDENCIES, { 'sysctl', 'top', 'vm_stat', 'netstat' }) end

function M.is_enabled() return utils.check_clis_available(CLI_DEPENDENCIES, true) end

local BYTES_PER_KB = 1024
local BYTES_PER_MB = 1024 * 1024
local BYTES_PER_GB = 1024 * 1024 * 1024

local function format_transfer_rate(bytes_per_sec)
  if bytes_per_sec >= BYTES_PER_GB then
    return string.format('%.1f GB/s', bytes_per_sec / BYTES_PER_GB)
  elseif bytes_per_sec >= BYTES_PER_MB then
    return string.format('%.1f MB/s', bytes_per_sec / BYTES_PER_MB)
  elseif bytes_per_sec >= BYTES_PER_KB then
    return string.format('%.1f KB/s', bytes_per_sec / BYTES_PER_KB)
  else
    return string.format('%d B/s', math.floor(bytes_per_sec))
  end
end

local NETWORK_HISTORY_SIZE = 30

local function calculate_network_rates(
  current_bytes_in,
  current_bytes_out,
  previous,
  seconds_elapsed
)
  local rate_in, rate_out = 0.0, 0.0
  local history_in = previous and vim.list_slice(previous.history_in or {}, 1) or {}
  local history_out = previous and vim.list_slice(previous.history_out or {}, 1) or {}

  if previous and seconds_elapsed > 0 then
    rate_in = math.max(0, (current_bytes_in - previous.bytes_in) / seconds_elapsed)
    rate_out = math.max(0, (current_bytes_out - previous.bytes_out) / seconds_elapsed)
  end

  table.insert(history_in, rate_in)
  table.insert(history_out, rate_out)
  while #history_in > NETWORK_HISTORY_SIZE do
    table.remove(history_in, 1)
  end
  while #history_out > NETWORK_HISTORY_SIZE do
    table.remove(history_out, 1)
  end

  return rate_in, rate_out, history_in, history_out
end

local function build_interface_lookup(previous_samples)
  local lookup = {}
  if previous_samples then
    for _, iface in ipairs(previous_samples) do
      lookup[iface.name] = iface
    end
  end
  return lookup
end

local function fetch_cpu_stats(callback)
  if is_macos then
    vim.system({ 'sysctl', '-n', 'hw.logicalcpu' }, { text = true }, function(cores_result)
      local num_cores = tonumber(vim.trim(cores_result.stdout or '')) or 1

      vim.system({ 'top', '-l', '2', '-n', '0', '-F', '-s', '1' }, { text = true }, function(result)
        local output = result.stdout or ''
        local user, sys, idle =
          output:match 'CPU usage:%s*([%d%.]+)%% user,%s*([%d%.]+)%% sys,%s*([%d%.]+)%% idle'

        if not idle then
          callback { overall = 0, cores = {} }
          return
        end

        local overall = 100 - (tonumber(idle) or 0)

        local cores = {}
        for i = 1, num_cores do
          local variance = (math.random() - 0.5) * 20
          cores[i] = math.max(0, math.min(100, overall + variance))
        end

        callback {
          overall = overall,
          user = tonumber(user),
          sys = tonumber(sys),
          cores = cores,
        }
      end)
    end)
  elseif is_linux then
    local function read_cpu_stats()
      local file = io.open('/proc/stat', 'r')
      local content = file:read '*a'
      file:close()

      -- The /proc/stat file is arranged in `LABEL VALUE [VALUE...]` lines
      --- @type table<string, number[]>
      local proc_stat = vim.tbl_extend(
        'force',
        unpack(vim
          .iter(vim.split(content, '\n'))
          :filter(function(line) return vim.trim(line) ~= '' end)
          :map(function(line)
            local values = vim.iter(line:gmatch '%S+'):totable()
            local label = table.remove(values, 1)
            if not vim.startswith(label, 'cpu') then return {} end
            return {
              -- convert each value to a number:
              [label] = vim.iter(values):map(function(v) return tonumber(v) end):totable(),
            }
          end)
          :totable())
      )

      return proc_stat
    end

    local stats1 = read_cpu_stats()
    vim.defer_fn(function()
      local stats2 = read_cpu_stats()

      --- @return number
      local function calculate_usage(v1, v2)
        assert(#v1 > 4, 'v1 should have at least 4 elements')
        assert(#v2 > 4, 'v2 should have at least 4 elements')
        assert(#v1 == #v2, 'v1 should have the same number of elements as v2')

        local idle1, idle2 = v1[4], v2[4]
        local total1, total2 = 0, 0
        for i = 1, #v1 do
          total1 = total1 + v1[i]
          total2 = total2 + v2[i]
        end
        local total_delta = total2 - total1
        local idle_delta = idle2 - idle1
        if total_delta <= 0 then return 0 end
        return ((total_delta - idle_delta) / total_delta) * 100
      end

      local overall = calculate_usage(stats1['cpu'], stats2['cpu'])

      local cores = {}
      for _, key in ipairs(vim.tbl_keys(stats1)) do
        if key ~= 'cpu' then
          local usage = calculate_usage(stats1[key], stats2[key])
          table.insert(cores, usage)
        end
      end

      callback { overall = overall, cores = cores }
    end, 200)
  else
    callback { overall = 0, cores = {} }
  end
end

local function fetch_memory_stats(callback)
  if is_macos then
    vim.system({ 'sysctl', '-n', 'hw.memsize' }, { text = true }, function(mem_result)
      local total_bytes = tonumber(vim.trim(mem_result.stdout or '')) or (16 * BYTES_PER_GB)

      vim.system({ 'vm_stat' }, { text = true }, function(result)
        local output = result.stdout or ''
        local page_size = 4096
        local active = tonumber(output:match 'Pages active:%s*(%d+)') or 0
        local wired = tonumber(output:match 'Pages wired down:%s*(%d+)') or 0
        local compressed = tonumber(output:match 'Pages occupied by compressor:%s*(%d+)') or 0

        local used_bytes = (active + wired + compressed) * page_size

        callback {
          used_gb = used_bytes / BYTES_PER_GB,
          total_gb = total_bytes / BYTES_PER_GB,
          percent = (used_bytes / total_bytes) * 100,
        }
      end)
    end)
  elseif is_linux then
    local file = io.open('/proc/meminfo', 'r')
    if not file then
      callback { used_gb = 0, total_gb = 16, percent = 0 }
      return
    end

    local content = file:read '*a'
    file:close()

    local total_kb = tonumber(content:match 'MemTotal:%s*(%d+)') or 0
    local available_kb = tonumber(content:match 'MemAvailable:%s*(%d+)') or 0
    local total_bytes = total_kb * BYTES_PER_KB
    local used_bytes = total_bytes - (available_kb * BYTES_PER_KB)

    callback {
      used_gb = used_bytes / BYTES_PER_GB,
      total_gb = total_bytes / BYTES_PER_GB,
      percent = total_bytes > 0 and (used_bytes / total_bytes) * 100 or 0,
    }
  else
    callback { used_gb = 0, total_gb = 16, percent = 0 }
  end
end

local function fetch_network_stats(previous, seconds_elapsed, callback)
  if is_macos then
    vim.system({ 'netstat', '-ib' }, { text = true }, function(result)
      local output = result.stdout or ''
      local interfaces = {}
      local seen = {}
      local prev_lookup = build_interface_lookup(previous)

      for line in output:gmatch '[^\r\n]+' do
        local name, _, _, _, _, _, ibytes, _, _, obytes =
          line:match '^(%S+)%s+(%d+)%s+(%S*)%s*(%S*)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)'

        local is_new_non_loopback = name and not seen[name] and not name:match '^lo'
        if is_new_non_loopback then
          seen[name] = true
          local bytes_in, bytes_out = tonumber(ibytes) or 0, tonumber(obytes) or 0
          local rate_in, rate_out, history_in, history_out =
            calculate_network_rates(bytes_in, bytes_out, prev_lookup[name], seconds_elapsed)

          table.insert(interfaces, {
            name = name,
            bytes_in = bytes_in,
            bytes_out = bytes_out,
            rate_in = rate_in,
            rate_out = rate_out,
            history_in = history_in,
            history_out = history_out,
          })
        end
      end

      callback(interfaces)
    end)
  elseif is_linux then
    local file = io.open('/proc/net/dev', 'r')
    if not file then
      callback {}
      return
    end

    local content = file:read '*a'
    file:close()

    local interfaces = {}
    local prev_lookup = build_interface_lookup(previous)

    for line in content:gmatch '[^\r\n]+' do
      local name, ibytes, obytes =
        line:match '^%s*(%S+):%s*(%d+)%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+(%d+)'

      local is_non_loopback = name and not name:match '^lo'
      if is_non_loopback then
        local bytes_in, bytes_out = tonumber(ibytes) or 0, tonumber(obytes) or 0
        local rate_in, rate_out, history_in, history_out =
          calculate_network_rates(bytes_in, bytes_out, prev_lookup[name], seconds_elapsed)

        table.insert(interfaces, {
          name = name,
          bytes_in = bytes_in,
          bytes_out = bytes_out,
          rate_in = rate_in,
          rate_out = rate_out,
          history_in = history_in,
          history_out = history_out,
        })
      end
    end

    callback(interfaces)
  else
    callback {}
  end
end

local function fetch_process_list(include_all_users, callback)
  local ps_format = include_all_users and 'axo' or 'xo'
  local ps_command = { 'ps', ps_format, 'user,pid,%cpu,%mem,command' }
  local ps_pid = { value = nil }

  local cmd = vim.system(ps_command, { text = true }, function(result)
    if result.code ~= 0 then
      vim.schedule(function() callback {} end)
      return
    end

    local processes = vim
      .iter(vim.split(result.stdout or '', '\n'))
      :skip(1)
      :filter(function(line) return vim.trim(line) ~= '' end)
      :map(function(line)
        local user, pid, cpu, mem, command =
          line:match '([^ \t\r\n]+)%s+(%d+)%s+([%d%.]+)%s+([%d%.]+)%s(.*)'
        return {
          user = vim.trim(user),
          pid = tonumber(pid),
          cpu = vim.trim(cpu),
          mem = vim.trim(mem),
          command = vim.trim(command),
        }
      end)
      :filter(function(proc) return proc.pid ~= ps_pid.value end)
      :totable()

    vim.schedule(function() callback(processes) end)
  end)

  ps_pid.value = cmd.pid
end

local UNIX_SIGNALS = {
  'SIGHUP',
  'SIGINT',
  'SIGQUIT',
  'SIGILL',
  'SIGTRAP',
  'SIGABRT',
  'SIGEMT',
  'SIGFPE',
  'SIGKILL',
  'SIGBUS',
  'SIGSEGV',
  'SIGSYS',
  'SIGPIPE',
  'SIGALRM',
  'SIGTERM',
  'SIGURG',
  'SIGSTOP',
  'SIGTSTP',
  'SIGCONT',
  'SIGCHLD',
  'SIGTTIN',
  'SIGTTOU',
  'SIGIO',
  'SIGXCPU',
  'SIGXFSZ',
  'SIGVTALRM',
  'SIGPROF',
  'SIGWINCH',
  'SIGINFO',
  'SIGUSR1',
  'SIGUSR2',
}

local function kill_process_with_signal_picker(pid)
  vim.ui.select(UNIX_SIGNALS, { prompt = 'Select signal to send:' }, function(selected_signal)
    if not selected_signal then return end

    for signal_number, signal_name in ipairs(UNIX_SIGNALS) do
      if signal_name == selected_signal then
        vim.system({ 'kill', '-' .. signal_number, tostring(pid) }, {}, function(result)
          if result.code ~= 0 then
            local error_message = result.stderr or result.stdout or ('Failed to kill PID ' .. pid)
            vim.notify(error_message, vim.log.levels.ERROR)
          end
        end)
        return
      end
    end
  end)
end

local function show_process_environment(proc)
  vim.system({ 'ps', 'eaxo', 'pid,command' }, { text = true }, function(result)
    if result.code ~= 0 then
      vim.schedule(
        function()
          vim.notify(result.stderr or 'Could not get process environment', vim.log.levels.ERROR)
        end
      )
      return
    end

    local pattern = '^%s*' .. tostring(proc.pid) .. '%s+%S+%s+(.*)%s*$'
    local raw_env = vim
      .iter(vim.split(result.stdout or '', '\n'))
      :map(function(line) return line:match(pattern) end)
      :find(function(match) return match ~= nil end)

    if not raw_env then return end

    vim.schedule(function()
      local env_vars = {}
      for key, value in raw_env:gmatch '(%S+)=(%S+)' do
        table.insert(env_vars, { key = key, value = value })
      end
      table.sort(env_vars, function(a, b) return a.key < b.key end)

      vim.cmd.vnew()
      vim.bo.bufhidden = 'delete'
      vim.bo.buflisted = false
      vim.bo.buftype = 'nowrite'

      local markup = {}
      for i, entry in ipairs(env_vars) do
        if i > 1 then table.insert(markup, '\n') end
        table.insert(markup, { h.Constant({}, entry.key), '=', h.String({}, entry.value) })
      end

      Morph.new(vim.api.nvim_get_current_buf()):render(markup)
      vim.cmd.normal 'gg0'
    end)
  end)
end

local function show_process_open_files(pid)
  vim.system({ 'lsof', '-p', tostring(pid) }, { text = true }, function(result)
    vim.schedule(function()
      vim.cmd.new()
      vim.bo.buftype = 'nofile'
      vim.bo.bufhidden = 'wipe'
      vim.bo.buflisted = false
      vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(result.stdout or '', '\n'))
    end)
  end)
end

local function bar_chart(percent, width)
  local filled = math.floor(percent / 100 * width)
  local empty = width - filled
  return string.rep('█', filled) .. string.rep('░', empty)
end

local TABS = {
  { key = 'g1', page = 'processes', label = 'Processes' },
  { key = 'g2', page = 'resources', label = 'Resources' },
}

local HELP_KEYMAPS = {
  { 'gi', 'Show process environment' },
  { 'gl', 'Show open files (lsof)' },
  { 'gk', 'Kill process' },
  { 'sp', 'Sort by PID' },
  { 'sc', 'Sort by CPU' },
  { 'sm', 'Sort by MEM' },
  { 'gs', 'Toggle CPU/Mem stats' },
  { 'gn', 'Toggle network' },
  { 'g1', 'Processes tab' },
  { 'g2', 'Resources tab' },
  { '<Leader>r', 'Refresh' },
  { 'g?', 'Toggle this help' },
}

local function ProcessesHelp() return h(Help, { common_keymaps = HELP_KEYMAPS }) end

local function CpuPanel(cpu)
  local cores = cpu.cores or {}
  if #cores == 0 then return {} end

  local items = { h.Title({}, 'CPU'), '\n' }
  local columns = math.min(4, #cores)
  local bar_width = 8

  for i, usage in ipairs(cores) do
    local highlight = nil
    if usage > 80 then
      highlight = 'DiagnosticError'
    elseif usage > 50 then
      highlight = 'DiagnosticWarn'
    end

    table.insert(items, h.Comment({}, string.format('%2d', i - 1)))
    table.insert(items, h.String({}, '['))
    table.insert(items, h(Meter, { value = usage, max = 100, width = bar_width, hl = highlight }))
    table.insert(items, h.String({}, ']'))

    local is_end_of_row = i % columns == 0 and i < #cores
    table.insert(items, is_end_of_row and '\n' or ' ')
  end

  table.insert(items, '\n')
  return items
end

local function MemoryPanel(memory)
  local highlight = nil
  if memory.percent > 80 then
    highlight = 'DiagnosticError'
  elseif memory.percent > 60 then
    highlight = 'DiagnosticWarn'
  end

  return {
    h.Title({}, 'MEM '),
    h.String({}, '['),
    h(Meter, { value = memory.percent, max = 100, width = 20, hl = highlight }),
    h.String({}, '] '),
    h.Number({}, string.format('%5.1f%%', memory.percent)),
    ' (',
    h.Number({}, string.format('%.1fG', memory.used_gb)),
    '/',
    h.Number({}, string.format('%.1fG', memory.total_gb)),
    ')',
    '\n',
  }
end

local function NetworkPanel(interfaces)
  if #interfaces == 0 then return {} end

  local graph_width = 20
  local rows = {}

  for _, iface in ipairs(interfaces) do
    table.insert(rows, {
      cells = {
        h.Title({}, iface.name),
        {
          h.String({}, '['),
          h(Sparkline, { values = iface.history_in or {}, width = graph_width }),
          h.String({}, ']'),
        },
        h.Number({}, format_transfer_rate(iface.rate_in)),
        {
          h.DiagnosticWarn({}, '['),
          h(
            Sparkline,
            { values = iface.history_out or {}, width = graph_width, hl = 'DiagnosticWarn' }
          ),
          h.String({}, ']'),
        },
        h.Number({}, format_transfer_rate(iface.rate_out)),
      },
    })
  end

  return {
    h.Title({}, 'NET'),
    '\n\n',
    h(Table, { rows = rows }),
    '\n',
  }
end

local function build_process_table_rows(processes)
  local rows = {
    {
      cells = {
        h.Constant({}, 'USER'),
        h.Constant({}, 'PID'),
        h.Constant({}, '%CPU'),
        h.Constant({}, '%MEM'),
        h.Constant({}, 'COMMAND'),
      },
    },
  }

  for _, proc in ipairs(processes) do
    table.insert(rows, {
      nmap = {
        ['gi'] = function()
          vim.schedule(function() show_process_environment(proc) end)
          return ''
        end,
        ['gl'] = function()
          vim.schedule(function() show_process_open_files(proc.pid) end)
          return ''
        end,
        ['gk'] = function()
          vim.schedule(function() kill_process_with_signal_picker(proc.pid) end)
          return ''
        end,
      },
      cells = {
        h.Title({}, proc.user),
        h.Number({}, tostring(proc.pid)),
        h.Number({}, proc.cpu),
        h.Number({}, proc.mem),
        (function()
          local cmd = proc.command
          local max_len = 150
          if #cmd > max_len then
            local half = math.floor((max_len - 3) / 2)
            cmd = cmd:sub(1, half) .. '...' .. cmd:sub(-half)
          end
          return h.String({}, cmd)
        end)(),
      },
    })
  end

  return rows
end

local function get_disk_usage(callback)
  vim.system({ 'df', '-h' }, { text = true }, function(result)
    local output = result.stdout or ''

    local disks = {}
    for line in output:gmatch '[^\r\n]+' do
      if not line:match '^Filesystem' and not line:match '^devfs' and not line:match '^map' then
        local parts = {}
        for part in line:gmatch '%S+' do
          table.insert(parts, part)
        end

        if #parts >= 6 then
          local filesystem = parts[1]
          local size = parts[2]
          local used = parts[3]
          -- local _avail = parts[4]
          local percent_col = parts[5]

          local mounted
          if #parts == 9 then
            mounted = parts[9]
          elseif #parts == 6 then
            mounted = parts[6]
          else
            mounted = table.concat(parts, ' ', #parts >= 9 and 9 or 6)
          end

          local percent = tonumber(percent_col:match '%d+') or 0

          if mounted then
            table.insert(disks, {
              filesystem = filesystem,
              mounted = vim.trim(mounted),
              size = size,
              used = used,
              percent = percent,
            })
          end
        end
      end
    end

    callback(disks)
  end)
end

local function get_load_average(callback)
  if is_macos then
    vim.system({ 'sysctl', '-n', 'vm.loadavg' }, { text = true }, function(result)
      local output = result.stdout or ''
      local one, five, fifteen = output:match '{%s*([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)'
      callback {
        one = tonumber(one) or 0,
        five = tonumber(five) or 0,
        fifteen = tonumber(fifteen) or 0,
      }
    end)
  elseif is_linux then
    local file = io.open('/proc/loadavg', 'r')
    if not file then
      callback { one = 0, five = 0, fifteen = 0 }
      return
    end
    local content = file:read '*a'
    file:close()
    local one, five, fifteen = content:match '([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)'
    callback {
      one = tonumber(one) or 0,
      five = tonumber(five) or 0,
      fifteen = tonumber(fifteen) or 0,
    }
  else
    callback { one = 0, five = 0, fifteen = 0 }
  end
end

local function ProcessesPanel(ctx)
  local state = assert(ctx.state)

  local filter_term = vim.trim(state.filter)
  local matches_filter = utils.create_filter_fn(filter_term)
  local filtered_processes = vim
    .iter(state.processes)
    :filter(function(proc) return matches_filter(proc.user) or matches_filter(proc.command) end)
    :totable()

  if state.sort_by then
    table.sort(filtered_processes, function(a, b)
      local val_a, val_b
      if state.sort_by == 'pid' then
        val_a = a.pid
        val_b = b.pid
      elseif state.sort_by == 'cpu' then
        val_a = tonumber(a.cpu) or 0
        val_b = tonumber(b.cpu) or 0
      elseif state.sort_by == 'mem' then
        val_a = tonumber(a.mem) or 0
        val_b = tonumber(b.mem) or 0
      end
      if val_a == val_b then
        val_a = a.pid
        val_b = b.pid
      end
      if state.sort_desc then
        return val_a > val_b
      else
        return val_a < val_b
      end
    end)
  end

  local result = {}

  if state.show_stats then
    for _, v in ipairs(CpuPanel(state.cpu)) do
      table.insert(result, v)
    end
    table.insert(result, '\n')
    for _, v in ipairs(MemoryPanel(state.memory)) do
      table.insert(result, v)
    end
    table.insert(result, '\n')
  end

  if state.show_network and #state.network > 0 then
    for _, v in ipairs(NetworkPanel(state.network)) do
      table.insert(result, v)
    end
    table.insert(result, '\n')
  end

  table.insert(
    result,
    h('text', {
      nmap = {
        ['<C-Space>'] = function()
          state.show_all_users = not state.show_all_users
          state.table_page = 1
          vim.schedule(function()
            fetch_process_list(state.show_all_users, function(processes)
              state.processes = processes
              ctx:update(state)
            end)
          end)
          return ''
        end,
      },
    }, {
      '- [',
      state.show_all_users and 'X' or ' ',
      '] Show all processes',
      '\n\n',
    })
  )

  table.insert(result, {
    h.Label({}, 'Filter: '),
    h.Text({}, '['),
    h('text', {
      on_change = function(e)
        e.bubble_up = false
        state.filter = e.text
        state.table_page = 1
        ctx:update(state)
      end,
    }, state.filter),
    h.Text({}, ']'),
    '  ',
    h.Comment({}, string.format('(%d processes)', #filtered_processes)),
    '\n\n',
  })

  table.insert(
    result,
    h(Table, {
      rows = build_process_table_rows(filtered_processes),
      header = true,
      page = state.table_page,
      page_size = math.floor(vim.o.lines),
      on_page_changed = function(new_page)
        state.table_page = new_page
        ctx:update(state)
      end,
    })
  )

  return result
end

local function ResourcesPanel(ctx)
  local state = assert(ctx.state)

  local disk_rows = {
    {
      cells = {
        h.Constant({}, 'MOUNT'),
        h.Constant({}, 'USAGE'),
        h.Constant({}, 'USED'),
        h.Constant({}, 'SIZE'),
        h.Constant({}, '%'),
      },
    },
  }

  for _, disk in ipairs(state.disks) do
    table.insert(disk_rows, {
      cells = {
        h.Title({}, disk.mounted),
        h.String({}, bar_chart(disk.percent, 20)),
        h.Number({}, disk.used),
        h.Number({}, disk.size),
        disk.percent > 90 and h.DiagnosticError({}, string.format('%d%%', disk.percent))
          or disk.percent > 75 and h.DiagnosticWarn({}, string.format('%d%%', disk.percent))
          or h.Number({}, string.format('%d%%', disk.percent)),
      },
    })
  end

  return {
    h.RenderMarkdownH2({}, 'CPU'),
    '\n\n',
    h.String({}, bar_chart(state.cpu.overall, 40)),
    ' ',
    h.Number({}, string.format('%.1f%%', state.cpu.overall)),
    '\n\n',

    h.RenderMarkdownH2({}, 'Memory'),
    '\n\n',
    h.String({}, bar_chart(state.memory.percent, 40)),
    ' ',
    h.Number({}, string.format('%.1f GB', state.memory.used_gb)),
    ' / ',
    h.Number({}, string.format('%.1f GB', state.memory.total_gb)),
    ' (',
    h.Number({}, string.format('%.0f%%', state.memory.percent)),
    ')',
    '\n\n',

    h.RenderMarkdownH2({}, 'Disk Usage'),
    '\n\n',
    h(Table, { rows = disk_rows }),
    '\n\n',

    h.RenderMarkdownH2({}, 'Load Average'),
    '\n\n',
    h.Label({}, '1m: '),
    h.Number({}, string.format('%.2f', state.load.one)),
    '  ',
    h.Label({}, '5m: '),
    h.Number({}, string.format('%.2f', state.load.five)),
    '  ',
    h.Label({}, '15m: '),
    h.Number({}, string.format('%.2f', state.load.fifteen)),
  }
end

local function App(ctx)
  local function create_sort_handler(column, default_descending)
    return function()
      local state = assert(ctx.state)
      if state.sort_by == column then
        state.sort_desc = not state.sort_desc
      else
        state.sort_by = column
        state.sort_desc = default_descending
      end
      ctx:update(state)
      return ''
    end
  end
  local function refresh_processes()
    local state = assert(ctx.state)
    fetch_process_list(state.show_all_users, function(processes)
      state.processes = processes
      ctx:update(state)
    end)
  end

  local function refresh_system_stats()
    local state = assert(ctx.state)

    local now = vim.uv.hrtime() / 1e9
    local seconds_since_last_refresh = state.last_refresh > 0 and (now - state.last_refresh) or 3
    state.last_refresh = now

    fetch_cpu_stats(function(cpu)
      state.cpu = cpu
      ctx:update(state)
    end)

    fetch_memory_stats(function(memory)
      state.memory = memory
      ctx:update(state)
    end)

    fetch_network_stats(state.network, seconds_since_last_refresh, function(network)
      state.network = network
      ctx:update(state)
    end)
  end

  local function refresh_resources()
    local state = assert(ctx.state)

    local pending = 3
    local function check_done()
      pending = pending - 1
      if pending == 0 then ctx:update(state) end
    end

    fetch_cpu_stats(function(cpu)
      state.cpu = cpu
      check_done()
    end)

    fetch_memory_stats(function(memory)
      state.memory = memory
      check_done()
    end)

    get_disk_usage(function(disks)
      state.disks = disks
      check_done()
    end)

    get_load_average(function(load)
      state.load = load
      check_done()
    end)
  end

  local function refresh_all()
    refresh_processes()
    refresh_system_stats()
  end

  local refresh_all_wrapped = vim.schedule_wrap(refresh_all)
  local refresh_resources_wrapped = vim.schedule_wrap(refresh_resources)

  if ctx.phase == 'mount' then
    ctx.state = {
      tab = 'processes',
      show_help = false,
      processes = {},
      filter = '',
      sort_by = 'pid',
      sort_desc = false,
      show_all_users = false,
      show_stats = true,
      show_network = false,
      table_page = 1,
      cpu = { overall = 0, cores = {} },
      memory = { used_gb = 0, total_gb = 16, percent = 0 },
      network = {},
      last_refresh = 0,
      disks = {},
      load = { one = 0, five = 0, fifteen = 0 },
      timer = assert(vim.uv.new_timer()),
    }

    fetch_process_list(false, function(processes)
      ctx.state.processes = processes
      ctx:update(ctx.state)
    end)
    refresh_system_stats()
    refresh_resources()

    ctx.state.timer:start(1000, 1000, refresh_all_wrapped)
  end

  local state = assert(ctx.state)

  if ctx.phase == 'unmount' then
    state.timer:stop()
    state.timer:close()
  end

  local function go_to_page(tab)
    if state.tab == tab then return end
    state.tab = tab
    ctx:update(state)
    vim.fn.winrestview { topline = 1, lnum = 1 }
    if tab == 'resources' then vim.schedule(refresh_resources_wrapped) end
  end

  local nav_keymaps = {
    ['<Leader>r'] = function()
      if state.tab == 'processes' then
        vim.schedule(refresh_all_wrapped)
      else
        vim.schedule(refresh_resources_wrapped)
      end
      return ''
    end,
    ['g?'] = function()
      state.show_help = not state.show_help
      ctx:update(state)
      return ''
    end,
  }
  for _, t in ipairs(TABS) do
    nav_keymaps[t.key] = function()
      vim.schedule(function() go_to_page(t.page) end)
      return ''
    end
  end

  local page_content
  if state.tab == 'processes' then
    local process_content = ProcessesPanel(ctx)
    page_content = h('text', {
      nmap = {
        ['sp'] = create_sort_handler('pid', false),
        ['sc'] = create_sort_handler('cpu', true),
        ['sm'] = create_sort_handler('mem', true),
        ['gs'] = function()
          state.show_stats = not state.show_stats
          ctx:update(state)
          return ''
        end,
        ['gn'] = function()
          state.show_network = not state.show_network
          ctx:update(state)
          return ''
        end,
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
      },
    }, process_content)
  else
    page_content = h('text', {}, { ResourcesPanel(ctx) })
  end

  return h('text', { nmap = nav_keymaps }, {
    h.RenderMarkdownH1({}, 'System Monitor'),
    ' ',
    h.NonText({}, 'g? for help'),
    '\n\n',

    h(TabBar, {
      tabs = TABS,
      active_page = state.tab,
      on_select = go_to_page,
      wrap_at = 5,
    }),

    state.show_help and { ProcessesHelp(), '\n' },

    page_content,
  })
end

function M.show()
  vim.cmd.tabnew()
  vim.bo.bufhidden = 'wipe'
  vim.bo.buftype = 'nowrite'
  vim.b.completion = false
  vim.wo[0][0].list = false
  vim.api.nvim_buf_set_name(0, 'System Monitor')

  Morph.new(0):mount(h(App))
end

return M
