local input = require("atom-repeat.input")
local repeat_filter = require("atom-repeat.repeat_filter")
local scope = require("atom-repeat.scope")
local state = require("atom-repeat.state")

local M = {}

local plug = "<Plug>(AtomRepeatDot)"
local multicursor = vim.api.nvim_create_namespace("nvim.multicursor")
local registration
local last_edit
local preceding_delete
local recording_dots
local playback_dots
local backend = "uninitialized"
local initialized = false
local warned = false

local function keycode(keys)
  return vim.api.nvim_replace_termcodes(keys, true, false, true)
end

local recipe_mapping = keycode("<Plug>(AtomReplayLast)")

local function notify_conflict()
  if warned then
    return
  end
  warned = true
  vim.notify("atom-repeat: dot-repeat disabled because normal-mode . is already mapped", vim.log.levels.WARN)
end

local function valid_registration()
  return registration
    and vim.api.nvim_buf_is_valid(registration.buf)
    and vim.api.nvim_get_current_buf() == registration.buf
    and vim.b.changedtick == registration.changedtick
end

local function default_register()
  local clipboard = vim.split(vim.o.clipboard, ",", { plain = true })
  if vim.tbl_contains(clipboard, "unnamedplus") then
    return "+"
  end
  if vim.tbl_contains(clipboard, "unnamed") then
    return "*"
  end
  return '"'
end

local function valid_edit(edit)
  if not vim.api.nvim_buf_is_loaded(edit.buf)
    or vim.api.nvim_buf_get_changedtick(edit.buf) ~= edit.changedtick then
    return false
  end
  return edit.undoseq == vim.api.nvim_buf_call(edit.buf, function()
    return vim.fn.undotree().seq_cur
  end)
end

function M.start_recording()
  recording_dots = {}
end

function M.finish_recording()
  local dots = recording_dots
  recording_dots = nil
  return dots and #dots > 0 and dots or nil
end

function M.playback(dots)
  playback_dots = dots and { keys = dots, index = 0 } or nil
end

local function native_dot(count, register)
  local prefix = register and '"' .. register or ""
  vim.api.nvim_feedkeys(prefix .. (count > 0 and tostring(count) or "") .. ".", "ni", false)
end

local function repeat_edit(count, register, chunk, recorded_index)
  local edit = last_edit
  local bufnr = vim.api.nvim_get_current_buf()
  if not edit or edit.native or not valid_edit(edit) or (not edit.entry and edit.buf ~= bufnr) then
    if chunk and chunk.typed == "." then
      chunk.ignored = false
    end
    native_dot(count, register)
    return
  end
  if not edit.entry then
    if recorded_index and recording_dots then
      recording_dots[recorded_index] = true
    end
    return
  end
  local previous_count, previous_register, body = input.prefix(edit.entry.replay_value)
  local selected_register = register or previous_register
  local keys = (selected_register and '"' .. selected_register or "")
    .. (count > 0 and tostring(count) or previous_count)
    .. body
  local entry = { replay_kind = edit.entry.replay_kind, replay_value = keys, seq = edit.entry.seq }
  require("atom-repeat.replay").now({ entry }, 1, function(ok, message)
    if ok and last_edit == edit and vim.api.nvim_get_current_buf() == bufnr then
      if chunk then
        chunk.ignored = false
        chunk.repeated = entry
      end
      if recorded_index and recording_dots then
        recording_dots[recorded_index] = entry.replay_kind == "keys" and { resolved = keys } or keys
      end
      edit.entry = entry
      edit.buf = bufnr
      edit.changedtick = vim.b.changedtick
      edit.undoseq = vim.fn.undotree().seq_cur
    elseif not ok then
      vim.notify("atom-repeat: replay stopped: " .. tostring(message), vim.log.levels.ERROR)
    end
  end)
end

---@param count integer
function M.run(count)
  count = count or 0
  local requested_register = vim.v.register
  local register = requested_register ~= default_register() and requested_register or nil
  local buf = vim.api.nvim_get_current_buf()
  if state.replay_depth > 0 then
    if playback_dots then
      playback_dots.index = playback_dots.index + 1
      local recorded = playback_dots.keys[playback_dots.index]
      if recorded == true then
        return
      elseif type(recorded) == "table" then
        vim.api.nvim_feedkeys(recorded.resolved, "ni", false)
        return
      elseif recorded then
        vim.api.nvim_feedkeys(recorded, "mi", false)
        return
      end
    end
    native_dot(count, register)
    return
  end
  local recorded_index
  if recording_dots then
    recorded_index = #recording_dots + 1
    recording_dots[recorded_index] = false
  end
  local chunk = input.ignore()
  if not valid_registration() then
    registration = nil
    if #vim.api.nvim_buf_get_extmarks(buf, multicursor, 0, -1, { limit = 1 }) > 0 then
      native_dot(count, register)
    else
      local config = state.config and state.config.dot
      local needs_native_atoms = config and (config.join_delete_insert or next(config.ignore) ~= nil)
      if input.pending(not needs_native_atoms and (not last_edit or last_edit.native)) then
        if not require("atom-repeat.replay").flush() then
          return
        end
      end
      repeat_edit(count, register, chunk, recorded_index)
    end
    return
  end

  local selected_count = count > 0 and count or registration.count
  local prefix = selected_count and selected_count > 0 and tostring(selected_count) or ""
  local selected_register = register or registration.register
  if selected_register and selected_register ~= "" then
    prefix = '"' .. selected_register .. prefix
  end
  vim.api.nvim_feedkeys(prefix .. registration.sequence, "mi", false)
end

function M.break_join()
  preceding_delete = nil
end

local function is_delete(atom, body)
  if atom.operator == "d" then
    return true
  end
  if atom.type ~= "mapping" then
    return false
  end
  if not atom.atoms then
    -- A Lua dd mapping can use :normal! and leave no resolved operator.
    return atom.keys == nil and (body == "dd" or body == "D")
  end
  -- A mapped d can set marks before it runs the deletion.
  local deleted = false
  for _, child in ipairs(atom.atoms) do
    if child.changed then
      if not is_delete(child) then
        return false
      end
      deleted = true
    end
  end
  return deleted
end

local function is_i_insert(atom, body)
  local insert = atom.atoms and atom.atoms[#atom.atoms] or atom
  -- An i mapping may enter Insert with cc on an empty line.
  return insert.type == "insert" and (insert.cmd == "i" or vim.startswith(body, "i"))
end

function M.observe(bufnr, entry, mapped)
  local atom = entry.atom
  local previous = preceding_delete
  M.break_join()
  if not atom.changed then
    return
  end
  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  local skip = repeat_filter.skip(entry)
  if skip then
    if skip == "ignored" then
      if not last_edit or last_edit.buf ~= bufnr then
        last_edit = { buf = bufnr }
      end
      -- An ignored edit can also replace Neovim's own dot target.
      last_edit.native = false
    end
    if last_edit and last_edit.buf == bufnr then
      last_edit.changedtick = changedtick
      last_edit.undoseq = atom.undoseq
    end
    return
  end
  -- Operator-pending expression mappings can consume their text object
  -- before on_key sees it. Re-enter the LHS when the motion ran an Ex command.
  local mapped_operator = atom.operator and atom.cmd == ":" and atom.type == "operator"
  local use_lhs = entry.replay_kind == "lhs"
    and (mapped or mapped_operator or atom.keys == nil or atom.operator == "g@" or atom.type == "excmd")

  if state.config.dot.join_delete_insert and entry.replay_kind == "lhs" then
    local body = repeat_filter.body(entry)
    if is_delete(atom, body) then
      preceding_delete = { buf = bufnr, entry = entry }
    elseif previous and previous.buf == bufnr and is_i_insert(atom, body) then
      entry = {
        replay_kind = "lhs",
        replay_value = previous.entry.replay_value .. entry.replay_value,
        seq = entry.seq,
      }
      use_lhs = true
    end
  end
  last_edit = {
    entry = entry.replay_kind ~= "unsupported" and entry or nil,
    buf = bufnr,
    changedtick = changedtick,
    undoseq = atom.undoseq,
    native = not use_lhs,
  }
end

---@class AtomRepeatDotOptions
---@field count? integer Default count reused when `.` has no explicit count. Use -1 to omit it.
---@field register? string Register reused when `.` has no explicit register.

---Register a mapping as the current dot-repeat action. Call this after the
---mapping has successfully made its change.
---@param sequence string Key notation such as `<Plug>(MyAction)`.
---@param opts? AtomRepeatDotOptions|integer
---@return boolean
function M.set(sequence, opts)
  if type(sequence) ~= "string" or sequence == "" then
    error("atom-repeat: repeat sequence must be a non-empty string", 2)
  end
  if type(opts) == "number" then
    opts = { count = opts }
  else
    opts = opts or {}
  end
  if type(opts) ~= "table" then
    error("atom-repeat: repeat options must be a table or integer", 2)
  end
  local count = opts.count
  if count == nil then
    count = vim.v.count
  end
  if type(count) ~= "number" or count % 1 ~= 0 or count < -1 then
    error("atom-repeat: repeat count must be an integer greater than or equal to -1", 2)
  end
  if opts.register ~= nil and (type(opts.register) ~= "string" or #opts.register > 1) then
    error("atom-repeat: repeat register must be a single-character string", 2)
  end

  if not initialized then
    M.setup()
  end

  if backend == "vim-repeat" then
    local ok = pcall(vim.fn["repeat#set"], keycode(sequence), count)
    if ok then
      pcall(vim.fn["repeat#setreg"], keycode(sequence), opts.register or "")
    end
    return ok
  end
  if backend ~= "builtin" then
    notify_conflict()
    return false
  end
  if vim.fn.maparg(".", "n") ~= plug then
    backend = "disabled"
    notify_conflict()
    return false
  end

  registration = {
    sequence = keycode(sequence),
    count = count,
    register = opts.register,
    buf = vim.api.nvim_get_current_buf(),
    changedtick = vim.b.changedtick,
  }
  return true
end

function M.invalidate()
  registration = nil
  last_edit = nil
  M.break_join()
end

function M.clear_recipe(bucket_id)
  if registration and registration.sequence == recipe_mapping
    and (not bucket_id or scope.resolve(registration.buf).id == bucket_id) then
    registration = nil
  end
end

function M.setup()
  vim.keymap.set("n", plug, function()
    M.run(vim.v.count)
  end, { silent = true, desc = "Repeat the registered plugin action" })

  local current = vim.fn.maparg(".", "n")
  if current == "" or current == plug then
    vim.keymap.set("n", ".", plug, { remap = true, silent = true, desc = "Repeat the last change" })
    backend = "builtin"
    initialized = true
    return
  end
  if current:find("<Plug>(RepeatDot)", 1, true) and vim.fn.exists("*repeat#set") == 1 then
    backend = "vim-repeat"
    initialized = true
    return
  end
  backend = "disabled"
  initialized = true
  notify_conflict()
end

function M.backend()
  return backend
end

return M
