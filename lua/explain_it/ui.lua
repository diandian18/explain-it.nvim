local Popup = require("nui.popup")
local Input = require("nui.input")
local event = require("nui.utils.autocmd").event

local config = require("explain_it.config")

local M = {}

---@type NuiPopup|nil
local active_popup = nil

local INLINE_NS = vim.api.nvim_create_namespace("explain_it_inline_md")

---Dedicated filetype so scrollbar plugins can exclude the float without
---affecting normal markdown buffers.
local RESULT_FT_NO_SCROLLBAR = "explain_it"

local scrollbar_excluded = false

---@param value number
---@param total integer
---@param min integer|nil
---@return integer
local function resolve_size(value, total, min)
  min = min or 3
  if value > 0 and value < 1 then
    return math.max(min, math.floor(total * value))
  end
  return math.max(min, math.floor(value))
end

---Render **bold** / `code` with extmarks so status text works even when
---render-markdown anti_conceal hides the cursor line.
---@param bufnr integer
local function apply_inline_markdown(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, INLINE_NS, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for row, line in ipairs(lines) do
    local col = 1
    while true do
      local s, e = line:find("%*%*[^*].-%*%*", col)
      if not s then
        break
      end
      -- conceal opening **
      vim.api.nvim_buf_set_extmark(bufnr, INLINE_NS, row - 1, s - 1, {
        end_col = s + 1,
        conceal = "",
      })
      -- bold inner text
      vim.api.nvim_buf_set_extmark(bufnr, INLINE_NS, row - 1, s + 1, {
        end_col = e - 2,
        hl_group = "Bold",
      })
      -- conceal closing **
      vim.api.nvim_buf_set_extmark(bufnr, INLINE_NS, row - 1, e - 2, {
        end_col = e,
        conceal = "",
      })
      col = e + 1
    end

    col = 1
    while true do
      local s, e = line:find("`([^`]+)`", col)
      if not s then
        break
      end
      vim.api.nvim_buf_set_extmark(bufnr, INLINE_NS, row - 1, s - 1, {
        end_col = s,
        conceal = "",
      })
      vim.api.nvim_buf_set_extmark(bufnr, INLINE_NS, row - 1, s, {
        end_col = e - 1,
        hl_group = "markdownCode",
      })
      vim.api.nvim_buf_set_extmark(bufnr, INLINE_NS, row - 1, e - 1, {
        end_col = e,
        conceal = "",
      })
      col = e + 1
    end
  end
end

---@return boolean
local function scrollbar_enabled()
  return config.options.ui.scrollbar ~= false
end

---@return string
local function result_filetype()
  if scrollbar_enabled() then
    return "markdown"
  end
  return RESULT_FT_NO_SCROLLBAR
end

---Ensure known scrollbar plugins skip our no-scrollbar filetype.
local function ensure_scrollbar_exclusions()
  if scrollbar_excluded or scrollbar_enabled() then
    return
  end
  scrollbar_excluded = true
  local ft = RESULT_FT_NO_SCROLLBAR

  -- petertriho/nvim-scrollbar
  pcall(function()
    local cfg = require("scrollbar.config").get()
    if cfg and type(cfg.excluded_filetypes) == "table" and not vim.tbl_contains(cfg.excluded_filetypes, ft) then
      table.insert(cfg.excluded_filetypes, ft)
    end
  end)

  -- dstein64/nvim-scrollview
  pcall(function()
    local ok, sv = pcall(require, "scrollview")
    if ok and type(sv) == "table" then
      local list = vim.g.scrollview_excluded_filetypes
      if type(list) ~= "table" then
        list = {}
      end
      if not vim.tbl_contains(list, ft) then
        list = vim.list_extend(vim.deepcopy(list), { ft })
        vim.g.scrollview_excluded_filetypes = list
      end
    end
  end)

  -- lewis6991/satellite.nvim
  pcall(function()
    local ok, sat = pcall(require, "satellite")
    if not ok or type(sat) ~= "table" or type(sat.config) ~= "table" then
      return
    end
    local excluded = sat.config.excluded_filetypes
    if type(excluded) == "table" and not vim.tbl_contains(excluded, ft) then
      table.insert(excluded, ft)
    end
  end)
end

---@param bufnr integer
local function clear_scrollbar(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  pcall(function()
    vim.api.nvim_buf_call(bufnr, function()
      require("scrollbar").clear()
    end)
  end)
  pcall(function()
    require("scrollview").remove_signs(bufnr)
  end)
end

---@param bufnr integer
---@param winid integer|nil
local function setup_markdown_buffer(bufnr, winid)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  pcall(function()
    vim.bo[bufnr].filetype = result_filetype()
  end)

  if not scrollbar_enabled() then
    clear_scrollbar(bufnr)
  end

  if winid and vim.api.nvim_win_is_valid(winid) then
    pcall(function()
      vim.wo[winid].conceallevel = 2
      vim.wo[winid].concealcursor = "nvic"
    end)
  end

  apply_inline_markdown(bufnr)

  pcall(function()
    vim.treesitter.start(bufnr, "markdown")
  end)

  if not config.options.ui.render_markdown then
    return
  end

  local ok, rm = pcall(require, "render-markdown")
  if not ok or type(rm) ~= "table" then
    return
  end

  -- anti_conceal hides marks on the cursor line; our float is focused, so disable it.
  if type(rm.render) == "function" then
    pcall(rm.render, {
      buf = bufnr,
      win = winid,
      config = {
        anti_conceal = { enabled = false },
      },
    })
  elseif type(rm.buf_enable) == "function" then
    pcall(function()
      vim.api.nvim_buf_call(bufnr, function()
        rm.buf_enable()
      end)
    end)
  end

  -- Re-apply after render-markdown in case it cleared unrelated marks; our ns is separate.
  apply_inline_markdown(bufnr)
end

---@param bufnr integer
---@param winid integer|nil
local function refresh_markdown(bufnr, winid)
  setup_markdown_buffer(bufnr, winid)
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      setup_markdown_buffer(bufnr, winid)
    end
  end)
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      setup_markdown_buffer(bufnr, winid)
    end
  end, 40)
end

---Measure wrapped content size for a given max width.
---@param text string
---@param max_width integer
---@return integer width
---@return integer height
local function measure_content(text, max_width)
  local lines = vim.split(text or "", "\n", { plain = true })
  if #lines == 0 then
    lines = { "" }
  end

  local longest = 0
  for _, line in ipairs(lines) do
    longest = math.max(longest, vim.fn.strdisplaywidth(line))
  end

  local width = math.min(max_width, math.max(1, longest))
  local height = 0
  for _, line in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(line)
    if w == 0 then
      height = height + 1
    else
      height = height + math.max(1, math.ceil(w / math.max(width, 1)))
    end
  end
  return width, height
end

---@param source { win?: integer, row?: integer, col?: integer, end_row?: integer, end_col?: integer }|nil
---@param width integer
---@param height integer
---@return { relative: any, position: any, size: any }
local function resolve_popup_placement(source, width, height)
  local ui = config.options.ui
  local anchor = ui.anchor or "auto"
  if anchor == "center" then
    return {
      relative = "editor",
      position = "50%",
      size = { width = width, height = height },
    }
  end

  local win = (source and source.win and vim.api.nvim_win_is_valid(source.win)) and source.win
    or vim.api.nvim_get_current_win()

  local start_row = (source and source.row) or (vim.api.nvim_win_get_cursor(win)[1] - 1)
  local start_col = (source and source.col) or vim.api.nvim_win_get_cursor(win)[2]
  local end_row = (source and source.end_row) or start_row
  local end_col = (source and source.end_col) or start_col

  -- Screen position of selection start / end for space calculation
  local screen_start, screen_end, screen_col
  vim.api.nvim_win_call(win, function()
    local saved = vim.api.nvim_win_get_cursor(win)
    pcall(vim.api.nvim_win_set_cursor, win, { start_row + 1, start_col })
    screen_start = vim.fn.screenrow()
    screen_col = vim.fn.screencol()
    pcall(vim.api.nvim_win_set_cursor, win, { end_row + 1, end_col })
    screen_end = vim.fn.screenrow()
    pcall(vim.api.nvim_win_set_cursor, win, saved)
  end)

  screen_start = screen_start or 1
  screen_end = screen_end or screen_start
  screen_col = screen_col or 1

  -- Gap so border does not sit on the source line
  local gap = math.max(0, tonumber(ui.gap) or 1)
  local space_below = vim.o.lines - screen_end - 2 - gap
  local space_above = screen_start - 2 - gap

  local place_below
  if anchor == "below" then
    place_below = true
  elseif anchor == "above" then
    place_below = false
  else
    place_below = space_below >= math.min(height, 8) or space_below >= space_above
  end

  local avail = place_below and space_below or space_above
  -- Leave a little breathing room so code around the popup stays visible
  height = math.min(height, math.max(3, avail))

  local col = 0
  if screen_col + width > vim.o.columns then
    col = math.min(0, vim.o.columns - width - screen_col + 1)
  end

  -- Anchor below the selection END (avoids covering multi-line targets);
  -- anchor above the selection START.
  local anchor_row, anchor_col, row
  if place_below then
    anchor_row, anchor_col = end_row, end_col
    row = 1 + gap
  else
    anchor_row, anchor_col = start_row, start_col
    row = -(height + 1 + gap)
  end

  return {
    relative = {
      type = "buf",
      winid = win,
      position = {
        row = anchor_row,
        col = anchor_col,
      },
    },
    position = {
      row = row,
      col = col,
    },
    size = { width = width, height = height },
  }
end

---@param title string
---@param source table|nil
---@param size { width: integer, height: integer }
---@return NuiPopup
---@return table place
local function create_result_popup(title, source, size)
  local opts = config.options.ui
  local place = resolve_popup_placement(source, size.width, size.height)

  if opts.scrollbar == false then
    ensure_scrollbar_exclusions()
  end

  local popup_opts = {
    enter = opts.enter ~= false,
    focusable = true,
    relative = place.relative,
    position = place.position,
    size = place.size,
    border = {
      style = opts.border,
      text = {
        top = " " .. title .. " ",
        top_align = opts.title_align or "center",
      },
    },
    win_options = {
      wrap = opts.wrap ~= false,
      linebreak = opts.linebreak ~= false,
      conceallevel = 2,
      concealcursor = "nvic",
      winhighlight = opts.winhighlight or "Normal:Normal,FloatBorder:FloatBorder",
    },
    buf_options = {
      modifiable = true,
      readonly = false,
      buftype = "nofile",
      bufhidden = "wipe",
      swapfile = false,
      filetype = result_filetype(),
    },
  }
  if opts.zindex then
    popup_opts.zindex = opts.zindex
  end

  local popup = Popup(popup_opts)

  popup:mount()

  if opts.scrollbar == false then
    clear_scrollbar(popup.bufnr)
  end

  popup:map("n", "q", function()
    popup:unmount()
  end, { noremap = true, silent = true })

  popup:map("n", "<Esc>", function()
    popup:unmount()
  end, { noremap = true, silent = true })

  if opts.close_on_leave ~= false then
    popup:on(event.BufLeave, function()
      popup:unmount()
    end)
  end

  return popup, place
end

---@param bufnr integer
---@param lines string[]
local function set_lines(bufnr, lines)
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].readonly = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
end

---Build horizontally + vertically centered lines for a status message.
---@param text string
---@param winid integer
---@return string[]
local function centered_status_lines(text, winid)
  text = vim.trim(text or "")
  local width = 40
  local height = 8
  if winid and vim.api.nvim_win_is_valid(winid) then
    width = vim.api.nvim_win_get_width(winid)
    height = vim.api.nvim_win_get_height(winid)
  end

  local tw = vim.fn.strdisplaywidth(text)
  local left = math.max(0, math.floor((width - tw) / 2))
  local line = string.rep(" ", left) .. text

  local top = math.max(0, math.floor((height - 1) / 2))
  local lines = {}
  for _ = 1, top do
    table.insert(lines, "")
  end
  table.insert(lines, line)
  while #lines < height do
    table.insert(lines, "")
  end
  return lines
end

---@param action string Explaining|Translating|Asking
---@return string
function M.status_text(action)
  return action .. "..."
end

---Fit-mode size caps derived from ui.width/height and ui.fit.
---@return { max_w: integer, max_h: integer, min_w: integer, min_h: integer }
local function fit_limits()
  local opts = config.options.ui
  local fit = opts.fit or {}
  local max_w = resolve_size(opts.width, vim.o.columns, 20)
  local max_h = resolve_size(opts.height, vim.o.lines, 6)
  local fit_max_w = math.min(max_w, resolve_size(fit.max_width or 0.55, vim.o.columns, 24))
  local fit_max_h = math.min(max_h, resolve_size(fit.max_height or 0.35, vim.o.lines, 6))
  return {
    max_w = fit_max_w,
    max_h = fit_max_h,
    min_w = fit.min_width or 24,
    min_h = fit.min_height or 3,
  }
end

---Default / fit size for a popup kind.
---@param fit boolean
---@param text string|nil
---@return { width: integer, height: integer }
local function initial_size(fit, text)
  local opts = config.options.ui
  local max_w = resolve_size(opts.width, vim.o.columns, 20)
  local max_h = resolve_size(opts.height, vim.o.lines, 6)

  if not fit then
    return { width = max_w, height = max_h }
  end

  local limits = fit_limits()
  local w, h = measure_content(text or "", limits.max_w)
  w = math.min(limits.max_w, math.max(limits.min_w, w + 2))
  h = math.min(limits.max_h, math.max(limits.min_h, h))
  return { width = w, height = h }
end

---Show a result popup; opts.fit enables content-aware sizing (for translate).
---@param title string|nil
---@param initial_text string|nil
---@param opts {
---  source?: { win?: integer, row?: integer, col?: integer, end_row?: integer, end_col?: integer },
---  fit?: boolean,
---}|nil
---@return table
function M.open_result(title, initial_text, opts)
  title = title or "Explain it"
  opts = opts or {}
  local fit = opts.fit == true
  local source = opts.source

  if active_popup then
    pcall(function()
      active_popup:unmount()
    end)
    active_popup = nil
  end

  local size = initial_size(fit, initial_text)
  local popup = create_result_popup(title, source, size)
  active_popup = popup

  set_lines(popup.bufnr, centered_status_lines(initial_text or M.status_text("Explaining"), popup.winid))
  refresh_markdown(popup.bufnr, popup.winid)

  local closed = false
  local last_render_ms = 0
  local last_size = { width = size.width, height = size.height }

  popup:on(event.BufWipeout, function()
    closed = true
    if active_popup == popup then
      active_popup = nil
    end
  end)

  local function apply_fit_size(text)
    if not fit or closed or not popup.winid or not vim.api.nvim_win_is_valid(popup.winid) then
      return
    end

    local limits = fit_limits()
    local content_w, content_h = measure_content(text or "", limits.max_w - 2)
    local width = math.min(limits.max_w, math.max(limits.min_w, content_w + 2))
    local height = math.min(limits.max_h, math.max(limits.min_h, content_h))

    if width == last_size.width and height == last_size.height then
      return
    end
    last_size = { width = width, height = height }

    local place = resolve_popup_placement(source, width, height)
    pcall(function()
      popup:update_layout({
        relative = place.relative,
        position = place.position,
        size = place.size,
      })
    end)
  end

  return {
    popup = popup,
    ---@param text string
    ---@param opts2 { stream?: boolean, status?: boolean }|nil
    update = function(text, opts2)
      if closed or not vim.api.nvim_buf_is_valid(popup.bufnr) then
        return
      end
      opts2 = opts2 or {}

      if opts2.status then
        set_lines(popup.bufnr, centered_status_lines(text, popup.winid))
        refresh_markdown(popup.bufnr, popup.winid)
        return
      end

      set_lines(popup.bufnr, vim.split(text or "", "\n", { plain = true }))
      apply_fit_size(text)

      if opts2.stream then
        local now = (vim.uv or vim.loop).hrtime() / 1e6
        if now - last_render_ms < 120 then
          return
        end
        last_render_ms = now
        setup_markdown_buffer(popup.bufnr, popup.winid)
        return
      end

      refresh_markdown(popup.bufnr, popup.winid)
    end,
    close = function()
      if not closed then
        pcall(function()
          popup:unmount()
        end)
      end
    end,
  }
end

---@param opts { title?: string, default_value?: string, on_submit: fun(value: string), on_close?: fun() }
function M.ask_input(opts)
  opts = opts or {}
  local title = opts.title or "Ask"
  local ui = config.options.ui
  local input = Input({
    relative = "editor",
    position = "50%",
    size = {
      width = resolve_size(0.6, vim.o.columns, 20),
    },
    border = {
      style = ui.border,
      text = {
        top = " " .. title .. " ",
        top_align = ui.title_align or "center",
      },
    },
    win_options = {
      winhighlight = ui.winhighlight or "Normal:Normal,FloatBorder:FloatBorder",
    },
  }, {
    prompt = "> ",
    default_value = opts.default_value or "",
    on_close = function()
      if opts.on_close then
        opts.on_close()
      end
    end,
    on_submit = function(value)
      if opts.on_submit then
        opts.on_submit(value)
      end
    end,
  })

  input:mount()

  input:map("n", "<Esc>", function()
    input:unmount()
  end, { noremap = true })

  input:map("i", "<Esc>", function()
    input:unmount()
  end, { noremap = true })
end

return M
