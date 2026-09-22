local config = require("explain_it.config")
local context = require("explain_it.context")
local llm = require("explain_it.llm")
local prompt = require("explain_it.prompt")
local ui = require("explain_it.ui")

local M = {}

local RESULT_TITLE = "Explain it"

---@type {
---  source: { win?: integer, row?: integer, col?: integer, end_row?: integer, end_col?: integer },
---  messages: { role: string, content: string }[],
---  transcript: string,
---  pending_ctx?: table,
---  building?: boolean,
---}|nil
local follow_session = nil

---@type table|nil
local active_result_ui = nil

local function clear_follow_session()
  follow_session = nil
end

---@param target string
---@param filetype string|nil
---@return string
local function target_header(target, filetype)
  return prompt.explain_header({
    target = target,
    filetype = filetype,
  })
end

---@param header string
---@param status string
---@return string
local function header_with_status(header, status)
  header = header or ""
  if header == "" then
    return "**" .. status .. "**"
  end
  return header .. "**" .. status .. "**"
end

---@param target string|nil
---@param empty_msg string
---@return string|nil
local function require_target(target, empty_msg)
  if not target or vim.trim(target) == "" then
    vim.notify("[explain-it.nvim] " .. empty_msg, vim.log.levels.WARN)
    return nil
  end
  if not context.contains_language_text(target) then
    vim.notify(
      "[explain-it.nvim] 目标需包含语言文字（英文/中文等），不能仅为符号。",
      vim.log.levels.WARN
    )
    return nil
  end
  return target
end

---@param err string|nil
---@param content string|nil
---@param result_ui table
local function handle_llm_result(err, content, result_ui)
  if err then
    result_ui.update("错误:\n" .. err)
    vim.notify("[explain-it.nvim] " .. err, vim.log.levels.ERROR)
    return
  end
  result_ui.update(content or "")
end

---Stream LLM output into the result UI, with optional prefix/suffix wrappers.
---@param messages table
---@param result_ui table
---@param opts {
---  prefix?: string,
---  format?: fun(content: string): string,
---  finalize?: fun(content: string): string,
---  on_success?: fun(raw: string, formatted: string),
---  on_error?: fun(),
---}|nil
local function stream_to_ui(messages, result_ui, opts)
  opts = opts or {}
  local prefix = opts.prefix or ""
  local format = opts.format
  local finalize = opts.finalize
  local on_success = opts.on_success
  local on_error = opts.on_error

  llm.chat(messages, {
    on_delta = function(_, full)
      local text = format and format(full) or (prefix .. full)
      result_ui.update(text, { stream = true })
    end,
    on_done = function(err, content)
      if err then
        if format then
          result_ui.update(format("错误: " .. (err or "")))
        else
          handle_llm_result(err, content, result_ui)
        end
        if on_error then
          on_error()
        end
        return
      end
      local raw = content or ""
      local text = raw
      if finalize then
        text = finalize(raw)
      elseif format then
        text = format(raw)
      else
        text = prefix .. raw
      end
      handle_llm_result(nil, text, result_ui)
      if on_success then
        on_success(raw, text)
      end
    end,
  })
end

---@param question string
local function run_follow(question)
  local session = follow_session
  local result_ui = active_result_ui
  if not session or not result_ui then
    return
  end

  if session.building then
    vim.notify("[explain-it.nvim] 正在准备上下文，请稍候再问。", vim.log.levels.WARN)
    if result_ui.set_busy then
      result_ui.set_busy(false)
    end
    return
  end

  local base = session.transcript
  local loading = "**" .. ui.status_text("Asking") .. "**"
  local pending_ctx = session.pending_ctx

  local function popup_width()
    local win = result_ui.popup and result_ui.popup.winid
    if win and vim.api.nvim_win_is_valid(win) then
      return math.max(3, vim.api.nvim_win_get_width(win) - 2)
    end
    return nil
  end

  local function follow_text(answer)
    return prompt.append_follow_turn(base, question, answer, popup_width())
  end

  if pending_ctx then
    session.pending_ctx = nil
    session.messages = prompt.ask_messages(pending_ctx, question)
  else
    table.insert(session.messages, {
      role = "user",
      content = prompt.follow_user_message(question),
    })
  end

  result_ui.update(follow_text(loading))
  if result_ui.focus_content then
    result_ui.focus_content()
  end

  stream_to_ui(session.messages, result_ui, {
    format = function(full)
      if not full or full == "" then
        return follow_text(loading)
      end
      return follow_text(full)
    end,
    finalize = function(content)
      if pending_ctx then
        content = prompt.format_ask_result(content, pending_ctx)
      end
      return follow_text(content)
    end,
    on_success = function(raw, formatted)
      table.insert(session.messages, { role = "assistant", content = raw })
      session.transcript = formatted
      if result_ui.set_busy then
        result_ui.set_busy(false)
      end
      if result_ui.focus_content then
        result_ui.focus_content()
      end
    end,
    on_error = function()
      if result_ui.set_busy then
        result_ui.set_busy(false)
      end
      if result_ui.focus_content then
        result_ui.focus_content()
      end
    end,
  })
end

---@param source table
---@return table
local function followable_opts(source)
  return {
    source = source,
    followable = true,
    on_submit = function(question)
      if not follow_session then
        vim.notify("[explain-it.nvim] 请等待当前任务完成后再提问。", vim.log.levels.WARN)
        if active_result_ui and active_result_ui.set_busy then
          active_result_ui.set_busy(false)
        end
        return
      end
      run_follow(question)
    end,
  }
end

---@param from_visual boolean|nil
function M.explain(from_visual)
  clear_follow_session()
  active_result_ui = nil

  local target = require_target(context.get_target_text(from_visual), "没有可解释的目标文本。")
  if not target then
    return
  end

  local source = context.snapshot_source()

  if from_visual then
    vim.cmd("normal! \27")
  end

  local source_opts = {
    win = source.win,
    row = source.row,
    col = source.col,
    end_row = source.end_row,
    end_col = source.end_col,
  }

  local header = target_header(target, source.filetype)
  local status = ui.status_text("Explaining")
  local open_opts = followable_opts(source_opts)
  open_opts.content = header
  local result_ui = ui.open_result(RESULT_TITLE, nil, open_opts)
  active_result_ui = result_ui

  result_ui.update(header_with_status(header, status))

  context.build_for_target(target, source, function(ctx)
    local h = prompt.explain_header(ctx)
    result_ui.update(header_with_status(h, status))
    local messages = prompt.explain_messages(ctx)
    stream_to_ui(messages, result_ui, {
      prefix = h,
      finalize = function(content)
        return prompt.format_explain_result(content, ctx)
      end,
      on_success = function(raw, formatted)
        follow_session = {
          source = source_opts,
          messages = vim.deepcopy(messages),
          transcript = formatted,
        }
        table.insert(follow_session.messages, { role = "assistant", content = raw })
      end,
    })
  end)
end

---@param from_visual boolean|nil
function M.translate(from_visual)
  clear_follow_session()
  active_result_ui = nil

  local target = require_target(context.get_target_text(from_visual), "没有可翻译的目标文本。")
  if not target then
    return
  end

  local source = context.snapshot_source()

  if from_visual then
    vim.cmd("normal! \27")
  end

  local status = ui.status_text("Translating")
  local result_ui = ui.open_result(RESULT_TITLE, status, {
    fit = true,
    source = {
      win = source.win,
      row = source.row,
      col = source.col,
      end_row = source.end_row,
      end_col = source.end_col,
    },
  })
  active_result_ui = result_ui

  local messages = prompt.translate_messages(target)
  local function popup_width()
    local win = result_ui.popup and result_ui.popup.winid
    if win and vim.api.nvim_win_is_valid(win) then
      return vim.api.nvim_win_get_width(win)
    end
    return nil
  end
  local function format_translation(content)
    return prompt.format_translate_result(target, content, popup_width())
  end
  stream_to_ui(messages, result_ui, {
    format = format_translation,
    finalize = function(content)
      local text = format_translation(content)
      vim.schedule(function()
        result_ui.update(format_translation(content))
      end)
      return text
    end,
  })
end

function M.reopen()
  if not follow_session then
    ui.reopen_last()
    return
  end

  if ui.is_open() then
    ui.reopen_last()
    return
  end

  local result_ui = ui.open_result(RESULT_TITLE, nil, vim.tbl_extend("force", followable_opts(follow_session.source), {
    content = follow_session.transcript,
  }))
  active_result_ui = result_ui
end

---@param from_visual boolean|nil
function M.ask(from_visual)
  clear_follow_session()
  active_result_ui = nil

  local target = context.get_target_text(from_visual)
  if target and vim.trim(target) ~= "" and not context.contains_language_text(target) then
    vim.notify(
      "[explain-it.nvim] 目标需包含语言文字（英文/中文等），不能仅为符号。",
      vim.log.levels.WARN
    )
    return
  end
  target = target or ""

  local source = context.snapshot_source()

  if from_visual then
    vim.cmd("normal! \27")
  end

  local source_opts = {
    win = source.win,
    row = source.row,
    col = source.col,
    end_row = source.end_row,
    end_col = source.end_col,
  }

  local header = target_header(target, source.filetype)
  local open_opts = followable_opts(source_opts)
  open_opts.content = header
  local result_ui = ui.open_result(RESULT_TITLE, nil, open_opts)
  active_result_ui = result_ui

  follow_session = {
    source = source_opts,
    messages = {},
    transcript = header,
    building = true,
  }

  vim.schedule(function()
    if result_ui.focus_input then
      result_ui.focus_input()
    end
  end)

  local include_context = config.options.ask.include_context ~= false

  local function ready(ctx)
    if not follow_session then
      return
    end
    local h = prompt.explain_header(ctx)
    follow_session.pending_ctx = ctx
    follow_session.building = false
    follow_session.transcript = h
    follow_session.messages = {}
    result_ui.update(h)
  end

  if include_context then
    context.build_for_target(target, source, ready)
  else
    ready({
      target = target,
      filetype = source.filetype,
      filename = source.filename,
      nearby = nil,
    })
  end
end

function M.setup_commands()
  vim.api.nvim_create_user_command("Explain", function(opts)
    M.explain(opts.range ~= nil and opts.range > 0)
  end, { desc = "Explain symbol/selection with LLM", range = true })

  vim.api.nvim_create_user_command("ExplainTranslate", function(opts)
    M.translate(opts.range ~= nil and opts.range > 0)
  end, { desc = "Translate word/selection with LLM", range = true })

  vim.api.nvim_create_user_command("ExplainAsk", function(opts)
    M.ask(opts.range ~= nil and opts.range > 0)
  end, { desc = "Ask LLM about word/selection", range = true })

  vim.api.nvim_create_user_command("ExplainLast", function()
    M.reopen()
  end, { desc = "Reopen last explain-it result popup" })
end

function M.setup_keymaps()
  local maps = config.options.keymaps
  if not maps then
    return
  end

  local function map(lhs, rhs_n, rhs_v, desc)
    if not lhs or lhs == false or lhs == "" then
      return
    end
    vim.keymap.set("n", lhs, rhs_n, { desc = desc, silent = true })
    vim.keymap.set("v", lhs, rhs_v, { desc = desc, silent = true })
  end

  map(maps.explain, function()
    M.explain(false)
  end, function()
    M.explain(true)
  end, "Explain: explain")

  map(maps.translate, function()
    M.translate(false)
  end, function()
    M.translate(true)
  end, "Explain: translate")

  map(maps.ask, function()
    M.ask(false)
  end, function()
    M.ask(true)
  end, "Explain: ask")

  local reopen = maps.reopen
  if reopen and reopen ~= false and reopen ~= "" then
    vim.keymap.set("n", reopen, function()
      M.reopen()
    end, { desc = "Explain: reopen last result", silent = true })
  end
end

return M
