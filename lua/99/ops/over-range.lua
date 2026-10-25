local RequestStatus = require("99.ops.request_status")
local Mark = require("99.ops.marks")
local geo = require("99.geo")
local make_prompt = require("99.ops.make-prompt")
local CleanUp = require("99.ops.clean-up")

local make_clean_up = CleanUp.make_clean_up
local make_observer = CleanUp.make_observer

local Point = geo.Point

--- @param context _99.Prompt
--- @param opts? _99.ops.Opts
local function over_range(context, opts)
  opts = opts or {}
  local logger = context.logger:set_area("visual")
  if context:is_cancelled() then
    context:stop()
    return
  end

  local function reject(reason, response)
    context.state = "failed"
    context.unapplied_response = type(response) == "string" and response or nil
    local recovery = ""
    if type(response) == "string" and response ~= "" then
      local excerpt = vim.fn.strcharpart(response, 0, 2048)
      logger:error(
        "visual response not applied",
        "response",
        excerpt,
        "truncated",
        #excerpt < #response
      )
      recovery =
        ". Use require('99').view_logs() to retrieve the unapplied response"
    end
    error("visual replacement aborted: " .. reason .. recovery, 0)
  end

  local snapshot = Mark.capture_visual(context)
  local range, capture_error = snapshot:live_range()
  if not range then
    context.state = "failed"
    context:stop()
    vim.notify(
      "99: visual replacement aborted: " .. capture_error,
      vim.log.levels.WARN
    )
    return
  end
  local data = context:visual_data()
  data.range = range
  local top_mark = Mark.mark_above_range(range)
  local bottom_mark = snapshot.end_mark
  context.marks.top_mark = top_mark
  context.marks.bottom_mark = bottom_mark

  logger:debug(
    "visual request start",
    "start",
    Point.from_mark(top_mark),
    "end",
    Point.from_mark(bottom_mark)
  )

  local display_ai_status = context._99.ai_stdout_rows > 1
  local top_status = RequestStatus.new(
    250,
    context._99.ai_stdout_rows or 1,
    "Implementing",
    top_mark
  )
  local bottom_status = RequestStatus.new(250, 1, "Implementing", bottom_mark)
  local clean_up = make_clean_up(function()
    top_status:stop()
    bottom_status:stop()
  end)

  local system_cmd = context._99.prompts.prompts.visual_selection(range)
  local prompt, refs = make_prompt(context, system_cmd, opts)

  context:add_prompt_content(prompt)
  context:add_references(refs)
  context:add_clean_up(clean_up)

  top_status:start()
  bottom_status:start()
  context:start_request(make_observer(context, {
    on_complete = function(status, response)
      if status == "cancelled" then
        logger:debug("request cancelled for visual selection, removing marks")
      elseif status == "failed" then
        logger:error(
          "request failed for visual_selection",
          "error response",
          response or "no response provided"
        )
      elseif status == "success" then
        if context:is_cancelled() then
          return
        end
        if type(response) ~= "string" or vim.trim(response) == "" then
          reject("the response is empty or is not text", response)
          return
        end
        local new_range, conflict = snapshot:live_range()
        if not new_range then
          reject(conflict, response)
          return
        end
        local lines = vim.split(response, "\n", { plain = true })
        local ok, apply_error = pcall(new_range.replace_text, new_range, lines)
        if not ok then
          reject(
            "unable to apply response: " .. tostring(apply_error),
            response
          )
          return
        end
      end
    end,
    on_stdout = function(line)
      if display_ai_status then
        top_status:push(line)
      end
    end,
  }))
end

return over_range
