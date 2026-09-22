local config = require("explain_it.config")
local context = require("explain_it.context")
local llm = require("explain_it.llm")
local prompt = require("explain_it.prompt")
local ui = require("explain_it.ui")

local M = {}

local RESULT_TITLE = "Explain it"

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
---}|nil
local function stream_to_ui(messages, result_ui, opts)
  opts = opts or {}
  local prefix = opts.prefix or ""
  local format = opts.format
  local finalize = opts.finalize

  llm.chat(messages, {
    on_delta = function(_, full)
      local text = format and format(full) or (prefix .. full)
      result_ui.update(text, { stream = true })
    end,
    on_done = function(err, content)
      if err then
        handle_llm_result(err, content, result_ui)
        return
      end
      local text = content or ""
      if finalize then
        text = finalize(text)
      elseif format then
        text = format(text)
      else
        text = prefix .. text
      end
      handle_llm_result(nil, text, result_ui)
    end,
  })
end

---@param from_visual boolean|nil
function M.explain(from_visual)
  local target = require_target(context.get_target_text(from_visual), "没有可解释的目标文本。")
  if not target then
    return
  end

  local source = context.snapshot_source()

  if from_visual then
    vim.cmd("normal! \27")
  end

  local status = ui.status_text("Explaining")
  local result_ui = ui.open_result(RESULT_TITLE, status, {
    source = {
      win = source.win,
      row = source.row,
      col = source.col,
      end_row = source.end_row,
      end_col = source.end_col,
    },
  })

  context.build_for_target(target, source, function(ctx)
    result_ui.update(status, { status = true })
    local messages = prompt.explain_messages(ctx)
    local header = prompt.explain_header(ctx)
    stream_to_ui(messages, result_ui, {
      prefix = header,
      finalize = function(content)
        return prompt.format_explain_result(content, ctx)
      end,
    })
  end)
end

---@param from_visual boolean|nil
function M.translate(from_visual)
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
      -- After fit resize, redraw separator to match final width
      vim.schedule(function()
        result_ui.update(format_translation(content))
      end)
      return text
    end,
  })
end

---@param from_visual boolean|nil
function M.ask(from_visual)
  local target = context.get_target_text(from_visual)
  if target and vim.trim(target) ~= "" and not context.contains_language_text(target) then
    vim.notify(
      "[explain-it.nvim] 目标需包含语言文字（英文/中文等），不能仅为符号。",
      vim.log.levels.WARN
    )
    return
  end
  local source = context.snapshot_source()

  if from_visual then
    vim.cmd("normal! \27")
  end

  local include_context = config.options.ask.include_context

  local function run_ask(question)
    question = vim.trim(question or "")
    if question == "" then
      vim.notify("[explain-it.nvim] 问题不能为空。", vim.log.levels.WARN)
      return
    end

    local status = ui.status_text("Asking")
    local result_ui = ui.open_result(RESULT_TITLE, status, {
      source = {
        win = source.win,
        row = source.row,
        col = source.col,
        end_row = source.end_row,
        end_col = source.end_col,
      },
    })

    local function send(ctx)
      result_ui.update(status, { status = true })
      local messages = prompt.ask_messages(ctx, question)
      stream_to_ui(messages, result_ui, {
        finalize = function(content)
          return prompt.format_ask_result(content, ctx)
        end,
      })
    end

    if include_context then
      context.build_for_target(target or "", source, send)
    else
      send({
        target = target or "",
        filetype = source.filetype,
        filename = source.filename,
        nearby = nil,
      })
    end
  end

  ui.ask_input({
    title = "Ask",
    on_submit = run_ask,
  })
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
end

return M
