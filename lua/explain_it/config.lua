local M = {}

---@class ExplainItApiConfig
---@field base_url string
---@field api_key string|nil
---@field model string
---@field timeout_ms integer
---@field temperature number|nil

---@class ExplainItTranslateConfig
---@field target_lang string

---@class ExplainItAskConfig
---@field include_context boolean

---@class ExplainItUiFitConfig
---@field max_width number fraction or columns; caps fit-mode width
---@field max_height number fraction or lines; caps fit-mode height
---@field min_width integer
---@field min_height integer

---@class ExplainItUiConfig
---@field border string|string[] nui border style
---@field width number fraction (0–1) or absolute columns
---@field height number fraction (0–1) or absolute lines
---@field render_markdown boolean use render-markdown.nvim when available
---@field anchor "auto"|"below"|"above"|"center" popup placement relative to code
---@field gap integer lines between selection and popup border
---@field zindex integer|nil
---@field enter boolean focus the popup on open
---@field close_on_leave boolean unmount when leaving the popup buffer
---@field wrap boolean
---@field linebreak boolean
---@field title_align "left"|"center"|"right"
---@field winhighlight string
---@field scrollbar boolean allow scrollbar plugins (nvim-scrollbar etc.); false hides them
---@field fit ExplainItUiFitConfig content-aware sizing (e.g. translate)

---@class ExplainItKeymapsConfig
---@field explain string|false
---@field translate string|false
---@field ask string|false

---@class ExplainItConfig
---@field api ExplainItApiConfig
---@field translate ExplainItTranslateConfig
---@field ask ExplainItAskConfig
---@field ui ExplainItUiConfig
---@field keymaps ExplainItKeymapsConfig
---@field context_lines integer
---@field definition_context_lines integer

---@type ExplainItConfig
M.defaults = {
  api = {
    base_url = "https://api.openai.com/v1",
    api_key = nil,
    model = "gpt-4o-mini",
    timeout_ms = 30000,
    temperature = 0.3,
  },
  translate = {
    target_lang = "zh-CN",
  },
  ask = {
    include_context = true,
  },
  ui = {
    border = "rounded",
    width = 0.4,
    height = 0.4,
    render_markdown = true,
    -- auto: below if enough room, otherwise above; center keeps old centered float
    anchor = "auto",
    gap = 1,
    zindex = 50,
    enter = true,
    close_on_leave = true,
    wrap = true,
    linebreak = false,
    title_align = "center",
    winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
    -- false: hide nvim-scrollbar / scrollview / satellite on the result float
    scrollbar = false,
    fit = {
      max_width = 0.55,
      max_height = 0.35,
      min_width = 24,
      min_height = 3,
    },
  },
  keymaps = {
    explain = "<leader>ee",
    translate = "<leader>et",
    ask = "<leader>ea",
  },
  context_lines = 15,
  definition_context_lines = 20,
}

---@type ExplainItConfig
M.options = vim.deepcopy(M.defaults)

---@param opts ExplainItConfig|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

---@return string|nil
function M.get_api_key()
  local key = M.options.api.api_key
  if type(key) == "string" and key ~= "" then
    return key
  end
  local env_key = vim.env.EXPLAIN_IT_NVIM_API_KEY or vim.env.OPENAI_API_KEY
  if type(env_key) == "string" and env_key ~= "" then
    return env_key
  end
  return nil
end

return M
