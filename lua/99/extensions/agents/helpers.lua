local M = {}
local RULE_BYTES = 100 * 1024
local PREVIEW_BYTES = 4096
local MAX_RULES = 5000

local function contains(root, path)
  local prefix = root:sub(-1) == "/" and root or root .. "/"
  return path:sub(1, #prefix) == prefix
end

local function absolute(path, cwd)
  if path:sub(1, 1) == "~" then
    path = vim.fn.expand(path)
  end
  return vim.fn.isabsolutepath(path) == 1 and path
    or vim.fs.joinpath(cwd or vim.fn.getcwd(), path)
end

--- Discover one level of skills under an explicitly configured directory.
function M.ls(dir, cwd)
  cwd = vim.uv.fs_realpath(cwd or vim.fn.getcwd())
  if not cwd then
    return {}
  end
  local root = vim.uv.fs_realpath(absolute(dir, cwd))
  local stat = root and vim.uv.fs_stat(root)
  if not stat or stat.type ~= "directory" then
    return {}
  end
  local files = {}
  local direct = vim.fs.joinpath(root, "SKILL.md")
  if vim.fn.filereadable(direct) == 1 then
    table.insert(files, direct)
  else
    for name, kind in vim.fs.dir(root) do
      if #files >= MAX_RULES then
        break
      end
      if kind == "directory" or kind == "link" then
        local file = vim.fs.joinpath(root, name, "SKILL.md")
        local real = vim.uv.fs_realpath(file)
        local file_stat = real and vim.uv.fs_stat(real)
        if
          real
          and contains(root, real)
          and file_stat
          and file_stat.type == "file"
        then
          table.insert(files, file)
        end
      end
    end
  end
  table.sort(files)
  local rules = {}
  for _, file in ipairs(files) do
    local real = vim.uv.fs_realpath(file)
    local file_stat = real and vim.uv.fs_stat(real)
    if
      real
      and contains(root, real)
      and file_stat
      and file_stat.type == "file"
    then
      table.insert(rules, {
        name = vim.fs.basename(vim.fs.dirname(file)),
        path = contains(cwd, file) and file:sub(
          #cwd + (cwd:sub(-1) == "/" and 1 or 2)
        ) or file,
        absolute_path = file,
        root = root,
      })
    end
  end
  return rules
end

local function read_bytes(file, root, limit, truncate)
  file = absolute(file)
  root = vim.uv.fs_realpath(root or vim.fs.dirname(file))
  local real = vim.uv.fs_realpath(file)
  if not root or not real or not contains(root, real) then
    return nil
  end
  local stat = vim.uv.fs_stat(real)
  if
    not stat
    or stat.type ~= "file"
    or (not truncate and stat.size > limit)
  then
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
    and opened.dev == stat.dev
    and opened.ino == stat.ino
  then
    data = vim.uv.fs_read(fd, truncate and limit or limit + 1, 0)
  end
  vim.uv.fs_close(fd)
  if data and #data <= limit then
    return data
  end
end

--- Full rules have a fixed byte limit independent of file-completion configuration.
function M.read(file, root)
  return read_bytes(file, root, RULE_BYTES, false)
end

--- Preview reads are bounded by bytes as well as line count.
function M.head(file, count, root)
  local data = read_bytes(file, root, PREVIEW_BYTES, true)
  if not data then
    return ""
  end
  local lines = {}
  for line in data:gmatch("([^\n]*)\n?") do
    if #lines >= (count or 5) then
      break
    end
    table.insert(lines, line)
  end
  return table.concat(lines, "\n")
end

return M
