local Window = require("99.window")
local utils = require("99.utils")

--- @class _99.Extensions.Worker
--- A persistent way to keep track of work.
---
--- this will likely be where the most change and focus goes into.  I would like
--- to take this into worktree territory and be able to swap between stuff super
--- slick.
---
--- Until then, it is going to be a single bit of work that you can provide
--- the description and then use search to find what is left that needs to be done.
--- @docs base
--- @field set_work fun(opts?: _99.WorkOpts): nil
--- will set the work for the project.  If opts provide a description then no
--- input capture of work description will be required
--- @field search fun(): nil
--- will use _99.search to find what is left to be done for this work item to be
--- considered done
local M = {}
local current_work_path

local DEFAULT_WORK_DESCRIPTION =
  "Put in the description of the work you want to complete"

--- @class _99.WorkOpts
--- @docs included
--- @field description string | nil

--- @return string
local function get_work_item_file()
  local _99 = require("99")
  local state = _99.__get_state()
  local path = utils.named_tmp_file(state:tmp_dir(), "work-item")
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

--- @param path string
--- @return string | nil
local function read_work_item(path)
  local ok, lines = pcall(vim.fn.readfile, path, "b")
  if ok then
    return table.concat(lines, "\n")
  end
end

--- @param path string
--- @return string
local function hydrate_current_work_item(path)
  if current_work_path ~= path then
    M.current_work_item = nil
    M.last_work_search = nil
    current_work_path = path
  end
  if M.current_work_item == nil then
    M.current_work_item = read_work_item(path)
  end
  return M.current_work_item or DEFAULT_WORK_DESCRIPTION
end

--- Save to the path captured when the prompt opened, even if the project changes.
--- @param path string
--- @param success boolean
--- @param result string
local function set_work_item(path, success, result)
  if not success then
    return
  end
  local ok, err = utils.write_file_atomic(path, result)
  assert(ok, "unable to save work item: " .. (err or path))
  if get_work_item_file() == path then
    current_work_path = path
    M.current_work_item = result
    M.last_work_search = nil
  end
end

local function capture_work(path)
  local work = hydrate_current_work_item(path)
  Window.capture_input(" Work ", {
    cb = function(success, result)
      set_work_item(path, success, result)
    end,
    content = vim.split(work, "\n"),
  })
end

function M.update_work()
  capture_work(get_work_item_file())
end

--- @param opts _99.WorkOpts | nil
function M.set_work(opts)
  local path = get_work_item_file()
  opts = opts or {}
  if opts.description then
    set_work_item(path, true, opts.description)
  else
    capture_work(path)
  end
end

--- craft_prompt can be overridden so you can create your own prompt
--- @param worker _99.Extensions.Worker
--- @return string
function M.craft_prompt(worker)
  return string.format(
    [[
## Description
%s

## You must complete the checklist
[ ] - Inspect and understand all changed code
 [ ] - git diff
 [ ] - git diff --staged
 [ ] - commits that have not been pushed to remote
[ ] - Take the current pending and commited changes and figure out what is left
      to change to complete the work item. The work item is described in <Description>
[ ] - Carefully review all the changes and <Description> before you respond.
      respond with proper Search Format described in <Rule> and an example in <Output>
[ ] - If you see bugs, also report those
[ ] - if there are tests, run the tests

]],
    worker.current_work_item
  )
end

function M.search()
  local _99 = require("99")
  hydrate_current_work_item(get_work_item_file())

  assert(
    M.current_work_item,
    'you must call "set_work" and set your current work item before calling this'
  )

  M.last_work_search = _99.search({
    additional_prompt = M.craft_prompt(M),
  })
end

function M.vibe()
  local _99 = require("99")
  hydrate_current_work_item(get_work_item_file())

  assert(
    M.current_work_item,
    'you must call "set_work" and set your current work item before calling this'
  )

  M.last_work_search = _99.vibe({
    additional_prompt = M.craft_prompt(M),
  })
end

return M
