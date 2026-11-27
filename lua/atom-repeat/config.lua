local M = {}

---@class AtomRepeatUIConfig
---@field height integer

---@class AtomRepeatRecipeConfig
---@field max_items integer
---@field persist boolean
---@field path string

---@class AtomRepeatConfig
---@field capture_lua_prompts boolean
---@field history_size integer
---@field max_buckets integer
---@field max_consecutive_motions integer|false
---@field recipes AtomRepeatRecipeConfig
---@field ui AtomRepeatUIConfig

---@type AtomRepeatConfig
local defaults = {
  capture_lua_prompts = true,
  history_size = 500,
  max_buckets = 20,
  max_consecutive_motions = false,
  recipes = {
    max_items = 20,
    persist = true,
    path = vim.fs.joinpath(vim.fn.stdpath("state"), "atom-repeat", "recipes.mpack"),
  },
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

local function motion_limit(value)
  if value == false then
    return
  end
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 then
    fail("opts.max_consecutive_motions", "expected a non-negative integer or false")
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

  validate_keys(opts, {
    capture_lua_prompts = true,
    history_size = true,
    max_buckets = true,
    max_consecutive_motions = true,
    recipes = true,
    ui = true,
  }, "opts")
  if opts.recipes ~= nil then
    if type(opts.recipes) ~= "table" then
      fail("opts.recipes", "expected a table")
    end
    validate_keys(opts.recipes, { max_items = true, persist = true, path = true }, "opts.recipes")
  end
  if opts.ui ~= nil then
    if type(opts.ui) ~= "table" then
      fail("opts.ui", "expected a table")
    end
    validate_keys(opts.ui, { height = true }, "opts.ui")
  end

  local config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  if type(config.capture_lua_prompts) ~= "boolean" then
    fail("opts.capture_lua_prompts", "expected a boolean")
  end
  positive_integer(config.history_size, "opts.history_size")
  positive_integer(config.max_buckets, "opts.max_buckets")
  motion_limit(config.max_consecutive_motions)
  positive_integer(config.recipes.max_items, "opts.recipes.max_items")
  if type(config.recipes.persist) ~= "boolean" then
    fail("opts.recipes.persist", "expected a boolean")
  end
  if type(config.recipes.path) ~= "string" or config.recipes.path == "" then
    fail("opts.recipes.path", "expected a non-empty string")
  end
  positive_integer(config.ui.height, "opts.ui.height")
  return config
end

return M
