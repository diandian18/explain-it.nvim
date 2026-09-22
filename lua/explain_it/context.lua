local config = require("explain_it.config")

local M = {}

---@return string|nil
function M.get_visual_selection()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_row, start_col = start_pos[2], start_pos[3]
  local end_row, end_col = end_pos[2], end_pos[3]

  if start_row == 0 or end_row == 0 then
    return nil
  end

  if start_row > end_row or (start_row == end_row and start_col > end_col) then
    start_row, end_row = end_row, start_row
    start_col, end_col = end_col, start_col
  end

  local lines = vim.api.nvim_buf_get_lines(0, start_row - 1, end_row, false)
  if #lines == 0 then
    return nil
  end

  local vmode = vim.fn.visualmode()
  if vmode == "V" then
    return table.concat(lines, "\n")
  end

  -- character / block: trim first/last by columns (byte-oriented)
  local last_line = lines[#lines]
  local end_byte = end_col
  if end_col >= vim.v.maxcol or end_col > #last_line then
    end_byte = #last_line
  end
  lines[#lines] = last_line:sub(1, end_byte)
  lines[1] = lines[1]:sub(start_col)

  local text = table.concat(lines, "\n")
  if text == "" then
    return nil
  end
  return text
end

---Capture visual selection while still in visual mode (preferred for keymaps).
---@return string|nil
function M.get_visual_selection_live()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return M.get_visual_selection()
  end

  local start_pos = vim.fn.getpos("v")
  local end_pos = vim.fn.getpos(".")
  local start_row, start_col = start_pos[2], start_pos[3]
  local end_row, end_col = end_pos[2], end_pos[3]

  if start_row > end_row or (start_row == end_row and start_col > end_col) then
    start_row, end_row = end_row, start_row
    start_col, end_col = end_col, start_col
  end

  local lines = vim.api.nvim_buf_get_lines(0, start_row - 1, end_row, false)
  if #lines == 0 then
    return nil
  end

  if mode == "V" then
    return table.concat(lines, "\n")
  end

  local last_line = lines[#lines]
  local end_byte = math.min(end_col, #last_line)
  lines[#lines] = last_line:sub(1, end_byte)
  lines[1] = lines[1]:sub(start_col)
  local text = table.concat(lines, "\n")
  if text == "" then
    return nil
  end
  return text
end

---@param prefer_visual boolean|nil
---@return string
function M.get_target_text(prefer_visual)
  if prefer_visual ~= false then
    local visual = M.get_visual_selection_live()
    if visual and vim.trim(visual) ~= "" then
      return visual
    end
  end
  return vim.fn.expand("<cword>") or ""
end

---Whether codepoint is a letter in a human language script (not digit/punct/symbol).
---@param cp integer
---@return boolean
local function is_unicode_letter(cp)
  -- ASCII A-Z a-z
  if (cp >= 0x41 and cp <= 0x5A) or (cp >= 0x61 and cp <= 0x7A) then
    return true
  end
  -- Latin-1 letters (exclude × ÷)
  if cp >= 0x00C0 and cp <= 0x024F and cp ~= 0x00D7 and cp ~= 0x00F7 then
    return true
  end
  -- Latin Extended Additional / Greek / Cyrillic / Armenian / Hebrew / Arabic
  if cp >= 0x1E00 and cp <= 0x1EFF then
    return true
  end
  if cp >= 0x0370 and cp <= 0x03FF then
    return true
  end
  if cp >= 0x0400 and cp <= 0x052F then
    return true
  end
  if cp >= 0x0530 and cp <= 0x058F then
    return true
  end
  if cp >= 0x0590 and cp <= 0x05FF then
    return true
  end
  if cp >= 0x0600 and cp <= 0x06FF then
    return true
  end
  -- Devanagari / Thai
  if cp >= 0x0900 and cp <= 0x097F then
    return true
  end
  if cp >= 0x0E00 and cp <= 0x0E7F then
    return true
  end
  -- Hangul Jamo / syllables
  if cp >= 0x1100 and cp <= 0x11FF then
    return true
  end
  if cp >= 0xAC00 and cp <= 0xD7AF then
    return true
  end
  -- CJK: kana, bopomofo, unified ideographs, compatibility
  if cp >= 0x3040 and cp <= 0x30FF then
    return true
  end
  if cp >= 0x3100 and cp <= 0x312F then
    return true
  end
  if cp >= 0x3400 and cp <= 0x4DBF then
    return true
  end
  if cp >= 0x4E00 and cp <= 0x9FFF then
    return true
  end
  if cp >= 0xF900 and cp <= 0xFAFF then
    return true
  end
  if cp >= 0x20000 and cp <= 0x2A6DF then
    return true
  end
  return false
end

---True if text contains at least one letter (Latin / CJK / etc.), not only symbols/digits.
---@param text string|nil
---@return boolean
function M.contains_language_text(text)
  if not text or text == "" then
    return false
  end
  local n = vim.fn.strchars(text)
  for i = 0, n - 1 do
    local cp = vim.fn.char2nr(vim.fn.strcharpart(text, i, 1))
    if is_unicode_letter(cp) then
      return true
    end
  end
  return false
end

---Whether the target is a single identifier (word), not a code snippet/selection.
---Selections / signatures / expressions should be explained as a whole — no LSP
---definition jump on a nested token like `str` inside `def foo(x: str)`.
---@param target string|nil
---@return boolean
function M.is_symbol_target(target)
  target = vim.trim(target or "")
  if target == "" or target:find("\n", 1, true) or target:find("%s") then
    return false
  end
  -- identifier, @decorator-name, or dotted path (mod.func / self.x)
  if target:match("^[@%a_][%w_]*$") then
    return true
  end
  if target:match("^[%a_][%w_]*%.[%w_.]+$") then
    return true
  end
  return false
end

---@param bufnr integer
---@param row integer 0-based
---@param col integer 0-based byte
---@param encoding string|nil
---@return table
local function make_position_params_at(bufnr, row, col, encoding)
  encoding = encoding or "utf-16"
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local character = col
  if encoding ~= "utf-8" then
    local ok, idx = pcall(vim.str_utfindex, line, encoding, col, false)
    if ok and type(idx) == "number" then
      character = idx
    else
      ok, idx = pcall(vim.str_utfindex, line, col)
      if ok and type(idx) == "number" then
        character = idx
      elseif ok and type(idx) == "table" then
        character = (encoding == "utf-32") and idx[2] or idx[1]
      end
    end
  end
  return {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position = { line = row, character = character },
  }
end

---@param bufnr integer
---@param start_row integer 0-based
---@param max_lines integer|nil
---@return string
function M.comments_above(bufnr, start_row, max_lines)
  max_lines = max_lines or 30
  local comments = {}
  local in_block = false

  for i = start_row, math.max(0, start_row - max_lines), -1 do
    local line = vim.api.nvim_buf_get_lines(bufnr, i, i + 1, false)[1] or ""
    local trimmed = vim.trim(line)

    if trimmed == "" then
      if #comments > 0 and not in_block then
        break
      end
    elseif trimmed:match("^%*/") or trimmed:match("%*/$") then
      table.insert(comments, 1, line)
      in_block = true
    elseif trimmed:match("^/%*") or trimmed:match("^/%*%*") then
      table.insert(comments, 1, line)
      in_block = false
      -- block start found going upward; continue one more if needed
    elseif in_block or trimmed:match("^%-%-") or trimmed:match("^//") or trimmed:match("^#") or trimmed:match("^%*") then
      table.insert(comments, 1, line)
      if trimmed:match("^/%*") then
        in_block = false
      end
    else
      break
    end
  end

  return table.concat(comments, "\n")
end

---@param bufnr integer
---@param row integer 0-based
---@return string|nil
function M.enclosing_block_text(bufnr, row)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil
  end

  local tree = parser:parse()[1]
  if not tree then
    return nil
  end

  local root = tree:root()
  local col = 0
  local node = root:named_descendant_for_range(row, col, row, col)
  if not node then
    local cursor = vim.api.nvim_win_get_cursor(0)
    node = vim.treesitter.get_node({ bufnr = bufnr, pos = { cursor[1] - 1, cursor[2] } })
  end

  local preferred = {
    function_definition = true,
    function_declaration = true,
    method_definition = true,
    method_declaration = true,
    function_item = true,
    impl_item = true,
    class_definition = true,
    class_declaration = true,
    struct_item = true,
  }

  while node do
    if preferred[node:type()] then
      local text = vim.treesitter.get_node_text(node, bufnr)
      local max_chars = 4000
      if #text > max_chars then
        text = text:sub(1, max_chars) .. "\n... (truncated)"
      end
      return text
    end
    node = node:parent()
  end

  return nil
end

---@param bufnr integer
---@param row integer 0-based
---@return string
function M.nearby_lines(bufnr, row)
  local n = config.options.context_lines or 15
  local total = vim.api.nvim_buf_line_count(bufnr)
  local start_row = math.max(0, row - n)
  local end_row = math.min(total, row + n + 1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, false)
  return table.concat(lines, "\n")
end

---@param location table
---@return string|nil filepath
---@return integer|nil line 1-based
local function location_file_line(location)
  if location.targetUri or location.targetSelectionRange then
    local uri = location.targetUri or location.uri
    local range = location.targetSelectionRange or location.targetRange or location.range
    if not uri or not range then
      return nil, nil
    end
    return vim.uri_to_fname(uri), range.start.line + 1
  end
  if location.uri and location.range then
    return vim.uri_to_fname(location.uri), location.range.start.line + 1
  end
  return nil, nil
end

---Match a Python/JS-style triple-quoted string opening at the start of trimmed text.
---@param trimmed string
---@return string|nil quote
---@return string|nil rest
local function match_triple_open(trimmed)
  local open, rest = trimmed:match('^[rRuUbBfF]*(""")(.*)$')
  if open then
    return open, rest
  end
  open, rest = trimmed:match("^[rRuUbBfF]*(''')(.*)$")
  if open then
    return open, rest
  end
  return nil, nil
end

---Collect a triple-quoted block starting at lines[i] (original lines, with quotes).
---@param lines string[]
---@param i integer
---@param max_i integer
---@return string
local function collect_triple_block(lines, i, max_i)
  local raw = lines[i] or ""
  local trimmed = vim.trim(raw)
  local quote, rest = match_triple_open(trimmed)
  if not quote then
    return ""
  end
  rest = rest or ""
  if rest:find(quote, 1, true) then
    return raw
  end
  local collected = { raw }
  for j = i + 1, max_i do
    local l = lines[j] or ""
    table.insert(collected, l)
    if vim.trim(l):find(quote, 1, true) then
      return table.concat(collected, "\n")
    end
  end
  return table.concat(collected, "\n")
end

---Find the line where a def/class signature ends (the line with the final `:`).
---@param lines string[]
---@param def_line integer
---@param max_i integer
---@return integer sig_end
---@return string|nil inline_doc same-line docstring after `:` if present
local function find_signature_end(lines, def_line, max_i)
  for i = def_line, max_i do
    local raw = lines[i] or ""
    local trimmed = vim.trim(raw)
    -- Same-line: def foo(): """doc"""
    local after_colon = trimmed:match(':%s*([rRuUbBfF]*""".*)$')
      or trimmed:match(":%s*([rRuUbBfF]*'''.*)$")
    if after_colon then
      return i, after_colon
    end
    if trimmed:match(":%s*$") or trimmed:match(":%s*#") then
      return i, nil
    end
    -- Still in signature (multi-line params) or blank within signature
    if trimmed == "" or trimmed:match("^%)") or trimmed:match(",%s*$") or trimmed:match("%(%s*$") or raw:match("^%s+") then
      -- continue
    elseif i > def_line then
      return def_line, nil
    end
  end
  return def_line, nil
end

---Extract """ / ''' docstring that is the first statement of the definition body.
---Returns the original source lines including the quotes (原文). Does NOT pick up
---module docstrings above the def, nor docstrings of later functions in a snippet.
---@param lines string[]
---@param def_line integer
---@return string
local function extract_docstring_below(lines, def_line)
  local max_i = math.min(#lines, def_line + 50)
  local first = vim.trim(lines[def_line] or "")
  local is_def = first:match("^async%s+def%s+")
    or first:match("^def%s+")
    or first:match("^class%s+")
    or first:match("^export%s+")
    or first:match("^function%s+")
    or first:match("^async%s+function%s+")

  local start_i = def_line
  if is_def then
    local sig_end, inline_doc = find_signature_end(lines, def_line, max_i)
    if inline_doc and inline_doc ~= "" then
      return inline_doc
    end
    start_i = sig_end + 1
  end

  -- Def line indent; body docstring must be more indented (or we reject column-0 module strings)
  local def_indent = #(lines[def_line] or ""):match("^(%s*)") or 0

  for i = start_i, max_i do
    local raw = lines[i] or ""
    local trimmed = vim.trim(raw)
    if trimmed == "" then
      -- allow blank lines between signature and docstring
    else
      local indent = #(raw:match("^(%s*)") or "")
      local quote = match_triple_open(trimmed)
      if quote then
        -- Body docstring must be indented past the def (skip module-level """ above/between)
        if is_def and indent <= def_indent then
          return ""
        end
        return collect_triple_block(lines, i, max_i)
      end
      -- First non-empty body statement is not a docstring
      return ""
    end
  end

  return ""
end

---@param filepath string
---@param line integer 1-based
---@return string snippet
---@return string comments
local function read_definition_snippet(filepath, line)
  local ok, lines = pcall(vim.fn.readfile, filepath)
  if not ok or not lines or #lines == 0 then
    return "", ""
  end

  local n = config.options.definition_context_lines or 20
  -- Ensure enough lines below def to capture multi-line docstrings
  local look_below = math.max(n, 40)
  local start_idx = math.max(1, line - 2)
  local end_idx = math.min(#lines, line + look_below)
  local snippet_lines = {}
  for i = start_idx, end_idx do
    table.insert(snippet_lines, lines[i])
  end
  local snippet = table.concat(snippet_lines, "\n")

  -- comments above definition line (1-based)
  local comments = {}
  local in_block = false
  local max_up = 30
  for i = line - 1, math.max(1, line - max_up), -1 do
    local text = lines[i] or ""
    local trimmed = vim.trim(text)
    if trimmed == "" then
      if #comments > 0 and not in_block then
        break
      end
    elseif trimmed:match("%*/") then
      table.insert(comments, 1, text)
      in_block = true
    elseif in_block or trimmed:match("^%-%-") or trimmed:match("^//") or trimmed:match("^#") or trimmed:match("^%*") or trimmed:match("^/%*") then
      table.insert(comments, 1, text)
      if trimmed:match("^/%*") then
        in_block = false
      end
    else
      break
    end
  end

  local above = table.concat(comments, "\n")
  local docstring = extract_docstring_below(lines, line)
  if above ~= "" and docstring ~= "" then
    return snippet, above .. "\n\n" .. docstring
  end
  if docstring ~= "" then
    return snippet, docstring
  end
  return snippet, above
end

---Snapshot the source buffer/window before any UI steals focus.
---Includes visual selection range when currently in visual mode.
---@return { bufnr: integer, win: integer, row: integer, col: integer, end_row: integer, end_col: integer, filetype: string, filename: string }
function M.snapshot_source()
  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row, col = cursor[1] - 1, cursor[2]
  local end_row, end_col = row, col

  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local start_pos = vim.fn.getpos("v")
    local end_pos = vim.fn.getpos(".")
    local sr, sc = start_pos[2] - 1, start_pos[3] - 1
    local er, ec = end_pos[2] - 1, end_pos[3] - 1
    if sr > er or (sr == er and sc > ec) then
      sr, er = er, sr
      sc, ec = ec, sc
    end
    row, col = sr, math.max(0, sc)
    end_row, end_col = er, math.max(0, ec)
  end

  return {
    bufnr = bufnr,
    win = win,
    row = row,
    col = col,
    end_row = end_row,
    end_col = end_col,
    filetype = vim.bo[bufnr].filetype or "",
    filename = vim.api.nvim_buf_get_name(bufnr),
  }
end

---@param source { bufnr: integer, win: integer, row: integer, col: integer, end_row?: integer, end_col?: integer, filetype?: string, filename?: string }
---@param callback fun(ctx: table)
---@param opts { resolve_symbol?: boolean }|nil
function M.collect_async(source, callback, opts)
  opts = opts or {}
  local resolve_symbol = opts.resolve_symbol
  if resolve_symbol == nil then
    resolve_symbol = true
  end

  local bufnr, row, col = source.bufnr, source.row, source.col
  local result = {
    target = nil,
    is_symbol = resolve_symbol,
    filetype = source.filetype or vim.bo[bufnr].filetype or "",
    filename = source.filename or vim.api.nvim_buf_get_name(bufnr),
    nearby = M.nearby_lines(bufnr, row),
    enclosing = M.enclosing_block_text(bufnr, row),
    local_comments = M.comments_above(bufnr, row - 1),
    hover = nil,
    definition = nil,
    definition_comments = nil,
  }

  -- Multi-token selection: explain the snippet as a whole — do not LSP-resolve
  -- whatever token the cursor happens to sit on (e.g. `str` in a signature).
  if not resolve_symbol then
    callback(result)
    return
  end

  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    callback(result)
    return
  end

  local encoding = clients[1].offset_encoding or "utf-16"
  -- Always use the snapped source position (selection start / cursor), never the
  -- live window cursor — after leaving visual mode the cursor often sits on a
  -- nested token at the end of the selection.
  local params = make_position_params_at(bufnr, row, col, encoding)

  local finished = false
  local pending = 2

  local function finish()
    if finished then
      return
    end
    finished = true
    -- Do not scrape docstrings from the padded definition snippet: that picks up
    -- module docstrings / neighboring functions. Only read_definition_snippet
    -- (line-accurate extract_docstring_below) may set definition_comments.
    callback(result)
  end

  local function done()
    pending = pending - 1
    if pending <= 0 then
      finish()
    end
  end

  -- hover
  vim.lsp.buf_request_all(bufnr, "textDocument/hover", params, function(responses)
    if finished then
      return
    end
    local lines = {}
    for _, resp in pairs(responses or {}) do
      if resp.result and resp.result.contents then
        local converted = vim.lsp.util.convert_input_to_markdown_lines(resp.result.contents)
        vim.list_extend(lines, converted)
      end
    end
    if #lines > 0 then
      result.hover = table.concat(lines, "\n")
    end
    done()
  end)

  -- definition
  vim.lsp.buf_request_all(bufnr, "textDocument/definition", params, function(responses)
    if finished then
      return
    end
    local snippets = {}
    local comment_parts = {}
    for _, resp in pairs(responses or {}) do
      if resp.result then
        local locs = resp.result
        if not vim.islist(locs) then
          locs = { locs }
        end
        for _, loc in ipairs(locs) do
          local path, line = location_file_line(loc)
          if path and line then
            local snippet, comments = read_definition_snippet(path, line)
            if snippet ~= "" then
              table.insert(snippets, ("-- %s:%d\n%s"):format(path, line, snippet))
            end
            if comments ~= "" then
              table.insert(comment_parts, comments)
            end
          end
        end
      end
    end
    if #snippets > 0 then
      result.definition = table.concat(snippets, "\n\n---\n\n")
    end
    if #comment_parts > 0 then
      result.definition_comments = table.concat(comment_parts, "\n\n")
    end
    done()
  end)

  -- timeout fallback
  vim.defer_fn(function()
    finish()
  end, 2500)
end

---@param target string
---@param source { bufnr: integer, win: integer, row: integer, col: integer, filetype?: string, filename?: string }
---@param callback fun(ctx: table)
function M.build_for_target(target, source, callback)
  local is_symbol = M.is_symbol_target(target)
  M.collect_async(source, function(ctx)
    ctx.target = target
    ctx.is_symbol = is_symbol
    callback(ctx)
  end, { resolve_symbol = is_symbol })
end

return M
