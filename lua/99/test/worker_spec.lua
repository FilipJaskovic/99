-- luacheck: globals describe it assert before_each after_each
local _99 = require("99")
local Window = require("99.window")
local Worker = require("99.extensions.work.worker")
local test_utils = require("99.test.test_utils")
local utils = require("99.utils")
local eq = assert.are.same

describe("worker", function()
  local previous_capture_input
  local captured_content
  local captured_callback
  local extra_dirs = {}
  local tmp_dir

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")

    local provider = test_utils.TestProvider.new()
    _99.setup(
      test_utils.get_test_setup_options({ tmp_dir = tmp_dir }, provider)
    )

    Worker.current_work_item = nil
    Worker.last_work_search = nil

    captured_content = nil
    previous_capture_input = Window.capture_input
    Window.capture_input = function(_, opts)
      captured_content = opts.content
      captured_callback = opts.cb
    end
  end)

  after_each(function()
    Window.capture_input = previous_capture_input
    Worker.current_work_item = nil
    Worker.last_work_search = nil

    if tmp_dir then
      vim.fn.delete(tmp_dir, "rf")
    end
    for _, dir in ipairs(extra_dirs) do
      vim.fn.delete(dir, "rf")
    end
    extra_dirs = {}
  end)

  it("set_work preloads existing persisted work", function()
    local work_path = utils.named_tmp_file(tmp_dir, "work-item")
    local file = assert(io.open(work_path, "w"))
    file:write("fix flaky tests")
    file:close()

    Worker.set_work()

    eq({ "fix flaky tests" }, captured_content)
  end)

  it("set_work shows default when no persisted work exists", function()
    Worker.set_work()

    eq(
      { "Put in the description of the work you want to complete" },
      captured_content
    )
  end)

  it("creates the directory before persisting the first work item", function()
    vim.fn.delete(tmp_dir, "rf")
    Worker.set_work({ description = "first task" })
    eq(
      { "first task" },
      vim.fn.readfile(utils.named_tmp_file(tmp_dir, "work-item"))
    )
    eq("first task", Worker.current_work_item)
  end)

  it("loads the active project's task after reconfiguration", function()
    Worker.set_work({ description = "project A" })
    local other = vim.fn.tempname()
    table.insert(extra_dirs, other)
    vim.fn.mkdir(other, "p")
    vim.fn.writefile(
      { "project B" },
      utils.named_tmp_file(other, "work-item"),
      "b"
    )
    _99.setup(
      test_utils.get_test_setup_options(
        { tmp_dir = other, in_flight_options = { enable = false } },
        test_utils.TestProvider.new()
      )
    )
    Worker.update_work()
    eq({ "project B" }, captured_content)
    eq("project B", Worker.current_work_item)
  end)

  it(
    "saves an open prompt to its original project without replacing the active task",
    function()
      Worker.set_work({ description = "project A" })
      Worker.update_work()
      local save_a = captured_callback
      local other = vim.fn.tempname()
      table.insert(extra_dirs, other)
      _99.setup(
        test_utils.get_test_setup_options(
          { tmp_dir = other, in_flight_options = { enable = false } },
          test_utils.TestProvider.new()
        )
      )
      Worker.set_work({ description = "project B" })
      save_a(true, "updated A")
      eq(
        { "updated A" },
        vim.fn.readfile(utils.named_tmp_file(tmp_dir, "work-item"))
      )
      eq(
        { "project B" },
        vim.fn.readfile(utils.named_tmp_file(other, "work-item"))
      )
      eq("project B", Worker.current_work_item)
    end
  )

  it("keeps the previous task if persistence fails", function()
    Worker.set_work({ description = "saved task" })
    -- A regular file cannot be the parent directory of a work item.
    local parent = vim.fn.tempname()
    table.insert(extra_dirs, parent)
    vim.fn.writefile({ "block parent creation" }, parent)
    _99.setup(
      test_utils.get_test_setup_options(
        { tmp_dir = parent .. "/child", in_flight_options = { enable = false } },
        test_utils.TestProvider.new()
      )
    )
    local ok = pcall(Worker.set_work, { description = "unsaved task" })
    eq(false, ok)
    assert.are_not.equal("unsaved task", Worker.current_work_item)
    eq(
      { "saved task" },
      vim.fn.readfile(utils.named_tmp_file(tmp_dir, "work-item"))
    )
  end)
end)
