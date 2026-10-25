local geo = require("99.geo")
local Point = geo.Point
local Range = geo.Range
local nsid = vim.api.nvim_create_namespace("99.marks")

--- @class _99.Mark.Text
--- @field text string
--- @field hlgroup string

--- @class _99.Mark
--- @field id any -- whatever extmark returns
--- @field buffer number
--- @field nsid any
local Mark = {}
Mark.__index = Mark

--- @param range _99.Range
--- @return _99.Mark
function Mark.mark_above_range(range)
  local buffer = range.buffer
  local start = range.start
  local line, _ = start:to_vim()
  local above = line == 0 and line or line - 1

  -- luacheck: ignore
  local id = nil
  if above == line then
    id = vim.api.nvim_buf_set_extmark(buffer, nsid, above, 0, {})
  else
    local text = vim.api.nvim_buf_get_lines(buffer, above, above + 1, false)[1]
    local ending = #text
    id = vim.api.nvim_buf_set_extmark(buffer, nsid, above, ending, {})
  end

  return setmetatable({
    id = id,
    buffer = buffer,
    nsid = nsid,
  }, Mark)
end

--- @param range _99.Range
--- @return _99.Mark
--- @return _99.Mark
function Mark.mark_range(range)
  local buffer = range.buffer
  return Mark.mark_point(buffer, range.start),
    Mark.mark_point(buffer, range.end_)
end

--- @return boolean
function Mark:is_valid()
  if
    not vim.api.nvim_buf_is_valid(self.buffer)
    or not vim.api.nvim_buf_is_loaded(self.buffer)
  then
    return false
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(
    self.buffer,
    self.nsid,
    self.id,
    { details = true }
  )
  return #pos > 0 and not pos[3].invalid
end

--- @param buffer number
--- @param point _99.Point
--- @return _99.Mark
function Mark.mark_point(buffer, point)
  local line, col = point:to_vim()
  local id = vim.api.nvim_buf_set_extmark(buffer, nsid, line, col, {})

  return setmetatable({
    id = id,
    buffer = buffer,
    nsid = nsid,
  }, Mark)
end

--- @param buffer number
--- @param func _99.treesitter.Function
--- @return _99.Mark
function Mark.mark_above_func(buffer, func)
  local start = func.function_range.start
  local line, col = start:to_vim()

  line = line - 1
  if line < 0 then
    col = 0
    line = 0
  end

  local id = vim.api.nvim_buf_set_extmark(buffer, nsid, line, col, {})

  return setmetatable({
    id = id,
    buffer = buffer,
    nsid = nsid,
  }, Mark)
end

---@param buffer number
---@param range _99.Range
---@return _99.Mark
function Mark.mark_end_of_range(buffer, range)
  local end_ = range.end_
  local line, col = end_:to_vim()
  local id = vim.api.nvim_buf_set_extmark(buffer, nsid, line, col + 1, {})

  return setmetatable({
    id = id,
    buffer = buffer,
    nsid = nsid,
  }, Mark)
end

--- @param buffer number
--- @param func _99.treesitter.Function
--- @return _99.Mark
function Mark.mark_func_body(buffer, func)
  local start = func.function_range.start
  local line, col = start:to_vim()
  local id = vim.api.nvim_buf_set_extmark(buffer, nsid, line, col, {})

  return setmetatable({
    id = id,
    buffer = buffer,
    nsid = nsid,
  }, Mark)
end

--- @param lines string[]
function Mark:set_virtual_text(lines)
  if not self:is_valid() then
    return
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(self.buffer, nsid, self.id, {})
  local row, col = pos[1], pos[2]

  local formatted_lines = {}
  for _, line in ipairs(lines) do
    table.insert(formatted_lines, {
      { line, "Comment" },
    })
  end

  vim.api.nvim_buf_set_extmark(self.buffer, nsid, row, col, {
    id = self.id,
    virt_lines = formatted_lines,
  })
end

--- @param text string
function Mark:set_text_at_mark(text)
  local point = Point.from_mark(self)
  local row, col = point:to_vim()
  local lines = vim.split(text, "\n")
  vim.api.nvim_buf_set_text(self.buffer, row, col, row, col, lines)
end

function Mark:delete()
  if vim.api.nvim_buf_is_valid(self.buffer) then
    vim.api.nvim_buf_del_extmark(self.buffer, nsid, self.id)
  end
end

--- @class _99.VisualSnapshot
--- @field range _99.Range
--- @field text string
--- @field changedtick number
--- @field start_mark _99.Mark
--- @field end_mark _99.Mark
local VisualSnapshot = {}
VisualSnapshot.__index = VisualSnapshot

--- Returns the exact live range only if nothing changed since capture.
--- @return _99.Range?, string?
function VisualSnapshot:live_range()
  local buffer = self.range.buffer
  if not self.start_mark:is_valid() or not self.end_mark:is_valid() then
    return nil, "the source buffer or selection marks are no longer available"
  end
  if vim.api.nvim_buf_get_changedtick(buffer) ~= self.changedtick then
    return nil, "the source buffer changed since the selection was captured"
  end
  local range = Range.from_marks(self.start_mark, self.end_mark)
  range.linewise = self.range.linewise
  if
    not range.start:eq(self.range.start) or not range.end_:eq(self.range.end_)
  then
    return nil, "the selection marks moved since capture"
  end
  local ok, text = pcall(range.to_text, range)
  if not ok or text ~= self.text then
    return nil, "the selected text changed since capture"
  end
  if not vim.bo[buffer].modifiable then
    return nil, "the source buffer is not modifiable"
  end
  return range
end

--- @class _99.Prompt
--- @field visual_snapshot? _99.VisualSnapshot
--- @field unapplied_response? string

--- Capture before opening prompt input. Never refresh an existing snapshot.
--- @param context _99.Prompt
--- @return _99.VisualSnapshot
function Mark.capture_visual(context)
  if context.visual_snapshot then
    return context.visual_snapshot
  end
  local range = context:visual_data().range
  local text = range:to_text()
  local start_mark, end_mark = Mark.mark_range(range)
  context.marks.visual_start = start_mark
  context.marks.visual_end = end_mark
  local snapshot = setmetatable({
    range = vim.deepcopy(range),
    text = text,
    changedtick = vim.api.nvim_buf_get_changedtick(range.buffer),
    start_mark = start_mark,
    end_mark = end_mark,
  }, VisualSnapshot)
  context.visual_snapshot = snapshot
  return snapshot
end

return Mark
