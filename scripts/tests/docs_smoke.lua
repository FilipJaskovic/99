-- Evaluate the lazy.nvim example without configuring 99 or starting providers.
local function check_setup(path, api)
  local markdown = table.concat(vim.fn.readfile(path), "\n")
  local snippet = markdown:match("### Basic [Ss]etup.-```lua\n(.-)\n```")
  assert(snippet, path .. ": missing basic setup example")

  local setup_calls = 0
  package.loaded["99"] = setmetatable({
    Providers = setmetatable({}, {
      __index = function(_, name)
        return assert(
          api.Providers[name],
          path .. ": unknown provider " .. name
        )
      end,
    }),
    setup = function(opts)
      assert(type(opts) == "table", "setup options must be a table")
      setup_calls = setup_calls + 1
    end,
  }, { __index = api })

  local chunk, err = loadstring("return {\n" .. snippet .. "\n}", "@" .. path)
  assert(chunk, err)
  local specs = chunk()
  for _, spec in ipairs(specs) do
    if type(spec.config) == "function" then
      spec.config()
    end
  end
  assert(setup_calls == 1, path .. ": basic setup must call _99.setup once")
  print("[docs] " .. path .. " setup runs with a stub _99.setup")
end

local ok, err = pcall(function()
  vim.opt.runtimepath:prepend(".")
  vim.system = function()
    error("docs smoke check must not start external processes")
  end
  local api = require("99")
  local paths = #arg > 0 and arg or { "README.md", "docs/README.md" }
  for _, path in ipairs(paths) do
    check_setup(path, api)
  end
end)

if not ok then
  vim.api.nvim_err_writeln(tostring(err))
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
