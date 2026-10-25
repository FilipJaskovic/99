--- A provider for completion tokens (#rules, @files) used in the prompt.
--- @class _99.CompletionProvider
--- @field trigger string
--- @field name string
--- @field get_items fun(): CompletionItem[]
--- @field is_valid fun(token: string, cwd?: string, rules?: _99.Agents.Rules): boolean
--- @field resolve fun(token: string, cwd?: string, rules?: _99.Agents.Rules): string|nil

--- @class _99.Reference
--- @field content string

--- @type _99.CompletionProvider[]
local providers = {}

local M = {}

--- Escape special Lua pattern characters in a string
--- @param str string The string to escape
--- @return string The escaped string safe for use in Lua patterns
function M.escape_pattern(str)
  return str:gsub("([%%%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
end

--- @param provider _99.CompletionProvider
function M.register(provider)
  for i, p in ipairs(providers) do
    if p.trigger == provider.trigger then
      providers[i] = provider
      return
    end
  end
  table.insert(providers, provider)
end

--- @return string[]
function M.get_trigger_characters()
  local chars = {}
  for _, p in ipairs(providers) do
    table.insert(chars, p.trigger)
  end
  return chars
end

--- @return string
function M.get_keyword_pattern()
  local triggers = {}
  for _, p in ipairs(providers) do
    table.insert(triggers, p.trigger)
  end
  return "[" .. table.concat(triggers) .. "]\\k*"
end

--- Quote references only when their path needs escaping. Parsing uses the same JSON syntax.
function M.format_reference(trigger, token)
  if token:find('[%s"\\]') then
    return trigger .. vim.json.encode(token)
  end
  return trigger .. token
end

local function scan_references(text)
  local triggers = {}
  for _, provider in ipairs(providers) do
    triggers[provider.trigger] = true
  end
  local refs = {}
  local pos = 1
  while pos <= #text do
    local trigger = text:sub(pos, pos)
    if
      triggers[trigger] and (pos == 1 or text:sub(pos - 1, pos - 1):match("%s"))
    then
      local start = pos
      pos = pos + 1
      local token
      local closed = false
      if text:sub(pos, pos) == '"' then
        local first = pos
        pos = pos + 1
        while pos <= #text do
          local char = text:sub(pos, pos)
          if char == "\\" then
            pos = pos + 2
          elseif char == '"' then
            local ok, decoded = pcall(vim.json.decode, text:sub(first, pos))
            closed = true
            pos = pos + 1
            if
              ok
              and type(decoded) == "string"
              and (pos > #text or text:sub(pos, pos):match("%s"))
            then
              token = decoded
            end
            break
          else
            pos = pos + 1
          end
        end
      else
        local first = pos
        while pos <= #text and not text:sub(pos, pos):match("%s") do
          pos = pos + 1
        end
        token = text:sub(first, pos - 1)
      end
      table.insert(refs, {
        trigger = trigger,
        token = token,
        start = start,
        finish = pos - 1,
        closed = closed,
      })
    else
      pos = pos + 1
    end
  end
  return refs
end

--- Return the active trigger and its 1-based byte column, including unfinished quotes.
function M.find_active_reference(before)
  local refs = scan_references(before)
  local ref = refs[#refs]
  if ref and ref.finish >= #before and not ref.closed then
    return ref.trigger, ref.start
  end
  return nil
end

--- Explicit cwd and rule snapshots keep pending prompts independent of later refreshes.
--- @param prompt_text string
--- @param cwd? string
--- @param rules? _99.Agents.Rules
--- @return _99.Reference[]
function M.parse(prompt_text, cwd, rules)
  local refs = {}
  local seen = {}
  for _, ref in ipairs(scan_references(prompt_text)) do
    if ref.token and ref.token ~= "" then
      local key = ref.trigger .. ref.token
      if not seen[key] then
        seen[key] = true
        for _, provider in ipairs(providers) do
          if
            provider.trigger == ref.trigger
            and provider.is_valid(ref.token, cwd, rules)
          then
            local content = provider.resolve(ref.token, cwd, rules)
            if content then
              table.insert(refs, { content = content })
            end
            break
          end
        end
      end
    end
  end
  return refs
end

--- @param trigger_char string
--- @return CompletionItem[]
function M.get_completions(trigger_char)
  for _, provider in ipairs(providers) do
    if provider.trigger == trigger_char then
      return provider.get_items()
    end
  end
  return {}
end

function M._reset()
  providers = {}
end

return M
