-- luacheck: globals describe it assert before_each after_each
local Logger = require("99.logger.logger")
local eq = assert.are.same

describe("retained request log bounds", function()
  before_each(function()
    Logger.reset()
  end)

  after_each(function()
    Logger.reset()
  end)

  it(
    "bounds a noisy request and retains one valid truncation notice",
    function()
      local logger = Logger:set_id(101)
      for _ = 1, 20 do
        logger:debug("stdout", "data", string.rep("x", 64 * 1024))
      end
      local bytes, notices = 0, 0
      for _, line in ipairs(Logger.logs_by_id(101)) do
        bytes = bytes + #line
        local entry = vim.json.decode(line)
        if entry.msg:find("logs truncated", 1, true) then
          notices = notices + 1
        end
      end
      assert(bytes <= 256 * 1024)
      eq(1, notices)
    end
  )

  it(
    "bounds one oversized entry while preserving the configured sink",
    function()
      local logger = Logger:set_id(102)
      local written_bytes = 0
      logger.sink = {
        write_line = function(_, line)
          written_bytes = written_bytes + #line
        end,
      }
      logger:debug("stdout", "data", string.rep("x", 1024 * 1024))
      local logs = Logger.logs_by_id(102)
      eq(1, #logs)
      assert(#logs[1] <= 256 * 1024)
      assert(written_bytes > 1024 * 1024)
    end
  )

  it("releases request ordering on reset and can log again", function()
    Logger:set_id(103):debug("before reset")
    Logger.reset()
    eq({}, Logger.logs())
    eq(nil, Logger.logs_by_id(103))
    Logger:set_id(104):debug("after reset")
    eq(1, #Logger.logs())
    eq("after reset", vim.json.decode(Logger.logs_by_id(104)[1]).msg)
  end)
end)
