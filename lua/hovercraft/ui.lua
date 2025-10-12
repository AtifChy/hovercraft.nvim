local async = require('plenary.async')
local has_winbar = vim.fn.has('nvim-0.8') == 1

local M = {}

---@alias Hovercraft.UI.ShowOpts { current_provider?: string, }

---@class Hovercraft.UI.Padding
---@field left? integer
---@field right? integer

---@class Hovercraft.UI.Options : vim.lsp.util.open_floating_preview.Opts
---@field width? integer
---@field height? integer
---@field wrap_at? integer
---@field padding? Hovercraft.UI.Padding
---@field max_width? integer
---@field max_height? integer
---@field border? Hovercraft.UI.Border
---@field scrollbar? boolean
---@field render_markdown_compat_mode? boolean Compat mode to make float big enough when MeanderingProgrammer/render-markdown.nvim plugin is used.

---@alias Hovercraft.UI.Border 'none' | 'single' | 'double' | 'rounded' | 'solid' | 'shadow' | Hovercraft.UI.Border.Tile
---@alias Hovercraft.UI.Border.Tile { [1]: string, [2]: string } | string
---@alias Hovercraft.UIBorder.Table Hovercraft.UI.Border.Tile[]

---@class Hovercraft.UI.CurrentWindowConfig
---@field active_provider string
---@field providers string[]
---@field winnr integer
---@field bufnr integer
---@field origin_bufnr integer bufnr of the buffer that triggered the hover
---@field augroup integer
---@field sb_win? integer
---@field sb_buf? integer
---@field sb_augroup? integer
---@field render_scrollbar? fun()

---@alias Hovercraft.UI.OnShow fun(bufnr: number)
---@alias Hovercraft.UI.OnHide fun(bufnr: number)

---@class Hovercraft.UI
---@field config Hovercraft.UI.Options
---@field providers Hovercraft.Providers
---@field current_run integer
---@field window_config? Hovercraft.UI.CurrentWindowConfig
---@field on_show_listeners Hovercraft.UI.OnShow[]
---@field on_hide_listeners Hovercraft.UI.OnHide[]
local UI = {}

UI.__index = UI

---@param providers Hovercraft.Providers
---@param opts Hovercraft.UI.Options
---@return Hovercraft.UI
function M.new(providers, opts)
  return setmetatable({
    config = opts,
    providers = providers,
    current_run = 0,
    on_show_listeners = {},
    on_hide_listeners = {},
  }, UI)
end

---@param listener Hovercraft.UI.OnShow
function UI:register_onshow(listener)
  table.insert(self.on_show_listeners, listener)
end

---@param bufnr number
function UI:_fire_onshow(bufnr)
  for _, l in ipairs(self.on_show_listeners) do
    l(bufnr)
  end
end

---@param listener Hovercraft.UI.OnHide
function UI:register_onhide(listener)
  table.insert(self.on_hide_listeners, listener)
end

---@param bufnr number
function UI:_fire_onhide(bufnr)
  for _, l in ipairs(self.on_hide_listeners) do
    l(bufnr)
  end
end

---@param active_provider string
---@param provider_ids string[]
---@return string title
---@return integer title_length
function UI:_build_title(active_provider, provider_ids)
  local title = {}
  local winbar_length = 0

  for _, id in ipairs(provider_ids) do
    local p = self.providers:get_provider(id)

    if not p then
      -- if we do not find a provider for a given id, we messed up and it is a bug
      error(string.format('could not find provider for id `%s`! This should not happen!', id))
    end

    local hl = id == active_provider and 'TabLineSel' or 'TabLineFill'
    title[#title + 1] = string.format('%%#%s# %s ', hl, p.title)
    title[#title + 1] = '%#Normal#'
    winbar_length = winbar_length + #p.title + 2 -- + 2 for whitespace padding
  end

  return table.concat(title, ''), winbar_length
end

---@param winnr integer
---@param title string
---@param title_length integer
local function add_title(winnr, title, title_length)
  if not has_winbar then
    vim.notify_once('hover.nvim: `config.title` requires neovim >= 0.8.0', vim.log.levels.WARN)
    return
  end

  local config = vim.api.nvim_win_get_config(winnr)

  vim.api.nvim_win_set_config(winnr, {
    height = config.height + 1,
    width = math.max(config.width, title_length + 2), -- + 2 for border
  })

  vim.wo[winnr].winbar = title
end

--- Extract the right vertical border character from the window config
---@param winnr integer
---@return string? border_char nil if window has no border
function M._get_border_right_char(winnr)
  local cfg = vim.api.nvim_win_get_config(winnr)
  local border = cfg.border
  if not border or border == 'none' or (type(border) == 'table' and #border == 0) then
    return nil
  end

  local right_entry = border[4]
  if type(right_entry) == 'table' then
    return (right_entry[1] and right_entry[1] ~= '') and right_entry[1] or '│'
  elseif type(right_entry) == 'string' and right_entry ~= '' then
    return right_entry
  end
  return '│'
end

--- Get total rendered visual lines accounting for soft wrapping
---@param winnr integer
---@param bufnr integer
---@return integer
function M._get_total_screen_lines(winnr, bufnr)
  if vim.api.nvim_win_text_height then
    local ok, res = pcall(vim.api.nvim_win_text_height, winnr, {})
    if ok and res and res.all then
      return res.all
    end
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local width = vim.api.nvim_win_get_width(winnr)
  if width <= 0 then
    width = 80
  end

  local total = 0
  for _, line in ipairs(lines) do
    local len = vim.fn.strdisplaywidth(line)
    total = total + math.max(1, math.ceil(len / width))
  end
  return math.max(1, total)
end

--- Calculate scrollbar thumb size, position, and lines.
---@param total integer
---@param win_height integer
---@param top integer
---@param track_char? string
---@return { should_show: boolean, bar_size: integer, bar_pos: integer, percent: number, lines: string[] }
function M._calculate_scrollbar(total, win_height, top, track_char)
  track_char = track_char or ' '
  local thumb_char = ' '

  if total <= win_height or win_height <= 0 then
    return {
      should_show = false,
      bar_size = 0,
      bar_pos = 0,
      percent = 0,
      lines = {},
    }
  end

  local bar_size = math.max(1, math.floor((win_height / total) * win_height))
  local max_scroll = total - win_height
  local percent = max_scroll > 0 and ((top - 1) / max_scroll) or 0
  percent = math.max(0, math.min(1, percent))
  local bar_pos = math.ceil((win_height - bar_size) * percent)

  local lines = {}
  for i = 1, win_height do
    if i > bar_pos and i <= bar_pos + bar_size then
      lines[i] = thumb_char
    else
      lines[i] = track_char
    end
  end

  return {
    should_show = true,
    bar_size = bar_size,
    bar_pos = bar_pos,
    percent = percent,
    lines = lines,
  }
end

---@param winnr integer
---@param bufnr integer
---@return integer? sb_win
---@return integer? sb_buf
---@return integer? sb_augroup
---@return fun()? render_fn
function UI:_build_scrollbar(winnr, bufnr)
  if self.config.scrollbar == false then
    return nil, nil, nil, nil
  end

  if not (vim.api.nvim_win_is_valid(winnr) and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil, nil, nil, nil
  end

  local win_height = vim.api.nvim_win_get_height(winnr)
  if win_height <= 0 then
    return nil, nil, nil, nil
  end

  local total = M._get_total_screen_lines(winnr, bufnr)
  if self.config.render_markdown_compat_mode then
    total = math.max(1, total - 1)
  end
  if total <= win_height then
    return nil, nil, nil, nil
  end

  local win_width = vim.api.nvim_win_get_width(winnr)
  local has_wb = vim.wo[winnr].winbar ~= ''
  local border_char = M._get_border_right_char(winnr)
  local hl_track = 'FloatBorder'
  local hl_thumb = 'PmenuThumb'

  local sb_col = border_char and win_width or math.max(0, win_width - 1)
  local sb_height = win_height

  local ns = vim.api.nvim_create_namespace('hovercraft_scrollbar')

  -- Create minimal scrollbar buffer
  local sb_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[sb_buf].buftype = 'nofile'
  vim.bo[sb_buf].bufhidden = 'wipe'
  vim.bo[sb_buf].swapfile = false
  vim.bo[sb_buf].buflisted = false
  vim.bo[sb_buf].undolevels = -1

  local sb_win = vim.api.nvim_open_win(sb_buf, false, {
    relative = 'win',
    win = winnr,
    width = 1,
    height = sb_height,
    row = has_wb and -1 or 0,
    col = sb_col,
    focusable = false,
    style = 'minimal',
    border = 'none',
    zindex = 200,
    noautocmd = true,
  })

  -- Prevent editor options and decorations from corrupting 1-col scrollbar
  local reset_opts = {
    wrap = false,
    number = false,
    relativenumber = false,
    cursorline = false,
    cursorcolumn = false,
    foldenable = false,
    foldcolumn = '0',
    spell = false,
    list = false,
    signcolumn = 'no',
    statuscolumn = '',
  }
  for opt, val in pairs(reset_opts) do
    pcall(function()
      vim.wo[sb_win][opt] = val
    end)
  end
  pcall(function()
    vim.wo[sb_win].winhighlight = string.format('Normal:%s,NormalFloat:%s', hl_track, hl_track)
  end)

  local function render()
    if
      not vim.api.nvim_win_is_valid(winnr)
      or not vim.api.nvim_buf_is_valid(bufnr)
      or not vim.api.nvim_win_is_valid(sb_win)
      or not vim.api.nvim_buf_is_valid(sb_buf)
    then
      return
    end

    local cur_win_height = vim.api.nvim_win_get_height(winnr)
    local cur_content_height = math.max(1, cur_win_height)

    local cur_total = M._get_total_screen_lines(winnr, bufnr)
    if self.config.render_markdown_compat_mode then
      cur_total = math.max(1, cur_total - 1)
    end

    -- Update window height if resized
    if vim.api.nvim_win_get_height(sb_win) ~= cur_content_height then
      pcall(vim.api.nvim_win_set_height, sb_win, cur_content_height)
    end

    local top = vim.fn.line('w0', winnr)
    local sb = M._calculate_scrollbar(cur_total, cur_content_height, top, border_char)

    if not sb.should_show then
      pcall(vim.api.nvim_buf_set_lines, sb_buf, 0, -1, false, {})
      return
    end

    pcall(vim.api.nvim_buf_set_lines, sb_buf, 0, -1, false, sb.lines)
    vim.api.nvim_buf_clear_namespace(sb_buf, ns, 0, -1)
    for row = sb.bar_pos, math.min(cur_content_height, sb.bar_pos + sb.bar_size) - 1 do
      pcall(vim.api.nvim_buf_set_extmark, sb_buf, ns, row, 0, {
        end_row = row + 1,
        end_col = 0,
        hl_group = hl_thumb,
        priority = 5000,
      })
    end
  end

  render()

  local aug = vim.api.nvim_create_augroup('hovercraft_scrollbar_' .. tostring(winnr), { clear = true })

  -- Only listen to CursorMoved if user enters the popup buffer
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = aug,
    buffer = bufnr,
    callback = function()
      vim.schedule(render)
    end,
  })

  vim.api.nvim_create_autocmd('VimResized', {
    group = aug,
    callback = function()
      vim.schedule(render)
    end,
  })

  vim.api.nvim_create_autocmd('WinClosed', {
    group = aug,
    pattern = tostring(winnr),
    once = true,
    callback = function()
      if vim.api.nvim_win_is_valid(sb_win) then
        pcall(vim.api.nvim_win_close, sb_win, true)
      end
      if vim.api.nvim_buf_is_valid(sb_buf) then
        pcall(vim.api.nvim_buf_delete, sb_buf, { force = true })
      end
      pcall(vim.api.nvim_del_augroup_by_id, aug)
    end,
  })

  return sb_win, sb_buf, aug, render
end

---@private
--- Creates autocommands to close a preview window when events happen.
---
---@param events table list of events
---@param winnr integer window id of preview window
---@param bufnr integer buffer id of the underlying buffer that will be configured with close events
---@return number augroup_id
function UI:_close_preview_autocmd(events, winnr, bufnr)
  local augroup = vim.api.nvim_create_augroup('hovercraft_preview_window', {
    clear = true,
  })

  -- HACK(patrick.pichler):
  -- In case somebody tries to launch hovercraft from within a hovercraft window, we fallback
  -- to use the current buffer to configure the autocommands. This should be whatever the originally
  -- opened buffer was. This logic might introduce other issues and might needs a bit more thought
  -- put into it on how to handle such nested cases.
  local target_bufnr = (vim.api.nvim_buf_is_valid(bufnr) and bufnr) or vim.api.nvim_get_current_buf()

  -- close the preview window when entered a buffer that is not
  -- the floating window buffer or the buffer that spawned it
  vim.api.nvim_create_autocmd('BufEnter', {
    group = augroup,
    callback = function()
      if self.window_config and self.window_config.bufnr ~= vim.api.nvim_get_current_buf() then
        vim.schedule(function()
          self:hide()
        end)
      end
    end,
  })

  vim.api.nvim_create_autocmd('WinClosed', {
    group = augroup,
    nested = true,
    once = true,
    pattern = tostring(winnr),
    callback = function()
      vim.schedule(function()
        self:winClosed()
      end)
    end,
  })

  if #events > 0 then
    vim.api.nvim_create_autocmd(events, {
      group = augroup,
      buffer = target_bufnr,
      callback = function()
        vim.schedule(function()
          self:hide()
        end)
      end,
    })
  end

  return augroup
end

---@param content string[]
function M._is_empty_content(content)
  if vim.tbl_isempty(content) then
    return true
  end

  for _, line in ipairs(content) do
    local trimmed = line:match('^%s*(.-)%s*$')
    if trimmed:len() > 0 then
      return false
    end
  end

  return true
end

---@param bufnr number
---@return string[]
function UI:_get_active_provider_ids(bufnr, pos)
  ---@type string[]
  local result = {}

  for _, provider in ipairs(self.providers:get_providers()) do
    if provider.is_enabled({ bufnr = bufnr, pos = pos }) then
      table.insert(result, provider.id)
    end
  end

  return result
end

---@param contents string[]
---@param padding Hovercraft.UI.Padding
local function apply_padding(contents, padding)
  if padding.left or padding.right then
    local pad_left = string.rep(' ', padding.left)
    local pad_right = string.rep(' ', padding.right)

    for i, _ in ipairs(contents) do
      contents[i] = pad_left .. contents[i] .. pad_right
    end
  end
end

---@param opts? Hovercraft.UI.ShowOpts
function UI:show(opts)
  opts = opts or {}

  -- the modulo operant is here only to prevent a potential integer overflow
  -- there is probably a better solution for this
  -- TODO: find better solution for abording old results
  local current_run = (self.current_run + 1) % 10000
  self.current_run = current_run

  local bufnr = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)

  async.void(function()
    local active_providers

    if self.window_config and self.window_config.providers then
      active_providers = self.window_config.providers
    else
      active_providers = self:_get_active_provider_ids(bufnr, pos)
    end

    if #active_providers == 0 then
      UI._show_no_provider_warning()
      return
    end

    local provider_id = opts.current_provider or active_providers[1]
    local provider = self.providers:get_provider(provider_id)

    if not provider then
      vim.notify(string.format('no provider for id "%s"!', provider_id))
      return
    end

    local result = provider.execute({
      bufnr = bufnr,
      pos = pos,
    }) or {}

    -- this should somewhat preevnt the issues of calling show in fast succession and
    -- only show the last result
    if current_run ~= self.current_run then
      return
    end

    if self:is_visible() then
      self:hide()
    end

    local contents ---@type string[]

    local filetype = result.filetype or 'markdown'

    if filetype == 'plaintext' then
      contents = result.lines --[[ @as string[] ]] or {}
    else
      local lines = result.lines or {}

      if self.config.render_markdown_compat_mode then
        if lines.value then
          -- HACK: This workaround is required, as MeanderingProgrammer/render-markdown.nvim is
          -- overriding whatever height we set the window when markdown is used. Otherwise
          -- the hovercraft float will be one line short, as the titlebar is not accounted
          -- for.
          -- Line causing issues: https://github.com/MeanderingProgrammer/render-markdown.nvim/blob/a2c2493c21cf61e5554ee8bc83da75bd695921da/lua/render-markdown/lib/compat.lua#L27
          lines.value = lines.value .. '\n '
        elseif type(lines) == 'table' and not lines.kind then
          -- Handle providers that return an array of strings
          table.insert(lines, ' ')
        end
      end

      contents = vim.lsp.util.convert_input_to_markdown_lines(lines)
    end

    if M._is_empty_content(contents) then
      contents = { '-- No information available --' }
    end

    local title, title_length = self:_build_title(provider_id, active_providers)

    local window_opts = vim.tbl_deep_extend('force', self.config, opts)

    if window_opts.padding then
      apply_padding(contents, window_opts.padding)
    end

    local preview_opts = {
      width = window_opts.width,
      height = window_opts.height,
      wrap_at = window_opts.wrap_at,
      max_width = window_opts.max_width,
      max_height = window_opts.max_height,
      border = window_opts.border,
      close_events = {},
    }
    local floating_bufnr, floating_winnr = vim.lsp.util.open_floating_preview(contents, filetype, preview_opts)

    -- Enable smooth scrolling if supported
    if vim.wo[floating_winnr].smoothscroll ~= nil then
      pcall(function()
        vim.wo[floating_winnr].smoothscroll = true
      end)
    end

    if result.customize then
      result.customize({ bufnr = floating_bufnr, winnr = floating_winnr })
    end

    local augroup =
      self:_close_preview_autocmd({ 'CursorMoved', 'CursorMovedI', 'InsertCharPre' }, floating_winnr, bufnr)

    add_title(floating_winnr, title, title_length)

    local sb_win, sb_buf, sb_augroup, render_sb = self:_build_scrollbar(floating_winnr, floating_bufnr)

    self.window_config = {
      active_provider = provider_id,
      bufnr = floating_bufnr,
      origin_bufnr = bufnr,
      winnr = floating_winnr,
      providers = active_providers,
      augroup = augroup,
      sb_win = sb_win,
      sb_buf = sb_buf,
      sb_augroup = sb_augroup,
      render_scrollbar = render_sb,
    }

    self:_fire_onshow(bufnr)
  end)()
end

---@param providers string[]
---@param current_provider_id string
---@param step number steps to find next provider. can also be negative to step backwards
---@param cycle boolean if true, the providers are treated as a ringbuffer and one can scroll through them
---@return string
function M._get_next_provider_id(providers, current_provider_id, step, cycle)
  local found_index = -1

  for i, p in ipairs(providers) do
    if p == current_provider_id then
      found_index = i
      break
    end
  end

  if found_index < 1 then
    -- this should never happen and is clearly indicates a bug
    error(string.format([[couldn't find provider for id `%s`]], current_provider_id))
  end

  local next_provider_index

  if cycle then
    -- we need to adjust it +1 as lua arrays start indexing at 1
    next_provider_index = ((found_index + step - 1) % #providers) + 1
  else
    -- in case we are not cycling we need to do some more logic to ensure
    -- to either show the first or last provider
    local adjusted_index = found_index + step

    if adjusted_index < 1 then
      next_provider_index = 1
    else
      next_provider_index = math.min(adjusted_index, #providers)
    end
  end

  return providers[next_provider_index]
end

---@alias Hovercraft.UI.ShowNextOpts {cycle?: boolean, step? : number}

---@param opts Hovercraft.UI.ShowNextOpts
function UI:show_next(opts)
  opts = vim.tbl_deep_extend('keep', opts or {}, { cycle = true, step = 1 })

  vim.validate('cycle', opts.cycle, 'boolean')
  vim.validate('step', opts.step, 'number')

  local bufnr = vim.api.nvim_get_current_buf()
  ---@type string
  local provider_id

  local providers
  local pos = vim.api.nvim_win_get_cursor(0)

  async.void(function()
    -- TODO: this needs to be reworked, as the figuring out which proivder is active is done twice
    if self.window_config and self.window_config.providers then
      providers = self.window_config.providers
    else
      providers = self:_get_active_provider_ids(bufnr, pos)
    end

    if #providers == 0 then
      UI._show_no_provider_warning()
      return
    end

    if self:is_visible() then
      -- if the window is visible, window_config will always be set
      local current_provider = self.window_config.active_provider

      provider_id = M._get_next_provider_id(providers, current_provider, opts.step, opts.cycle)
    else
      provider_id = providers[1]
    end

    self:show({ current_provider = provider_id })
  end)()
end

function UI._show_no_provider_warning()
  vim.print('No active providers for line!')
end

function UI:show_select()
  local bufnr = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)

  ---@type string[]
  local providers

  async.void(function()
    -- TODO: this needs to be reworked, as the figuring out active providers is done twice
    if self.window_config and self.window_config.providers then
      providers = self.window_config.providers
    else
      providers = self:_get_active_provider_ids(bufnr, pos)
    end

    if #providers == 0 then
      UI._show_no_provider_warning()
      return
    end

    local providers_to_select = {}

    for _, p in ipairs(providers) do
      table.insert(providers_to_select, {
        id = p,
        title = self.providers:get_provider(p).title or p,
      })
    end

    vim.ui.select(providers_to_select, {
      prompt = 'Select hover provider:',
      format_item = function(item)
        return item.title
      end,
    }, function(choice)
      if choice then
        self:show({ current_provider = choice.id })
      end
    end)
  end)()
end

---@param ui Hovercraft.UI
local function _hide_cleanup(ui)
  if ui.window_config then
    -- Clean up scrollbar window & buffer
    if ui.window_config.sb_win and vim.api.nvim_win_is_valid(ui.window_config.sb_win) then
      pcall(vim.api.nvim_win_close, ui.window_config.sb_win, true)
    end
    if ui.window_config.sb_buf and vim.api.nvim_buf_is_valid(ui.window_config.sb_buf) then
      pcall(vim.api.nvim_buf_delete, ui.window_config.sb_buf, { force = true })
    end
    if ui.window_config.sb_augroup then
      pcall(vim.api.nvim_del_augroup_by_id, ui.window_config.sb_augroup)
    end

    -- Remove main augroup to not get ghost close requests.
    if ui.window_config.augroup then
      pcall(vim.api.nvim_del_augroup_by_id, ui.window_config.augroup)
    end
  end

  ui.window_config = nil
  ui.current_run = -1
end

function UI:hide()
  if not self:is_visible() then
    _hide_cleanup(self)
    return
  end

  if vim.api.nvim_win_is_valid(self.window_config.winnr) then
    vim.api.nvim_win_hide(self.window_config.winnr)
  end
end

function UI:winClosed()
  -- If the window is still visible, the close method was probably called
  -- async and too late. We hence skip the logic, as we would otherwise
  -- mess up with another already opened popup.
  if not self.window_config or vim.api.nvim_win_is_valid(self.window_config.winnr) then
    return
  end

  local origin_bufnr = self.window_config.origin_bufnr

  _hide_cleanup(self)
  self:_fire_onhide(origin_bufnr)
end

---@return boolean
function UI:is_visible()
  if not self.window_config or not vim.api.nvim_win_is_valid(self.window_config.winnr) then
    return false
  end

  -- If there is a valid window config, we at least know that there was a non cleaned
  -- up window, that still can be closed.
  return true
end

---@class Hovercraft.UI.ScrollOptions
---@field delta integer amount of lines to scroll (can also be negative)

---@param opts Hovercraft.UI.ScrollOptions
function UI:scroll(opts)
  if not self:is_visible() then
    return
  end

  opts = opts or {}
  vim.validate('delta', opts.delta, 'number')

  if opts.delta == 0 then
    return
  end

  local winnr = self.window_config.winnr
  local bufnr = self.window_config.bufnr
  local count = math.abs(opts.delta)
  local is_down = opts.delta > 0

  vim.api.nvim_win_call(winnr, function()
    local total_lines = vim.api.nvim_buf_line_count(bufnr)
    local scroll = vim.api.nvim_replace_termcodes(is_down and '<C-e>' or '<C-y>', true, false, true)

    for _ = 1, count do
      local old_w0 = vim.fn.line('w0')

      vim.cmd.normal({ bang = true, args = { scroll } })

      if is_down and self.config.render_markdown_compat_mode then
        if vim.fn.line('w$') == total_lines then
          local up = vim.api.nvim_replace_termcodes('<C-y>', true, false, true)
          vim.cmd.normal({ bang = true, args = { up } })
          break
        end
      end

      if vim.fn.line('w0') == old_w0 then
        break
      end
    end
  end)

  -- Immediately re-render scrollbar to eliminate 1-frame latency
  if self.window_config and self.window_config.render_scrollbar then
    self.window_config.render_scrollbar()
  end
end

function UI:enter_popup()
  if not self:is_visible() then
    return
  end

  vim.api.nvim_set_current_win(self.window_config.winnr)
end

return M
