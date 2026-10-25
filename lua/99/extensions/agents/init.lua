local helpers = require("99.extensions.agents.helpers")
local Completions = require("99.extensions.completions")
local M = {}

--- @class _99.Agents.Rule
--- @docs included
--- @field name string
--- @field path string
--- @field absolute_path string?
--- @field root string? Configured directory used to confine reads

--- @class _99.Agents.Rules
--- @field custom _99.Agents.Rule[]
--- @field by_name table<string, _99.Agents.Rule[]>

--- @class _99.Agents.Agent
--- @field rules _99.Agents.Rules

--- @param map table<string, _99.Agents.Rule[]>
--- @param rules _99.Agents.Rule[]
local function add_rule_by_name(map, rules)
  for _, r in ipairs(rules) do
    if map[r.name] == nil then
      map[r.name] = {}
    end
    table.insert(map[r.name], r)
  end
end

--- @param _99 _99.State
--- @return _99.Agents.Rules
function M.rules(_99, cwd)
  local custom = {}
  for _, path in ipairs(_99.completion.custom_rules or {}) do
    local custom_rules = helpers.ls(path, cwd)
    for _, r in ipairs(custom_rules) do
      table.insert(custom, r)
    end
  end

  local by_name = {}
  add_rule_by_name(by_name, custom)
  return {
    by_name = by_name,
    custom = custom,
  }
end

--- @param rules _99.Agents.Rules
--- @return _99.Agents.Rule[]
function M.rules_to_items(rules)
  local items = {}
  for _, rule in ipairs(rules.custom or {}) do
    table.insert(items, rule)
  end
  return items
end

--- @param rules _99.Agents.Rules
--- @param path string
--- @return _99.Agents.Rule | nil
function M.get_rule_by_path(rules, path)
  for _, rule in ipairs(rules.custom or {}) do
    if rule.path == path then
      return rule
    end
  end
  local match
  for _, rule in ipairs(rules.custom or {}) do
    if rule.name == path then
      if match then
        return nil
      end
      match = rule
    end
  end
  return match
end

--- Bare names are accepted only when they identify a single rule.
function M.is_rule(rules, token)
  return M.get_rule_by_path(rules, token) ~= nil
end

--- @param rules _99.Agents.Rules
--- @param prompt string
--- @return {names: string[], rules: _99.Agents.Rules[]}
function M.by_name(rules, prompt)
  --- @type table<string, boolean>
  local found = {}

  --- @type string[]
  local names = {}

  --- @type _99.Agents.Rule[]
  local out_rules = {}
  for word in prompt:gmatch("%S+") do
    if word:sub(1, 1) == "#" then
      local w = word:sub(2)
      local rules_by_name = rules.by_name[w]
      if rules_by_name and found[w] == nil then
        for _, r in ipairs(rules_by_name) do
          table.insert(out_rules, r)
        end
        table.insert(names, w)
        found[w] = true
      end
    end
  end

  return {
    names = names,
    rules = out_rules,
  }
end

--- @param rule _99.Agents.Rule
--- @return string | nil
function M.get_rule_content(rule, cwd)
  local file_path = rule.absolute_path or rule.path
  if cwd and vim.fn.isabsolutepath(file_path) == 0 then
    file_path = vim.fs.joinpath(cwd, file_path)
  end
  local content = helpers.read(file_path, rule.root)
  if not content then
    return nil
  end
  return string.format("<%s>\n%s\n</%s>", rule.name, content, rule.name)
end

--- @param _99 _99.State
--- @return _99.CompletionProvider
function M.completion_provider(_99)
  return {
    trigger = "#",
    name = "rules",
    get_items = function()
      local agent_rules = M.rules_to_items(_99.rules)
      local items = {}
      for _, rule in ipairs(agent_rules) do
        local docs =
          helpers.head(rule.absolute_path or rule.path, nil, rule.root)
        table.insert(items, {
          label = rule.name,
          insertText = Completions.format_reference("#", rule.path),
          filterText = "#" .. rule.name,
          kind = 12, -- LSP CompletionItemKind.Value
          documentation = { kind = "markdown", value = docs },
          detail = "Rule: " .. rule.path,
        })
      end
      return items
    end,
    is_valid = function(token, _, rules)
      return M.is_rule(rules or _99.rules, token)
    end,
    resolve = function(token, cwd, rules)
      local rule = M.get_rule_by_path(rules or _99.rules, token)
      if not rule then
        return nil
      end
      return M.get_rule_content(rule, cwd)
    end,
  }
end

return M
