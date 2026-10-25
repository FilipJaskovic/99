local M = {}

--- @param str string
---@param word_count number
---@return string[]
function M.split_with_count(str, word_count)
  local out = {}
  local words = vim.split(str, "%s+", { trimempty = true })

  local count = math.min(word_count, #words)
  for i = 1, count do
    table.insert(out, words[i])
  end

  return out
end

function M.copy(t)
  assert(type(t) == "table", "passed in non table into table")
  local out = {}
  for k, v in pairs(t) do
    out[k] = v
  end
  for i, v in ipairs(t) do
    out[i] = v
  end
  return out
end

--- @param dir string
--- @return string
function M.random_file(dir)
  local request_dir, err = M.request_directory(dir)
  assert(request_dir, err)
  return vim.fs.joinpath(request_dir, "response")
end

--- Exclusively reserve a private directory inside the configured project temp root.
--- @param dir string
--- @return string?, string?
function M.request_directory(dir)
  vim.fn.mkdir(dir, "p", 448)
  return vim.uv.fs_mkdtemp(vim.fs.joinpath(dir, "99-XXXXXX"))
end

--- Read a regular file without allocating more than limit + 1 bytes.
--- @param path string
--- @param limit number
--- @return string?, string?
function M.read_file_bounded(path, limit)
  local stat, err = vim.uv.fs_lstat(path)
  if not stat or stat.type ~= "file" then
    return nil, err or "expected a regular file: " .. path
  end
  if stat.size > limit then
    return nil, "file exceeds byte limit: " .. path
  end
  local fd
  fd, err = vim.uv.fs_open(path, "r", 0)
  if not fd then
    return nil, err
  end
  local content
  content, err = vim.uv.fs_read(fd, limit + 1, 0)
  vim.uv.fs_close(fd)
  if content and #content > limit then
    return nil, "file exceeds byte limit: " .. path
  end
  return content, err
end

--- @param dir string
--- @param name string
--- @return string
function M.named_tmp_file(dir, name)
  return string.format("%s/99-%s", dir, name)
end

--- @param path string
--- @return table | nil
function M.read_file_json_safe(path)
  local ok, fh = pcall(io.open, path, "r")
  if ok and fh then
    local ok2, content = pcall(fh.read, fh, "*a")
    pcall(fh.close, fh)
    if not ok2 then
      return nil
    end
    local ok3, obj = pcall(vim.json.decode, content)
    if ok3 and obj then
      return obj
    end
  end
end

--- Atomically replace a file only after its private temporary file is closed.
--- @param path string
--- @param contents string
--- @return boolean, string?
function M.write_file_atomic(path, contents)
  local made_dir, err = pcall(vim.fn.mkdir, vim.fs.dirname(path), "p", 448)
  if not made_dir then
    return false, tostring(err)
  end
  local fd, tmp = vim.uv.fs_mkstemp(path .. ".XXXXXX")
  if not fd then
    return false, tmp
  end
  local written, write_err = vim.uv.fs_write(fd, contents, 0)
  local closed, close_err = vim.uv.fs_close(fd)
  if written ~= #contents or not closed then
    vim.uv.fs_unlink(tmp)
    return false, write_err or close_err or "incomplete file write"
  end
  local renamed, rename_err = vim.uv.fs_rename(tmp, path)
  if not renamed then
    vim.uv.fs_unlink(tmp)
    return false, rename_err
  end
  return true
end

--- @param obj table
--- @param path string
--- @return boolean, string?
function M.write_file_json_safe(obj, path)
  local ok, obj_str = pcall(vim.json.encode, obj)
  if not ok then
    return false, tostring(obj_str)
  end
  return M.write_file_atomic(path, obj_str)
end

return M
