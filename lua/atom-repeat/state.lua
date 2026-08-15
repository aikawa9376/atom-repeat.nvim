local M = {
  initialized = false,
  config = nil,
  buckets = {},
  sequence = 0,
  clock = 0,
  suppress_tokens = {},
  replaying = false,
  owned_buffers = {},
  ui = nil,
}

return M
