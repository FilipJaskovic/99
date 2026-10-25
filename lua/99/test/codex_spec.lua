local _99 = require("99")
local Providers = require("99.providers")
local Codex = require("99.providers.codex")(Providers.BaseProvider)
local Prompt = require("99.prompt")
local test_utils = require("99.test.test_utils")
local eq = assert.are.same

-- The test init uses a relative runtime path; requests below change cwd.
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local function option(command, name)
  for i, arg in ipairs(command) do
    if arg == name then
      return command[i + 1]
    end
  end
end

describe("CodexProvider", function()
  local root, cwd, previous_cwd, previous_path

  before_each(function()
    root = vim.fn.tempname()
    cwd = root .. "/vault with spaces"
    previous_cwd = vim.fn.getcwd()
    previous_path = vim.env.PATH
    vim.fn.mkdir(root .. "/bin", "p")
    vim.fn.mkdir(root .. "/results", "p")
    vim.fn.mkdir(cwd, "p")
    local executable = root .. "/bin/codex"
    vim.fn.writefile({
      "#!/bin/sh",
      'root="${0%/*}/.."',
      'printf "%s\\n" "$@" > "$root/argv"',
      'pwd -P > "$root/cwd"',
      'cat > "$root/stdin"',
      "output=",
      'while [ "$#" -gt 0 ]; do',
      '  if [ "$1" = "--output-last-message" ]; then',
      "    shift",
      '    output="$1"',
      "  fi",
      "  shift",
      "done",
      'if [ -f "$root/fail" ]; then',
      '  printf "Codex login required\\n" >&2',
      "  exit 7",
      "fi",
      'if [ -f "$root/no-output" ]; then exit 0; fi',
      'if [ -f "$root/empty" ]; then : > "$output"; exit 0; fi',
      'if [ -f "$root/payload" ]; then',
      '  cat "$root/payload" > "$output"',
      "else",
      '  printf "replacement\\nsecond line" > "$output"',
      "fi",
      'if [ -f "$root/quiet" ]; then exit 0; fi',
      'printf "stdout is not the replacement\\n"',
      'printf "progress\\n" >&2',
    }, executable)
    assert(vim.uv.fs_chmod(executable, 493))
    vim.env.PATH = root .. "/bin:" .. previous_path
    vim.fn.chdir(cwd)
    _99.setup({
      provider = Codex,
      tmp_dir = root .. "/results",
      logger = { type = "void" },
      in_flight_options = { enable = false },
    })
  end)

  after_each(function()
    vim.fn.chdir(previous_cwd)
    vim.env.PATH = previous_path
    test_utils.clean_files()
    vim.fn.delete(root, "rf")
  end)

  local function context(operation)
    local request = Prompt.search(_99.__get_state())
    request.operation = operation or "search"
    assert.is_true(request:finalize())
    return request
  end

  local function run(query, configure)
    local request = context()
    if configure then
      configure(request)
    end
    local result
    local calls = 0
    Codex:make_request(query, request, {
      on_start = function()
        request.state = "requesting"
      end,
      on_stdout = function() end,
      on_stderr = function() end,
      on_complete = function(status, response)
        calls = calls + 1
        result = { status = status, response = response }
      end,
    })
    assert.is_true(vim.wait(3000, function()
      return result ~= nil
    end))
    eq(1, calls)
    return result
  end

  it("uses the CLI model default and safe operation sandboxes", function()
    eq("default", Codex._get_default_model())
    for _, operation in ipairs({ "visual", "search", "tutorial", "vibe" }) do
      local command = Codex:_build_command("unused", context(operation))
      eq({ "codex", "exec" }, { command[1], command[2] })
      eq(
        operation == "vibe" and "workspace-write" or "read-only",
        option(command, "--sandbox")
      )
      assert.is_nil(option(command, "--model"))
      assert.is_true(vim.tbl_contains(command, "--skip-git-repo-check"))
      eq('approval_policy="never"', option(command, "-c"))
      eq("-", command[#command])
    end
  end)

  it(
    "preserves an explicit model and forwards advanced options before stdin",
    function()
      local request = context()
      request.model = "custom-codex-model"
      request.provider_extra_args =
        { "--config", 'model_reasoning_effort="high"' }
      local command = Codex:_build_command("unused", request)
      eq("custom-codex-model", option(command, "--model"))
      eq('model_reasoning_effort="high"', option(command, "--config"))
      eq("-", command[#command])
      assert.is_true(Codex.handles_extra_args)
    end
  )

  it("allows an explicit sandbox override without duplicate flags", function()
    local request = context()
    request.provider_extra_args = { "--sandbox=workspace-write" }
    local command = Codex:_build_command("unused", request)
    eq("workspace-write", option(command, "--sandbox"))
    local count = 0
    for _, arg in ipairs(command) do
      count = count + (arg == "--sandbox" and 1 or 0)
    end
    eq(1, count)
  end)

  it("keeps captured advanced options after state changes", function()
    local state = _99.__get_state()
    state.provider_extra_args =
      { "--profile", "original", "--sandbox", "read-only" }
    local request = context()
    state.provider_extra_args[2] = "changed"
    state.provider_extra_args = { "--sandbox", "danger-full-access" }
    local command = Codex:_build_command("unused", request)
    eq("original", option(command, "--profile"))
    eq("read-only", option(command, "--sandbox"))

    state.provider_extra_args = {}
    request = context()
    state.provider_extra_args = { "--sandbox", "danger-full-access" }
    eq(
      "read-only",
      option(Codex:_build_command("unused", request), "--sandbox")
    )
  end)

  it("rejects arguments that replace the output or prompt contract", function()
    for _, args in ipairs({
      { "--json" },
      { "--experimental-json" },
      { "--json=true" },
      { "-o", "/tmp/wrong" },
      { "-o/tmp/wrong" },
      { "--output-last-message=/tmp/wrong" },
      { "--output-schema", "/tmp/schema" },
      { "resume" },
      { "extra prompt" },
      { "--" },
      { "-" },
      { "--config" },
      { "--config", "--json" },
      { "--dangerously-bypass-approvals-and-sandbox" },
    }) do
      local request = context()
      request.provider_extra_args = args
      assert.has_error(function()
        Codex:_build_command("unused", request)
      end)
    end
  end)

  it(
    "sends exact large stdin and reads the final-message file in a non-Git vault",
    function()
      local query = "--not-an-option\n"
        .. string.rep("selection '$` text\n", 10000)
      local result = run(query, function()
        vim.fn.chdir(root)
      end)
      eq("success", result.status)
      eq("replacement\nsecond line", result.response)
      eq(query, table.concat(vim.fn.readfile(root .. "/stdin", "b"), "\n"))
      eq(vim.uv.fs_realpath(cwd), vim.fn.readfile(root .. "/cwd")[1])
      local args = vim.fn.readfile(root .. "/argv")
      assert.is_true(vim.tbl_contains(args, "--skip-git-repo-check"))
      assert.is_false(vim.tbl_contains(args, query))
      assert.is_nil(vim.uv.fs_stat(cwd .. "/.git"))
    end
  )

  it("reports CLI failure without a successful replacement", function()
    vim.fn.writefile({}, root .. "/fail")
    local result = run("query")
    eq("failed", result.status)
    assert.is_truthy(result.response:find("7", 1, true))
    assert.is_truthy(result.response:find("Codex login required", 1, true))
  end)

  local function replace_visual(keys, payload)
    vim.fn.writefile(
      vim.split(payload, "\n", { plain = true }),
      root .. "/payload",
      "b"
    )
    local buffer = test_utils.create_file({ "first", "tail" })
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes(keys .. "<Esc>", true, false, true),
      "x",
      false
    )
    local id = _99.visual({ additional_prompt = "replace selection" })
    local request = _99.__get_state().tracking.id_to_request[id]
    assert.is_true(vim.wait(3000, function()
      return request._completed
    end))
    eq("success", request.state)
    return test_utils.r(buffer)
  end

  it("preserves every response newline in character replacements", function()
    eq({ "NEWtail" }, replace_visual("v$", "NEW"))
    eq({ "NEW", "tail" }, replace_visual("v$", "NEW\n"))
    eq({ "NEW", "", "tail" }, replace_visual("v$", "NEW\n\n"))
  end)

  it("normalizes only one line terminator for linewise replacements", function()
    eq({ "NEW", "tail" }, replace_visual("V", "NEW"))
    eq({ "NEW", "tail" }, replace_visual("V", "NEW\n"))
    eq({ "NEW", "", "tail" }, replace_visual("V", "NEW\n\n"))
  end)

  it(
    "rejects a successful process that did not produce its output file",
    function()
      vim.fn.writefile({}, root .. "/no-output")
      eq("failed", run("query").status)
    end
  )

  it("rejects an empty final response", function()
    vim.fn.writefile({}, root .. "/empty")
    eq("failed", run("query").status)
  end)

  it("enforces the configured final-response byte limit", function()
    vim.fn.writefile({}, root .. "/quiet")
    local result = run("query", function(request)
      request._99.max_response_bytes = 8
    end)
    eq("failed", result.status)
    assert.is_truthy(result.response:find("limit", 1, true))
  end)

  it("uses final-response instructions for all Codex operations", function()
    local state = _99.__get_state()
    for _, create in ipairs({ Prompt.search, Prompt.tutorial, Prompt.vibe }) do
      local request = create(state)
      if request.operation == "vibe" then
        request:add_prompt_content(
          state.prompts.prompts.vibe(Codex.response_mode)
        )
      end
      assert.is_true(request:finalize())
      local query = table.concat(request.agent_context, "\n")
      assert.is_nil(query:find("TEMP_FILE", 1, true))
      assert.is_truthy(query:find("final", 1, true))
    end

    local buffer = test_utils.create_file({ "local value = 1" }, "lua")
    vim.fn.setpos("'<", { buffer, 1, 1, 0 })
    vim.fn.setpos("'>", { buffer, 1, 15, 0 })
    local request = Prompt.visual(state)
    assert.is_true(request:finalize())
    assert.is_nil(
      table.concat(request.agent_context, "\n"):find("TEMP_FILE", 1, true)
    )
  end)

  it("keeps the file-output vibe prompt for other providers", function()
    local prompts = require("99.prompt-settings").prompts
    assert.is_truthy(prompts.vibe():find("<TEMP_FILE>", 1, true))
    assert.is_nil(prompts.vibe("stdout"):find("TEMP_FILE", 1, true))
    assert.is_truthy(prompts.vibe("stdout"):find("final response", 1, true))
  end)

  it("uses the captured provider mode when building a vibe prompt", function()
    local recording = test_utils.TestProvider.new()
    recording.response_mode = "stdout"
    local state = _99.__get_state()
    state.provider_override = recording
    local request = Prompt.vibe(state)
    state.provider_override = Providers.OpenCodeProvider

    require("99.ops.vibe")(request, { additional_prompt = "Update the code" })

    assert.is_not_nil(recording.request)
    assert.is_nil(recording.request.query:find("TEMP_FILE", 1, true))
    assert.is_truthy(recording.request.query:find("final response", 1, true))
    recording:resolve("cancelled", "")
  end)
end)
