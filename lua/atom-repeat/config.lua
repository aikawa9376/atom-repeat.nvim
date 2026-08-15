local M = {}

---@class AtomRepeatUIConfig
---@field height integer

---@class AtomRepeatConfig
---@field history_size integer
---@field max_buckets integer
---@field ui AtomRepeatUIConfig

---@type AtomRepeatConfig
local defaults = {
  history_size = 500,
  max_buckets = 20,
  ui = {
    height = 12,
  },
}

local function fail(path, message)
  error(("atom-repeat: invalid option %s: %s"):format(path, message), 3)
end

local function validate_keys(value, allowed, path)
  for key in pairs(value) do
    if not allowed[key] then
      fail(path .. "." .. tostring(key), "unknown option")
    end
  end
end

local function positive_integer(value, path)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 1 then
    fail(path, "expected a positive integer")
  end
end

---@param opts? table
---@return AtomRepeatConfig
function M.resolve(opts)
  if opts == nil then
    opts = {}
  end
  if type(opts) ~= "table" then
    fail("opts", "expected a table")
  end

  validate_keys(opts, { history_size = true, max_buckets = true, ui = true }, "opts")
  if opts.ui ~= nil then
    if type(opts.ui) ~= "table" then
      fail("opts.ui", "expected a table")
    end
    validate_keys(opts.ui, { height = true }, "opts.ui")
  end

  local config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  positive_integer(config.history_size, "opts.history_size")
  positive_integer(config.max_buckets, "opts.max_buckets")
  positive_integer(config.ui.height, "opts.ui.height")
  return config
end

return M
