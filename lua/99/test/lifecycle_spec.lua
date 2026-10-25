local Providers = require("99.providers")
local Prompt = require("99.prompt")
local Tracking = require("99.state.tracking")
local Utils = require("99.utils")
local Logger = require("99.logger.logger")
local test_utils = require("99.test.test_utils")
local eq = assert.are.same

-- These cases change cwd after creation; keep lazy module loads repository-bound.
vim.opt.runtimepath:prepend(vim.fn.getcwd())

describe("request lifecycle", function()
  local root, previous_cwd, original_system, original_notify
  local requests, buffers, notifications

  local function setup(command, config)
    local provider = setmetatable({
      _build_command = command or function()
        return { "offline-test" }
      end,
      _get_provider_name = function()
        return "OfflineProvider"
      end,
    }, { __index = Providers.BaseProvider })
    local state = vim.tbl_extend("force", {
      model = "offline",
      md_files = {},
      rules = { custom = {} },
      provider_override = provider,
      provider_extra_args = {},
      prompts = require("99.prompt-settings"),
      tracking = Tracking.new(),
      tmp_dir = function()
        return "./tmp"
      end,
      refresh_rules = function(self, cwd)
        self.refreshed_root = cwd
      end,
      sync = function(self)
        self.sync_count = (self.sync_count or 0) + 1
      end,
    }, config or {})
    local request = Prompt.search(state)
    requests[#requests + 1] = request
    return request, state, provider
  end

  local function start(request, extra)
    local results = {}
    request:start_request(vim.tbl_extend("force", {
      on_complete = function(status, text)
        results[#results + 1] = { status = status, text = text }
      end,
    }, extra or {}))
    return results
  end

  local function eventually(predicate)
    assert.is_true(vim.wait(2000, predicate, 5))
  end

  local function fake_spawn()
    local spawned = { signals = {} }
    spawned.proc = {
      kill = function(_, signal)
        spawned.signals[#spawned.signals + 1] = signal
      end,
    }
    vim.system = function(command, opts, on_exit)
      spawned.command, spawned.opts, spawned.exit = command, opts, on_exit
      return spawned.proc
    end
    return spawned
  end

  local function named_buffer(path)
    local buffer = test_utils.create_file({ "fixture" }, "lua")
    vim.api.nvim_buf_set_name(buffer, path)
    buffers[#buffers + 1] = buffer
    return buffer
  end

  before_each(function()
    previous_cwd = vim.fn.getcwd()
    original_system, original_notify = vim.system, vim.notify
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.chdir(root)
    requests, buffers, notifications = {}, {}, {}
    vim.notify = function(message)
      notifications[#notifications + 1] = message
    end
  end)

  after_each(function()
    vim.system, vim.notify = original_system, original_notify
    for _, request in ipairs(requests) do
      request:stop()
      if request._proc and request._proc.pid then
        pcall(request._proc.kill, request._proc, 9)
        eventually(function()
          return request._proc == nil
        end)
      else
        request:_process_exited()
      end
    end
    for _, buffer in ipairs(buffers) do
      pcall(vim.api.nvim_buf_delete, buffer, { force = true })
    end
    vim.fn.chdir(previous_cwd)
    vim.fn.delete(root, "rf")
  end)

  it("completes spawn and command-builder failures exactly once", function()
    for _, command in ipairs({
      function()
        return { root .. "/missing-executable" }
      end,
      function()
        error("invalid provider arguments")
      end,
    }) do
      local request, state = setup(command)
      local cleanups = 0
      request:add_clean_up(function()
        cleanups = cleanups + 1
      end)
      local results = start(request)
      eq(1, #results)
      eq("failed", results[1].status)
      eq(0, state.tracking:active_count())
      eq(1, cleanups)
      assert.is_nil(vim.uv.fs_stat(request._request_dir))
      assert.is_string(request.debug_prompt)
      assert.is_truthy(
        notifications[#notifications]:find("99 request failed", 1, true)
      )
    end
  end)

  it(
    "keeps cancellation terminal when a successful exit is already queued",
    function()
      local spawned = fake_spawn()
      local request, state = setup()
      local results = start(request)
      vim.fn.writefile({ "late response" }, request.tmp_file)
      spawned.exit({ code = 0, signal = 0 })
      request:cancel()
      test_utils.next_frame()
      eq({ { status = "cancelled", text = "" } }, results)
      eq("cancelled", request.state)
      eq(0, state.tracking:active_count())
      eq(1, state.sync_count)
    end
  )

  it(
    "guards final delivery when response retrieval cancels the request",
    function()
      local spawned = fake_spawn()
      local request, _, provider = setup()
      provider._retrieve_response = function()
        request:cancel()
        return true, "late success"
      end
      local results = start(request)
      spawned.exit({ code = 0, signal = 0 })
      eventually(function()
        return #results == 1
      end)
      eq("cancelled", results[1].status)
      eq("cancelled", request.state)
    end
  )

  it("guards completion and late output from a custom provider", function()
    local request, state = setup()
    local observer
    request.provider = {
      make_request = function(_, _, _, obs)
        observer = obs
      end,
    }
    local output = 0
    local results = start(request, {
      on_stdout = function()
        output = output + 1
      end,
    })
    request:cancel()
    observer.on_stdout("late output")
    observer.on_complete("success", "late response")
    observer.on_complete("failed", nil)
    eq({ { status = "cancelled", text = "" } }, results)
    eq(0, output)
    eq(1, state.sync_count)
  end)

  it(
    "reports completion-handler errors and still runs every cleanup once",
    function()
      local request, state = setup()
      local provider = test_utils.TestProvider.new()
      request.provider = provider
      local cleaned = 0
      request.marks.bad = {
        delete = function()
          error("deleted source buffer")
        end,
      }
      request:add_clean_up(function()
        error("broken cleanup")
      end)
      request:add_clean_up(function()
        cleaned = cleaned + 1
      end)
      start(request, {
        on_complete = function()
          error("cannot apply response")
        end,
      })
      provider:resolve("success", "replacement")
      request:stop()
      eq("failed", request.state)
      eq(1, cleaned)
      eq(0, state.tracking:active_count())
      assert.is_truthy(notifications[1]:find("cannot apply response", 1, true))
    end
  )

  it(
    "accepts a nil custom-provider failure response without breaking cleanup",
    function()
      local request = setup()
      local provider = test_utils.TestProvider.new()
      request.provider = provider
      local results = start(request)
      provider:resolve("failed", nil)
      eq({ { status = "failed", text = "" } }, results)
      assert.is_nil(vim.uv.fs_stat(request._request_dir))
      assert.is_truthy(
        notifications[1]:find("provider request failed", 1, true)
      )
    end
  )

  it(
    "reserves private directories independently of the random-number generator",
    function()
      local first = setup()
      local second = setup()
      assert(first:finalize())
      vim.fn.writefile({ "first" }, first.tmp_file)
      assert(second:finalize())
      assert.is_not_equal(first._request_dir, second._request_dir)
      eq(448, bit.band(vim.uv.fs_stat(first._request_dir).mode, 511))
      eq({ "first" }, vim.fn.readfile(first.tmp_file))
      assert(first:finalize())
      eq({ "first" }, vim.fn.readfile(first.tmp_file))
      first:save_prompt("debug context")
      first:stop()
      first:stop()
      eq("debug context", first.debug_prompt)
      assert.is_nil(vim.uv.fs_stat(first._request_dir))
      assert.is_not_nil(vim.uv.fs_stat(second._request_dir))
    end
  )

  it(
    "snapshots canonical cwd, rules, provider, and arguments before submission",
    function()
      local request, state, provider =
        setup(nil, { provider_extra_args = { "--old" } })
      state.rules.custom[1] = { name = "new-rule" }
      state.provider_override = Providers.OpenCodeProvider
      state.provider_extra_args[1] = "--new"
      local next_root = root .. "/next-project"
      vim.fn.mkdir(next_root, "p")
      vim.fn.chdir(next_root)
      local spawned = fake_spawn()
      start(request)
      eq(vim.uv.fs_realpath(root), request.cwd)
      eq(request.cwd, state.refreshed_root)
      eq({}, request.rules.custom)
      eq(provider, request.provider)
      eq(request.cwd, spawned.opts.cwd)
      eq({ "offline-test", "--old" }, spawned.command)
      assert.is_truthy(request.tmp_file:find(request.cwd .. "/tmp/", 1, true))
    end
  )

  it("bounds combined stdout and stderr before scheduling delivery", function()
    local spawned = fake_spawn()
    local request = setup(nil, { max_response_bytes = 32 })
    local results = start(request)
    spawned.opts.stdout(nil, string.rep("A", 16))
    spawned.opts.stderr(nil, string.rep("B", 17))
    spawned.opts.stderr(nil, nil)
    spawned.opts.stdout(nil, string.rep("C", 1024))
    eventually(function()
      return #results == 1
    end)
    eq("failed", results[1].status)
    assert.is_truthy(results[1].text:find("byte limit", 1, true))
    eq({ 15 }, spawned.signals)
    local logs = table.concat(Logger.logs_by_id(request.xid) or {}, "\n")
    assert.is_nil(logs:find(string.rep("A", 16), 1, true))
    spawned.exit({ code = 1, signal = 15 })
    test_utils.next_frame()
    eq(1, #results)
  end)

  it(
    "fails a silent request at its deadline while retaining its process handle",
    function()
      local spawned = fake_spawn()
      local request, state = setup(nil, { request_timeout = 5 })
      local results = start(request)
      eventually(function()
        return #results == 1
      end)
      eq("failed", results[1].status)
      assert.is_truthy(results[1].text:find("timed out", 1, true))
      eq(0, state.tracking:active_count())
      eq(spawned.proc, request._proc)
      eq({ 15 }, spawned.signals)
      spawned.exit({ code = 143, signal = 15 })
      eventually(function()
        return request._proc == nil
      end)
      eq(1, #results)
    end
  )

  it("escalates Codex cancellation through INT, TERM, and KILL", function()
    local spawned = fake_spawn()
    local request, _, provider = setup()
    provider.cancellation_signal = 2
    local results = start(request)
    request:cancel()
    eventually(function()
      return #spawned.signals == 3
    end)
    eq({ 2, 15, 9 }, spawned.signals)
    eq(1, #results)
    eq("cancelled", results[1].status)
    eq(spawned.proc, request._proc)
    spawned.exit({ code = 137, signal = 9 })
    eventually(function()
      return request._proc == nil
    end)
  end)

  it("kills and reaps a real child that ignores TERM", function()
    if vim.fn.has("win32") == 1 then
      return
    end
    local ready = root .. "/ready"
    local request = setup(function()
      return {
        "/bin/sh",
        "-c",
        'trap "" TERM; printf ready > "$1"; exec /bin/sleep 30',
        "offline",
        ready,
      }
    end)
    local results = start(request)
    eventually(function()
      return vim.fn.filereadable(ready) == 1
    end)
    local proc = request._proc
    request:cancel()
    eq(proc, request._proc)
    eq("cancelled", results[1].status)
    eventually(function()
      return request._proc == nil
    end)
    assert.is_nil(vim.uv.kill(proc.pid, 0))
    eq(1, #results)
  end)

  it(
    "confines automatic Markdown context to the captured real project root",
    function()
      local project = root .. "/project"
      local sibling = root .. "/project-private"
      vim.fn.mkdir(project, "p")
      vim.fn.mkdir(sibling, "p")
      vim.fn.writefile({ "ROOT_RULE" }, project .. "/AGENT.md")
      vim.fn.writefile({ "PRIVATE_RULE" }, sibling .. "/AGENT.md")
      vim.fn.chdir(project)
      named_buffer(sibling .. "/fixture.lua")
      local outside = setup(nil, { md_files = { "AGENT.md" } })
      outside:_read_md_files()
      eq({}, outside.agent_context)

      named_buffer(project .. "/fixture.lua")
      local inside =
        setup(nil, { md_files = { "AGENT.md", "LINK.md", "HUGE.md" } })
      assert(vim.uv.fs_symlink(sibling .. "/AGENT.md", project .. "/LINK.md"))
      vim.fn.writefile(
        { string.rep("X", 256 * 1024 + 1) },
        project .. "/HUGE.md"
      )
      vim.fn.chdir(sibling)
      inside:_read_md_files()
      eq({ "ROOT_RULE\n" }, inside.agent_context)
    end
  )

  it("drops session-local tutorial handles when loading history", function()
    local _, state = setup()
    local saved = {
      user_prompt = "tutorial",
      data = {
        type = "tutorial",
        buffer = 17,
        window = 23,
        tutorial = { "# Saved tutorial" },
      },
    }
    local restored = Prompt.deserialize(state, saved)
    assert.is_nil(restored.data.buffer)
    assert.is_nil(restored.data.window)
    eq({ "# Saved tutorial" }, restored.data.tutorial)
    eq(17, saved.data.buffer)
  end)

  it(
    "persists closed JSON immediately and preserves prior state on encoding failure",
    function()
      local file = root .. "/nested/99-state"
      assert.is_true(
        Utils.write_file_json_safe({ requests = { "saved" } }, file)
      )
      eq({ requests = { "saved" } }, Utils.read_file_json_safe(file))
      local invalid = {}
      invalid.self = invalid
      assert.is_false(Utils.write_file_json_safe(invalid, file))
      eq({ requests = { "saved" } }, Utils.read_file_json_safe(file))
    end
  )
end)
