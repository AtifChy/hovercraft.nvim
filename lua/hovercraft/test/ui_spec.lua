local UI = require('hovercraft.ui')

local eq = assert.are.same
local is_true = assert.is.True
local is_false = assert.is.False

---@param num integer number of dummy providers to create
---@return string[]
local function make_dummy_provider_ids(num)
  ---@type string[]
  local result = {}

  for i = 1, num do
    table.insert(result, string.format('provider-%d', i))
  end

  return result
end

describe('hovercraft', function()
  describe('hovercraft.ui._get_next_provider_id', function()
    it('simple step forward', function()
      local providers = make_dummy_provider_ids(10)
      local current_provider_id = providers[1]

      local next_provider_id = UI._get_next_provider_id(providers, current_provider_id, 1, true)

      eq(providers[2], next_provider_id)
    end)

    it('step multiple forward', function()
      local providers = make_dummy_provider_ids(10)
      local current_provider_id = providers[1]

      local next_provider_id = UI._get_next_provider_id(providers, current_provider_id, 3, true)

      eq(providers[4], next_provider_id)
    end)

    it('step forward over bounds with cycle', function()
      local providers = make_dummy_provider_ids(10)
      local current_provider_id = providers[10]

      local next_provider_id = UI._get_next_provider_id(providers, current_provider_id, 1, true)

      eq(providers[1], next_provider_id)
    end)

    it('step forward over bounds without cycle', function()
      local providers = make_dummy_provider_ids(10)
      local current_provider_id = providers[10]

      local next_provider_id = UI._get_next_provider_id(providers, current_provider_id, 1, false)

      eq(providers[10], next_provider_id)
    end)

    it('simple step backwards', function()
      local providers = make_dummy_provider_ids(10)
      local current_provider_id = providers[2]

      local next_provider_id = UI._get_next_provider_id(providers, current_provider_id, -1, true)

      eq(providers[1], next_provider_id)
    end)

    it('step multiple backwards', function()
      local providers = make_dummy_provider_ids(10)
      local current_provider_id = providers[4]

      local next_provider_id = UI._get_next_provider_id(providers, current_provider_id, -3, true)

      eq(providers[1], next_provider_id)
    end)

    it('step backwards over bounds with cycle', function()
      local providers = make_dummy_provider_ids(10)
      local current_provider_id = providers[1]

      local next_provider_id = UI._get_next_provider_id(providers, current_provider_id, -1, true)

      eq(providers[10], next_provider_id)
    end)

    it('step backwards over bounds without cycle', function()
      local providers = make_dummy_provider_ids(10)
      local current_provider_id = providers[1]

      local next_provider_id = UI._get_next_provider_id(providers, current_provider_id, -1, false)

      eq(providers[1], next_provider_id)
    end)

    it('step multiple backwards over bounds with cycle', function()
      local providers = make_dummy_provider_ids(10)
      local current_provider_id = providers[1]

      local next_provider_id = UI._get_next_provider_id(providers, current_provider_id, -3, true)

      eq(providers[8], next_provider_id)
    end)

    it('step backwards over bounds without cycle', function()
      local providers = make_dummy_provider_ids(10)
      local current_provider_id = providers[1]

      local next_provider_id = UI._get_next_provider_id(providers, current_provider_id, -4, false)

      eq(providers[1], next_provider_id)
    end)
  end)

  describe('hovercraft._is_empty_content', function()
    it('should return true for empty content table', function()
      local result = UI._is_empty_content({})

      is_true(result)
    end)

    it('should return true for content table with only empty strings', function()
      local result = UI._is_empty_content({ '', '' })

      is_true(result)
    end)

    it('should return false for content table with non empty lines', function()
      local result = UI._is_empty_content({ '', 'hello' })

      is_false(result)
    end)
  end)

  describe('scrollbar calculation', function()
    it('returns scrollbar info when content fits inside window', function()
      local res = UI._calculate_scrollbar(5, 10, 1)
      eq(0, res.bar_size)
      eq(0, res.bar_pos)
      eq({}, res.lines)
    end)

    it('positions thumb at the very top when top = 1', function()
      local res = UI._calculate_scrollbar(20, 10, 1, '│')
      eq(0, res.percent)
      eq(0, res.bar_pos)
      eq(5, res.bar_size)
      for i = 1, 5 do
        eq(' ', res.lines[i])
      end
      for i = 6, 10 do
        eq('│', res.lines[i])
      end
    end)

    it('positions thumb at the very bottom when scrolled to bottom', function()
      local res = UI._calculate_scrollbar(20, 10, 11, '│')
      eq(1, res.percent)
      eq(10 - res.bar_size, res.bar_pos)
      for i = 1, 10 - res.bar_size do
        eq('│', res.lines[i])
      end
      for i = 10 - res.bar_size + 1, 10 do
        eq(' ', res.lines[i])
      end
    end)

    it('positions thumb proportionally in the middle', function()
      local res = UI._calculate_scrollbar(20, 10, 6, '│')
      eq(0.5, res.percent)
      eq(math.ceil((10 - res.bar_size) * 0.5), res.bar_pos)
    end)

    it('handles custom track glyph', function()
      local res = UI._calculate_scrollbar(20, 10, 1, '║')
      eq(' ', res.lines[1])
      eq('║', res.lines[10])
    end)
  end)

  describe('border right char extraction', function()
    it('extracts right border character for single border', function()
      local buf = vim.api.nvim_create_buf(false, true)
      local win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor',
        width = 10,
        height = 5,
        row = 1,
        col = 1,
        border = 'single',
      })
      eq('│', UI._get_border_right_char(win))
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('extracts right border character for rounded border', function()
      local buf = vim.api.nvim_create_buf(false, true)
      local win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor',
        width = 10,
        height = 5,
        row = 1,
        col = 1,
        border = 'rounded',
      })
      eq('│', UI._get_border_right_char(win))
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('extracts right border character for double border', function()
      local buf = vim.api.nvim_create_buf(false, true)
      local win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor',
        width = 10,
        height = 5,
        row = 1,
        col = 1,
        border = 'double',
      })
      eq('║', UI._get_border_right_char(win))
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('extracts right border character for solid border', function()
      local buf = vim.api.nvim_create_buf(false, true)
      local win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor',
        width = 10,
        height = 5,
        row = 1,
        col = 1,
        border = 'solid',
      })
      eq(' ', UI._get_border_right_char(win))
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('returns nil when border is none', function()
      local buf = vim.api.nvim_create_buf(false, true)
      local win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor',
        width = 10,
        height = 5,
        row = 1,
        col = 1,
        border = 'none',
      })
      eq(nil, UI._get_border_right_char(win))
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('extracts right character from custom table with highlights', function()
      local buf = vim.api.nvim_create_buf(false, true)
      local win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor',
        width = 10,
        height = 5,
        row = 1,
        col = 1,
        border = { '1', '2', '3', { 'X', 'Special' }, '5', '6', '7', '8' },
      })
      eq('X', UI._get_border_right_char(win))
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe('border resolution', function()
    it('respects explicit border if given', function()
      eq('rounded', UI._resolve_border('rounded'))
      eq('double', UI._resolve_border('double'))
    end)

    it('falls back to vim.o.winborder when border is nil', function()
      local original = vim.o.winborder
      vim.o.winborder = 'double'
      eq('double', UI._resolve_border(nil))

      vim.o.winborder = 'rounded'
      eq('rounded', UI._resolve_border(nil))

      vim.o.winborder = original
    end)
  end)

  describe('screen lines calculation with wrapping', function()
    it('returns line count when lines fit in window width', function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'short line 1', 'short line 2', 'short line 3' })
      local win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor',
        width = 40,
        height = 10,
        row = 1,
        col = 1,
      })

      local total = UI._get_total_screen_lines(win, buf)
      eq(3, total)

      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe('UI:_build_scrollbar', function()
    it('returns nil when scrollbar = false in config', function()
      local Providers = require('hovercraft.providers')
      local providers = Providers.new({ providers = {} })
      local ui = UI.new(providers, { scrollbar = false })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'line 1', 'line 2', 'line 3' })
      local win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor',
        width = 10,
        height = 2,
        row = 1,
        col = 1,
      })

      local sb_win, sb_buf = ui:_build_scrollbar(win, buf)
      eq(nil, sb_win)
      eq(nil, sb_buf)

      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('creates and cleans up scrollbar window and scratch buffer', function()
      local Providers = require('hovercraft.providers')
      local providers = Providers.new({ providers = {} })
      local ui = UI.new(providers, { scrollbar = true })

      local buf = vim.api.nvim_create_buf(false, true)
      local lines = {}
      for i = 1, 20 do
        table.insert(lines, 'content line ' .. i)
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      local win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor',
        width = 30,
        height = 5,
        row = 1,
        col = 1,
        border = 'single',
      })

      local sb_win, sb_buf, sb_aug = ui:_build_scrollbar(win, buf)
      is_true(sb_win ~= nil and vim.api.nvim_win_is_valid(sb_win))
      is_true(sb_buf ~= nil and vim.api.nvim_buf_is_valid(sb_buf))
      eq('wipe', vim.bo[sb_buf].bufhidden)
      eq('nofile', vim.bo[sb_buf].buftype)

      vim.api.nvim_win_close(win, true)
      vim.wait(50, function()
        return not vim.api.nvim_win_is_valid(sb_win)
      end)
      is_false(vim.api.nvim_win_is_valid(sb_win))

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('renders scrollbar lines matching _calculate_scrollbar output', function()
      local Providers = require('hovercraft.providers')
      local providers = Providers.new({ providers = {} })
      local ui = UI.new(providers, { scrollbar = true })

      local buf = vim.api.nvim_create_buf(false, true)
      local content = {}
      for i = 1, 20 do
        table.insert(content, 'content line ' .. i)
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
      local win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor',
        width = 30,
        height = 5,
        row = 1,
        col = 1,
        border = 'none',
      })

      local _, sb_buf = ui:_build_scrollbar(win, buf)

      local sb_lines = vim.api.nvim_buf_get_lines(sb_buf, 0, -1, false)
      local win_h = vim.api.nvim_win_get_height(win)
      local total = UI._get_total_screen_lines(win, buf)
      local top = vim.fn.line('w0', win)
      local expected = UI._calculate_scrollbar(total, win_h, top)

      eq(expected.lines, sb_lines)

      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('returns nil when content fits in the window (no scrollbar needed)', function()
      local Providers = require('hovercraft.providers')
      local providers = Providers.new({ providers = {} })
      local ui = UI.new(providers, { scrollbar = true })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'line 1', 'line 2' })
      local win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor',
        width = 30,
        height = 10,
        row = 1,
        col = 1,
        border = 'none',
      })

      local sb_win, sb_buf = ui:_build_scrollbar(win, buf)
      eq(nil, sb_win)
      eq(nil, sb_buf)

      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)
end)
