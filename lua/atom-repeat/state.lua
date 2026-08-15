local M = {
  initialized = false,
  config = nil,
  buckets = {},
  sequence = 0,
  clock = 0,
  suppress_tokens = {},
  replaying = false,
  motion_run = { bucket_id = nil, count = 0 },
  recipe_buckets = {},
  recipes_loaded_path = nil,
  next_recipe_id = 1,
  owned_buffers = {},
  ui = nil,
  recipe_ui = nil,
}

return M
