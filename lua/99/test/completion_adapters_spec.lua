-- luacheck: globals describe it assert before_each after_each
local Completions = require("99.extensions.completions")
local Native = require("99.extensions.native")
local eq = assert.are.same

local function state(source)
  return {
    completion = { source = source, custom_rules = {}, files = {} },
    rules = { custom = {}, by_name = {} },
  }
end

describe("native completion lifecycle", function()
  local previous_timer, previous_mode, previous_complete
  local timers, completed, buffers

  local function buffer(before)
    local buf = vim.api.nvim_create_buf(false, true)
    table.insert(buffers, buf)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { before .. "X" })
    vim.api.nvim_win_set_cursor(0, { 1, #before })
    return buf
  end

  local function flush(timer)
    timer.callback()
    local done = false
    vim.schedule(function()
      done = true
    end)
    local timer_factory = vim.uv.new_timer
    vim.uv.new_timer = previous_timer
    local finished = vim.wait(1000, function()
      return done
    end)
    vim.uv.new_timer = timer_factory
    assert(finished)
  end

  before_each(function()
    previous_timer = vim.uv.new_timer
    previous_mode = vim.fn.mode
    previous_complete = vim.fn.complete
    timers, completed, buffers = {}, {}, {}
    vim.uv.new_timer = function()
      local timer = { closed = false }
      function timer:stop()
        assert(not self.closed, "stopped a closed timer")
      end
      function timer:start(_, _, callback)
        assert(not self.closed, "started a closed timer")
        self.callback = callback
      end
      function timer:close()
        assert(not self.closed, "closed a timer twice")
        self.closed = true
      end
      table.insert(timers, timer)
      return timer
    end
    vim.fn.mode = function()
      return "i"
    end
    vim.fn.complete = function(col, items)
      table.insert(completed, { col = col, items = items })
    end
    Completions._reset()
    Completions.register({
      trigger = "@",
      name = "files",
      get_items = function()
        return {
          { label = "My Note.md", insertText = '@"My Note.md"' },
        }
      end,
    })
  end)

  after_each(function()
    for _, buf in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    vim.uv.new_timer = previous_timer
    vim.fn.mode = previous_mode
    vim.fn.complete = previous_complete
    Completions._reset()
  end)

  it(
    "completes an unfinished quoted reference from its trigger column",
    function()
      local buf = buffer('read @"My N')
      Native.init_for_buffer(state())
      vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
      flush(timers[1])
      eq(6, completed[1].col)
      eq('@"My Note.md"', completed[1].items[1].word)
    end
  )

  it("ignores queued completion after switching to another buffer", function()
    local buf = buffer("@M")
    Native.init_for_buffer(state())
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
    buffer("@M")
    flush(timers[1])
    eq({}, completed)
  end)

  it(
    "disposes timers on replacement and wipe, including queued callbacks",
    function()
      local buf = buffer("@M")
      Native.init_for_buffer(state())
      vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
      Native.init_for_buffer(state())
      eq(true, timers[1].closed)
      flush(timers[1])
      eq({}, completed)
      vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
      vim.api.nvim_buf_delete(buf, { force = true })
      eq(true, timers[2].closed)
      flush(timers[2])
      eq({}, completed)
    end
  )
end)

describe("cmp and blink adapter initialization", function()
  local previous_cmp, previous_adapter, previous_loader, previous_notify
  local previous_compat, previous_compat_loader
  local registrations, registered, notifications

  before_each(function()
    previous_cmp = package.loaded.cmp
    previous_adapter = package.loaded["99.extensions.cmp"]
    previous_loader = package.preload.cmp
    previous_compat = package.loaded["blink.compat"]
    previous_compat_loader = package.preload["blink.compat"]
    previous_notify = vim.notify
    registrations, notifications = 0, {}
    package.loaded["99.extensions.cmp"] = nil
    package.loaded.cmp = {
      register_source = function(_, source)
        registrations = registrations + 1
        registered = source
      end,
      setup = { buffer = function() end },
    }
    vim.notify = function(message)
      table.insert(notifications, message)
    end
  end)

  after_each(function()
    package.loaded.cmp = previous_cmp
    package.loaded["99.extensions.cmp"] = previous_adapter
    package.preload.cmp = previous_loader
    package.loaded["blink.compat"] = previous_compat
    package.preload["blink.compat"] = previous_compat_loader
    vim.notify = previous_notify
    Completions._reset()
  end)

  it("registers once and updates the source when setup repeats", function()
    local adapter = require("99.extensions.cmp")
    adapter.init(state("cmp"))
    local latest = state("cmp")
    adapter.init(latest)
    eq(1, registrations)
    eq(latest, registered._99)
  end)

  it("uses the same reusable source through blink.compat", function()
    package.loaded["blink.compat"] = {}
    local extensions = require("99.extensions")
    extensions.init(state("blink"))
    extensions.init(state("blink"))
    eq(1, registrations)
    eq({}, notifications)
  end)

  it("lets the extension router report a missing cmp dependency", function()
    package.loaded.cmp = nil
    package.preload.cmp = function()
      error("cmp intentionally unavailable")
    end
    require("99.extensions").init(state("cmp"))
    eq(0, registrations)
    eq(1, #notifications)
    assert(notifications[1]:find("nvim%-cmp is not installed"))
  end)
end)
