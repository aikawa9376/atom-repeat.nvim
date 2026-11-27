local capture = require("atom-repeat.capture")
local config = require("atom-repeat.config")
local dot = require("atom-repeat.dot")
local input = require("atom-repeat.input")
local recipe_ui = require("atom-repeat.recipe_ui")
local recipes = require("atom-repeat.recipes")
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
  local group = store.get_last_group(context.id) or recipes.first(context.id)
  if not group then
    notify("no replay group for the current project and branch", vim.log.levels.WARN)
    return
  end
  replay.now(group.atoms, count or 1, function(ok, replay_error)
    if ok then
      if group.id then
        recipes.touch(context.id, group.id)
      else
        local saved = recipes.add(context, group)
        store.set_last_group(context.id, saved)
      end
      dot.set("<Plug>(AtomReplayLast)", { count = count or 1 })
    elseif not ok then
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
  replace_command("AtomRemember", function(command)
    M.remember(command.args == "" and 1 or tonumber(command.args) or 0)
  end, { nargs = "?", desc = "Use the last N actions as a repeatable recipe" })
  replace_command("AtomReplayLast", function()
    M.replay_last()
  end, { desc = "Replay the last atom group" })
  replace_command("AtomReplaySelect", function()
    M.select()
  end, { desc = "Select a saved atom replay recipe" })
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
  replace_command("AtomReplayClear", function(command)
    owned_action(function()
      if command.bang then
        recipes.clear_all()
        recipe_ui.close(true)
        notify("cleared all saved replay recipes")
        return
      end
      local bucket_id
      if state.recipe_ui then
        bucket_id = state.recipe_ui.bucket_id
      elseif state.ui then
        bucket_id = state.ui.bucket_id
      else
        bucket_id = scope.resolve(vim.api.nvim_get_current_buf()).id
      end
      recipes.clear(bucket_id)
      if state.recipe_ui and state.recipe_ui.bucket_id == bucket_id then
        recipe_ui.close(true)
      end
      notify("cleared saved replay recipes for the current project and branch")
    end)
  end, { bang = true, desc = "Clear saved atom replay recipes" })

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
  recipes.setup()
  store.apply_limits()
  capture.setup()
  install_interfaces()
  dot.setup()
  state.initialized = true
  ui.resize()
  recipe_ui.resize()
end

function M.open()
  assert_initialized()
  capture.ignore_next()
  if input.pending() then
    -- Include CmdAtoms emitted by input immediately before the command.
    vim.schedule(ui.open)
  else
    ui.open()
  end
end

function M.remember(count)
  assert_initialized()
  count = count or 1
  if type(count) ~= "number" or count < 1 or count % 1 ~= 0 then
    error("atom-repeat: expected a positive action count", 2)
  end
  capture.ignore_next()
  if input.pending() and not replay.flush() then
    return
  end
  local context = scope.resolve(vim.api.nvim_get_current_buf())
  local bucket = store.get(context.id)
  if not bucket or #bucket.entries < count then
    notify("too few actions in the current history", vim.log.levels.WARN)
    return
  end
  local entries = vim.list_slice(bucket.entries, #bucket.entries - count + 1)
  local valid, message = replay.validate(entries)
  if not valid then
    notify(message, vim.log.levels.WARN)
    return
  end
  local saved = recipes.add(context, { atoms = entries, created_at = os.time(), repeatable = true })
  store.set_last_group(context.id, saved)
  dot.set("<Plug>(AtomReplayLast)", { count = 1 })
end

function M.replay_last()
  assert_initialized()
  capture.ignore_next()
  replay_last(1)
end

function M.select()
  assert_initialized()
  capture.ignore_next()
  local context
  if state.recipe_ui then
    context = {
      id = state.recipe_ui.bucket_id,
      project = state.recipe_ui.project,
      branch = state.recipe_ui.branch,
    }
  elseif state.ui then
    context = {
      id = state.ui.bucket_id,
      project = state.ui.project,
      branch = state.ui.branch,
    }
  else
    context = scope.resolve(vim.api.nvim_get_current_buf())
  end
  recipe_ui.open(context)
end

---Register another plugin's <Plug> mapping as the current dot-repeat action.
---@param sequence string
---@param opts? AtomRepeatDotOptions|integer
---@return boolean
function M.set_repeat(sequence, opts)
  return dot.set(sequence, opts)
end

function M.invalidate_repeat()
  dot.invalidate()
end

return M
