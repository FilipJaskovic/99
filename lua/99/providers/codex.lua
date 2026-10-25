local value_options = {
  ["--config"] = true,
  ["-c"] = true,
  ["--profile"] = true,
  ["-p"] = true,
  ["--model"] = true,
  ["-m"] = true,
  ["--sandbox"] = true,
  ["-s"] = true,
  ["--enable"] = true,
  ["--disable"] = true,
  ["--add-dir"] = true,
  ["--local-provider"] = true,
}
local switches = {
  ["--oss"] = true,
  ["--ignore-user-config"] = true,
  ["--ignore-rules"] = true,
  ["--strict-config"] = true,
}

-- Limit advanced options so the CLI keeps its stdin and final-message contracts.
local function parse_extra_args(args)
  local forwarded = {}
  local sandbox, model
  local i = 1
  while i <= #args do
    local arg = args[i]
    assert(type(arg) == "string", "Codex extra arguments must be strings")
    local option, value = arg:match("^(%-%-[^=]+)=(.*)$")
    option = option or arg
    if value_options[option] then
      if value == nil then
        i = i + 1
        value = args[i]
      end
      assert(
        type(value) == "string" and value ~= "" and value:sub(1, 1) ~= "-",
        "Codex option requires a value: " .. option
      )
      if option == "--sandbox" or option == "-s" then
        assert(
          value == "read-only"
            or value == "workspace-write"
            or value == "danger-full-access",
          "Invalid Codex sandbox: " .. value
        )
        sandbox = value
      elseif option == "--model" or option == "-m" then
        model = value
      else
        vim.list_extend(forwarded, { option, value })
      end
    elseif switches[option] and value == nil then
      table.insert(forwarded, option)
    else
      error("Unsupported Codex extra argument: " .. arg)
    end
    i = i + 1
  end
  return forwarded, sandbox, model
end

--- @param BaseProvider _99.Providers.BaseProvider
return function(BaseProvider)
  --- @class CodexProvider : _99.Providers.BaseProvider
  local CodexProvider = setmetatable({
    response_mode = "stdout",
    handles_extra_args = true,
    cancellation_signal = 2,
  }, { __index = BaseProvider })

  --- @param query string
  --- @param context _99.Prompt
  --- @return string[]
  function CodexProvider._build_command(_self, _query, context)
    local extra_args = context.provider_extra_args
      or (context._99 and context._99.provider_extra_args)
      or {}
    local forwarded, sandbox, model = parse_extra_args(extra_args)
    sandbox = sandbox
      or (context.operation == "vibe" and "workspace-write" or "read-only")
    model = model or context.model
    local command = {
      "codex",
      "exec",
      "--skip-git-repo-check",
      "--sandbox",
      sandbox,
      "--color",
      "never",
      "--ephemeral",
      "--output-last-message",
      vim.fn.fnamemodify(context.tmp_file, ":p"),
    }

    if model and model ~= "default" then
      vim.list_extend(command, { "--model", model })
    end

    vim.list_extend(command, forwarded)
    vim.list_extend(command, { "-c", 'approval_policy="never"', "-" })
    return command
  end

  --- @param context _99.Prompt
  --- @param query string
  function CodexProvider._system_opts(_self, _context, query)
    return { stdin = query }
  end

  function CodexProvider._get_provider_name()
    return "CodexProvider"
  end

  function CodexProvider._get_default_model()
    return "default"
  end

  -- The CLI selects its configured model. Account-aware discovery needs app-server.
  function CodexProvider.fetch_models(callback)
    callback({ "default" }, nil)
  end

  return CodexProvider
end
