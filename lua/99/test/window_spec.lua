-- luacheck: globals describe it assert before_each after_each
local Window = require("99.window")
local test_utils = require("99.test.test_utils")
local eq = assert.are.same

describe("Window", function()
  local previous_list_uis

  before_each(function()
    previous_list_uis = vim.api.nvim_list_uis
    vim.api.nvim_list_uis = function()
      return {
        { width = 120, height = 40 },
      }
    end
  end)

  after_each(function()
    vim.api.nvim_list_uis = previous_list_uis
    Window.clear_active_popups()
  end)

  it("shows keymap legend window and applies keyoffset", function()
    local win = Window.capture_input("Prompt", {
      cb = function() end,
      keymap = {
        q = "cancel",
        ["<CR>"] = "submit",
      },
    })
    eq(2, #Window.active_windows)
    eq(3, vim.wo[win.win_id].scrolloff)

    local legend = Window.active_windows[2]
    local lines = vim.api.nvim_buf_get_lines(legend.buf_id, 0, -1, false)
    eq({ " <CR>=submit q=cancel" }, lines)
  end)

  it("highlights keymap legend as warning=comment", function()
    Window.capture_input("Prompt", {
      cb = function() end,
      keymap = {
        q = "cancel",
        ["<CR>"] = "submit",
      },
    })

    local legend = Window.active_windows[2]
    local legend_nsid = vim.api.nvim_get_namespaces()["99.window.legend"]
    local extmarks = vim.api.nvim_buf_get_extmarks(
      legend.buf_id,
      legend_nsid,
      0,
      -1,
      { details = true }
    )

    local highlights = {}
    for _, extmark in ipairs(extmarks) do
      table.insert(highlights, {
        extmark[2],
        extmark[3],
        extmark[4].end_col,
        extmark[4].hl_group,
      })
    end

    eq({
      { 0, 1, 5, "WarningMsg" },
      { 0, 6, 12, "Comment" },
      { 0, 13, 14, "WarningMsg" },
      { 0, 15, 21, "Comment" },
    }, highlights)
  end)

  it("submits, cancels, and selects with exactly one callback", function()
    local calls = {}
    local function callback(ok, result)
      table.insert(calls, { ok, result })
    end
    Window.capture_input("Prompt", { content = { "hello" }, cb = callback })
    vim.cmd("write")
    eq({ { true, "hello" } }, calls)

    calls = {}
    Window.capture_input("Prompt", { cb = callback })
    vim.fn.maparg("q", "n", false, true).callback()
    eq({ { false, "" } }, calls)

    calls = {}
    Window.capture_select_input(
      "Select",
      { content = { "1: first" }, cb = callback }
    )
    vim.fn.maparg("<CR>", "n", false, true).callback()
    eq({ { true, "1: first" } }, calls)
    test_utils.next_frame()
  end)

  it("removes prompt buffers and autocmds on native close", function()
    local calls = 0
    local before = #vim.api.nvim_get_autocmds({ event = "WinClosed" })
    local win = Window.capture_input("Prompt", {
      cb = function()
        calls = calls + 1
      end,
    })
    local legend = Window.active_windows[2]
    vim.api.nvim_win_close(win.win_id, true)
    eq(1, calls)
    eq(false, vim.api.nvim_buf_is_valid(win.buf_id))
    eq(false, vim.api.nvim_buf_is_valid(legend.buf_id))
    eq({}, Window.active_windows)
    eq(before, #vim.api.nvim_get_autocmds({ event = "WinClosed" }))
  end)

  it("keeps a replacement prompt opened by a cancellation callback", function()
    local replacement
    Window.capture_input("First", {
      cb = function()
        replacement = Window.capture_input("Second", { cb = function() end })
      end,
    })
    Window.clear_active_popups()
    eq(true, Window.valid(replacement))
    eq(true, Window.is_active_window(replacement))
  end)

  it("skips deferred setup after a selector is closed", function()
    local called = false
    Window.capture_select_input("Select", {
      content = { "1: first" },
      cb = function() end,
      on_load = function()
        called = true
      end,
    })
    Window.clear_active_popups()
    test_utils.next_frame()
    eq(false, called)
  end)

  it("cleans buffers when status windows are closed directly", function()
    local win = Window.status_window()
    vim.api.nvim_win_close(win.win_id, true)
    Window.close(win)
    Window.refresh_active_windows()
    eq(false, vim.api.nvim_buf_is_valid(win.buf_id))
    eq({}, Window.active_windows)
  end)
end)
