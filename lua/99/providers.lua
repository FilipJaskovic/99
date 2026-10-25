--- @class _99.Providers.Observer
--- @field on_stdout fun(line: string): nil
--- @field on_stderr fun(line: string): nil
--- @field on_complete fun(status: _99.Prompt.EndingState, res: string): nil
--- @field on_start fun(): nil

--- @param fn fun(...: any): nil
--- @return fun(...: any): nil
local function once(fn)
  local called = false
  return function(...)
    if called then
      return
    end
    called = true
    fn(...)
  end
end

--- @class _99.Providers.BaseProvider
--- @field _build_command fun(self: _99.Providers.BaseProvider, query: string, context: _99.Prompt): string[]
--- @field _get_provider_name fun(self: _99.Providers.BaseProvider): string
--- @field _get_default_model fun(): string
--- @field response_mode? "stdout"
--- @field handles_extra_args? boolean
--- @field cancellation_signal? number
--- @field _system_opts? fun(self: _99.Providers.BaseProvider, context: _99.Prompt, query: string): table
local BaseProvider = {}

--- @param callback fun(models: string[]|nil, err: string|nil): nil
function BaseProvider.fetch_models(callback)
  callback(nil, "This provider does not support listing models")
end

--- @param context _99.Prompt
function BaseProvider._retrieve_response(_, context)
  local limit = context._99.max_response_bytes or 4 * 1024 * 1024
  local text, err =
    require("99.utils").read_file_bounded(context.tmp_file, limit)
  if not text then
    return false, "unable to retrieve response: " .. tostring(err)
  end
  if vim.trim(text) == "" then
    return false, "provider produced no response"
  end
  return true, text:gsub("\r\n", "\n")
end

--- Spawn and supervise one CLI. Hooks can supply stdin/env, while the base owns
--- cwd, deadlines, output limits, and callbacks. Final output is read from tmp_file.
--- @param query string
--- @param context _99.Prompt
--- @param observer _99.Providers.Observer
function BaseProvider:make_request(query, context, observer)
  local logger = context.logger:set_area(self:_get_provider_name())
  local limit = context._99.max_response_bytes or 4 * 1024 * 1024
  local timeout = context._99.request_timeout or 300000
  local completed, output_error = false, nil
  local stdout_bytes, stderr_bytes = 0, 0
  local stderr_tail = ""
  local deadline
  local function stop_deadline()
    if deadline then
      deadline:stop()
      deadline:close()
      deadline = nil
    end
  end
  local complete = once(function(status, text)
    completed = true
    stop_deadline()
    if context:is_cancelled() then
      status, text = "cancelled", ""
    end
    pcall(
      logger.debug,
      logger,
      "process completed",
      "stdout_bytes",
      stdout_bytes,
      "stderr_bytes",
      stderr_bytes
    )
    observer.on_complete(status, text)
  end)
  local function fail(message)
    context:_terminate_process()
    complete("failed", message)
  end

  -- Coalesce fast-event chunks into one pending delivery. The byte budget is
  -- checked before scheduling, so a noisy process cannot flood the event queue.
  local pending = { stdout = {}, stderr = {} }
  local scheduled = false
  local function stream(kind)
    return function(err, data)
      if completed or context._completed or output_error then
        return
      end
      if err and err ~= "" then
        output_error = kind .. " read error: " .. tostring(err)
        vim.schedule(function()
          fail(output_error)
        end)
        return
      end
      if not data or data == "" then
        return
      end
      if kind == "stdout" then
        stdout_bytes = stdout_bytes + #data
      else
        stderr_bytes = stderr_bytes + #data
        stderr_tail = (stderr_tail .. data):sub(-8192)
      end
      if stdout_bytes + stderr_bytes > limit then
        output_error = "provider output exceeds byte limit (" .. limit .. ")"
        vim.schedule(function()
          fail(output_error)
        end)
        return
      end
      local chunks = pending[kind]
      chunks[#chunks + 1] = data
      if #chunks >= 64 then
        pending[kind] = { table.concat(chunks) }
      end
      if scheduled then
        return
      end
      scheduled = true
      vim.schedule(function()
        scheduled = false
        local batch = pending
        pending = { stdout = {}, stderr = {} }
        if completed or context:is_cancelled() then
          return
        end
        for _, name in ipairs({ "stdout", "stderr" }) do
          local text = table.concat(batch[name])
          if text ~= "" then
            local callback = name == "stdout" and observer.on_stdout
              or observer.on_stderr
            local ok, message = pcall(callback, text)
            if not ok then
              fail("provider output observer failed: " .. tostring(message))
              return
            end
          end
        end
      end)
    end
  end

  local ok, err = pcall(function()
    observer.on_start()
    if context:is_cancelled() then
      complete("cancelled", "")
      return
    end
    local command = self:_build_command(query, context)
    if not self.handles_extra_args then
      vim.list_extend(
        command,
        context.provider_extra_args or context._99.provider_extra_args or {}
      )
    end
    local opts = self._system_opts and self:_system_opts(context, query) or {}
    opts.cwd = context.cwd
    opts.text = true
    opts.timeout = nil
    opts.detach = false
    opts.stdout = stream("stdout")
    opts.stderr = stream("stderr")
    if context:is_cancelled() then
      complete("cancelled", "")
      return
    end
    local proc = vim.system(
      command,
      opts,
      vim.schedule_wrap(function(obj)
        context:_process_exited()
        if completed then
          return
        end
        if context:is_cancelled() then
          complete("cancelled", "")
        elseif output_error then
          complete("failed", output_error)
        elseif obj.code ~= 0 then
          complete(
            "failed",
            string.format(
              "process exit code: %s (signal %s)\n%s",
              tostring(obj.code),
              tostring(obj.signal),
              stderr_tail
            )
          )
        else
          local read_ok, retrieved, text =
            pcall(self._retrieve_response, self, context)
          if not read_ok then
            complete(
              "failed",
              "response retrieval failed: " .. tostring(retrieved)
            )
          else
            complete(retrieved and "success" or "failed", text)
          end
        end
      end)
    )
    context:_set_process(proc)
    if not completed then
      deadline = assert(vim.uv.new_timer())
      deadline:start(
        timeout,
        0,
        vim.schedule_wrap(function()
          if not completed then
            fail("provider request timed out after " .. timeout .. " ms")
          end
        end)
      )
      context:add_clean_up(stop_deadline)
    end
  end)
  if not ok then
    fail("unable to start provider: " .. tostring(err))
  end
end

--- @class OpenCodeProvider : _99.Providers.BaseProvider
local OpenCodeProvider = setmetatable({}, { __index = BaseProvider })

--- @param query string
--- @param context _99.Prompt
--- @return string[]
function OpenCodeProvider._build_command(_, query, context)
  return {
    "opencode",
    "run",
    "--agent",
    "build",
    "-m",
    context.model,
    query,
  }
end

--- @return string
function OpenCodeProvider._get_provider_name()
  return "OpenCodeProvider"
end

--- @return string
function OpenCodeProvider._get_default_model()
  return "opencode/claude-sonnet-4-5"
end

function OpenCodeProvider.fetch_models(callback)
  vim.system({ "opencode", "models" }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        callback(nil, "Failed to fetch models from opencode")
        return
      end
      local models = vim.split(obj.stdout, "\n", { trimempty = true })
      callback(models, nil)
    end)
  end)
end

--- @class ClaudeCodeProvider : _99.Providers.BaseProvider
local ClaudeCodeProvider = setmetatable({}, { __index = BaseProvider })

--- @param query string
--- @param context _99.Prompt
--- @return string[]
function ClaudeCodeProvider._build_command(_, query, context)
  return {
    "claude",
    "--model",
    context.model,
    "--print",
    query,
  }
end

--- @return string
function ClaudeCodeProvider._get_provider_name()
  return "ClaudeCodeProvider"
end

--- @return string
function ClaudeCodeProvider._get_default_model()
  return "claude-sonnet-4-5"
end

-- TODO: the claude CLI has no way to list available models.
-- We could use the Anthropic API (https://docs.anthropic.com/en/api/models)
-- but that requires the user to have an ANTHROPIC_API_KEY set which isn't ideal.
-- Until Anthropic adds a CLI command for this, we have to hardcode the list here.
-- See https://github.com/anthropics/claude-code/issues/12612
function ClaudeCodeProvider.fetch_models(callback)
  callback({
    "claude-opus-4-6",
    "claude-sonnet-4-5",
    "claude-haiku-4-5",
    "claude-opus-4-5",
    "claude-opus-4-1",
    "claude-sonnet-4-0",
    "claude-opus-4-0",
    "claude-3-7-sonnet-latest",
  }, nil)
end

--- @class CursorAgentProvider : _99.Providers.BaseProvider
local CursorAgentProvider = setmetatable({}, { __index = BaseProvider })

--- @param query string
--- @param context _99.Prompt
--- @return string[]
function CursorAgentProvider._build_command(_, query, context)
  return {
    "cursor-agent",
    "--model",
    context.model,
    "--print",
    query,
  }
end

--- @return string
function CursorAgentProvider._get_provider_name()
  return "CursorAgentProvider"
end

--- @return string
function CursorAgentProvider._get_default_model()
  return "sonnet-4.5"
end

function CursorAgentProvider.fetch_models(callback)
  vim.system({ "cursor-agent", "models" }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        callback(nil, "Failed to fetch models from cursor-agent")
        return
      end
      local models = {}
      for _, line in ipairs(vim.split(obj.stdout, "\n", { trimempty = true })) do
        -- `cursor-agent models` outputs lines like "model-id - description",
        -- so we grab everything before the first " - " separator
        local id = line:match("^(%S+)%s+%-")
        if id then
          table.insert(models, id)
        end
      end
      callback(models, nil)
    end)
  end)
end

--- @class KiroProvider : _99.Providers.BaseProvider
local KiroProvider = setmetatable({}, { __index = BaseProvider })

--- @param query string
--- @param context _99.Prompt
--- @return string[]
function KiroProvider._build_command(_, query, context)
  return {
    "kiro-cli",
    "chat",
    "--no-interactive",
    "--model",
    context.model,
    query,
  }
end

--- @return string
function KiroProvider._get_provider_name()
  return "KiroProvider"
end

--- @return string
function KiroProvider._get_default_model()
  return "claude-sonnet-4.5"
end

--- @class GeminiCLIProvider : _99.Providers.BaseProvider
local GeminiCLIProvider = setmetatable({}, { __index = BaseProvider })

--- @param query string
--- @param context _99.Prompt
--- @return string[]
function GeminiCLIProvider._build_command(_, query, context)
  return {
    "gemini",
    "--approval-mode",
    -- Allow writing to temp files by default. See:
    -- https://geminicli.com/docs/core/policy-engine/#default-policies
    "auto_edit",
    "--model",
    context.model,
    "--prompt",
    query,
  }
end

--- @return string
function GeminiCLIProvider._get_provider_name()
  return "GeminiCLIProvider"
end

--- @return string
function GeminiCLIProvider._get_default_model()
  -- Default to auto-routing between pro and flash. See:
  -- https://geminicli.com/docs/cli/model/
  return "auto"
end

return {
  BaseProvider = BaseProvider,
  CodexProvider = require("99.providers.codex")(BaseProvider),
  OpenCodeProvider = OpenCodeProvider,
  ClaudeCodeProvider = ClaudeCodeProvider,
  CursorAgentProvider = CursorAgentProvider,
  KiroProvider = KiroProvider,
  GeminiCLIProvider = GeminiCLIProvider,
}
