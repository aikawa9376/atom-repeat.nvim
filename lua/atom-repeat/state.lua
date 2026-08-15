local M = {
  initialized = false,
  config = nil,
  buckets = {},
  sequence = 0,
  clock = 0,
  suppress_tokens = {},
  replaying = false,
  motion_run = { bucket_id = nil, count = 0 },
  owned_buffers = {},
  ui = nil,
}

return M
