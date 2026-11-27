local dot = require("atom-repeat.dot")
local input = require("atom-repeat.input")
local recipes = require("atom-repeat.recipes")
local scope = require("atom-repeat.scope")
local state = require("atom-repeat.state")
local store = require("atom-repeat.store")

local M = {}
local register = "z"
local session

local function notify(message, level)
  vim.notify("atom-repeat: " .. message, level or vim.log.levels.INFO)
end

local function normal(keys)
  vim.cmd.normal({ bang = true, args = { keys } })
end

function M.start(name)
  if vim.fn.reg_recording() ~= "" or state.replay_depth > 0 then
    notify("finish the current recording or replay before starting a recording", vim.log.levels.WARN)
    return
  end
  if name and name:find("[%s|]") then
    notify("recipe names must be a single word", vim.log.levels.WARN)
    return
  end
  session = { name = name, context = scope.resolve() }
  local ok = pcall(normal, "q" .. register)
  if not ok or vim.fn.reg_recording() ~= register then
    session = nil
    notify("could not start recording", vim.log.levels.WARN)
    return
  end
  notify(name and ("recording " .. name) or "recording started")
end

function M.stop(discard)
  if not session or vim.fn.reg_recording() ~= register then
    notify("no Atom recording is active", vim.log.levels.WARN)
    return
  end
  local current = session
  current.stop_keys = input.command_keys()
  current.discard = discard
  local ok, message = pcall(normal, "q")
  if current.register_info then
    vim.fn.setreg(register, current.register_info)
  end
  if not ok then
    current.stop_keys, current.discard = nil, nil
    notify("could not stop recording: " .. tostring(message), vim.log.levels.WARN)
  end
end

function M.on_leave(event)
  local dots = dot.finish_recording()
  local contents = vim.v.event.regcontents
  local managed = session and vim.v.event.regname == register and session or nil
  if managed then
    session = nil
    managed.register_info = vim.fn.getreginfo(register)
    if managed.stop_keys == nil then
      -- Native q can also stop the recording. Neovim writes the scratch
      -- register after this event, so restore it once that write finishes.
      vim.schedule(function()
        if vim.fn.getreg(register) == contents then
          vim.fn.setreg(register, managed.register_info)
        end
      end)
    end
    if managed.discard then
      notify("recording cancelled")
      return
    end
  elseif state.replay_depth > 0 or state.owned_buffers[event.buf] then
    return
  end
  local keys = contents and vim.keycode(vim.fn.keytrans(contents)) or ""
  if managed and managed.stop_keys and managed.stop_keys ~= "" then
    if not vim.endswith(keys, managed.stop_keys) then
      notify("could not identify the recording's stop command", vim.log.levels.WARN)
      return
    end
    keys = keys:sub(1, #keys - #managed.stop_keys)
  end
  if keys == "" then
    if managed then
      notify("recording contained no actions", vim.log.levels.WARN)
    end
    return
  end

  local context = managed and managed.context or scope.resolve(event.buf)
  local entry = {
    atom = { type = "macro", lhs = keys },
    context = context,
    replay_kind = "lhs",
    replay_value = keys,
    recorded_dots = dots,
  }
  local group = { atoms = { entry }, name = managed and managed.name, created_at = os.time(), repeatable = true }
  if managed then
    group = recipes.add(context, group)
    notify(group.name and ("saved recording " .. group.name) or "saved recording")
  end
  store.ensure(context)
  store.set_last_group(context.id, group)
  if not managed or scope.resolve().id == context.id then
    dot.set("<Plug>(AtomReplayLast)", { count = 1 })
  end
end

return M
