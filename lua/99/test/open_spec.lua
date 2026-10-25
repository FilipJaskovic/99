-- luacheck: globals describe it assert before_each after_each
local _99 = require("99")
local Window = require("99.window")
local Logger = require("99.logger.logger")
local test_utils = require("99.test.test_utils")
local eq = assert.are.same

local function some_window_has(str)
  local wins = vim.api.nvim_list_wins()

  for _, winid in ipairs(wins) do
    local bufnr = vim.api.nvim_win_get_buf(winid)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local content = table.concat(lines, "\n")
    if str == content then
      return
    end
  end
  assert(
    false,
    "unable to find buffer with the str contents from an active window"
  )
end

local function qfix_items()
  local items = vim.fn.getqflist()
  local out = {}
  for _, item in ipairs(items) do
    table.insert(out, {
      filename = vim.api.nvim_buf_get_name(item.bufnr),
      col = item.col,
      lnum = item.lnum,
      text = item.text,
    })
  end
  return out
end

describe("open", function()
  local provider
  local previous_capture_select_input
  local previous_display_full_screen_message
  local previous_logs_by_id
  local tmp_dir
  local search_file
  local vibe_file

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
    tmp_dir = vim.uv.fs_realpath(tmp_dir)
    search_file = vim.fs.joinpath(tmp_dir, "foo.lua")
    vibe_file = vim.fs.joinpath(tmp_dir, "bar.lua")
    vim.fn.writefile({ "local foo = true" }, search_file)
    vim.fn.writefile({ "local bar = true", "return bar" }, vibe_file)

    provider = test_utils.TestProvider.new()
    _99.setup(test_utils.get_test_setup_options({
      tmp_dir = tmp_dir,
      in_flight_options = { enable = false },
    }, provider))

    previous_capture_select_input = Window.capture_select_input
    previous_display_full_screen_message = Window.display_full_screen_message
    previous_logs_by_id = Logger.logs_by_id
  end)

  after_each(function()
    Window.capture_select_input = previous_capture_select_input
    Window.display_full_screen_message = previous_display_full_screen_message
    Logger.logs_by_id = previous_logs_by_id
    Window.clear_active_popups()
    vim.cmd("silent! cclose")
    vim.fn.delete(tmp_dir, "rf")
  end)

  --- @param term "search" | "tutorial" | "vibe"
  ---@param result_str string
  local function op(term, result_str)
    _99[term]({ additional_prompt = result_str })
    local out = result_str
    provider:resolve("success", out)
    test_utils.next_frame()
    return out
  end

  local function search()
    return op("search", search_file .. ":1:1,1,search note")
  end

  local function vibe()
    return op("vibe", vibe_file .. ":2:2,1,vibe note")
  end

  local function tutorial()
    return op("tutorial", "here is a large tutorial")
  end

  local function select_content(idx)
    Window.capture_select_input = function(_, opts)
      opts.cb(true, opts.content[idx])
    end
  end

  it("reopens saved tutorial, vibe, and search results", function()
    search()
    vibe()
    local t = tutorial()

    select_content(1)
    _99.open()
    some_window_has(t)

    select_content(2)
    _99.open()
    eq({
      { filename = vibe_file, col = 2, lnum = 2, text = "vibe note" },
    }, qfix_items())

    select_content(3)
    _99.open()
    eq({
      { filename = search_file, col = 1, lnum = 1, text = "search note" },
    }, qfix_items())
  end)

  it("views logs for selected request xid", function()
    search()
    vibe()

    local history = _99:__get_state().tracking.history
    local logs_by_xid = {
      [history[1].xid] = { "search log" },
      [history[2].xid] = { "vibe log" },
    }
    Logger.logs_by_id = function(xid)
      return logs_by_xid[xid]
    end

    local shown = nil
    Window.display_full_screen_message = function(lines)
      shown = lines
    end

    select_content(1)
    _99.view_logs()
    eq({ "search log" }, shown)

    select_content(2)
    _99.view_logs()
    eq({ "vibe log" }, shown)
  end)
end)
