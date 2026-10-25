local _99 = require("99")
local State = require("99.state")
local Tracking = require("99.state.tracking")
local StatusWindow = require("99.window.status-window")
local test_utils = require("99.test.test_utils")
local eq = assert.are.same

describe("setup lifecycle", function()
  it(
    "does not reuse an interactive prompt through caller-owned options",
    function()
      local provider = test_utils.TestProvider.new()
      _99.setup(test_utils.get_test_setup_options({
        in_flight_options = { enable = false },
      }, provider))
      local Window = require("99.window")
      local capture = Window.capture_input
      local callbacks = {}
      Window.capture_input = function(_, opts)
        table.insert(callbacks, opts.cb)
      end
      local opts = { additional_rules = {} }
      local ok, err = pcall(function()
        _99.search(opts)
        callbacks[1](true, "first request")
        provider:resolve("success", "")
        _99.search(opts)
      end)
      Window.capture_input = capture
      assert.is_true(ok, err)
      eq(2, #callbacks)
      eq({ additional_rules = {} }, opts)
      callbacks[2](false, "")
    end
  )

  it(
    "cancels old requests and stops their status loop on reconfiguration",
    function()
      local provider = test_utils.TestProvider.new()
      _99.setup(test_utils.get_test_setup_options({
        in_flight_options = { enable = false },
      }, provider))
      _99.search({ additional_prompt = "find a marker" })
      local old_state = _99.__get_state()
      local old_request = provider.request.prompt
      local original_stop = StatusWindow.stop
      local stopped = false
      StatusWindow.stop = function(self)
        stopped = self._99 == old_state
        return original_stop(self)
      end
      local ok, err = pcall(
        _99.setup,
        test_utils.get_test_setup_options({
          in_flight_options = { enable = false },
        }, test_utils.TestProvider.new())
      )
      StatusWindow.stop = original_stop
      assert.is_true(ok, err)
      assert.is_true(stopped)
      assert.is_true(old_request:is_cancelled())
      eq(0, old_state.tracking:active_count())
      eq(1, #vim.api.nvim_get_autocmds({
        group = "99_lifecycle",
        event = "VimLeavePre",
      }))
      provider:resolve("success", "/tmp/stale:1:1,1,stale")
      test_utils.next_frame()
      assert.is_true(old_request:is_cancelled())
    end
  )

  it("attempts every cancellation even if one cleanup throws", function()
    local tracking = Tracking.new({}, nil)
    local stopped = false
    tracking.history = {
      {
        state = "requesting",
        stop = function()
          error("broken cleanup")
        end,
      },
      {
        state = "requesting",
        stop = function()
          stopped = true
        end,
      },
    }
    local notify = vim.notify
    local notice
    vim.notify = function(message)
      notice = message
    end
    local ok, err = pcall(tracking.stop_all_requests, tracking)
    vim.notify = notify
    assert.is_true(ok, err)
    assert.is_true(stopped)
    assert.is_truthy(notice:find("broken cleanup", 1, true))
  end)

  it(
    "keeps a configured relative history directory bound to setup cwd",
    function()
      local cwd = vim.fn.getcwd()
      local a, b = vim.fn.tempname(), vim.fn.tempname()
      vim.fn.mkdir(a, "p")
      vim.fn.mkdir(b, "p")
      vim.api.nvim_set_current_dir(a)
      local state = State.new({ tmp_dir = "cache" })
      local initial = state:tmp_dir()
      vim.api.nvim_set_current_dir(b)
      eq(initial, state:tmp_dir())
      assert.is_truthy(initial:find(vim.uv.fs_realpath(a), 1, true))
      vim.api.nvim_set_current_dir(cwd)
      vim.fn.delete(a, "rf")
      vim.fn.delete(b, "rf")
    end
  )
end)
