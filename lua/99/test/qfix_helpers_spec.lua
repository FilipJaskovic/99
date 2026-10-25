-- luacheck: globals describe it assert
local QFixHelpers = require("99.ops.qfix-helpers")
local eq = assert.are.same
local create_entries = QFixHelpers.create_qfix_entries

describe("qfix helpers", function()
  it("parse_line parses filename, line, column, range, and notes", function()
    local parsed = QFixHelpers.parse_line(
      "lua/99/ops/search.lua:42:7,3,found semantic search"
    )

    eq({
      filename = "lua/99/ops/search.lua",
      lnum = 42,
      col = 7,
      text = "found semantic search",
    }, parsed)
  end)

  it("parse_line keeps commas in notes text", function()
    local parsed = QFixHelpers.parse_line("file.lua:10:3,1,note,with,commas")

    assert(parsed)
    eq("file.lua", parsed.filename)
    eq(10, parsed.lnum)
    eq(3, parsed.col)
    eq("note,with,commas", parsed.text)
  end)

  it("parse_line returns nil for malformed lines", function()
    eq(nil, QFixHelpers.parse_line("file.lua:10"))
    eq(nil, QFixHelpers.parse_line("file.lua:10:3:extra"))
    eq(nil, QFixHelpers.parse_line("file.lua:10:3"))
  end)

  it("parse_line keeps colons in notes text", function()
    local parsed =
      QFixHelpers.parse_line("file.lua:10:3,2,check this: important section")

    assert(parsed)
    eq("check this: important section", parsed.text)
  end)

  it(
    "create_qfix_entries parses valid lines and skips malformed ones",
    function()
      local response = table.concat({
        "a.lua:1:2,4,first hit",
        "not a valid line",
        "b.lua:3:4,1,",
        "c.lua:5:7,2,fallback values",
        "",
      }, "\n")

      local locations = create_entries(response)

      eq({
        {
          filename = "a.lua",
          lnum = 1,
          col = 2,
          text = "first hit",
        },
        {
          filename = "b.lua",
          lnum = 3,
          col = 4,
          text = "",
        },
        {
          filename = "c.lua",
          lnum = 5,
          col = 7,
          text = "fallback values",
        },
      }, locations)
    end
  )

  it("create_qfix_entries returns empty list for empty response", function()
    eq({}, create_entries(""))
  end)

  it("preserves colon-containing and Windows filenames", function()
    eq({
      filename = "/tmp/name:part.lua",
      lnum = 42,
      col = 7,
      text = "note: 2:3,4,example",
    }, QFixHelpers.parse_line(
      "/tmp/name:part.lua:42:7,1,note: 2:3,4,example"
    ))
    eq(
      { filename = [[C:\vault\note.md]], lnum = 24, col = 8, text = "hello" },
      QFixHelpers.parse_line([[C:\vault\note.md:24:8,3,hello]])
    )
  end)

  it(
    "rejects malformed, non-finite, and non-positive coordinates and ranges",
    function()
      for _, line in ipairs({
        "file.lua:oops:3,1,note",
        "file.lua:1:NaN,1,note",
        "file.lua:1:inf,1,note",
        "file.lua:0:3,1,note",
        "file.lua:1:-3,1,note",
        "file.lua:1.5:3,1,note",
        "file.lua:1:3,0,note",
        "file.lua:1:3,note",
        "file.lua:1:3,1",
        ":1:3,1,note",
        "file.lua:999999999999999999999999:3,1,note",
      }) do
        eq(nil, QFixHelpers.parse_line(line), line)
      end
    end
  )
end)
