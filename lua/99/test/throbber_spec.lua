local Throbber = require("99.ops.throbber")
local Time = require("99.time")
local eq = assert.are.same

describe("Throbber", function()
  local original_now, original_defer, now, pending, throbber

  before_each(function()
    original_now, original_defer = Time.now, vim.defer_fn
    now, pending = 0, {}
    Time.now = function()
      return now
    end
    vim.defer_fn = function(callback)
      local timer = { callback = callback, closed = false }
      timer.stop = function() end
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
    if throbber then
      throbber:stop()
    end
    Time.now, vim.defer_fn = original_now, original_defer
  end)

  it(
    "cycles through throb, cooldown, and restart phases, then stops",
    function()
      local received = {}
      throbber = Throbber.new(function(icon)
        table.insert(received, { icon, throbber.state })
      end, { throb_time = 600, cooldown_time = 200, tick_time = 10 })
      throbber.throb_fn = function(percent)
        return tostring(percent)
      end

      local function tick(at)
        now = at
        table.remove(pending, 1).callback()
      end

      throbber:start()
      tick(300)
      tick(600)
      tick(700)
      tick(800)
      tick(950)
      eq({
        { "0", "throbbing" },
        { "0.5", "throbbing" },
        { "1", "cooldown" },
        { "1", "cooldown" },
        { "1", "throbbing" },
        { "0.25", "throbbing" },
      }, received)

      local last = pending[1]
      throbber:stop()
      assert.is_true(last.closed)
      tick(1000)
      eq(6, #received)
      eq(0, #pending)
    end
  )
end)
