-- luacheck: globals describe it assert after_each
local Range = require("99.geo").Range
local test_utils = require("99.test.test_utils")
local eq = assert.are.same

local function selection(content, keys, col)
  local buffer = test_utils.create_file(content, "lua", 1, col or 0)
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes(keys .. "<Esc>", true, false, true),
    "x",
    false
  )
  return buffer
end

describe("visual selection geometry", function()
  after_each(function()
    vim.o.selection = "inclusive"
    test_utils.clean_files()
  end)

  it("includes complete multibyte and combining characters", function()
    selection({ "a🙂éz" }, "vl", 1)
    eq("🙂é", Range.from_visual_selection():to_text())
  end)

  it("honors an exclusive UTF-8 endpoint", function()
    vim.o.selection = "exclusive"
    selection({ "αβγ" }, "v2l")
    eq("αβ", Range.from_visual_selection():to_text())
  end)

  it("honors reversed exclusive selections", function()
    vim.o.selection = "exclusive"
    selection({ "αβγ" }, "$vh")
    eq("β", Range.from_visual_selection():to_text())
  end)

  it("keeps a single-character exclusive selection nonempty", function()
    vim.o.selection = "exclusive"
    selection({ "🙂tail" }, "v")
    eq("🙂", Range.from_visual_selection():to_text())
  end)

  it("does not consume a newline at an exclusive EOL endpoint", function()
    vim.o.selection = "exclusive"
    local buffer = selection({ "first", "tail" }, "v$")
    local range = Range.from_visual_selection()
    eq("first", range:to_text())
    range:replace_text({ "NEW" })
    eq({ "NEW", "tail" }, test_utils.r(buffer))
  end)

  it("includes the newline before an exclusive next-row endpoint", function()
    vim.o.selection = "exclusive"
    local buffer = selection({ "first", "", "tail" }, "v2j0")
    local range = Range.from_visual_selection()
    eq("first\n\n", range:to_text())
    range:replace_text({ "NEW" })
    eq({ "NEWtail" }, test_utils.r(buffer))
  end)

  it("includes a single empty-line newline in exclusive mode", function()
    vim.o.selection = "exclusive"
    selection({ "", "tail" }, "v")
    eq("\n", Range.from_visual_selection():to_text())
  end)

  it("does not include an empty-line newline with selection=old", function()
    vim.o.selection = "old"
    selection({ "", "tail" }, "v")
    eq("", Range.from_visual_selection():to_text())
  end)

  it("uses complete lines for linewise selections", function()
    local buffer = selection({ "one", "two", "tail" }, "Vj", 1)
    local range = Range.from_visual_selection()
    eq("one\ntwo", range:to_text())
    range:replace_text({ "NEW" })
    eq({ "NEW", "tail" }, test_utils.r(buffer))
  end)

  it("replaces an entire one-line buffer without a leading blank", function()
    local buffer = selection({ "only line" }, "V")
    Range.from_visual_selection():replace_text({ "NEW" })
    eq({ "NEW" }, test_utils.r(buffer))
  end)

  it("rejects block selections clearly before returning a range", function()
    selection({ "ab111ZZ", "cd222YY" }, "<C-v>jl", 2)
    local ok, err = pcall(Range.from_visual_selection)
    assert.is_false(ok)
    assert.is_truthy(
      tostring(err):find(
        "blockwise visual selections are not supported",
        1,
        true
      )
    )
  end)
end)
