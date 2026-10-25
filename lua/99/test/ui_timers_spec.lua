local Window = require("99.window")
local StatusWindow = require("99.window.status-window")
local RequestStatus = require("99.ops.request_status")
local Throbber = require("99.ops.throbber")
local Mark = require("99.ops.marks")
local Point = require("99.geo").Point
local eq = assert.are.same

describe("UI timer lifecycle", function()
  local defer_fn, list_uis, pending

  before_each(function()
    defer_fn, list_uis = vim.defer_fn, vim.api.nvim_list_uis
    pending = {}
    vim.api.nvim_list_uis = function()
      return { { width = 120, height = 40 } }
    end
    vim.defer_fn = function(callback)
      local timer = { closed = false, callback = callback }
      function timer:stop()
        self.stopped = true
      end
      function timer:is_closing()
        return self.closed
      end
      function timer:close()
        self.closed = true
      end
      table.insert(pending, timer)
      return timer
    end
  end)

  after_each(function()
    Window.clear_active_popups()
    vim.defer_fn, vim.api.nvim_list_uis = defer_fn, list_uis
  end)

  it(
    "stops status windows synchronously and ignores queued callbacks after restart",
    function()
      local tracking = {
        active_count = function()
          return 1
        end,
        active = function()
          return { { state = "requesting", operation = "search" } }
        end,
      }
      local status = StatusWindow.new({ tracking = tracking })
      status:start()
      local first = status.win
      local queued = vim.list_slice(pending)
      status:stop()
      status:stop()
      eq(false, vim.api.nvim_win_is_valid(first.win_id))
      eq(false, vim.api.nvim_buf_is_valid(first.buf_id))
      for _, timer in ipairs(queued) do
        eq(true, timer.closed)
      end

      status:start()
      local current = status.win
      local count = #pending
      for _, timer in ipairs(queued) do
        timer.callback()
      end
      eq(current, status.win)
      eq(count, #pending)
      status:stop()
      StatusWindow.new({ tracking = tracking }, { enable = false }):stop()
    end
  )

  it("stops a request status when its buffer is wiped", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local mark = Mark.mark_point(buf, Point:from_1_based(1, 1))
    local status = RequestStatus.new(5, 1, "Implementing", mark)
    status:start()
    vim.api.nvim_buf_delete(buf, { force = true })
    pending[1].callback()
    eq(false, status.running)
    eq(1, #pending)
  end)

  it("releases request timers and does not revive an old run", function()
    local calls = 0
    local status = RequestStatus.new(5, 1, "Implementing", function()
      calls = calls + 1
    end)
    status:start()
    local first = pending[1]
    status:start()
    eq(1, #pending)
    status:stop()
    eq(true, first.closed)
    status:start()
    first.callback()
    eq(0, calls)
    eq(2, #pending)
    pending[2].callback()
    eq(1, calls)
    status:stop()
  end)

  it(
    "releases throbber timers and stops scheduling after its callback stops it",
    function()
      local calls = 0
      local throbber = Throbber.new(function()
        calls = calls + 1
      end)
      throbber:start()
      local first = pending[1]
      throbber:start()
      eq(1, #pending)
      throbber:stop()
      eq(true, first.closed)
      throbber:start()
      first.callback()
      eq(2, calls)
      eq(2, #pending)
      throbber:stop()

      local stopping
      stopping = Throbber.new(function()
        stopping:stop()
      end)
      stopping:start()
      eq(2, #pending)
    end
  )
end)
