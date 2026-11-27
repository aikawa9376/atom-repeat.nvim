local input = require("atom-repeat.input")
local scope = require("atom-repeat.scope")

local M = {}

local plug = "<Plug>(AtomRepeatDot)"
local multicursor = vim.api.nvim_create_namespace("nvim.multicursor")
local registration
local automatic
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

local function valid_automatic()
  if not automatic or not vim.api.nvim_buf_is_loaded(automatic.buf)
    or vim.api.nvim_buf_get_changedtick(automatic.buf) ~= automatic.changedtick then
    return false
  end
  return automatic.undoseq == vim.api.nvim_buf_call(automatic.buf, function()
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
  if not valid_automatic() then
    if chunk and chunk.typed == "." then
      chunk.ignored = false
    end
    native_dot(count, register)
    return
  end
  local edit = automatic
  local bufnr = vim.api.nvim_get_current_buf()
  local previous_count, previous_register, body = input.prefix(edit.entry.replay_value)
  local selected_register = register or previous_register
  local keys = (selected_register and '"' .. selected_register or "")
    .. (count > 0 and tostring(count) or previous_count)
    .. body
  local entry = { replay_kind = "lhs", replay_value = keys, seq = edit.entry.seq }
  require("atom-repeat.replay").now({ entry }, 1, function(ok, message)
    if ok and automatic == edit and vim.api.nvim_get_current_buf() == bufnr then
      if chunk then
        chunk.ignored = false
        chunk.repeated = keys
      end
      if recorded_index and recording_dots then
        recording_dots[recorded_index] = keys
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
  if require("atom-repeat.state").replay_depth > 0 then
    if playback_dots then
      playback_dots.index = playback_dots.index + 1
      local keys = playback_dots.keys[playback_dots.index]
      if keys then
        vim.api.nvim_feedkeys(keys, "mi", false)
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
      if input.pending(automatic == nil) then
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

function M.observe(bufnr, entry, mapped)
  local atom = entry.atom
  if not atom.changed then
    return
  end
  if atom.cmd == "u" or atom.cmd == "U" or atom.cmd == "<C-R>" then
    if automatic and automatic.buf == bufnr then
      automatic.changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
      automatic.undoseq = atom.undoseq
    end
    return
  end
  if entry.replay_kind == "lhs" and (mapped or atom.keys == nil or atom.operator == "g@" or atom.type == "excmd") then
    automatic = {
      entry = entry,
      buf = bufnr,
      changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
      undoseq = atom.undoseq,
    }
  else
    automatic = nil
  end
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
  automatic = nil
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
