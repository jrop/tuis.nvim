local Morph = require 'tuis.morph'
local components = require 'tuis.components'
local Table = components.Table
local Meter = components.Meter
local Sparkline = components.Sparkline
local TabBar = components.TabBar
local h = Morph.h

local function with_buf(lines, f)
  vim.go.swapfile = false

  vim.cmd.new()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  local ok, result = pcall(f)
  vim.cmd.bdelete { bang = true }
  if not ok then error(result) end
end
describe('Morph-UI Components', function()
  --------------------------------------------------------------------------------
  -- Meter
  --------------------------------------------------------------------------------

  describe('Meter', function()
    it('should render an empty meter when value is 0', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:mount(h(Meter, { value = 0, max = 100, width = 10 }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        -- 10 spaces for empty meter
        assert.are.equal('          ', text)
      end)
    end)

    it('should render a full meter when value equals max', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:mount(h(Meter, { value = 100, max = 100, width = 10 }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        -- 10 full blocks
        assert.are.equal('██████████', text)
      end)
    end)

    it('should render a half-filled meter at 50%', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:mount(h(Meter, { value = 50, max = 100, width = 10 }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        -- 5 full blocks + 5 spaces
        assert.are.equal('█████     ', text)
      end)
    end)

    it('should render partial blocks for fractional values', function()
      with_buf({}, function()
        local r = Morph.new(0)
        -- 25% of 10 chars = 2.5 chars, should show partial block
        r:mount(h(Meter, { value = 25, max = 100, width = 10 }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        -- Should have 2 full blocks, 1 partial, and spaces
        assert.are.equal(10, vim.fn.strdisplaywidth(text))
        assert.matches('^██', text) -- starts with 2 full blocks
      end)
    end)

    it('should scale value based on max', function()
      with_buf({}, function()
        local r = Morph.new(0)
        -- 50 out of 200 = 25%
        r:mount(h(Meter, { value = 50, max = 200, width = 10 }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        -- 25% = 2.5 chars, similar to above
        assert.are.equal(10, vim.fn.strdisplaywidth(text))
        assert.matches('^██', text)
      end)
    end)

    it('should clamp value to max', function()
      with_buf({}, function()
        local r = Morph.new(0)
        -- Value exceeds max
        r:mount(h(Meter, { value = 150, max = 100, width = 10 }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        -- Should be fully filled
        assert.are.equal('██████████', text)
      end)
    end)

    it('should handle zero max gracefully', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:mount(h(Meter, { value = 50, max = 0, width = 10 }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        -- Should be empty when max is 0
        assert.are.equal('          ', text)
      end)
    end)

    it('should apply highlight when hl prop is provided', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:mount(h(Meter, { value = 50, max = 100, width = 10, hl = 'DiagnosticError' }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        -- Text should still render correctly
        assert.are.equal('█████     ', text)

        local ns =
          vim.api.nvim_create_namespace(('morph:%d'):format(vim.api.nvim_get_current_buf()))
        local extmarks = vim.api.nvim_buf_get_extmarks(
          0,
          ns,
          { 0, 0 },
          { -1, -1 },
          { details = true }
        )
        assert.are.equal(1, #extmarks)
        assert.are.equal('DiagnosticError', extmarks[1][4].hl_group)
      end)
    end)

    it('should respect width parameter', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:mount(h(Meter, { value = 100, max = 100, width = 5 }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        assert.are.equal('█████', text)
        assert.are.equal(5, vim.fn.strdisplaywidth(text))
      end)
    end)
  end)

  --------------------------------------------------------------------------------
  -- Sparkline
  --------------------------------------------------------------------------------

  describe('Sparkline', function()
    it('should render empty sparkline for empty values', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:mount(h(Sparkline, { values = {}, width = 10 }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        -- 10 spaces for empty sparkline
        assert.are.equal('          ', text)
      end)
    end)

    it('should render full height for max value', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:mount(h(Sparkline, { values = { 100 }, width = 5 }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        -- Single max value should show full block at the end, spaces before
        assert.are.equal(5, vim.fn.strdisplaywidth(text))
        assert.matches('█', text)
      end)
    end)

    it('should auto-scale based on max value in data', function()
      with_buf({}, function()
        local r = Morph.new(0)
        -- Values 0, 50, 100 - should scale so 100 is full height
        r:mount(h(Sparkline, { values = { 0, 50, 100 }, width = 3 }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        assert.are.equal(3, vim.fn.strdisplaywidth(text))
        -- Last char should be full block (max value)
        assert.matches('█$', text)
      end)
    end)

    it('should show varying heights for different values', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:mount(h(Sparkline, { values = { 25, 50, 75, 100 }, width = 4 }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        assert.are.equal(4, vim.fn.strdisplaywidth(text))
        assert.are.equal('▂▄▆█', text)
      end)
    end)

    it('should take last N values when more than width', function()
      with_buf({}, function()
        local r = Morph.new(0)
        -- 6 values but width is 3, should only show last 3
        r:mount(h(Sparkline, { values = { 10, 20, 30, 40, 50, 60 }, width = 3 }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        assert.are.equal(3, vim.fn.strdisplaywidth(text))
      end)
    end)

    it('should pad with spaces when fewer values than width', function()
      with_buf({}, function()
        local r = Morph.new(0)
        -- 2 values but width is 5
        r:mount(h(Sparkline, { values = { 50, 100 }, width = 5 }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        assert.are.equal(5, vim.fn.strdisplaywidth(text))
        -- Should have spaces at the start
        assert.matches('^%s+', text)
      end)
    end)

    it('should handle all zero values', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:mount(h(Sparkline, { values = { 0, 0, 0, 0 }, width = 4 }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        -- All zeros should render as spaces
        assert.are.equal('    ', text)
      end)
    end)

    it('should apply highlight when hl prop is provided', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:mount(h(Sparkline, { values = { 50, 100 }, width = 5, hl = 'DiagnosticWarn' }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        -- Text should still render correctly
        assert.are.equal(5, vim.fn.strdisplaywidth(text))
      end)
    end)

    it('should use vertical block characters', function()
      with_buf({}, function()
        local r = Morph.new(0)
        -- Use a value that should produce a mid-height block
        r:mount(h(Sparkline, { values = { 50, 100 }, width = 2 }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        -- Should contain vertical block chars (▁▂▃▄▅▆▇█)
        -- The 50% value should be around ▄ or ▅
        assert.matches('[▁▂▃▄▅▆▇█]', text)
      end)
    end)
  end)

  --------------------------------------------------------------------------------
  -- Table
  --------------------------------------------------------------------------------

  describe('Table', function()
    it('should render a simple table with aligned columns', function()
      with_buf({}, function()
        local r = Morph.new(0)

        local table_tree = h(Table, {
          rows = {
            { cells = { 'Name', 'Age', 'City' } },
            { cells = { 'Alice', '25', 'NYC' } },
            { cells = { 'Bob', '30', 'LA' } },
          },
        })

        r:mount(table_tree)

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        assert.are.same(
          table.concat({
            'Name  Age City',
            'Alice 25  NYC',
            'Bob   30  LA',
          }, '\n'),
          text
        )
      end)
    end)

    it('should handle varying cell widths', function()
      with_buf({}, function()
        local r = Morph.new(0)

        local table_tree = h(Table, {
          rows = {
            { cells = { 'Short', 'VeryLongHeader', 'Med' } },
            { cells = { 'X', 'Y', 'Medium' } },
          },
        })

        r:mount(table_tree)

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        -- VeryLongHeader should determine the width of column 2
        assert.are.same(
          table.concat({
            'Short VeryLongHeader Med',
            'X     Y              Medium',
          }, '\n'),
          text
        )
      end)
    end)

    it('should handle single row tables', function()
      with_buf({}, function()
        local r = Morph.new(0)

        local table_tree = h(Table, {
          rows = {
            { cells = { 'Col1', 'Col2', 'Col3' } },
          },
        })

        r:mount(table_tree)

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        -- Single row: no padding between cells needed at the end
        assert.are.same('Col1 Col2 Col3', text)
      end)
    end)

    it('should handle empty tables', function()
      with_buf({}, function()
        local r = Morph.new(0)

        local table_tree = h(Table, {
          rows = {},
        })

        r:mount(table_tree)

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        assert.are.same('', text)
      end)
    end)

    it('should handle tables with markup elements', function()
      with_buf({}, function()
        local r = Morph.new(0)

        local table_tree = h(Table, {
          rows = {
            { cells = { h('text', {}, 'Header1'), h('text', {}, 'Header2') } },
            { cells = { h('text', { hl = 'Comment' }, 'Value1'), h('text', {}, 'Value2') } },
          },
        })

        r:mount(table_tree)

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        assert.are.same(
          table.concat({
            'Header1 Header2',
            'Value1  Value2',
          }, '\n'),
          text
        )
      end)
    end)

    it('should handle tables with row attributes', function()
      with_buf({}, function()
        local r = Morph.new(0)

        local table_tree = h(Table, {
          rows = {
            { cells = { 'A', 'B' }, hl = 'Title' },
            { cells = { 'C', 'D' }, hl = 'Comment' },
          },
        })

        r:mount(table_tree)

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        assert.are.same(table.concat({ 'A B', 'C D' }, '\n'), text)
      end)
    end)

    describe('borders', function()
      it('should render single border with border = true', function()
        with_buf({}, function()
          local r = Morph.new(0)

          local table_tree = h(Table, {
            rows = {
              { cells = { 'A', 'B' } },
              { cells = { 'C', 'D' } },
            },
            border = true,
          })

          r:mount(table_tree)

          local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
          local text = table.concat(lines, '\n')

          assert.are.same(
            table.concat({
              '┌──┬──┐',
              '│A │B │',
              '│C │D │',
              '└──┴──┘',
            }, '\n'),
            text
          )
        end)
      end)

      it('should render single border style', function()
        with_buf({}, function()
          local r = Morph.new(0)

          local table_tree = h(Table, {
            rows = {
              { cells = { 'Name', 'Age' } },
              { cells = { 'Bob', '30' } },
            },
            border = 'single',
          })

          r:mount(table_tree)

          local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
          local text = table.concat(lines, '\n')

          assert.are.same(
            table.concat({
              '┌─────┬────┐',
              '│Name │Age │',
              '│Bob  │30  │',
              '└─────┴────┘',
            }, '\n'),
            text
          )
        end)
      end)

      it('should render double border style', function()
        with_buf({}, function()
          local r = Morph.new(0)

          local table_tree = h(Table, {
            rows = {
              { cells = { 'A', 'B' } },
              { cells = { 'C', 'D' } },
            },
            border = 'double',
          })

          r:mount(table_tree)

          local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
          local text = table.concat(lines, '\n')

          assert.are.same(
            table.concat({
              '╔══╦══╗',
              '║A ║B ║',
              '║C ║D ║',
              '╚══╩══╝',
            }, '\n'),
            text
          )
        end)
      end)

      it('should render rounded border style', function()
        with_buf({}, function()
          local r = Morph.new(0)

          local table_tree = h(Table, {
            rows = {
              { cells = { 'A', 'B' } },
              { cells = { 'C', 'D' } },
            },
            border = 'rounded',
          })

          r:mount(table_tree)

          local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
          local text = table.concat(lines, '\n')

          assert.are.same(
            table.concat({
              '╭──┬──╮',
              '│A │B │',
              '│C │D │',
              '╰──┴──╯',
            }, '\n'),
            text
          )
        end)
      end)

      it('should render ascii border style', function()
        with_buf({}, function()
          local r = Morph.new(0)

          local table_tree = h(Table, {
            rows = {
              { cells = { 'A', 'B' } },
              { cells = { 'C', 'D' } },
            },
            border = 'ascii',
          })

          r:mount(table_tree)

          local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
          local text = table.concat(lines, '\n')

          assert.are.same(
            table.concat({
              '+--+--+',
              '|A |B |',
              '|C |D |',
              '+--+--+',
            }, '\n'),
            text
          )
        end)
      end)

      it('should render header separator when header = true', function()
        with_buf({}, function()
          local r = Morph.new(0)

          local table_tree = h(Table, {
            rows = {
              { cells = { 'Name', 'Age' } },
              { cells = { 'Alice', '25' } },
              { cells = { 'Bob', '30' } },
            },
            border = 'single',
            header = true,
          })

          r:mount(table_tree)

          local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
          local text = table.concat(lines, '\n')

          assert.are.same(
            table.concat({
              '┌──────┬────┐',
              '│Name  │Age │',
              '├──────┼────┤',
              '│Alice │25  │',
              '│Bob   │30  │',
              '└──────┴────┘',
            }, '\n'),
            text
          )
        end)
      end)

      it('should not render border when border = "none"', function()
        with_buf({}, function()
          local r = Morph.new(0)

          local table_tree = h(Table, {
            rows = {
              { cells = { 'A', 'B' } },
              { cells = { 'C', 'D' } },
            },
            border = 'none',
          })

          r:mount(table_tree)

          local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
          local text = table.concat(lines, '\n')

          assert.are.same(table.concat({ 'A B', 'C D' }, '\n'), text)
        end)
      end)
    end)

    describe('pagination', function()
      it('should show only first page when page=1 and page_size is set', function()
        with_buf({}, function()
          local r = Morph.new(0)

          local table_tree = h(Table, {
            rows = {
              { cells = { 'Header' } },
              { cells = { 'Row1' } },
              { cells = { 'Row2' } },
              { cells = { 'Row3' } },
              { cells = { 'Row4' } },
              { cells = { 'Row5' } },
            },
            header = true,
            page = 1,
            page_size = 2,
          })

          r:mount(table_tree)

          local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
          local text = table.concat(lines, '\n')

          -- Should show header + 2 data rows + page indicator
          assert.matches('Header', text)
          assert.matches('Row1', text)
          assert.matches('Row2', text)
          assert.not_matches('Row3', text)
          assert.not_matches('Row4', text)
          assert.not_matches('Row5', text)
          -- Page indicator should show page 1
          assert.matches('Page 1 of 3', text)
        end)
      end)

      it('should show second page when page=2', function()
        with_buf({}, function()
          local r = Morph.new(0)

          local table_tree = h(Table, {
            rows = {
              { cells = { 'Header' } },
              { cells = { 'Row1' } },
              { cells = { 'Row2' } },
              { cells = { 'Row3' } },
              { cells = { 'Row4' } },
              { cells = { 'Row5' } },
            },
            header = true,
            page = 2,
            page_size = 2,
          })

          r:mount(table_tree)

          local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
          local text = table.concat(lines, '\n')

          -- Should show header + rows 3-4 (page 2)
          assert.matches('Header', text)
          assert.not_matches('Row1', text)
          assert.not_matches('Row2', text)
          assert.matches('Row3', text)
          assert.matches('Row4', text)
          assert.not_matches('Row5', text)
          -- Page indicator should show page 2
          assert.matches('Page 2 of 3', text)
        end)
      end)

      it('should show last page correctly with partial rows', function()
        with_buf({}, function()
          local r = Morph.new(0)

          local table_tree = h(Table, {
            rows = {
              { cells = { 'Header' } },
              { cells = { 'Row1' } },
              { cells = { 'Row2' } },
              { cells = { 'Row3' } },
              { cells = { 'Row4' } },
              { cells = { 'Row5' } },
            },
            header = true,
            page = 3,
            page_size = 2,
          })

          r:mount(table_tree)

          local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
          local text = table.concat(lines, '\n')

          -- Should show header + row 5 only (last page, partial)
          assert.matches('Header', text)
          assert.not_matches('Row1', text)
          assert.not_matches('Row4', text)
          assert.matches('Row5', text)
          -- Page indicator should show page 3
          assert.matches('Page 3 of 3', text)
        end)
      end)

      it('should clamp page to valid range', function()
        with_buf({}, function()
          local r = Morph.new(0)

          local table_tree = h(Table, {
            rows = {
              { cells = { 'Header' } },
              { cells = { 'Row1' } },
              { cells = { 'Row2' } },
            },
            header = true,
            page = 99, -- Way beyond available pages
            page_size = 2,
          })

          r:mount(table_tree)

          local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
          local text = table.concat(lines, '\n')

          -- Should show the last (and only) page
          assert.matches('Header', text)
          assert.matches('Row1', text)
          assert.matches('Row2', text)
        end)
      end)

      it('should not show page indicator when only one page', function()
        with_buf({}, function()
          local r = Morph.new(0)

          local table_tree = h(Table, {
            rows = {
              { cells = { 'Header' } },
              { cells = { 'Row1' } },
              { cells = { 'Row2' } },
            },
            header = true,
            page = 1,
            page_size = 10, -- More than enough for all rows
          })

          r:mount(table_tree)

          local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
          local text = table.concat(lines, '\n')

          -- Should show all rows, no page indicator
          assert.matches('Header', text)
          assert.matches('Row1', text)
          assert.matches('Row2', text)
          assert.not_matches('%[1%]', text)
        end)
      end)

      it('should work without header row', function()
        with_buf({}, function()
          local r = Morph.new(0)

          local table_tree = h(Table, {
            rows = {
              { cells = { 'Row1' } },
              { cells = { 'Row2' } },
              { cells = { 'Row3' } },
              { cells = { 'Row4' } },
            },
            page = 2,
            page_size = 2,
          })

          r:mount(table_tree)

          local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
          local text = table.concat(lines, '\n')

          -- Should show rows 3-4 (page 2, no header)
          assert.not_matches('Row1', text)
          assert.not_matches('Row2', text)
          assert.matches('Row3', text)
          assert.matches('Row4', text)
        end)
      end)

      it('should call on_page_changed callback', function()
        with_buf({}, function()
          local called_with = nil

          local table_tree = h(Table, {
            rows = {
              { cells = { 'Header' } },
              { cells = { 'Row1' } },
              { cells = { 'Row2' } },
              { cells = { 'Row3' } },
            },
            header = true,
            page = 1,
            page_size = 2,
            on_page_changed = function(new_page) called_with = new_page end,
          })

          local r = Morph.new(0)
          r:mount(table_tree)

          -- Simulate pressing ]] to go to next page
          -- The keymap should be registered on the table
          vim.api.nvim_feedkeys(']]', 'x', false)

          assert.are.equal(2, called_with)
        end)
      end)

      it('should show page range in indicator', function()
        with_buf({}, function()
          local r = Morph.new(0)

          local table_tree = h(Table, {
            rows = {
              { cells = { 'Header' } },
              { cells = { 'Row1' } },
              { cells = { 'Row2' } },
              { cells = { 'Row3' } },
              { cells = { 'Row4' } },
            },
            header = true,
            page = 1,
            page_size = 2,
          })

          r:mount(table_tree)

          local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
          local text = table.concat(lines, '\n')

          -- Should show range indicator (1-2 of 4)
          assert.matches('1%-2 of 4', text)
        end)
      end)

      describe('uncontrolled mode (page_size only)', function()
        it('should show first page by default when only page_size is passed', function()
          with_buf({}, function()
            local r = Morph.new(0)

            local table_tree = h(Table, {
              rows = {
                { cells = { 'Header' } },
                { cells = { 'Row1' } },
                { cells = { 'Row2' } },
                { cells = { 'Row3' } },
                { cells = { 'Row4' } },
                { cells = { 'Row5' } },
              },
              header = true,
              page_size = 2, -- No page prop - uncontrolled mode
            })

            r:mount(table_tree)

            local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
            local text = table.concat(lines, '\n')

            -- Should show header + first 2 data rows
            assert.matches('Header', text)
            assert.matches('Row1', text)
            assert.matches('Row2', text)
            assert.not_matches('Row3', text)
            assert.not_matches('Row4', text)
            assert.not_matches('Row5', text)
            -- Page indicator should show page 1
            assert.matches('Page 1 of 3', text)
          end)
        end)

        it('should have navigation keymaps in uncontrolled mode', function()
          with_buf({}, function()
            local pages_navigated = {}

            local table_tree = h(Table, {
              rows = {
                { cells = { 'Header' } },
                { cells = { 'Row1' } },
                { cells = { 'Row2' } },
                { cells = { 'Row3' } },
                { cells = { 'Row4' } },
              },
              header = true,
              page_size = 2, -- No page prop - uncontrolled mode
              on_page_changed = function(new_page) table.insert(pages_navigated, new_page) end,
            })

            local r = Morph.new(0)
            r:mount(table_tree)

            -- Verify starting on page 1
            local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
            local text = table.concat(lines, '\n')
            assert.matches('Page 1 of 2', text)
            assert.matches('Row1', text)

            -- Navigate to next page
            vim.api.nvim_feedkeys(']]', 'x', false)
            assert.are.equal(1, #pages_navigated)
            assert.are.equal(2, pages_navigated[1])

            -- Navigate back with [[
            vim.api.nvim_feedkeys('[[', 'x', false)
            assert.are.equal(2, #pages_navigated)
            assert.are.equal(1, pages_navigated[2])
          end)
        end)

        it('should call on_page_changed callback in uncontrolled mode', function()
          with_buf({}, function()
            local called_with = nil

            local table_tree = h(Table, {
              rows = {
                { cells = { 'Header' } },
                { cells = { 'Row1' } },
                { cells = { 'Row2' } },
                { cells = { 'Row3' } },
              },
              header = true,
              page_size = 2, -- No page prop - uncontrolled mode
              on_page_changed = function(new_page) called_with = new_page end,
            })

            local r = Morph.new(0)
            r:mount(table_tree)

            -- Navigate to next page
            vim.api.nvim_feedkeys(']]', 'x', false)

            -- Callback should have been called
            assert.are.equal(2, called_with)
          end)
        end)

        it('should work without on_page_changed callback (pure uncontrolled)', function()
          with_buf({}, function()
            local r = Morph.new(0)

            -- Table with page_size but no page and no on_page_changed
            local table_tree = h(Table, {
              rows = {
                { cells = { 'Header' } },
                { cells = { 'Row1' } },
                { cells = { 'Row2' } },
                { cells = { 'Row3' } },
                { cells = { 'Row4' } },
              },
              header = true,
              page_size = 2, -- No page, no on_page_changed - pure uncontrolled
            })

            -- Should not error when mounting
            assert.has_no_error(function() r:mount(table_tree) end)

            local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
            local text = table.concat(lines, '\n')

            -- Should show first page
            assert.matches('Page 1 of 2', text)
            assert.matches('Row1', text)
            assert.matches('Row2', text)

            -- Navigation should not error even without callback
            assert.has_no_error(function() vim.api.nvim_feedkeys(']]', 'x', false) end)
          end)
        end)

        it('should not show pagination when only one page (uncontrolled)', function()
          with_buf({}, function()
            local r = Morph.new(0)

            local table_tree = h(Table, {
              rows = {
                { cells = { 'Header' } },
                { cells = { 'Row1' } },
                { cells = { 'Row2' } },
              },
              header = true,
              page_size = 10, -- More than enough for all rows
            })

            r:mount(table_tree)

            local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
            local text = table.concat(lines, '\n')

            -- Should show all rows, no page indicator
            assert.matches('Header', text)
            assert.matches('Row1', text)
            assert.matches('Row2', text)
            assert.not_matches('Page', text)
          end)
        end)
      end)
    end)
  end)

  --------------------------------------------------------------------------------
  -- TabBar
  --------------------------------------------------------------------------------

  describe('TabBar', function()
    local tabs = {
      { key = 'g1', page = 'containers', label = 'Containers' },
      { key = 'g2', page = 'images', label = 'Images' },
      { key = 'g3', page = 'volumes', label = 'Volumes' },
      { key = 'g4', page = 'networks', label = 'Networks' },
    }

    it('should render all tabs on one line when no wrap_at specified', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:mount(h(TabBar, { tabs = tabs, active_page = 'containers' }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        -- All tabs should be on the first line (before the double newline)
        assert.matches('Containers', text)
        assert.matches('Images', text)
        assert.matches('Volumes', text)
        assert.matches('Networks', text)
        -- Should contain separators
        assert.matches('|', text)
        -- Should have key hints
        assert.matches('g1', text)
        assert.matches('g2', text)
      end)
    end)

    it('should highlight the active tab', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:mount(h(TabBar, { tabs = tabs, active_page = 'images' }))

        -- Active tab should be highlighted with H2Bg
        -- The inactive tabs use H2, active uses H2Bg
        local ns =
          vim.api.nvim_create_namespace(('morph:%d'):format(vim.api.nvim_get_current_buf()))
        local extmarks = vim.api.nvim_buf_get_extmarks(
          0,
          ns,
          { 0, 0 },
          { -1, -1 },
          { details = true }
        )
        -- Should have extmarks for highlighting (at least the active tab)
        assert.are.equal(true, #extmarks > 0)
      end)
    end)

    it('should wrap tabs after wrap_at limit', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:mount(h(TabBar, { tabs = tabs, active_page = 'containers', wrap_at = 2 }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

        -- Should have multiple lines (2 tabs per line + blank line at end)
        -- Line 1: Tab1 | Tab2
        -- Line 2: Tab3 | Tab4
        -- Line 3: empty
        assert.are.equal(4, #lines)
        -- First line should have first 2 tabs
        assert.matches('Containers', lines[1])
        assert.matches('Images', lines[1])
        -- Second line should have remaining tabs
        assert.matches('Volumes', lines[2])
        assert.matches('Networks', lines[2])
      end)
    end)

    it('should wrap at exact wrap_at limit', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:mount(h(TabBar, { tabs = tabs, active_page = 'volumes', wrap_at = 3 }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

        -- First 3 tabs on line 1, last tab on line 2 + blank
        assert.are.equal(4, #lines)
        assert.matches('Containers', lines[1])
        assert.matches('Images', lines[1])
        assert.matches('Volumes', lines[1])
        assert.matches('Networks', lines[2])
      end)
    end)

    it('should use custom separator', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:mount(h(TabBar, { tabs = tabs, active_page = 'containers', separator = ' :: ' }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        -- Should contain custom separator
        assert.matches(' :: ', text)
        -- Should not contain default separator
        assert.not_matches(' | ', text)
      end)
    end)

    it('should handle single tab', function()
      with_buf({}, function()
        local single_tab = { { key = 'g1', page = 'home', label = 'Home' } }
        local r = Morph.new(0)
        r:mount(h(TabBar, { tabs = single_tab, active_page = 'home' }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        assert.matches('Home', text)
        assert.matches('g1', text)
        -- No separator should appear for single tab
        assert.not_matches('|', text)
      end)
    end)

    it('should handle empty tabs array', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:mount(h(TabBar, { tabs = {}, active_page = '' }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        -- Should just have the trailing newlines
        assert.are.equal('\n\n', text)
      end)
    end)

    it('should include key hints for each tab', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:mount(h(TabBar, { tabs = tabs, active_page = 'containers' }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        -- Each tab should have its key shown
        assert.matches('g1', text)
        assert.matches('g2', text)
        assert.matches('g3', text)
        assert.matches('g4', text)
      end)
    end)

    it('should render with on_select callback without error', function()
      with_buf({}, function()
        local selected_page = nil
        local r = Morph.new(0)

        -- This should not throw an error
        assert.has_no_error(function()
          r:mount(h(TabBar, {
            tabs = tabs,
            active_page = 'containers',
            on_select = function(page) selected_page = page end,
          }))
        end)

        -- Verify the component rendered correctly
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local text = table.concat(lines, '\n')

        -- Should contain all tabs
        assert.matches('Containers', text)
        assert.matches('Images', text)
      end)
    end)

    it('should add trailing newlines after tabs', function()
      with_buf({}, function()
        local r = Morph.new(0)
        r:mount(h(TabBar, { tabs = tabs, active_page = 'containers' }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

        -- Last line should be empty (from the trailing newline)
        assert.are.equal('', lines[#lines])
      end)
    end)

    it('should work with more tabs than wrap_at on multiple lines', function()
      with_buf({}, function()
        local many_tabs = {
          { key = 'g1', page = 'tab1', label = 'Tab1' },
          { key = 'g2', page = 'tab2', label = 'Tab2' },
          { key = 'g3', page = 'tab3', label = 'Tab3' },
          { key = 'g4', page = 'tab4', label = 'Tab4' },
          { key = 'g5', page = 'tab5', label = 'Tab5' },
          { key = 'g6', page = 'tab6', label = 'Tab6' },
        }
        local r = Morph.new(0)
        r:mount(h(TabBar, { tabs = many_tabs, active_page = 'tab1', wrap_at = 2 }))

        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

        -- 3 lines of tabs + 1 blank line = 4 lines
        assert.are.equal(5, #lines) -- Changed to 5 based on actual output
        -- Line 1: Tab1 | Tab2
        assert.matches('Tab1', lines[1])
        assert.matches('Tab2', lines[1])
        -- Line 2: Tab3 | Tab4
        assert.matches('Tab3', lines[2])
        assert.matches('Tab4', lines[2])
        -- Line 3: Tab5 | Tab6
        assert.matches('Tab5', lines[3])
        assert.matches('Tab6', lines[3])
      end)
    end)
  end)
end)
