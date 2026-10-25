local M = {}

--- @return _99.Search.Result | nil
function M.parse_line(line)
  -- Stop at the first coordinate suffix so location-like text in notes stays intact.
  local filepath, lnum_raw, col_raw, count_raw, notes =
    line:match("^(.-):(%d+):(%d+),(%d+),(.*)$")
  if not filepath or filepath == "" then
    return nil
  end

  local lnum, col, count =
    tonumber(lnum_raw), tonumber(col_raw), tonumber(count_raw)
  local max_coordinate = 2147483647
  if
    not lnum
    or not col
    or not count
    or lnum < 1
    or col < 1
    or count < 1
    or lnum > max_coordinate
    or col > max_coordinate
    or count > max_coordinate
  then
    return nil
  end

  return {
    filename = filepath,
    lnum = lnum,
    col = col,
    text = notes or "",
  }
end

--- @param response string
--- @return _99.Search.Result[]
function M.create_qfix_entries(response)
  local lines = vim.split(response, "\n")
  local qf_list = {} --[[ @as _99.Search.Result[] ]]

  for _, line in ipairs(lines) do
    local res = M.parse_line(line)
    if res then
      table.insert(qf_list, res)
    end
  end
  return qf_list
end

return M
