local config = require("explain_it.config")

local M = {}

---@param base_url string
---@return string
local function chat_url(base_url)
  base_url = base_url:gsub("/+$", "")
  if base_url:match("/chat/completions$") then
    return base_url
  end
  return base_url .. "/chat/completions"
end

---@param obj table
---@return string|nil
local function extract_content(obj)
  if not obj then
    return nil
  end
  local choice = obj.choices and obj.choices[1]
  if not choice then
    return nil
  end
  local msg = choice.message
  if msg and type(msg.content) == "string" then
    return msg.content
  end
  if type(choice.text) == "string" then
    return choice.text
  end
  return nil
end

---@param obj table
---@return string|nil delta
---@return string|nil error_message
local function extract_delta(obj)
  if not obj then
    return nil, nil
  end
  if obj.error then
    return nil, obj.error.message or vim.inspect(obj.error)
  end
  local choice = obj.choices and obj.choices[1]
  if not choice then
    return nil, nil
  end
  local delta = choice.delta
  if delta and type(delta.content) == "string" and delta.content ~= "" then
    return delta.content, nil
  end
  -- some providers put the full message in streaming frames
  if choice.message and type(choice.message.content) == "string" and choice.message.content ~= "" then
    return choice.message.content, nil
  end
  return nil, nil
end

---@param handlers fun(err: string|nil, content: string|nil)|{ on_delta?: fun(delta: string, full: string), on_done: fun(err: string|nil, content: string|nil) }
---@return { on_delta?: fun(delta: string, full: string), on_done: fun(err: string|nil, content: string|nil) }
local function normalize_handlers(handlers)
  if type(handlers) == "function" then
    return { on_done = handlers }
  end
  return handlers
end

---@param messages { role: string, content: string }[]
---@param handlers fun(err: string|nil, content: string|nil)|{ on_delta?: fun(delta: string, full: string), on_done: fun(err: string|nil, content: string|nil) }
function M.chat(messages, handlers)
  handlers = normalize_handlers(handlers)
  local on_done = handlers.on_done
  local on_delta = handlers.on_delta

  local opts = config.options.api
  local api_key = config.get_api_key()
  if not api_key then
    on_done("未配置 API Key。请在 setup 中设置 api.api_key，或设置环境变量 EXPLAIN_IT_NVIM_API_KEY / OPENAI_API_KEY。", nil)
    return
  end

  local url = chat_url(opts.base_url)
  local body = vim.json.encode({
    model = opts.model,
    messages = messages,
    temperature = opts.temperature,
    stream = true,
  })

  local args = {
    "curl",
    "-sS",
    "-N",
    "-X",
    "POST",
    url,
    "-H",
    "Content-Type: application/json",
    "-H",
    "Authorization: Bearer " .. api_key,
    "-H",
    "Accept: text/event-stream",
    "--data-binary",
    "@-",
    "--max-time",
    tostring(math.ceil((opts.timeout_ms or 30000) / 1000)),
  }

  local line_buf = ""
  local pieces = {}
  local raw_chunks = {}
  local stream_error = nil
  local saw_sse = false

  local function emit_delta(piece)
    if not piece or piece == "" then
      return
    end
    table.insert(pieces, piece)
    local full = table.concat(pieces)
    if on_delta then
      vim.schedule(function()
        on_delta(piece, full)
      end)
    end
  end

  local function handle_data_payload(payload)
    payload = vim.trim(payload)
    if payload == "" then
      return
    end
    if payload == "[DONE]" then
      saw_sse = true
      return
    end

    local ok, obj = pcall(vim.json.decode, payload)
    if not ok or type(obj) ~= "table" then
      return
    end

    saw_sse = true
    local piece, err = extract_delta(obj)
    if err then
      stream_error = err
      return
    end
    if piece then
      emit_delta(piece)
    end
  end

  local function consume_lines(chunk)
    line_buf = line_buf .. chunk
    while true do
      local nl = line_buf:find("\n", 1, true)
      if not nl then
        break
      end
      local line = line_buf:sub(1, nl - 1):gsub("\r$", "")
      line_buf = line_buf:sub(nl + 1)

      if line:match("^data:") then
        handle_data_payload(line:gsub("^data:%s*", ""))
      end
    end
  end

  vim.system(args, {
    text = true,
    stdin = body,
    stdout = function(err, data)
      if err then
        stream_error = stream_error or err
        return
      end
      if data and data ~= "" then
        table.insert(raw_chunks, data)
        consume_lines(data)
      end
    end,
  }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        local err = obj.stderr
        if err == nil or err == "" then
          err = table.concat(raw_chunks)
        end
        on_done(("请求失败 (exit %s): %s"):format(tostring(obj.code), err or "unknown"), nil)
        return
      end

      if stream_error then
        on_done("API 错误: " .. tostring(stream_error), nil)
        return
      end

      local full = table.concat(pieces)
      if full ~= "" then
        on_done(nil, full)
        return
      end

      -- Fallback: provider ignored stream and returned a normal JSON body
      local raw = table.concat(raw_chunks)
      if line_buf ~= "" then
        raw = raw -- line_buf already in raw_chunks
      end
      raw = vim.trim(raw)
      if raw == "" then
        on_done("API 返回空内容。", nil)
        return
      end

      -- leftover data: line without trailing newline
      if line_buf:match("^data:") then
        handle_data_payload(line_buf:gsub("^data:%s*", ""))
        full = table.concat(pieces)
        if full ~= "" then
          on_done(nil, full)
          return
        end
      end

      local ok, decoded = pcall(vim.json.decode, raw)
      if ok and type(decoded) == "table" then
        if decoded.error then
          local msg = decoded.error.message or vim.inspect(decoded.error)
          on_done("API 错误: " .. tostring(msg), nil)
          return
        end
        local content = extract_content(decoded)
        if content and content ~= "" then
          if on_delta then
            on_delta(content, content)
          end
          on_done(nil, content)
          return
        end
      end

      if not saw_sse then
        on_done("无法解析 API 响应: " .. raw:sub(1, 500), nil)
        return
      end

      on_done("API 返回空内容。", nil)
    end)
  end)
end

return M
