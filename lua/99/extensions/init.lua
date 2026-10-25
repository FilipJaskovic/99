local Files = require("99.extensions.files")
local Agents = require("99.extensions.agents")
local Completions = require("99.extensions.completions")

--- @class _99.Extensions.Source
--- @field init_for_buffer fun(_99: _99.State): nil
--- @field init? fun(_99: _99.State): nil
--- @field refresh_state? fun(_99: _99.State): nil

--- @param completion _99.Completion | nil
--- @return _99.Extensions.Source | nil
local function get_source(completion)
  local source = completion and completion.source or "native"

  if source == "native" then
    local ok, native = pcall(require, "99.extensions.native")
    if not ok then
      vim.notify("[99] Failed to load native completions", vim.log.levels.ERROR)
      return
    end
    return native
  end

  if source == "cmp" then
    local ok, cmp = pcall(require, "99.extensions.cmp")
    if not ok then
      vim.notify(
        '[99] nvim-cmp is not installed. Install hrsh7th/nvim-cmp or use source = "blink" or "native"',
        vim.log.levels.WARN
      )
      return
    end
    return cmp
  end
  if source == "blink" then
    local ok, _ = pcall(require, "blink.compat")
    if not ok then
      vim.notify(
        "[99] blink.compat is required for blink source. Install: { 'saghen/blink.compat', version = '2.*' }",
        vim.log.levels.ERROR
      )
      return
    end
    local cmp_ok, cmp = pcall(require, "99.extensions.cmp")
    if not cmp_ok then
      vim.notify(
        "[99] 99 completion module failed to load",
        vim.log.levels.ERROR
      )
      return
    end
    return cmp
  end
end

local function capture_project_root(cwd)
  Files.set_project_root(Files.project_root(cwd or vim.fn.getcwd()))
end

local function register_providers(_99)
  Completions.register(Agents.completion_provider(_99))
  Completions.register(Files.completion_provider())
end

return {
  --- @param _99 _99.State
  init = function(_99)
    -- Reference policy applies even when the optional completion UI cannot load.
    local completion = _99.completion or {}
    Files.setup(completion.files or {}, completion.custom_rules or {})
    register_providers(_99)
    local source = get_source(_99.completion)
    if source and source.init then
      source.init(_99)
    end
  end,

  capture_project_root = capture_project_root,

  --- @param _99 _99.State
  setup_buffer = function(_99)
    local source = get_source(_99.completion)
    if not source then
      return
    end
    source.init_for_buffer(_99)
  end,

  --- @param _99 _99.State
  refresh = function(_99, root)
    capture_project_root(root)
    register_providers(_99)
    local source = get_source(_99.completion)
    if source and source.refresh_state then
      source.refresh_state(_99)
    end
  end,
}
