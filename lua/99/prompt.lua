local BaseProvider = require("99.providers")
local Logger = require("99.logger.logger")
local utils = require("99.utils")
local copy = utils.copy
local get_id = require("99.id")
local Range = require("99.geo").Range
local Time = require("99.time")

--- you can only set those marks after the visual selection is removed
local function set_selection_marks()
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
    "x",
    false
  )
end

local filetype_map = {
  typescriptreact = "typescript",
}

-- luacheck: ignore
--- @alias _99.Prompt.Data _99.Prompt.Data.Search | _99.Prompt.Data.Tutorial | _99.Prompt.Data.Visual | _99.Prompt.Data.Vibe
--- @alias _99.Prompt.Operation "visual" | "tutorial" | "search" | "vibe"
--- @alias _99.Prompt.QFixOperation "search" | "vibe"
--- @alias _99.Prompt.EndingState "failed" | "success" | "cancelled"
--- @alias _99.Prompt.State "ready" | "requesting" | _99.Prompt.EndingState
--- @alias _99.Prompt.Cleanup fun(): nil

--- @class _99.Prompt.Serialized
--- @field data _99.Prompt.Data
--- @field user_prompt string
--- @class _99.Prompt.Data.Search
--- @field type "search"
--- @field qfix_items _99.Search.Result[]
--- @field response string

--- @class _99.Prompt.Data.Vibe
--- @field type "vibe"
--- @field response string
--- @field qfix_items _99.Search.Result[]

--- @class _99.Prompt.Data.Visual
--- @field type "visual"
--- @field buffer number
--- @field file_type string
--- @field range _99.Range

--- @class _99.Prompt.Data.Tutorial
--- @field type "tutorial"
--- @field buffer number
--- @field window number
--- @field xid number TODO: we should probably get rid of this.  The request pattern is not quite correct
--- @field tutorial string[]

--- @class _99.Prompt
--- @field md_file_names string[]
--- @field model string
--- @field user_prompt string
--- @field operation _99.Prompt.Operation
--- @field state _99.Prompt.State
--- @field full_path string
--- @field started_at number
--- @field data _99.Prompt.Data
--- @field agent_context string[]
--- @field tmp_file string
--- @field cwd string
--- @field rules _99.Agents.Rules
--- @field provider _99.Providers.BaseProvider
--- @field provider_extra_args string[]
--- @field debug_prompt? string
--- @field _tmp_root string
--- @field _request_dir? string
--- @field _finalized? boolean
--- @field _completed? boolean
--- @field _stopped? boolean
--- @field _terminating? boolean
--- @field _complete_request? fun(status: _99.Prompt.EndingState, res: string): nil
--- @field marks table<string, _99.Mark>
--- @field logger _99.Logger
--- @field xid number
--- @field clean_ups (fun(): nil)[]
--- @field _99 _99.State
---@diagnostic disable-next-line: undefined-doc-name
--- @field _proc vim.SystemObj?
local Prompt = {}
Prompt.__index = Prompt

--- @type _99.Prompt[]
Prompt.__previous_contexts = {}

--- @type table<number, _99.Prompt>
Prompt.__context_by_id = {}

--- @param context  _99.Prompt
--- @param _99 _99.State
local function set_defaults(context, _99)
  local xid = get_id()
  local full_path = vim.api.nvim_buf_get_name(0)
  local cwd = vim.fn.getcwd()
  context.cwd = vim.fs.normalize(vim.uv.fs_realpath(cwd) or cwd)
  context._tmp_root = vim.fs.normalize(vim.fn.fnamemodify(_99:tmp_dir(), ":p"))
  _99:refresh_rules(context.cwd)

  context.state = "ready"
  context._99 = _99
  context.user_prompt = ""
  context.clean_ups = {}
  context.md_file_names = copy(_99.md_files)
  context.model = _99.model
  context.agent_context = {}
  context.tmp_file = ""
  context.rules = vim.deepcopy(_99.rules or {})
  context.provider = _99.provider_override or BaseProvider.CodexProvider
  context.provider_extra_args = copy(_99.provider_extra_args or {})
  context.logger = Logger:set_id(xid)
  context.xid = xid
  context.full_path = full_path
  context.marks = {}
  context.started_at = Time.now()
end

--- TODO: Work item for "TODO implementation"
function Prompt.todo(_99)
  _ = _99
  assert(false, "not implemented")
end

--- @param _99 _99.State
--- @param data _99.Prompt.Serialized
--- @return _99.Prompt
function Prompt.deserialize(_99, data)
  local prompt = setmetatable({
    _99 = _99,
    data = vim.deepcopy(data.data),
    operation = data.data.type,
    user_prompt = data.user_prompt,
    started_at = Time.now(),

    --- we should only sync successful requests
    state = "success",

    xid = get_id(),
  }, Prompt)
  if prompt.operation == "tutorial" then
    prompt.data.buffer = nil
    prompt.data.window = nil
  end
  assert(prompt:valid(), "prompt is not valid from data")
  return prompt
end

--- @return _99.Prompt.Serialized
function Prompt:serialize()
  assert(self.state == "success", "you can only serialize successful prompts")
  return {
    data = self.data,
    user_prompt = self.user_prompt,
  }
end

--- @param _99 _99.State
--- @return _99.Prompt
function Prompt.vibe(_99)
  --- @type _99.Prompt
  local context = setmetatable({}, Prompt)
  set_defaults(context, _99)
  context.operation = "vibe"
  context.data = {
    type = "vibe",
    response = "",
    qfix_items = {},
  }
  context.logger:debug("99 Request", "method", "vibe")

  return context
end

--- @param _99 _99.State
--- @return _99.Prompt
function Prompt.visual(_99)
  set_selection_marks()
  local range = Range.from_visual_selection()

  local file_type = vim.bo[0].ft
  local buffer = vim.api.nvim_get_current_buf()
  file_type = filetype_map[file_type] or file_type

  local mds = {}
  for _, md in ipairs(_99.md_files) do
    table.insert(mds, md)
  end

  --- @type _99.Prompt
  local context = setmetatable({}, Prompt)
  set_defaults(context, _99)
  context.operation = "visual"
  context.data = {
    type = "visual",
    buffer = buffer,
    file_type = file_type,
    range = range,
  }
  require("99.ops.marks").capture_visual(context)
  context.logger:debug("99 Request", "method", "visual")

  return context
end

--- @return string
function Prompt:summary()
  local prompt_str = utils.split_with_count(self.user_prompt, 8)
  return string.format("%s: %s", self.operation, table.concat(prompt_str, " "))
end

--- @param _99 _99.State
--- @return _99.Prompt
function Prompt.tutorial(_99)
  --- @type _99.Prompt
  local context = setmetatable({}, Prompt)
  set_defaults(context, _99)
  context.operation = "tutorial"
  context.data = {
    type = "tutorial",
    xid = context.xid, -- TODO: i want to get rid of this when i implement rehydration of the data.
    buffer = 0,
    window = 0,
    tutorial = {},
  }
  context.logger:debug("99 Request", "method", "tutorial")

  return context
end

--- @param _99 _99.State
--- @return _99.Prompt
function Prompt.search(_99)
  --- @type _99.Prompt
  local context = setmetatable({}, Prompt)
  set_defaults(context, _99)
  context.operation = "search"
  context.data = {
    type = "search",
    qfix_items = {},
    response = "",
  }
  context.logger:debug("99 Request", "method", "search")

  return context
end

local function report_error(context, message, err)
  pcall(context.logger.error, context.logger, message, "error", tostring(err))
end

--- @param obs _99.Providers.Observer | nil
function Prompt:_observer(obs)
  local observer
  observer = {
    on_start = function()
      if self.state ~= "ready" then
        return
      end
      self.state = "requesting"
      self._99.tracking:track(self)

      if obs and obs.on_start then
        obs.on_start()
      end
    end,
    on_complete = function(status, res)
      if self._completed then
        return
      end
      self._completed = true
      self._complete_request = nil
      res = type(res) == "string" and res or tostring(res or "")
      if self:is_cancelled() then
        status, res = "cancelled", ""
      end
      self.state = status
      if obs and obs.on_complete then
        local ok, err = pcall(obs.on_complete, status, res)
        if not ok then
          self.state = "failed"
          res = tostring(err)
          report_error(self, "request completion failed", err)
        end
      end
      self:stop()
      local ok, err = pcall(self._99.sync, self._99)
      if not ok then
        report_error(self, "request state sync failed", err)
      end
      if self.state == "failed" then
        local message = res ~= "" and res or "provider request failed"
        vim.notify(
          "99 request failed: " .. message:sub(1, 2048),
          vim.log.levels.ERROR
        )
      end
    end,
    on_stderr = function(line)
      if not self._completed and obs and obs.on_stderr then
        obs.on_stderr(line)
      end
    end,
    on_stdout = function(line)
      if not self._completed and obs and obs.on_stdout then
        obs.on_stdout(line)
      end
    end,
  }
  self._complete_request = observer.on_complete
  return observer
end

local allowed_context_types = {
  "visual",
  "search",
  "tutorial",
  "vibe",
}
--- @return boolean
function Prompt:valid()
  local t = self.data.type
  for _, allowed in ipairs(allowed_context_types) do
    if t == allowed then
      return true
    end
  end
  return false
end

--- @param observer _99.Providers.Observer?
function Prompt:start_request(observer)
  local l = self.logger
  l:assert(
    self.state == "ready",
    'state is not "ready" when attempting to start a request'
  )

  local obs = self:_observer(observer)
  local ok, err = pcall(function()
    obs.on_start()
    if self.state ~= "requesting" then
      return
    end
    assert(self:finalize(), "context failed to finalize")
    local prompt = table.concat(self.agent_context, "\n")
    self:save_prompt(prompt)
    self.provider:make_request(prompt, self, obs)
  end)
  if not ok then
    obs.on_complete("failed", tostring(err))
  end
end

function Prompt:is_cancelled()
  return self.state == "cancelled"
end

function Prompt:is_completed()
  return self.state == "success" or self.state == "failed"
end

---@diagnostic disable-next-line: undefined-doc-name
--- @param proc vim.SystemObj?
function Prompt:_set_process(proc)
  self._proc = proc
  if self:is_cancelled() or self:is_completed() then
    self:_terminate_process()
  end
end

--- Retain the handle until exit, and escalate if graceful cancellation is ignored.
function Prompt:_terminate_process()
  local proc = self._proc
  if not proc or self._terminating then
    return
  end
  self._terminating = true
  local signal = self.provider.cancellation_signal or 15
  pcall(proc.kill, proc, signal)
  local function escalate()
    if self._proc ~= proc then
      return
    end
    if signal == 2 then
      pcall(proc.kill, proc, 15)
      vim.defer_fn(function()
        if self._proc == proc then
          pcall(proc.kill, proc, 9)
        end
      end, 250)
    else
      pcall(proc.kill, proc, 9)
    end
  end
  vim.defer_fn(escalate, 250)
end

function Prompt:_process_exited()
  self._proc = nil
  if self._stopped then
    self:_cleanup_files()
  end
end

function Prompt:cancel()
  if self:is_cancelled() or self:is_completed() then
    return
  end

  self.state = "cancelled"
  self:_terminate_process()
  if self._complete_request then
    self._complete_request("cancelled", "")
  else
    self:stop()
  end
end

--- @return _99.Prompt.Data.Visual
function Prompt:visual_data()
  assert(
    self.data.type == "visual",
    "you cannot get visual data if its not type visual"
  )
  return self.data --[[@as _99.Prompt.Data.Visual]]
end

--- @return _99.Prompt.Data.Tutorial
function Prompt:tutorial_data()
  assert(
    self.data.type == "tutorial",
    "you cannot get tutorial data if its not type tutorial"
  )
  return self.data --[[@as _99.Prompt.Data.Tutorial]]
end

--- @return _99.Prompt.Data.Search
function Prompt:search_data()
  assert(
    self.data.type == "search",
    "you cannot get search data if its not type search"
  )
  return self.data --[[@as _99.Prompt.Data.Search]]
end

--- @return _99.Search.Result[]
function Prompt:qfix_data()
  assert(
    self.data.type == "search" or self.data.type == "vibe",
    "data type is not search or vibe: " .. self.data.type
  )
  return self.data.qfix_items
end

function Prompt:stop()
  self:cancel()
  if self._stopped then
    return
  end
  self._stopped = true
  self:_terminate_process()
  self:clear_marks()

  local callbacks = self.clean_ups or {}
  self.clean_ups = {}
  for _, cb in ipairs(callbacks) do
    local ok, err = pcall(cb)
    if not ok then
      report_error(self, "request cleanup failed", err)
    end
  end
  self:_cleanup_files()
end

--- @param clean_up fun(): nil
function Prompt:add_clean_up(clean_up)
  if self._stopped then
    clean_up()
  else
    table.insert(self.clean_ups, clean_up)
  end
end

--- @param md_file_name string
--- @return self
function Prompt:add_md_file_name(md_file_name)
  table.insert(self.md_file_names, md_file_name)
  return self
end

--- @param content string
--- @return self
function Prompt:add_prompt_content(content)
  table.insert(self.agent_context, content)
  return self
end

--- @param refs _99.Reference[]
function Prompt:add_references(refs)
  for _, ref in ipairs(refs) do
    self.logger:debug("adding reference to context")
    table.insert(self.agent_context, ref.content)
  end
end

function Prompt:_read_md_files()
  local cwd = self.cwd
  local function contained(path)
    local prefix = cwd:sub(-1) == "/" and cwd or cwd .. "/"
    return path == cwd or path:sub(1, #prefix) == prefix
  end
  local dir = self.full_path == "" and cwd
    or vim.uv.fs_realpath(vim.fs.dirname(self.full_path))
  dir = dir and vim.fs.normalize(dir)
  local remaining = 256 * 1024

  while dir and contained(dir) do
    for _, md_file_name in ipairs(self.md_file_names) do
      local md_path = vim.uv.fs_realpath(vim.fs.joinpath(dir, md_file_name))
      md_path = md_path and vim.fs.normalize(md_path)
      if md_path and contained(md_path) then
        local content, err = utils.read_file_bounded(md_path, remaining)
        if content then
          remaining = remaining - #content
          table.insert(self.agent_context, content)
        else
          self.logger:warn("skipped automatic context", "error", err)
        end
      end
    end

    if dir == cwd then
      break
    end

    dir = vim.fs.dirname(dir)
  end
end

--- @return string[]
function Prompt:content()
  return self.agent_context
end

--- @return boolean
function Prompt:_ready_request_files()
  if self._request_dir then
    return true
  end
  local dir, err = utils.request_directory(self._tmp_root)
  assert(dir, err)
  self._request_dir = dir
  self.tmp_file = vim.fs.joinpath(dir, "response")
  return true
end

function Prompt:_cleanup_files()
  if self._request_dir and vim.uv.fs_lstat(self._request_dir) then
    local ok, result = pcall(vim.fn.delete, self._request_dir, "rf")
    if not ok or result ~= 0 then
      report_error(self, "failed to remove request directory", result)
    end
  end
end

--- @param prompt string
function Prompt:save_prompt(prompt)
  self.debug_prompt = prompt
  self.logger:debug("request prompt", "prompt", prompt)
end

--- @return boolean, self
function Prompt:finalize()
  if self._finalized then
    return true, self
  end
  if self:_ready_request_files() == false then
    return false, self
  end
  self:_read_md_files()

  local ok, visual_data = pcall(self.visual_data, self)
  if ok then
    local f_loc =
      self._99.prompts.get_file_location(self.full_path, visual_data.range)
    table.insert(self.agent_context, f_loc)
    table.insert(
      self.agent_context,
      self._99.prompts.get_range_text(visual_data.range)
    )
  end
  if self.provider.response_mode == "stdout" then
    table.insert(
      self.agent_context,
      "Return the requested result as your final response. Do not write an output file."
    )
    if self.operation ~= "vibe" then
      table.insert(self.agent_context, "Do not modify any project files.")
    end
  else
    table.insert(
      self.agent_context,
      self._99.prompts.tmp_file_location(self.tmp_file)
    )
    if self.operation ~= "vibe" then
      table.insert(self.agent_context, self._99.prompts.only_tmp_file_change())
    end
  end
  self._finalized = true
  return true, self
end

function Prompt:clear_marks()
  for _, mark in pairs(self.marks or {}) do
    local ok, err = pcall(mark.delete, mark)
    if not ok then
      report_error(self, "failed to clear request mark", err)
    end
  end
  self.marks = {}
end

return Prompt
