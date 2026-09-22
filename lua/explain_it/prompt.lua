local config = require("explain_it.config")

local M = {}

---@param code string
---@param filetype string|nil
---@return string
local function fence(code, filetype)
  local lang = (filetype and filetype ~= "") and filetype or ""
  return "```" .. lang .. "\n" .. code .. "\n```"
end

---@param ctx table
---@return string
local function format_meta(ctx)
  local parts = {}
  if ctx.filetype and ctx.filetype ~= "" then
    table.insert(parts, "文件类型: " .. ctx.filetype)
  end
  if ctx.filename and ctx.filename ~= "" then
    table.insert(parts, "文件: " .. ctx.filename)
  end
  if #parts == 0 then
    return ""
  end
  return table.concat(parts, "\n") .. "\n\n"
end

---@param ctx table
---@return string
local function collect_original_comments(ctx)
  -- Only for single-symbol explains; selections must not inherit nested-token docs
  if ctx.is_symbol == false then
    return ""
  end
  -- Strictly definition-site original comments/docstring (not local, not hover)
  if ctx.definition_comments and ctx.definition_comments ~= "" then
    return ctx.definition_comments
  end
  return ""
end

---@param ctx table
---@return string
local function format_context(ctx)
  local parts = {}
  local ft = ctx.filetype

  if ctx.target and ctx.target ~= "" then
    table.insert(parts, "目标文本:\n" .. fence(ctx.target, ft))
  end

  if ctx.local_comments and ctx.local_comments ~= "" then
    table.insert(parts, "光标附近注释:\n" .. ctx.local_comments)
  end

  -- Symbol-only: definition / hover belong to a single identifier
  if ctx.is_symbol ~= false then
    if ctx.definition_comments and ctx.definition_comments ~= "" then
      table.insert(parts, "定义处原文注释:\n" .. ctx.definition_comments)
    end

    if ctx.hover and ctx.hover ~= "" then
      table.insert(parts, "LSP Hover:\n" .. ctx.hover)
    end

    if ctx.definition and ctx.definition ~= "" then
      table.insert(parts, "定义处源码:\n" .. fence(ctx.definition, ft))
    end
  end

  if ctx.enclosing and ctx.enclosing ~= "" then
    table.insert(parts, "包围代码块:\n" .. fence(ctx.enclosing, ft))
  elseif ctx.nearby and ctx.nearby ~= "" then
    table.insert(parts, "周围代码:\n" .. fence(ctx.nearby, ft))
  end

  return table.concat(parts, "\n\n")
end

---@param ctx table
---@return { role: string, content: string }[]
function M.explain_messages(ctx)
  local lang = config.options.translate.target_lang or "zh-CN"
  local system

  if ctx.is_symbol then
    system = table.concat({
      "你是资深程序员助手，解释代码中的符号。",
      "用简体中文，精简直接：优先 3–6 句；禁止套话、百科式铺垫、让用户再贴代码。",
      "必须结合给定文件类型与上下文作答；可引用注释含义，但不要在文末重复粘贴注释原文（系统会自动附加「## 原文注释」）。",
      "若上下文中有「定义处原文注释」且主要为英文（或明显不是目标语言），在文末另起「## 原文注释翻译」，将注释译为目标语言（"
        .. lang
        .. "）；注释已是目标语言则不要此节。",
      "不要编造不存在的信息；不要输出解释目标标题（系统会自动加上）。",
      "用 Markdown 输出，结构如下（按需省略「注意点」「原文注释翻译」）：",
      "## 定义",
      "一句话。",
      "## 在本处的作用",
      "结合上下文说明。",
      "## 注意点",
      "- 条目",
      "## 原文注释翻译",
      "（仅当原文注释为英文时）译文",
      "不要使用「* **粗体**：」这种嵌套列表写法；标题用 ##，正文用段落或简单 - 列表。",
    }, "\n")
  else
    system = table.concat({
      "你是资深程序员助手，解释用户选中的整段代码。",
      "用简体中文，精简直接：优先 3–8 句；禁止套话、百科式铺垫、让用户再贴代码。",
      "必须解释整段选中内容本身（例如完整函数签名、表达式、语句块），不要只挑选区里的某一个标识符或类型名来下「定义」。",
      "必须结合给定文件类型与上下文作答；不要编造不存在的信息；不要输出解释目标标题（系统会自动加上）。",
      "不要输出「## 原文注释」或「## 定义」（选区场景不用符号定义结构）。",
      "用 Markdown 输出，结构如下（按需省略「注意点」）：",
      "## 解释",
      "这段选中代码在做什么。",
      "## 注意点",
      "- 条目",
      "不要使用「* **粗体**：」这种嵌套列表写法；标题用 ##，正文用段落或简单 - 列表。",
    }, "\n")
  end

  local user = format_meta(ctx) .. "请解释下列目标：\n\n" .. format_context(ctx)

  return {
    { role = "system", content = system },
    { role = "user", content = user },
  }
end

---Header shown above the model reply (target identity).
---@param ctx table
---@return string
function M.explain_header(ctx)
  local target = vim.trim(ctx.target or "")
  if target == "" then
    return ""
  end
  if not target:find("\n", 1, true) and vim.fn.strdisplaywidth(target) <= 72 then
    return "# `" .. target .. "`\n\n"
  end
  return "# 解释目标\n" .. fence(target, ctx.filetype) .. "\n\n"
end

---Pull optional「原文注释翻译」out of the model body so we can append it after 原文注释.
---@param body string
---@return string body
---@return string|nil translation
local function extract_comment_translation(body)
  local before, rest = body:match("^(.-)\n*##%s*原文注释翻译%s*\n(.*)$")
  if not before then
    -- heading with no body (or only whitespace after)
    before = body:match("^(.-)\n*##%s*原文注释翻译%s*$")
    if before then
      return vim.trim(before), nil
    end
    return body, nil
  end

  local translation = rest
  local next_heading = rest:find("\n##%s+")
  if next_heading then
    translation = rest:sub(1, next_heading - 1)
    before = before .. rest:sub(next_heading)
  end

  translation = vim.trim(translation)
  if translation == "" then
    translation = nil
  end
  return vim.trim(before), translation
end

---Comments footer appended after the model reply.
---@param ctx table
---@param translation string|nil
---@return string
function M.comments_footer(ctx, translation)
  local comments = collect_original_comments(ctx)
  if comments == "" then
    return ""
  end
  -- Keep original text as-is inside a fence (no reformatting)
  local out = "\n\n## 原文注释\n```\n" .. comments .. "\n```"
  if translation and translation ~= "" then
    out = out .. "\n\n## 原文注释翻译\n" .. translation
  end
  return out
end

---Strip trailing comment sections the model may have duplicated.
---@param body string
---@return string
local function strip_trailing_comment_sections(body)
  body = body:gsub("\n*##%s*相关注释[%s%S]*$", "")
  body = body:gsub("\n*##%s*原文注释[%s%S]*$", "")
  return vim.trim(body)
end

---Wrap model reply with target header and original comments (code-side, reliable).
---@param content string|nil
---@param ctx table
---@return string
function M.format_explain_result(content, ctx)
  local body = vim.trim(content or "")
  local translation
  body, translation = extract_comment_translation(body)
  body = strip_trailing_comment_sections(body)
  return M.explain_header(ctx) .. body .. M.comments_footer(ctx, translation)
end

---@param text string
---@return { role: string, content: string }[]
function M.translate_messages(text)
  local lang = config.options.translate.target_lang or "zh-CN"
  local system = table.concat({
    "你是专业翻译。将用户给出的文本翻译成目标语言。",
    "目标语言: " .. lang,
    "只输出译文本身，不要复述原文，不要加「原文:」等前缀或标题，不要额外解释。",
    "保留专有名词、标识符、代码片段不乱译。",
  }, "\n")

  return {
    { role = "system", content = system },
    { role = "user", content = text },
  }
end

---Strip leading whitespace on each line (keeps blank lines).
---@param text string
---@return string
local function dedent_lines(text)
  local lines = vim.split(text or "", "\n", { plain = true })
  for i, line in ipairs(lines) do
    lines[i] = line:gsub("^%s+", "")
  end
  return vim.trim(table.concat(lines, "\n"))
end

---@param text string
---@return integer
local function max_line_width(text)
  local max_w = 0
  for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
    max_w = math.max(max_w, vim.fn.strdisplaywidth(line))
  end
  return max_w
end

---Full-width separator with a centered bullet: ────•────
---@param width integer|nil
---@return string
function M.translate_separator(width)
  width = math.max(3, math.floor(width or 40))
  local bullet = "•"
  local bw = vim.fn.strdisplaywidth(bullet)
  local side = math.max(0, width - bw)
  local left = math.floor(side / 2)
  local right = side - left
  return string.rep("─", left) .. bullet .. string.rep("─", right)
end

---Format translate float: original, full-width rule, then translation.
---@param original string
---@param translation string|nil
---@param width integer|nil popup width; defaults to content width
---@return string
function M.format_translate_result(original, translation, width)
  local src = dedent_lines(original or "")
  local dst = dedent_lines(translation or "")
  -- Strip common model prefixes if still present
  dst = dst:gsub("^原文%s*[:：]%s*", "")
  dst = dst:gsub("^原文%s*\n+", "")
  dst = dedent_lines(dst)
  if src == "" then
    return dst
  end
  if dst == "" then
    return src
  end
  local sep_w = width
  if not sep_w or sep_w < 3 then
    sep_w = math.max(max_line_width(src), max_line_width(dst), 24)
  end
  return src .. "\n" .. M.translate_separator(sep_w) .. "\n" .. dst
end

---@param ctx table
---@param question string
---@return { role: string, content: string }[]
function M.ask_messages(ctx, question)
  local lang = config.options.translate.target_lang or "zh-CN"
  local system = table.concat({
    "你是资深程序员助手。根据目标文本、文件类型与上下文回答用户问题。",
    "用简体中文，精简准确；用清晰 Markdown（## 标题 + 段落/简单列表）；不要编造。",
    "可引用注释含义，但不要在文末重复粘贴注释原文（系统会自动附加「## 原文注释」）。",
    "若上下文中有「定义处原文注释」且主要为英文（或明显不是目标语言），在文末另起「## 原文注释翻译」，将注释译为目标语言（"
      .. lang
      .. "）；注释已是目标语言则不要此节。",
  }, "\n")

  local user_parts = {
    format_meta(ctx) .. "用户问题:\n" .. question,
    "",
    format_context(ctx),
  }

  return {
    { role = "system", content = system },
    { role = "user", content = table.concat(user_parts, "\n") },
  }
end

---Append original comments for ask results when present.
---@param content string|nil
---@param ctx table
---@return string
function M.format_ask_result(content, ctx)
  local body = vim.trim(content or "")
  local translation
  body, translation = extract_comment_translation(body)
  body = strip_trailing_comment_sections(body)

  local footer = M.comments_footer(ctx, translation)
  if footer == "" then
    return body
  end
  return body .. footer
end

return M
