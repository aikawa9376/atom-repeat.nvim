local capture = require("atom-repeat.capture")

local dot = require("atom-repeat.dot")

local M = {}
local running = false

function M.validate(entries)
  if type(entries) ~= "table" or #entries == 0 then
    return false, "the replay group is empty"
  end
  for index, entry in ipairs(entries) do
    local kind = entry and entry.replay_kind
    local value = entry and entry.replay_value
    if (kind ~= "keys" and kind ~= "lhs") or type(value) ~= "string" or value == "" then
      return false, ("entry %d (seq %s) is not replayable"):format(index, entry and entry.seq or "?")
    end
  end
  return true
end

local function feed(entry)
  vim.v.errmsg = ""
  local mode = entry.replay_kind == "keys" and "nx!" or "mx!"
  dot.playback(entry.recorded_dots)
  vim.api.nvim_feedkeys(entry.replay_value, mode, false)
  if vim.v.errmsg ~= "" then
    return false, vim.v.errmsg
  end
  return true
end

-- CmdAtom is deferred. Pump events through a queued callback while the
-- current Normal command still owns its position in the input stream.
function M.flush()
  local flushed = false
  vim.schedule(function()
    flushed = true
  end)
  return vim.wait(1000, function() return flushed end, 1)
end

function M.now(entries, count, callback)
  if running then
    callback(false, "a recipe is already running")
    return
  end
  local valid, validation_error = M.validate(entries)
  if not valid then
    callback(false, validation_error)
    return
  end
  count = count or 1
  if type(count) ~= "number" or count % 1 ~= 0 or count < 1 then
    callback(false, "the replay count must be a positive integer")
    return
  end

  running = true
  if not M.flush() then
    running = false
    callback(false, "interrupted before replay")
    return
  end
  -- feedkeys(..., "x") drains all typeahead. Isolate the replay so keys
  -- following the invocation run after its last step.
  vim.fn.inputsave()
  capture.begin_replay()
  local ok, message = xpcall(function()
    for _ = 1, count do
      for _, entry in ipairs(entries) do
        local fed, failure = feed(entry)
        if not fed then
          return failure
        end
      end
    end
  end, debug.traceback)
  dot.playback(nil)
  -- Scheduled mapping callbacks may queue more keys while we flush CmdAtom
  -- events. Restore typeahead first so those callbacks keep their input.
  vim.fn.inputrestore()
  local flushed = M.flush()
  capture.end_replay()
  if not flushed and message == nil then
    message = "interrupted while finishing replay"
  end
  running = false
  callback(ok and message == nil, message)
end

-- Leave the Ex command or selector mapping before feeding Normal-mode keys.
function M.run(entries, count, callback)
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  vim.schedule(function()
    if vim.api.nvim_get_current_win() ~= win or vim.api.nvim_get_current_buf() ~= buf then
      callback(false, "the replay window or buffer changed")
      return
    end
    M.now(entries, count, callback)
  end)
end

return M
