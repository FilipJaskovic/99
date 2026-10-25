--- TODO: I would like to clean up this file.  I will probably need to create a
--- task for me to do in the future to make this a bit more clean and only have
--- stuff that makes sense for the api to be in here... but for now.. ia m sorry
local Logger = require("99.logger.logger")
local Tracking = require("99.state.tracking")
local Level = require("99.logger.level")
local ops = require("99.ops")
local Window = require("99.window")
local select_window = require("99.window.select-window")
local StatusWindow = require("99.window.status-window")
local Prompt = require("99.prompt")
local State = require("99.state")
local Extensions = require("99.extensions")
local Providers = require("99.providers")

---@param path_or_rule string | _99.Agents.Rule
---@return _99.Agents.Rule | string
local function expand(path_or_rule)
  if type(path_or_rule) == "string" then
    return vim.fn.expand(path_or_rule)
  end
  return {
    name = path_or_rule.name,
    path = vim.fn.expand(path_or_rule.path),
  }
end

--- @param opts _99.ops.Opts?
--- @return _99.ops.Opts
local function process_opts(opts)
  opts = vim.deepcopy(opts or {})
  for i, rule in ipairs(opts.additional_rules or {}) do
    local r = expand(rule)
    assert(
      type(r) ~= "string",
      "broken configuration.  additional_rules must never be a string"
    )
    opts.additional_rules[i] = r
  end
  return opts
end

--- @class _99.Completion
--- @docs included
--- @field source "native" | "cmp" | "blink" | nil
--- @field custom_rules string[]
--- @field files _99.Files.Config?

--- @class _99.Options
--- @docs base
--- @field logger? _99.Logger.Options
--- @field model? string
--- @field in_flight_options? _99.StatusWindow.Opts
--- @field md_files? string[]
--- @field provider? _99.Providers.BaseProvider
--- @field provider_extra_args? string[]
--- @field display_errors? boolean
--- @field completion? _99.Completion
--- @field tmp_dir? string
--- @field request_timeout? number Request deadline in milliseconds. Default: 300000.
--- @field max_response_bytes? number Maximum response file size. Default: 4194304.

--- @type _99.State
local _99_state
local status_window

--- @alias _99.TraceID number

--- @class _99
--- This fork uses Codex for visual replacements, project searches, tutorials,
--- and workspace edits. It requires Neovim 0.11.5 or newer and a signed-in
--- Codex CLI. The integration was developed against Codex CLI 0.164.0.
---
--- ### Basic setup
--- ```lua
--- {
--- 	"FilipJaskovic/99",
--- 	config = function()
--- 		local _99 = require("99")
--- 		_99.setup({
--- 			provider = _99.Providers.CodexProvider,
--- 			-- Omit model to use your Codex CLI configuration.
--- 			completion = { source = "native" },
--- 			md_files = { "AGENTS.md" },
--- 		})
--- 		vim.keymap.set("x", "<leader>9v", _99.visual)
--- 		vim.keymap.set("n", "<leader>9s", _99.search)
--- 		vim.keymap.set("n", "<leader>9x", _99.stop_all_requests)
--- 	end,
--- }
--- ```
---
--- ### Usage
--- Select text and run `visual()` to request a replacement. The replacement
--- applies only if the source buffer has not changed since capture.
--- `search()` returns locations in the quickfix list. `tutorial()` opens a
--- Markdown explanation. `vibe()` lets Codex edit files in the workspace.
--- Visual, search, and tutorial requests use the read-only Codex sandbox.
--- Vibe uses workspace-write. Codex also loads its own configuration and tools.
---
--- @docs base
--- @field setup fun(opts?: _99.Options): nil
--- Sets up _99.  Must be called for this library to work.  This is how we setup
--- in flight request spinners, set default values, get completion to work the
--- way you want it to.
--- @field search fun(opts: _99.ops.SearchOpts): _99.TraceID
--- Performs a search across your project with the prompt you provide and return out a list of
--- locations with notes that will be put into your quick fix list.
--- @field vibe fun(opts?: _99.ops.Opts): _99.TraceID | nil
--- will ask opencode or whatever provider currently being used to perform a vibe
--- session.
--- @field open fun(): nil
--- Opens a selection window for you to select the last interaction to open
--- and display its contents in a way that makes sense for its type.  For
--- search and vibe, it will open the qfix window.  For tutorial, it will open
--- the tutorial window.
--- @field visual fun(opts: _99.ops.Opts): _99.TraceID
--- takes your current selection and sends that along with the prompt provided and replaces
--- your visual selection with the results
--- @field view_logs fun(): nil
--- view_logs allows you to select the request you want to see and then you
--- get to see the logs.
--- @field stop_all_requests fun(): nil
--- stops all in flight requests.  this means that the underlying process will
--- receive a termination signal, and late results are discarded
--- @field clear_previous_requests fun(): nil
--- clears all previous search and visual operations
--- @field Extensions _99.Extensions
--- check out Worker for cool abstraction on search and vibe
local _99 = {
  DEBUG = Level.DEBUG,
  INFO = Level.INFO,
  WARN = Level.WARN,
  ERROR = Level.ERROR,
  FATAL = Level.FATAL,
}

--- @param cb fun(context: _99.Prompt, o: _99.ops.Opts?): nil
--- @param name string
--- @param context _99.Prompt
--- @param opts _99.ops.Opts
--- @param capture_content string[] | nil
local function capture_prompt(cb, name, context, opts, capture_content)
  Window.capture_input(name, {
    keymap = {
      [":w"] = "submit",
    },
    content = capture_content,

    --- @param ok boolean
    --- @param response string
    cb = function(ok, response)
      context.logger:debug(
        "capture_prompt",
        "success",
        ok,
        "response",
        response
      )
      if not ok or context._99 ~= _99_state or context:is_cancelled() then
        context:stop()
        return
      end
      opts.additional_prompt = response
      context.user_prompt = response
      cb(context, opts)
    end,
    on_load = function()
      Extensions.setup_buffer(context._99)
    end,
    rules = context.rules or context._99.rules,
  })
end

function _99.info()
  local info = {}
  _99_state:refresh_rules()
  table.insert(
    info,
    string.format("Previous Requests: %d", _99_state.tracking:completed())
  )
  table.insert(
    info,
    string.format("custom rules(%d):", #(_99_state.rules.custom or {}))
  )
  for _, rule in ipairs(_99_state.rules.custom or {}) do
    table.insert(info, string.format("* %s", rule.name))
  end
  Window.display_centered_message(info)
end

--     elseif #tutorials == 1 then
--       local data = tutorials[1]
--       assert(data, "tutorial is malformed")
--       Window.create_split(data.tutorial, data.buffer, opts)
--       return

--- @param context _99.Prompt
function _99.open_tutorial(context)
  local tutorial = context:tutorial_data()
  local win = Window.create_split(tutorial.tutorial, tutorial.buffer, {
    split_direction = "vertical",
    window_opts = {
      wrap = true,
    },
  })
  tutorial.buffer = win.buffer
  tutorial.window = win.win
end

function _99.open()
  local requests = _99_state.tracking:successful()
  local str_requests = Tracking.to_selectable_list(requests)
  select_window(str_requests, function(idx)
    local r = requests[idx]
    assert(r:valid(), "encountered unexpected issue.  malformated data")
    if r.operation == "visual" then
      --- TODO: this is its own work item for being able to have a global mark
      --- section in which i keep track of marks for the lifetime of the
      --- editor and when you close the editor, then it should lose them
      print("visual not supported: i will figure this out... at some point")
    elseif r.operation == "search" or r.operation == "vibe" then
      _99.open_qfix_for_request(r)
    elseif r.operation == "tutorial" then
      _99.open_tutorial(r)
    end
  end)
end

--- @param opts? _99.ops.Opts
--- @return _99.TraceID
function _99.vibe(opts)
  local o = process_opts(opts)
  local context = Prompt.vibe(_99_state)
  if o.additional_prompt then
    context.user_prompt = o.additional_prompt
    ops.vibe(context, o)
  else
    capture_prompt(ops.vibe, "Vibe", context, o)
  end
  return context.xid
end

--- @param opts? _99.ops.SearchOpts
--- @return _99.TraceID
function _99.search(opts)
  local o = process_opts(opts) --[[ @as _99.ops.SearchOpts ]]
  local context = Prompt.search(_99_state)
  if o.additional_prompt then
    context.user_prompt = o.additional_prompt
    ops.search(context, o)
  else
    capture_prompt(ops.search, "Search", context, o)
  end
  return context.xid
end

--- @param opts _99.ops.Opts
function _99.tutorial(opts)
  opts = process_opts(opts)
  local context = Prompt.tutorial(_99_state)
  if opts.additional_prompt then
    context.user_prompt = opts.additional_prompt
    ops.tutorial(context, opts)
  else
    capture_prompt(ops.tutorial, "Tutorial", context, opts)
  end
end

--- @param opts _99.ops.Opts?
--- @return _99.TraceID
function _99.visual(opts)
  opts = process_opts(opts)
  local context = Prompt.visual(_99_state)
  if opts.additional_prompt then
    context.user_prompt = opts.additional_prompt
    ops.over_range(context, opts)
  else
    capture_prompt(ops.over_range, "Visual", context, opts)
  end
  return context.xid
end

function _99.view_logs()
  local requests = _99_state.tracking.history
  local str_requests = Tracking.to_selectable_list(requests)
  select_window(str_requests, function(idx)
    local r = requests[idx]
    local logs = Logger.logs_by_id(r.xid)
    if logs == nil then
      logs = { "No logs found for request: " .. r.xid }
    end
    Window.display_full_screen_message(logs)
  end)
end

--- @param request _99.Prompt
function _99.open_qfix_for_request(request)
  local items = request:qfix_data()
  if #items == 0 then
    print("there are no quickfix items to show")
    return
  end

  vim.fn.setqflist({}, "r", { title = "99 Results", items = items })
  vim.cmd("copen")
end

function _99.stop_all_requests()
  _99_state.tracking:stop_all_requests()
end

function _99.clear_previous_requests()
  _99_state.tracking:clear_history()
end

--- if you touch this function you will be fired
--- @return _99.State
function _99.__get_state()
  return _99_state
end

--- @param opts _99.Options?
function _99.setup(opts)
  opts = opts or {}

  if opts.tmp_dir then
    assert(type(opts.tmp_dir) == "string", "opts.tmp_dir must be a string")
  end
  if opts.provider_extra_args then
    assert(
      type(opts.provider_extra_args) == "table",
      "provider_extra_args must be a list"
    )
    for _, value in ipairs(opts.provider_extra_args) do
      assert(
        type(value) == "string",
        "provider_extra_args must contain strings"
      )
    end
  end
  if _99_state then
    _99_state.tracking:stop_all_requests()
    _99_state:sync()
  end
  if status_window then
    status_window:stop()
  end
  _99_state = State.new(opts)

  local crules = _99_state.completion.custom_rules
  for i, rule in ipairs(crules) do
    local str = expand(rule)
    assert(type(str) == "string", "error parsing rule: path must be a string")
    crules[i] = str
  end

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("99_lifecycle", { clear = true }),
    callback = function()
      _99.stop_all_requests()
      if status_window then
        status_window:stop()
      end
      _99_state:sync()
    end,
  })

  Logger:configure(opts.logger)

  if opts.model then
    assert(type(opts.model) == "string", "opts.model is not a string")
    _99_state.model = opts.model
  else
    local provider = _99_state.provider_override
    if provider._get_default_model then
      _99_state.model = provider._get_default_model()
    end
  end

  if opts.md_files then
    assert(type(opts.md_files) == "table", "opts.md_files is not a table")
    for _, md in ipairs(opts.md_files) do
      _99.add_md_file(md)
    end
  end

  _99_state.display_errors = opts.display_errors or false
  _99_state:refresh_rules()
  Extensions.init(_99_state)
  Extensions.capture_project_root()

  status_window = StatusWindow.new(_99_state, opts.in_flight_options)
  status_window:start()
end

--- @param md string
--- @return _99
function _99.add_md_file(md)
  table.insert(_99_state.md_files, md)
  return _99
end

--- @param md string
--- @return _99
function _99.rm_md_file(md)
  for i, name in ipairs(_99_state.md_files) do
    if name == md then
      table.remove(_99_state.md_files, i)
      break
    end
  end
  return _99
end

--- @param model string
--- @return _99
function _99.set_model(model)
  _99_state.model = model
  return _99
end

--- @return string
function _99.get_model()
  return _99_state.model
end

--- @return _99.Providers.BaseProvider
function _99.get_provider()
  return _99_state.provider_override or Providers.CodexProvider
end

--- @param provider _99.Providers.BaseProvider
--- @return _99
function _99.set_provider(provider)
  _99_state.provider_override = provider
  if provider._get_default_model then
    _99_state.model = provider._get_default_model()
  end
  return _99
end

function _99.__debug()
  Logger:configure({
    path = nil,
    level = Level.DEBUG,
  })
end

_99.Providers = Providers

--- @class _99.Extensions
--- @field Worker _99.Extensions.Worker
_99.Extensions = {
  Worker = require("99.extensions.work.worker"),
}
return _99
