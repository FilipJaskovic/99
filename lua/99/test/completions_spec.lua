-- luacheck: globals describe it assert before_each
---@diagnostic disable: undefined-field, missing-fields
local Completions = require("99.extensions.completions")
local eq = assert.are.same

local function mock_provider(trigger, name, valid_tokens)
  return {
    trigger = trigger,
    name = name,
    get_items = function()
      local items = {}
      for token, _ in pairs(valid_tokens) do
        table.insert(items, {
          label = token,
          insertText = trigger .. token,
          filterText = trigger .. token,
          kind = 1,
        })
      end
      return items
    end,
    is_valid = function(token)
      return valid_tokens[token] ~= nil
    end,
    resolve = function(token)
      return valid_tokens[token]
    end,
  }
end

describe("completions", function()
  before_each(function()
    Completions._reset()
  end)

  it("register and get_trigger_characters", function()
    Completions.register(mock_provider("#", "rules", {}))
    Completions.register(mock_provider("@", "files", {}))
    eq({ "#", "@" }, Completions.get_trigger_characters())
  end)

  it("register replaces provider with same trigger", function()
    Completions.register(
      mock_provider("#", "rules-v1", { old = "old-content" })
    )
    Completions.register(
      mock_provider("#", "rules-v2", { new = "new-content" })
    )

    local triggers = Completions.get_trigger_characters()
    eq({ "#" }, triggers)

    local refs = Completions.parse("use #new in prompt")
    eq(1, #refs)
    eq("new-content", refs[1].content)

    local old_refs = Completions.parse("use #old in prompt")
    eq(0, #old_refs)
  end)

  it("get_keyword_pattern builds pattern from triggers", function()
    Completions.register(mock_provider("#", "rules", {}))
    Completions.register(mock_provider("@", "files", {}))
    eq("[#@]\\k*", Completions.get_keyword_pattern())
  end)

  it("get_completions returns items for known trigger", function()
    Completions.register(mock_provider("#", "rules", { debug = "content" }))
    local items = Completions.get_completions("#")
    eq(1, #items)
    eq("debug", items[1].label)
    eq("#debug", items[1].insertText)
  end)

  it("get_completions returns empty for unknown trigger", function()
    Completions.register(mock_provider("#", "rules", {}))
    eq({}, Completions.get_completions("@"))
  end)

  it("parse extracts valid tokens and resolves content", function()
    Completions.register(mock_provider("#", "rules", {
      ["debug.md"] = "<debug>content</debug>",
    }))
    Completions.register(mock_provider("@", "files", {
      ["utils.lua"] = "```lua\ncode\n```",
    }))

    local refs = Completions.parse("add logging #debug.md and read @utils.lua")
    eq(2, #refs)
    eq("<debug>content</debug>", refs[1].content)
    eq("```lua\ncode\n```", refs[2].content)
  end)

  it("parse skips invalid tokens", function()
    Completions.register(mock_provider("#", "rules", {
      ["valid.md"] = "resolved",
    }))

    local refs = Completions.parse("#valid.md #nonexistent")
    eq(1, #refs)
    eq("resolved", refs[1].content)
  end)

  it("parse returns empty for no tokens", function()
    Completions.register(mock_provider("#", "rules", { a = "b" }))
    eq({}, Completions.parse("just a plain prompt"))
  end)

  it(
    "round-trips quoted paths and rejects malformed quoted references",
    function()
      local name = 'folder/My "Note"\\file.md'
      Completions.register(mock_provider("@", "files", { [name] = "CONTENTS" }))
      local inserted = Completions.format_reference("@", name)
      eq('@"', inserted:sub(1, 2))
      eq({ { content = "CONTENTS" } }, Completions.parse(inserted))
      eq({}, Completions.parse('@"unterminated'))
      eq({}, Completions.parse('@"bad\\q"'))
      eq({}, Completions.parse(inserted .. "suffix"))
    end
  )

  it(
    "finds active ordinary and quoted references for native completion",
    function()
      Completions.register(mock_provider("@", "files", {}))
      Completions.register(mock_provider("#", "rules", {}))
      local trigger, col = Completions.find_active_reference('use @"My Note')
      eq("@", trigger)
      eq(5, col)
      trigger, col = Completions.find_active_reference("use #")
      eq("#", trigger)
      eq(5, col)
      eq(nil, Completions.find_active_reference('@"My Note"'))
      eq(nil, Completions.find_active_reference("use @file "))
      eq(nil, Completions.find_active_reference("name@example.com"))
    end
  )

  it(
    "includes repeated references once and preserves their order in the prompt",
    function()
      Completions.register(mock_provider("#", "rules", { rule = "RULE" }))
      Completions.register(mock_provider("@", "files", { file = "FILE" }))
      eq(
        { { content = "FILE" }, { content = "RULE" } },
        Completions.parse("@file #rule @file #rule")
      )
      eq({}, Completions.parse("name@file"))
    end
  )

  it("real providers register and resolve through the registry", function()
    local Agents = require("99.extensions.agents")
    local Files = require("99.extensions.files")

    -- Set up files module
    local default_exclude = {
      ".env",
      ".env.*",
      "node_modules",
      ".git",
      "dist",
      "build",
      "*.log",
      ".DS_Store",
      "tmp",
      ".cursor",
    }
    Files.setup({ enabled = true, exclude = default_exclude }, {})
    Files.set_project_root(vim.uv.cwd() or "")
    Files.discover_files()

    -- Build a minimal state
    local state = {
      rules = Agents.rules({
        completion = {
          cursor_rules = "scratch/cursor/rules/",
          custom_rules = {},
        },
      }),
    }

    -- Register real providers through the registry
    Completions.register(Agents.completion_provider(state))
    Completions.register(Files.completion_provider())

    -- Verify triggers registered
    local triggers = Completions.get_trigger_characters()
    eq(2, #triggers)

    -- Parse a prompt with a real @file reference
    local refs = Completions.parse("check @scratch/refresh.lua")
    assert.is_true(#refs > 0, "expected at least one resolved reference")

    -- Verify resolved content is a real code fence with non-empty body
    assert.is_true(
      refs[1].content:sub(1, 6) == "```lua",
      "expected code fence from real file provider"
    )
    assert.is_true(#refs[1].content > 20, "expected non-trivial file content")

    -- Clean up
    Files.set_project_root("")
  end)
end)
