local capture = require("atom-repeat.capture")

local M = {}

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
  vim.api.nvim_feedkeys(entry.replay_value, mode, false)
  if vim.v.errmsg ~= "" then
    return false, vim.v.errmsg
  end
  return true
end

function M.run(entries, count, callback)
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
  vim.schedule(function()
    capture.set_replaying(true)
    local replay_ok = true
    local failure
    local call_ok, call_error = xpcall(function()
      for _ = 1, count do
        for _, entry in ipairs(entries) do
          replay_ok, failure = feed(entry)
          if not replay_ok then
            break
          end
        end
        if not replay_ok then
          break
        end
      end
    end, debug.traceback)
    -- CmdAtom is deferred. Keep replay capture disabled until events produced
    -- by the fed keys have had a chance to run; otherwise a trailing insert
    -- Atom can arrive after `feedkeys()` returns and leak into history.
    vim.schedule(function()
      capture.set_replaying(false)
      if not call_ok then
        callback(false, call_error)
      else
        callback(replay_ok, failure)
      end
    end)
  end)
end

return M
