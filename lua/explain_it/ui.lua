local Popup = require("nui.popup")
local Layout = require("nui.layout")
local event = require("nui.utils.autocmd").event

local config = require("explain_it.config")

local M = {}

---@type NuiPopup|nil
local active_popup = nil

---@type NuiLayout|nil
local active_layout = nil

---@type table|nil result handle (update / close / focus_*)
local active_handle = nil

local FOLLOW_INPUT_LINES = 2
-- nui box size ≈ text lines + top/bottom border
local FOLLOW_INPUT_HEIGHT = FOLLOW_INPUT_LINES + 2

---@type {
---  title: string,
---  text: string,
---  fit: boolean,
---  source?: { win?: integer, row?: integer, col?: integer, end_row?: integer, end_col?: integer },
---}|nil
local last_result = nil

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

  local ft = result_filetype()
  pcall(function()
    vim.bo[bufnr].filetype = ft
  end)

  -- scrollbar=false uses filetype explain_it; map it so treesitter / render-markdown
  -- still treat the buffer as markdown (otherwise fenced ``` stays visible).
  if ft == RESULT_FT_NO_SCROLLBAR then
    pcall(vim.treesitter.language.register, "markdown", RESULT_FT_NO_SCROLLBAR)
  end

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

  -- Allow auto-attach / Api.render for our no-scrollbar filetype.
  if ft == RESULT_FT_NO_SCROLLBAR then
    pcall(function()
      local state = require("render-markdown.state")
      if type(state.file_types) == "table" and not vim.tbl_contains(state.file_types, RESULT_FT_NO_SCROLLBAR) then
        table.insert(state.file_types, RESULT_FT_NO_SCROLLBAR)
      end
    end)
  end

  -- state.get() only merges custom config on cache miss.
  pcall(function()
    local state = require("render-markdown.state")
    if type(state.cache) == "table" then
      state.cache[bufnr] = nil
    end
  end)

  -- render-markdown defaults: anti_conceal on + concealcursor='' while rendered,
  -- which both expose raw MD on the cursor line. Override for our focused float.
  if type(rm.render) == "function" then
    pcall(rm.render, {
      buf = bufnr,
      win = winid,
      config = {
        anti_conceal = { enabled = false },
        code = { width = "full" },
        win_options = {
          concealcursor = {
            default = "",
            rendered = "nvic",
          },
        },
      },
    })
  elseif type(rm.buf_enable) == "function" then
    pcall(function()
      vim.api.nvim_buf_call(bufnr, function()
        rm.buf_enable()
      end)
    end)
  end

  -- Re-assert after render (rm applies win_options asynchronously via debounce).
  if winid and vim.api.nvim_win_is_valid(winid) then
    pcall(function()
      vim.wo[winid].conceallevel = 2
      vim.wo[winid].concealcursor = "nvic"
    end)
    vim.schedule(function()
      if winid and vim.api.nvim_win_is_valid(winid) then
        pcall(function()
          vim.wo[winid].conceallevel = 2
          vim.wo[winid].concealcursor = "nvic"
        end)
      end
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

  -- gap: target clearance (in lines) between source and float outer edge.
  local gap = math.max(0, tonumber(ui.gap) or 1)
  local space_below = vim.o.lines - screen_end - 1 - gap
  local space_above = screen_start - 1 - gap

  local place_below
  if anchor == "below" then
    place_below = true
  elseif anchor == "above" then
    place_below = false
  else
    place_below = space_below >= space_above
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
  -- nui/neovim accept fractional row for sub-line tweaks.
  local anchor_row, anchor_col, row
  if place_below then
    anchor_row, anchor_col = end_row, end_col
    -- Previous tuck (gap - 2), then shift down by 2 lines + one gap, then up 0.5.
    row = (gap - 2) + (2 + gap) - 0.5
  else
    anchor_row, anchor_col = start_row, start_col
    local above_fudge = 2
    -- Shift up by half a line from the border-compensated position.
    row = -(height + gap - above_fudge) - 1
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
---@param opts {
---  enter?: boolean,
---  close_on_leave?: boolean,
---  mount?: boolean,
---  relative?: any,
---  position?: any,
---  size?: { width: integer, height: integer },
---  padding?: table,
---}|nil
---@return NuiPopup
local function create_content_popup(title, opts)
  opts = opts or {}
  local ui_opts = config.options.ui

  if ui_opts.scrollbar == false then
    ensure_scrollbar_exclusions()
  end

  local border = {
    style = ui_opts.border,
    text = {
      top = " " .. title .. " ",
      top_align = ui_opts.title_align or "center",
    },
  }
  if opts.padding then
    border.padding = opts.padding
  end

  local popup_opts = {
    enter = opts.enter ~= false,
    focusable = true,
    border = border,
    win_options = {
      wrap = ui_opts.wrap ~= false,
      linebreak = ui_opts.linebreak ~= false,
      conceallevel = 2,
      concealcursor = "nvic",
      winhighlight = ui_opts.winhighlight or "Normal:Normal,FloatBorder:FloatBorder",
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
  if opts.relative then
    popup_opts.relative = opts.relative
  end
  if opts.position then
    popup_opts.position = opts.position
  end
  if opts.size then
    popup_opts.size = opts.size
  end
  if ui_opts.zindex then
    popup_opts.zindex = ui_opts.zindex
  end

  local popup = Popup(popup_opts)

  if opts.mount ~= false then
    popup:mount()
    if ui_opts.scrollbar == false then
      clear_scrollbar(popup.bufnr)
    end
  end

  if opts.close_on_leave ~= false then
    popup:on(event.BufLeave, function()
      popup:unmount()
    end)
  end

  return popup
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

---@param winid integer|nil
---@param bufnr integer
local function scroll_to_bottom(winid, bufnr)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  pcall(vim.api.nvim_win_set_cursor, winid, { line_count, 0 })
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

---Remember the latest non-status result so it can be reopened after close.
---@param title string
---@param text string
---@param fit boolean
---@param source table|nil
local function remember_result(title, text, fit, source)
  if type(text) ~= "string" or vim.trim(text) == "" then
    return
  end
  last_result = {
    title = title,
    text = text,
    fit = fit == true,
    source = source,
  }
end

local function clear_active()
  active_popup = nil
  active_layout = nil
  active_handle = nil
end

---Close the active result UI if any.
function M.close_active()
  if active_layout then
    pcall(function()
      active_layout:unmount()
    end)
  elseif active_popup then
    pcall(function()
      active_popup:unmount()
    end)
  end
  clear_active()
end

---@return boolean
function M.is_open()
  if active_layout then
    return true
  end
  return active_popup ~= nil and active_popup.winid ~= nil and vim.api.nvim_win_is_valid(active_popup.winid)
end

---@param popup NuiPopup
---@param unmount_fn fun()
local function map_close_keys(popup, unmount_fn)
  popup:map("n", "q", unmount_fn, { noremap = true, silent = true })
  popup:map("n", "<Esc>", unmount_fn, { noremap = true, silent = true })
end

---@param source table|nil
---@return integer
local function resolve_return_win(source)
  if source and source.win and vim.api.nvim_win_is_valid(source.win) then
    return source.win
  end
  return vim.api.nvim_get_current_win()
end

---@param win integer|nil
local function restore_win(win)
  vim.schedule(function()
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_set_current_win, win)
    end
  end)
end

---@param title string
---@param source table|nil
---@param size { width: integer, height: integer }
---@param fit boolean
---@param content string|nil
---@param initial_text string|nil
---@param on_submit fun(question: string)
---@return table
local function open_followable_result(title, source, size, fit, content, initial_text, on_submit)
  local ui_opts = config.options.ui
  local return_win = resolve_return_win(source)
  -- Placement must use the full layout height (content + Ask), otherwise
  -- "above" overlaps the source and "below" spacing looks inconsistent.
  local desired_height = size.height + FOLLOW_INPUT_HEIGHT
  local place = resolve_popup_placement(source, size.width, desired_height)
  local layout_width = place.size.width
  local layout_height = math.max(place.size.height, FOLLOW_INPUT_HEIGHT + 3)

  local content_popup = create_content_popup(title, {
    enter = ui_opts.enter ~= false,
    close_on_leave = false,
    mount = false,
    -- left padding for the answer body
    padding = { top = 0, right = 0, bottom = 0, left = 1 },
  })

  -- Ask always keeps its own scrollbar (ignore ui.scrollbar).
  -- Extra right padding so the scrollbar does not cover the last character.
  local prompt = Popup({
    enter = false,
    focusable = true,
    border = {
      style = ui_opts.border,
      padding = { top = 0, right = 2, bottom = 0, left = 1 },
      text = {
        top = " Ask · C-s 发送 ",
        top_align = "left",
      },
    },
    win_options = {
      wrap = true,
      linebreak = true,
      scrolloff = 0,
      sidescrolloff = 0,
      smoothscroll = false,
      list = false,
      number = false,
      relativenumber = false,
      signcolumn = "no",
      foldcolumn = "0",
      -- non-empty showbreak suppresses the smoothscroll "<<<" marker
      showbreak = " ",
      winhighlight = ui_opts.winhighlight or "Normal:Normal,FloatBorder:FloatBorder",
    },
    buf_options = {
      modifiable = true,
      buftype = "nofile",
      bufhidden = "wipe",
      swapfile = false,
      filetype = "explain_it_ask",
    },
  })

  local layout_opts = {
    relative = place.relative,
    position = place.position,
    size = { width = layout_width, height = layout_height },
  }
  if ui_opts.zindex then
    layout_opts.zindex = ui_opts.zindex
  end

  local layout = Layout(
    layout_opts,
    Layout.Box({
      Layout.Box(content_popup, { grow = 1 }),
      Layout.Box(prompt, { size = FOLLOW_INPUT_HEIGHT }),
    }, { dir = "col" })
  )

  layout:mount()

  local function harden_ask_win()
    if not prompt.winid or not vim.api.nvim_win_is_valid(prompt.winid) then
      return
    end
    local win = prompt.winid
    pcall(vim.api.nvim_win_call, win, function()
      vim.opt_local.wrap = true
      vim.opt_local.linebreak = true
      vim.opt_local.smoothscroll = false
      vim.opt_local.list = false
      vim.opt_local.number = false
      vim.opt_local.relativenumber = false
      vim.opt_local.signcolumn = "no"
      vim.opt_local.foldcolumn = "0"
      -- Non-empty showbreak disables the "<<<" first-line marker.
      vim.opt_local.showbreak = " "
      pcall(function()
        vim.opt_local.fillchars:append({ lastline = " " })
      end)
    end)
  end

  harden_ask_win()
  if vim.api.nvim_buf_is_valid(prompt.bufnr) then
    vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
      buffer = prompt.bufnr,
      callback = function()
        vim.schedule(harden_ask_win)
      end,
    })
  end

  if not scrollbar_enabled() then
    clear_scrollbar(content_popup.bufnr)
  end

  active_popup = content_popup
  active_layout = layout

  local closed = false
  local busy = false
  local last_render_ms = 0

  local function unmount_all()
    if closed then
      return
    end
    closed = true
    pcall(function()
      layout:unmount()
    end)
    if active_layout == layout then
      clear_active()
    end
    restore_win(return_win)
  end

  content_popup:on(event.BufWipeout, function()
    closed = true
    if active_layout == layout then
      clear_active()
    end
    restore_win(return_win)
  end)

  map_close_keys(content_popup, unmount_all)

  local function focus_content()
    if content_popup.winid and vim.api.nvim_win_is_valid(content_popup.winid) then
      pcall(vim.api.nvim_set_current_win, content_popup.winid)
    end
  end

  local function focus_input()
    if closed or not prompt.winid or not vim.api.nvim_win_is_valid(prompt.winid) then
      return
    end
    pcall(vim.api.nvim_set_current_win, prompt.winid)
    vim.schedule(function()
      if prompt.winid and vim.api.nvim_win_is_valid(prompt.winid) then
        vim.api.nvim_win_call(prompt.winid, function()
          vim.cmd("startinsert!")
        end)
      end
    end)
  end

  local follow_key = config.options.keymaps and config.options.keymaps.follow_float
  if follow_key and follow_key ~= false and follow_key ~= "" then
    content_popup:map("n", follow_key, function()
      focus_input()
    end, { noremap = true, silent = true })
  end

  local function clear_prompt()
    if not vim.api.nvim_buf_is_valid(prompt.bufnr) then
      return
    end
    vim.bo[prompt.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(prompt.bufnr, 0, -1, false, { "" })
  end

  local function read_prompt()
    if not vim.api.nvim_buf_is_valid(prompt.bufnr) then
      return ""
    end
    return vim.trim(table.concat(vim.api.nvim_buf_get_lines(prompt.bufnr, 0, -1, false), "\n"))
  end

  local function submit_prompt()
    if busy then
      return
    end
    local question = read_prompt()
    clear_prompt()
    vim.cmd("stopinsert")
    focus_content()
    if question == "" then
      return
    end
    busy = true
    on_submit(question)
  end

  clear_prompt()

  -- Screen-line movement so Up/Down scroll wrapped / multi-line Ask text.
  prompt:map("i", "<Up>", "<C-o>gk", { noremap = true, silent = true })
  prompt:map("i", "<Down>", "<C-o>gj", { noremap = true, silent = true })
  prompt:map("n", "<Up>", "gk", { noremap = true, silent = true })
  prompt:map("n", "<Down>", "gj", { noremap = true, silent = true })
  prompt:map("n", "k", "gk", { noremap = true, silent = true })
  prompt:map("n", "j", "gj", { noremap = true, silent = true })

  -- Insert <CR> = newline; C-s (and normal <CR>) = send
  prompt:map("i", "<C-s>", function()
    submit_prompt()
  end, { noremap = true, silent = true })

  prompt:map("n", "<C-s>", function()
    submit_prompt()
  end, { noremap = true, silent = true })

  prompt:map("n", "<CR>", function()
    submit_prompt()
  end, { noremap = true, silent = true })

  prompt:map("i", "<Esc>", function()
    -- Leave insert on the Ask window first; :stopinsert is deferred and would
    -- otherwise apply the Esc left-shift after we already switched to content.
    local keys = vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true)
    vim.api.nvim_feedkeys(keys, "n", false)
    vim.schedule(function()
      focus_content()
    end)
  end, { noremap = true, silent = true })

  prompt:map("n", "<Esc>", function()
    focus_content()
  end, { noremap = true, silent = true })

  prompt:map("n", "q", function()
    unmount_all()
  end, { noremap = true, silent = true })

  local function apply_content(text, opts2)
    if closed or not vim.api.nvim_buf_is_valid(content_popup.bufnr) then
      return
    end
    opts2 = opts2 or {}

    if opts2.status then
      set_lines(content_popup.bufnr, centered_status_lines(text, content_popup.winid))
      refresh_markdown(content_popup.bufnr, content_popup.winid)
      return
    end

    remember_result(title, text or "", fit, source)
    set_lines(content_popup.bufnr, vim.split(text or "", "\n", { plain = true }))
    scroll_to_bottom(content_popup.winid, content_popup.bufnr)

    if opts2.stream then
      local now = (vim.uv or vim.loop).hrtime() / 1e6
      if now - last_render_ms < 120 then
        return
      end
      last_render_ms = now
      setup_markdown_buffer(content_popup.bufnr, content_popup.winid)
      return
    end

    refresh_markdown(content_popup.bufnr, content_popup.winid)
  end

  if content then
    apply_content(content, {})
  else
    set_lines(
      content_popup.bufnr,
      centered_status_lines(initial_text or M.status_text("Explaining"), content_popup.winid)
    )
    refresh_markdown(content_popup.bufnr, content_popup.winid)
  end

  local handle = {
    popup = content_popup,
    layout = layout,
    update = function(text, opts2)
      apply_content(text, opts2)
    end,
    set_busy = function(value)
      busy = value == true
    end,
    focus_input = focus_input,
    focus_content = focus_content,
    close = unmount_all,
  }
  active_handle = handle
  return handle
end

---@param title string
---@param source table|nil
---@param size { width: integer, height: integer }
---@param fit boolean
---@param content string|nil
---@param initial_text string|nil
---@return table
local function open_simple_result(title, source, size, fit, content, initial_text)
  local ui_opts = config.options.ui
  local return_win = resolve_return_win(source)
  local place = resolve_popup_placement(source, size.width, size.height)

  local popup = create_content_popup(title, {
    enter = ui_opts.enter ~= false,
    close_on_leave = ui_opts.close_on_leave ~= false,
    mount = true,
    relative = place.relative,
    position = place.position,
    size = place.size,
  })
  active_popup = popup
  active_layout = nil

  local closed = false
  local last_render_ms = 0
  local last_size = { width = size.width, height = size.height }

  local function unmount_popup()
    if closed then
      return
    end
    closed = true
    pcall(function()
      popup:unmount()
    end)
    if active_popup == popup then
      clear_active()
    end
    restore_win(return_win)
  end

  map_close_keys(popup, unmount_popup)

  popup:on(event.BufWipeout, function()
    if not closed then
      closed = true
      if active_popup == popup then
        clear_active()
      end
      restore_win(return_win)
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

    local new_place = resolve_popup_placement(source, width, height)
    pcall(function()
      popup:update_layout({
        relative = new_place.relative,
        position = new_place.position,
        size = new_place.size,
      })
    end)
  end

  if content then
    set_lines(popup.bufnr, vim.split(content, "\n", { plain = true }))
    apply_fit_size(content)
    remember_result(title, content, fit, source)
  else
    set_lines(popup.bufnr, centered_status_lines(initial_text or M.status_text("Explaining"), popup.winid))
  end
  refresh_markdown(popup.bufnr, popup.winid)

  local handle = {
    popup = popup,
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

      remember_result(title, text or "", fit, source)
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
    close = unmount_popup,
  }
  active_handle = handle
  return handle
end

---Show a result popup; opts.fit enables content-aware sizing (for translate).
---@param title string|nil
---@param initial_text string|nil
---@param opts {
---  source?: { win?: integer, row?: integer, col?: integer, end_row?: integer, end_col?: integer },
---  fit?: boolean,
---  content?: string,
---  followable?: boolean,
---  on_submit?: fun(question: string),
---}|nil
---@return table
function M.open_result(title, initial_text, opts)
  title = title or "Explain it"
  opts = opts or {}
  local fit = opts.fit == true
  local source = opts.source
  local content = opts.content
  local followable = opts.followable == true and type(opts.on_submit) == "function"

  M.close_active()

  local size = initial_size(fit, content or initial_text)

  if followable then
    return open_followable_result(title, source, size, fit, content, initial_text, opts.on_submit)
  end
  return open_simple_result(title, source, size, fit, content, initial_text)
end

---Reopen the last result popup after it was closed with q / Esc.
---@return boolean opened
function M.reopen_last()
  if M.is_open() then
    if active_popup and active_popup.winid and vim.api.nvim_win_is_valid(active_popup.winid) then
      pcall(vim.api.nvim_set_current_win, active_popup.winid)
    end
    return true
  end

  if not last_result then
    vim.notify("[explain-it.nvim] 没有可重新打开的上次结果。", vim.log.levels.WARN)
    return false
  end

  M.open_result(last_result.title, nil, {
    fit = last_result.fit,
    source = last_result.source,
    content = last_result.text,
  })
  return true
end

return M
