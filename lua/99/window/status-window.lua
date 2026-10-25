local Window = require("99.window")
local Consts = require("99.consts")
local Throbber = require("99.ops.throbber")

--- @alias _99.StatusWindow.State "init" | "running"

--- @class _99.StatusWindow.Opts
--- this is pure a class for testing.   helps controls timings
--- @docs include
--- @field throbber_opts _99.Throbber.Opts | nil
--- options for the throbber in the top left
--- @field in_flight_interval number | nil
--- frequency in which the in-flight interval checks to see if it should be
--- displayed / removed
--- @field enable boolean | nil
--- defaults to true

--- @param opts _99.StatusWindow.Opts | nil
--- @return _99.StatusWindow.Opts
local function default_opts(opts)
  opts = opts or {}
  opts.throbber_opts = opts.throbber_opts
    or {
      throb_time = Consts.throbber_throb_time,
      cooldown_time = Consts.throbber_cooldown_time,
      tick_time = Consts.throbber_tick_time,
    }
  opts.in_flight_interval = opts.in_flight_interval
    or Consts.show_in_flight_requests_loop_time
  opts.enable = opts.enable == nil and true or opts.enable
  return opts
end

--- @class _99.StatusWindow
--- @field opts _99.StatusWindow.Opts
--- @field state _99.StatusWindow.State
--- @field generation number
--- @field timer uv.uv_timer_t?
--- @field win _99.window.Window | nil
--- @field throbber _99.Throbber | nil
--- @field _99 _99.State
local StatusWindow = {}
StatusWindow.__index = StatusWindow

--- @param _99 _99.State
--- @param opts _99.StatusWindow.Opts | nil
function StatusWindow.new(_99, opts)
  return setmetatable({
    opts = default_opts(opts),
    state = "init",
    generation = 0,
    _99 = _99,
  }, StatusWindow)
end

function StatusWindow:_shutdown_status_window()
  if self.throbber then
    self.throbber:stop()
  end

  local win = self.win
  if win ~= nil then
    Window.close(win)
  end
  self.win = nil
  self.throbber = nil
end

function StatusWindow:_run_loop(generation)
  if self.state ~= "running" or self.generation ~= generation then
    return
  end
  self.timer = vim.defer_fn(function()
    self:_run_loop(generation)
  end, self.opts.in_flight_interval)

  Window.refresh_active_windows()
  local current_win = self.win
  if current_win ~= nil and not Window.is_active_window(current_win) then
    self:_shutdown_status_window()
    current_win = nil
  end

  local active_window = Window.has_active_status_window()
  local active_other_window = Window.has_active_windows()
  local active_requests = self._99.tracking:active_count()
  if
    active_window == false and active_other_window
    or active_window and active_requests > 0
    or active_window == false and active_requests == 0
  then
    return
  end

  if current_win == nil then
    local ok, win = pcall(Window.status_window)
    if not ok then
      --- TODO: There needs to be a way to display logs for "all active requests"
      --- this is its own activity and should not be added to any work set
      return
    end

    local throb = Throbber.new(function(throb)
      local count = self._99.tracking:active_count()
      local win_valid = Window.valid(win)

      if count == 0 or not win_valid then
        return self:_shutdown_status_window()
      end

      --- @type string[]
      local lines = {
        throb .. " requests(" .. tostring(count) .. ") " .. throb,
      }

      for _, c in ipairs(self._99.tracking:active()) do
        if c.state == "requesting" then
          table.insert(lines, c.operation)
        end
      end

      Window.resize(win, #lines[1], #lines)
      vim.api.nvim_buf_set_lines(win.buf_id, 0, -1, false, lines)
    end, self.opts.throbber_opts)

    self.win = win
    self.throbber = throb

    throb:start()
  end
end

function StatusWindow:start()
  if not self.opts.enable or self.state == "running" then
    return
  end
  self.state = "running"
  self.generation = self.generation + 1
  self:_run_loop(self.generation)
end

-- Stop immediately, including callbacks already queued on Neovim's main loop.
function StatusWindow:stop()
  self.state = "init"
  self.generation = self.generation + 1
  if self.timer then
    if not self.timer:is_closing() then
      self.timer:stop()
      self.timer:close()
    end
    self.timer = nil
  end
  self:_shutdown_status_window()
end

return StatusWindow
