-- luacheck: globals describe it assert before_each after_each
local api = require("99")
local Pickers = require("99.extensions.pickers")
local eq = assert.are.same

describe("model picker provider identity", function()
  local saved, current, model, pending, notices
  local provider_a, provider_b
  local original_modules = {}
  local module_names = {
    "fzf-lua",
    "telescope.pickers",
    "telescope.finders",
    "telescope.config",
    "telescope.actions",
    "telescope.actions.state",
  }

  before_each(function()
    saved = {
      get_provider = api.get_provider,
      get_model = api.get_model,
      set_model = api.set_model,
      notify = vim.notify,
    }
    for _, name in ipairs(module_names) do
      original_modules[name] = package.loaded[name]
    end
    notices = {}
    provider_a = {
      fetch_models = function(callback)
        pending = callback
      end,
    }
    provider_b = {}
    current, model = provider_a, "model-a"
    api.get_provider = function()
      return current
    end
    api.get_model = function()
      return model
    end
    api.set_model = function(value)
      model = value
    end
    vim.notify = function(message)
      table.insert(notices, message)
    end
  end)

  after_each(function()
    api.get_provider = saved.get_provider
    api.get_model = saved.get_model
    api.set_model = saved.set_model
    vim.notify = saved.notify
    for _, name in ipairs(module_names) do
      package.loaded[name] = original_modules[name]
    end
  end)

  it("includes the exported Codex provider in the provider catalog", function()
    local info = Pickers.get_providers()
    assert(api.Providers.CodexProvider)
    eq(api.Providers.CodexProvider, info.lookup.CodexProvider)
  end)

  it("discards model results fetched for a previous provider", function()
    local shown = false
    Pickers.get_models(nil, function()
      shown = true
    end)
    current = provider_b
    pending({ "model-a" }, nil)
    eq(false, shown)
  end)

  it(
    "requires an explicit provider to be selected before listing its models",
    function()
      Pickers.get_models(provider_b, function()
        error("must not show another provider's models")
      end)
      eq(1, #notices)
      eq(provider_a, current)
    end
  )

  it("rejects a stale fzf selection and accepts a current one", function()
    local selection
    package.loaded["fzf-lua"] = {
      fzf_exec = function(_, opts)
        selection = opts.actions.enter
      end,
    }
    require("99.extensions.fzf_lua").select_model()
    pending({ "new-a" }, nil)
    selection({ "new-a" })
    eq("new-a", model)
    current, model = provider_b, "model-b"
    selection({ "new-a" })
    eq("model-b", model)
  end)

  it("rejects a stale telescope selection", function()
    local selection
    package.loaded["telescope.pickers"] = {
      new = function(_, opts)
        return {
          find = function()
            opts.attach_mappings(1)
          end,
        }
      end,
    }
    package.loaded["telescope.finders"] = {
      new_table = function(opts)
        return opts
      end,
    }
    package.loaded["telescope.config"] = {
      values = { generic_sorter = function() end },
    }
    package.loaded["telescope.actions"] = {
      close = function() end,
      select_default = {
        replace = function(_, callback)
          selection = callback
        end,
      },
    }
    package.loaded["telescope.actions.state"] = {
      get_selected_entry = function()
        return { "new-a" }
      end,
    }
    require("99.extensions.telescope").select_model()
    pending({ "new-a" }, nil)
    current, model = provider_b, "model-b"
    selection()
    eq("model-b", model)
  end)
end)
