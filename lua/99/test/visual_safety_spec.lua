-- luacheck: globals describe it assert before_each after_each
local test_utils = require("99.test.test_utils")
local _99 = require("99")
local Prompt = require("99.prompt")
local over_range = require("99.ops.over-range")
local Window = require("99.window")
local Logger = require("99.logger.logger")
local eq = assert.are.same

local function select(keys)
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes(keys .. "<Esc>", true, false, true),
    "x",
    false
  )
end

local function capture()
  local context = Prompt.visual(_99.__get_state())
  assert.is_not_nil(context.visual_snapshot)
  return context
end

local function setup(content, keys, row, col)
  local provider, buffer = test_utils.test_setup(content, row or 1, col or 0)
  select(keys)
  return provider, buffer, capture()
end

local function start(context)
  over_range(context, { additional_prompt = "replace selection" })
end

local function resolve(provider, text)
  provider:resolve("success", text)
  test_utils.next_frame()
end

describe("visual edit safety", function()
  local previous_select, previous_display
  before_each(function()
    previous_select = Window.capture_select_input
    previous_display = Window.display_full_screen_message
  end)

  after_each(function()
    Window.capture_select_input = previous_select
    Window.display_full_screen_message = previous_display
    _99.stop_all_requests()
    for _, buffer in ipairs(test_utils.created_files) do
      if vim.api.nvim_buf_is_valid(buffer) then
        vim.api.nvim_buf_delete(buffer, { force = true })
      end
    end
    test_utils.created_files = {}
    vim.o.selection = "inclusive"
  end)

  it(
    "replaces only selected UTF-8 text and keeps both surrounding fragments",
    function()
      local p, b, c = setup({ "prefix αβγ suffix", "tail" }, "vl", 1, 7)
      eq("αβ", c.data.range:to_text())
      start(c)
      resolve(p, "🙂")
      eq({ "prefix 🙂γ suffix", "tail" }, test_utils.r(b))
      eq("success", c.state)
    end
  )

  it(
    "replaces a multiline character selection without losing either edge",
    function()
      local p, b, c = setup({ "head ABC", "DEF tail" }, "vj0l", 1, 5)
      eq("ABC\nDE", c.data.range:to_text())
      start(c)
      resolve(p, "NEW")
      eq({ "head NEWF tail" }, test_utils.r(b))
    end
  )

  it(
    "replaces first-line and empty-line selections without extra blank lines",
    function()
      local p, b, c = setup({ "#!/bin/sh", "", "tail" }, "V")
      start(c)
      resolve(p, "#!/bin/bash")
      eq({ "#!/bin/bash", "", "tail" }, test_utils.r(b))
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      select("V")
      local empty = capture()
      start(empty)
      resolve(p, "NEW")
      eq({ "#!/bin/bash", "NEW", "tail" }, test_utils.r(b))
    end
  )

  it("includes a selected line break for character mode", function()
    local p, b, c = setup({ "first", "tail" }, "v$")
    eq("first\n", c.data.range:to_text())
    start(c)
    resolve(p, "NEW")
    eq({ "NEWtail" }, test_utils.r(b))
  end)

  it("keeps cancellation terminal before prompt submission", function()
    local p, b, c = setup({ "TARGET" }, "V")
    c:stop()
    start(c)
    assert.is_nil(p.request)
    eq("cancelled", c.state)
    eq({ "TARGET" }, test_utils.r(b))
  end)

  it("rejects edits made while prompt input is pending", function()
    local p, b, c = setup({ "header", "TARGET", "tail" }, "V", 2)
    vim.api.nvim_buf_set_text(b, 1, 0, 1, 6, { "USER WORK" })
    start(c)
    assert.is_nil(p.request)
    eq("failed", c.state)
    eq({ "header", "USER WORK", "tail" }, test_utils.r(b))
  end)

  local mutations = {
    {
      name = "user edits",
      change = function(b)
        vim.api.nvim_buf_set_text(b, 1, 0, 1, 6, { "USER WORK" })
      end,
      expected = { "header", "USER WORK", "middle", "tail" },
    },
    {
      name = "selection deletion",
      change = function(b)
        vim.api.nvim_buf_set_lines(b, 1, 2, false, {})
      end,
      expected = { "header", "middle", "tail" },
    },
    {
      name = "insertion before the selection",
      change = function(b)
        vim.api.nvim_buf_set_lines(b, 1, 1, false, { "NEW USER LINE" })
      end,
      expected = { "header", "NEW USER LINE", "TARGET", "middle", "tail" },
    },
    {
      name = "moving the selection",
      change = function()
        vim.cmd("2move 3")
      end,
      expected = { "header", "middle", "TARGET", "tail" },
    },
    {
      name = "edits elsewhere in the buffer",
      change = function(b)
        vim.api.nvim_buf_set_lines(b, 3, 4, false, { "USER TAIL" })
      end,
      expected = { "header", "TARGET", "middle", "USER TAIL" },
    },
  }
  for _, mutation in ipairs(mutations) do
    it("preserves " .. mutation.name .. " during a request", function()
      local p, b, c = setup({ "header", "TARGET", "middle", "tail" }, "V", 2)
      start(c)
      mutation.change(b)
      resolve(p, "STALE")
      eq(mutation.expected, test_utils.r(b))
      eq("failed", c.state)
      eq("STALE", c.unapplied_response)
      local logs = require("99.logger.logger").logs_by_id(c.xid)
      assert.is_truthy(table.concat(logs, "\n"):find("STALE", 1, true))
    end)
  end

  it("allows only the first completed overlapping request to apply", function()
    local p, b, first = setup({ "header", "TARGET", "tail" }, "V", 2)
    start(first)
    local first_request = p.request
    local second = capture()
    start(second)
    resolve(p, "NEWEST")
    first_request.observer.on_complete("success", "STALE")
    test_utils.next_frame()
    eq({ "header", "NEWEST", "tail" }, test_utils.r(b))
    eq("failed", first.state)
  end)

  for _, condition in ipairs({ "truncated", "filtered", "evicted" }) do
    it("shows the rejected response when logs are " .. condition, function()
      local p, b, c = setup({ "TARGET", "tail" }, "V")
      c.logger:set_level(condition == "filtered" and _99.FATAL or _99.DEBUG)
      over_range(c, {
        additional_prompt = string.rep(
          "x",
          condition == "truncated" and 270000 or 1
        ),
      })
      vim.api.nvim_buf_set_lines(b, 0, 1, false, { "USER WORK" })
      local response = string.rep("RECOVERY_TEXT\n", 200) .. "END"
      resolve(p, response)
      eq("failed", c.state)
      eq({ "USER WORK", "tail" }, test_utils.r(b))
      if condition == "evicted" then
        Logger.reset()
      end
      local cached = vim.deepcopy(Logger.logs_by_id(c.xid))
      assert.is_nil(table.concat(cached or {}, "\n"):find(response, 1, true))
      local displayed
      Window.capture_select_input = function(_, opts)
        opts.cb(true, opts.content[1])
      end
      Window.display_full_screen_message = function(lines)
        displayed = lines
      end
      _99.view_logs()
      assert.is_truthy(table.concat(displayed, "\n"):find(response, 1, true))
      eq(cached, Logger.logs_by_id(c.xid))
    end)
  end

  it("uses the source buffer after switching to another buffer", function()
    local p, b, c = setup({ "TARGET", "tail" }, "V")
    start(c)
    local other = test_utils.create_file({ "OTHER" })
    resolve(p, "NEW")
    eq({ "NEW", "tail" }, test_utils.r(b))
    eq({ "OTHER" }, test_utils.r(other))
  end)

  it("does not apply to an unloaded buffer", function()
    local p, b, c = setup({ "TARGET", "tail" }, "V")
    start(c)
    test_utils.create_file({ "OTHER" })
    vim.api.nvim_buf_delete(b, { force = true, unload = true })
    resolve(p, "STALE")
    eq("failed", c.state)
    assert.is_false(vim.api.nvim_buf_is_loaded(b))
  end)

  it("cancels every request even after the first buffer is wiped", function()
    local p, b, first = setup({ "TARGET", "tail" }, "V")
    start(first)
    local first_request = p.request
    local other = test_utils.create_file({ "OTHER" })
    select("V")
    local second = capture()
    start(second)
    vim.api.nvim_buf_delete(b, { force = true })
    _99.stop_all_requests()
    eq("cancelled", first.state)
    eq("cancelled", second.state)
    first_request.observer.on_complete("cancelled", "STALE")
    resolve(p, "STALE")
    eq({ "OTHER" }, test_utils.r(other))
  end)

  it("reports a nonmodifiable buffer as unapplied", function()
    local p, b, c = setup({ "TARGET" }, "V")
    start(c)
    vim.bo[b].modifiable = false
    resolve(p, "NEW")
    eq({ "TARGET" }, test_utils.r(b))
    eq("failed", c.state)
    eq("NEW", c.unapplied_response)
  end)

  for _, response in ipairs({ "", " \n ", false }) do
    it(
      "rejects an empty or malformed response: " .. tostring(response),
      function()
        local p, b, c = setup({ "TARGET" }, "V")
        start(c)
        resolve(p, response)
        eq({ "TARGET" }, test_utils.r(b))
        eq("failed", c.state)
      end
    )
  end

  it("rejects missing selection marks without editing", function()
    local p, b, c = setup({ "TARGET" }, "V")
    start(c)
    c.visual_snapshot.start_mark:delete()
    resolve(p, "NEW")
    eq({ "TARGET" }, test_utils.r(b))
    eq("failed", c.state)
  end)
end)
