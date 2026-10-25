local Agents = require("99.extensions.agents")
local Files = require("99.extensions.files")
local Completions = require("99.extensions.completions")

local DEBOUNCE_MS = 100
local completion_cleanup = {}

--- @param items CompletionItem[]
--- @return table[]
local function to_native_items(items)
  local out = {}
  for _, item in ipairs(items) do
    local info = ""
    if item.documentation then
      if type(item.documentation) == "string" then
        info = item.documentation
      elseif item.documentation.value then
        info = item.documentation.value
      end
    end
    table.insert(out, {
      word = item.insertText or item.label,
      abbr = item.label,
      info = info,
      icase = 1,
      dup = 0,
    })
  end
  return out
end

--- @param _99 _99.State
local function register_providers(_99)
  Completions.register(Agents.completion_provider(_99))
  Completions.register(Files.completion_provider())
end

--- @param buf number
local function setup_completion_autocmd(buf)
  if completion_cleanup[buf] then
    completion_cleanup[buf]()
  end
  local timer = assert(vim.uv.new_timer())
  local disposed = false
  local group = vim.api.nvim_create_augroup(
    "99_native_completion_" .. buf,
    { clear = true }
  )
  local function dispose()
    if disposed then
      return
    end
    disposed = true
    timer:stop()
    timer:close()
    completion_cleanup[buf] = nil
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end
  completion_cleanup[buf] = dispose

  vim.api.nvim_create_autocmd("TextChangedI", {
    group = group,
    buffer = buf,
    callback = function()
      timer:stop()
      timer:start(
        DEBOUNCE_MS,
        0,
        vim.schedule_wrap(function()
          if
            disposed
            or not vim.api.nvim_buf_is_valid(buf)
            or vim.api.nvim_get_current_buf() ~= buf
            or vim.fn.mode() ~= "i"
          then
            return
          end

          local line = vim.api.nvim_get_current_line()
          local col = vim.fn.col(".")
          local before = line:sub(1, col - 1)

          local trigger, start_col = Completions.find_active_reference(before)

          if not trigger or not start_col then
            return
          end

          local items = Completions.get_completions(trigger)
          if #items == 0 then
            return
          end

          local native_items = to_native_items(items)
          vim.fn.complete(start_col, native_items)
        end)
      )
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = dispose,
  })
end

--- @param buf number
local function setup_keymaps(buf)
  vim.keymap.set("i", "<Tab>", function()
    if vim.fn.pumvisible() == 1 then
      return "<C-n>"
    end
    return "<Tab>"
  end, { buffer = buf, expr = true, noremap = true })

  vim.keymap.set("i", "<S-Tab>", function()
    if vim.fn.pumvisible() == 1 then
      return "<C-p>"
    end
    return "<S-Tab>"
  end, { buffer = buf, expr = true, noremap = true })
end

--- @param _ _99.State
local function init_for_buffer(_)
  local buf = vim.api.nvim_get_current_buf()

  vim.bo[buf].filetype = "99prompt"
  vim.opt_local.completeopt = "menuone,noinsert,noselect,popup,fuzzy"

  setup_completion_autocmd(buf)
  setup_keymaps(buf)
end

--- @param _99 _99.State
local function init(_99)
  local rule_dirs = {}
  if _99.completion and _99.completion.custom_rules then
    for _, dir in ipairs(_99.completion.custom_rules) do
      table.insert(rule_dirs, dir)
    end
  end

  if _99.completion and _99.completion.files then
    Files.setup(_99.completion.files, rule_dirs)
  else
    Files.setup({ enabled = true }, rule_dirs)
  end

  register_providers(_99)
end

--- @param _99 _99.State
local function refresh_state(_99)
  register_providers(_99)
end

--- @type _99.Extensions.Source
return {
  init_for_buffer = init_for_buffer,
  init = init,
  refresh_state = refresh_state,
}
