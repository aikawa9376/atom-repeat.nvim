local M = {}

local plug = "<Plug>(AtomRepeatDot)"
local registration
local backend = "uninitialized"
local initialized = false
local warned = false

local function keycode(keys)
  return vim.api.nvim_replace_termcodes(keys, true, false, true)
end

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

---@param count integer
function M.run(count)
  count = count or 0
  if not valid_registration() then
    registration = nil
    vim.api.nvim_feedkeys((count > 0 and tostring(count) or "") .. ".", "ni", false)
    return
  end

  local selected_count = count > 0 and count or registration.count
  local prefix = selected_count and selected_count > 0 and tostring(selected_count) or ""
  local requested_register = vim.v.register
  local selected_register = requested_register ~= default_register() and requested_register or registration.register
  if selected_register and selected_register ~= "" then
    prefix = '"' .. selected_register .. prefix
  end
  vim.api.nvim_feedkeys(prefix .. registration.sequence, "mi", false)
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
