local capture = require("atom-repeat.capture")
local config = require("atom-repeat.config")
local replay = require("atom-repeat.replay")
local scope = require("atom-repeat.scope")
local state = require("atom-repeat.state")
local store = require("atom-repeat.store")
local ui = require("atom-repeat.ui")

local M = {}

local function assert_initialized()
  if not state.initialized then
    error("atom-repeat: setup() must be called before using the plugin", 3)
  end
end

local function notify(message, level)
  vim.notify("atom-repeat: " .. message, level or vim.log.levels.INFO)
end

local function owned_action(callback)
  capture.ignore_next()
  callback()
end

local function replay_last(count)
  assert_initialized()
  local context = scope.resolve(vim.api.nvim_get_current_buf())
  local group = store.get_last_group(context.id)
  if not group then
    notify("no replay group for the current project and branch", vim.log.levels.WARN)
    return
  end
  replay.run(group.atoms, count or 1, function(ok, replay_error)
    if not ok then
      notify("replay stopped: " .. tostring(replay_error), vim.log.levels.ERROR)
    end
  end)
end

local function replace_command(name, callback, opts)
  if state.initialized then
    pcall(vim.api.nvim_del_user_command, name)
  end
  vim.api.nvim_create_user_command(name, callback, opts or {})
end

local function install_interfaces()
  replace_command("AtomHistory", function()
    M.open()
  end, { desc = "Open CmdAtom history" })
  replace_command("AtomReplayLast", function()
    M.replay_last()
  end, { desc = "Replay the last atom group" })
  replace_command("AtomHistoryClear", function(command)
    owned_action(function()
      if command.bang then
        store.clear_all()
        ui.close(true)
        notify("cleared all history buckets")
        return
      end
      local bucket_id = state.ui and state.ui.bucket_id or scope.resolve(vim.api.nvim_get_current_buf()).id
      store.clear(bucket_id)
      if state.ui and state.ui.bucket_id == bucket_id then
        ui.close(true)
      end
      notify("cleared history for the current project and branch")
    end)
  end, { bang = true, desc = "Clear CmdAtom history" })

  vim.keymap.set("n", "<Plug>(AtomReplayLast)", function()
    owned_action(function()
      replay_last(vim.v.count1)
    end)
  end, { silent = true, desc = "Replay the last atom group" })
end

---@param opts? table
function M.setup(opts)
  if vim.fn.exists("##CmdAtom") ~= 1 then
    error("atom-repeat: this Neovim build does not provide the CmdAtom event", 2)
  end
  state.config = config.resolve(opts)
  store.apply_limits()
  capture.setup()
  install_interfaces()
  state.initialized = true
  ui.resize()
end

function M.open()
  assert_initialized()
  capture.ignore_next()
  ui.open()
end

function M.replay_last()
  assert_initialized()
  capture.ignore_next()
  replay_last(1)
end

return M
