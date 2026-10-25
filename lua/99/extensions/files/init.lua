local Completions = require("99.extensions.completions")
local M = {}

--- @class _99.Files.Config
--- @field enabled boolean?
--- @field max_file_size number?
--- @field max_files number?
--- @field exclude string[]?

--- @class _99.Files.File
--- @field path string Relative path from project root
--- @field name string
--- @field absolute_path string

local defaults = {
  enabled = true,
  max_file_size = 100 * 1024,
  max_files = 5000,
  exclude = {
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
  },
}
local config = vim.deepcopy(defaults)
local rule_dirs = {}
local project_root = ""
local cache = { root = "", files = nil }

local function canonical_root(root)
  if not root or root == "" then
    return ""
  end
  local real = vim.uv.fs_realpath(root)
  local stat = real and vim.uv.fs_stat(real)
  return stat and stat.type == "directory" and real or ""
end

--- Find the discovery root for a captured request cwd.
function M.project_root(cwd)
  if not cwd or cwd == "" then
    return ""
  end
  return canonical_root(vim.fs.root(cwd, ".git") or cwd)
end

local function relative_path(path, root)
  local prefix = root:sub(-1) == "/" and root or root .. "/"
  if path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end
end

-- Match whole path components. Only * and ? are glob operators.
local function compile_exclusions(patterns)
  local compiled = {}
  for _, pattern in ipairs(patterns) do
    pattern = pattern:gsub("^%./", ""):gsub("/+$", "")
    if pattern ~= "" then
      local glob = Completions.escape_pattern(pattern)
        :gsub("%%%*", "[^/]*")
        :gsub("%%%?", "[^/]")
      table.insert(compiled, "/" .. glob .. "/")
    end
  end
  return compiled
end
local exclude_patterns = compile_exclusions(config.exclude)

local function matches_exclude(path, root)
  for _, pattern in ipairs(exclude_patterns) do
    if ("/" .. path .. "/"):find(pattern) then
      return true
    end
  end
  for _, dir in ipairs(rule_dirs) do
    local relative = dir
    if vim.fn.isabsolutepath(dir) == 1 then
      relative = relative_path(dir, root)
    end
    if
      relative and ("/" .. path .. "/"):find("/" .. relative .. "/", 1, true)
    then
      return true
    end
  end
  return false
end

local function checked_path(path, root)
  if
    not config.enabled
    or root == ""
    or path == ""
    or path:find("\0", 1, true)
  then
    return nil
  end
  if vim.fn.isabsolutepath(path) == 1 then
    return nil
  end
  for component in path:gmatch("[^/]+") do
    if component == ".." or component == "." then
      return nil
    end
  end
  if matches_exclude(path, root) then
    return nil
  end
  local real = vim.uv.fs_realpath(vim.fs.joinpath(root, path))
  local relative = real and relative_path(real, root)
  if not relative or matches_exclude(relative, root) then
    return nil
  end
  local stat = vim.uv.fs_stat(real)
  if not stat or stat.type ~= "file" or stat.size > config.max_file_size then
    return nil
  end
  return real, stat
end

--- Explicit roots do not change the default project used by completion.
function M.set_project_root(root)
  project_root = canonical_root(root)
  cache.files = nil
end

function M.get_project_root()
  return project_root
end

local function scan(root)
  local files = {}
  local seen = {}
  local function add(path)
    if #files >= config.max_files or seen[path] then
      return
    end
    local real = checked_path(path, root)
    if real then
      seen[path] = true
      table.insert(files, {
        path = path,
        name = vim.fs.basename(path),
        absolute_path = vim.fs.joinpath(root, path),
      })
    end
  end

  if vim.uv.fs_stat(vim.fs.joinpath(root, ".git")) then
    local result = vim
      .system({
        "git",
        "-C",
        root,
        "ls-files",
        "-z",
        "--cached",
        "--others",
        "--exclude-standard",
        "--deduplicate",
      }, { text = false })
      :wait(10000)
    -- Git failures must not expose ignored files through a filesystem fallback.
    if result.code ~= 0 then
      return files
    end
    local paths =
      vim.split(result.stdout or "", "\0", { plain = true, trimempty = true })
    table.sort(paths)
    for _, path in ipairs(paths) do
      if #files >= config.max_files then
        break
      end
      add(path)
    end
  else
    local function scan_dir(dir)
      if #files >= config.max_files then
        return
      end
      local handle = vim.uv.fs_scandir(dir)
      if not handle then
        return
      end
      while #files < config.max_files do
        local name, kind = vim.uv.fs_scandir_next(handle)
        if not name then
          break
        end
        local full = vim.fs.joinpath(dir, name)
        local relative = relative_path(full, root)
        if relative and not matches_exclude(relative, root) then
          if kind == "directory" then
            scan_dir(full)
          elseif kind == "file" or kind == "link" then
            add(relative)
          end
        end
      end
    end
    scan_dir(root)
  end
  table.sort(files, function(a, b)
    return a.path < b.path
  end)
  return files
end

function M.discover_files(root)
  root = root and canonical_root(root) or project_root
  local files = {}
  if config.enabled and root ~= "" and config.max_files > 0 then
    files = scan(root)
  end
  cache = { root = root, files = files }
  return files
end

function M.get_files(root)
  root = root and canonical_root(root) or project_root
  if not config.enabled then
    return {}
  end
  if cache.root ~= root or not cache.files then
    return M.discover_files(root)
  end
  return cache.files
end

function M.find_matches(query)
  local files = M.get_files()
  if not query or query == "" then
    return files
  end
  query = query:lower()
  local matches = {}
  for _, file in ipairs(files) do
    local searchable = (file.name .. " " .. file.path):lower()
    local pos = 1
    local matched = true
    for i = 1, #query do
      local found = searchable:find(query:sub(i, i), pos, true)
      if not found then
        matched = false
        break
      end
      pos = found + 1
    end
    if matched then
      table.insert(matches, file)
    end
  end
  return matches
end

--- Read only regular, bounded files whose current real path is allowed.
function M.read_file(path, root)
  root = root and canonical_root(root) or project_root
  local real, stat = checked_path(path, root)
  if not real then
    return nil
  end
  local fd = vim.uv.fs_open(real, "r", 438)
  if not fd then
    return nil
  end
  local opened = vim.uv.fs_fstat(fd)
  local data
  if
    opened
    and opened.type == "file"
    and opened.size <= config.max_file_size
    and opened.dev == stat.dev
    and opened.ino == stat.ino
  then
    data = vim.uv.fs_read(fd, config.max_file_size + 1, 0)
  end
  vim.uv.fs_close(fd)
  if data and #data <= config.max_file_size then
    return data
  end
end

function M.get_project_file(path, root)
  root = root and canonical_root(root) or project_root
  local files = M.get_files(root)
  for _, file in ipairs(files) do
    if file.path == path then
      return checked_path(file.path, root) and file or nil
    end
  end
  local match
  for _, file in ipairs(files) do
    if file.name == path and checked_path(file.path, root) then
      if match then
        return nil
      end
      match = file
    end
  end
  return match
end

function M.is_project_file(path, root)
  return M.get_project_file(path, root) ~= nil
end

function M.setup(opts, dirs)
  opts = opts or {}
  config = vim.deepcopy(defaults)
  config.enabled = opts.enabled ~= false
  config.max_file_size = opts.max_file_size or config.max_file_size
  config.max_files = opts.max_files or config.max_files
  config.exclude = vim.deepcopy(opts.exclude or config.exclude)
  exclude_patterns = compile_exclusions(config.exclude)
  rule_dirs = {}
  for _, dir in ipairs(dirs or {}) do
    dir = dir:sub(1, 1) == "~" and vim.fn.expand(dir) or dir
    table.insert(rule_dirs, (dir:gsub("^%./", ""):gsub("/+$", "")))
  end
  cache.files = nil
end

function M.completion_provider()
  return {
    trigger = "@",
    name = "files",
    get_items = function()
      local items = {}
      for _, file in ipairs(M.get_files()) do
        table.insert(items, {
          label = file.name,
          insertText = Completions.format_reference("@", file.path),
          filterText = "@" .. file.name .. " " .. file.path,
          kind = 17,
          documentation = {
            kind = "markdown",
            value = "File: `" .. file.path .. "`",
          },
          detail = file.path,
        })
      end
      return items
    end,
    is_valid = function(token, cwd)
      return M.is_project_file(token, cwd and M.project_root(cwd))
    end,
    resolve = function(token, cwd)
      local root = cwd and M.project_root(cwd) or project_root
      local file = M.get_project_file(token, root)
      if not file then
        return nil
      end
      local content = M.read_file(file.path, root)
      if not content then
        return nil
      end
      local ext = file.path:match("%.([%w]+)$") or ""
      return string.format("```%s\n-- %s\n%s\n```", ext, file.path, content)
    end,
  }
end

return M
