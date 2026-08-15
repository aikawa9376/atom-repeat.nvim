local scope = require("atom-repeat.scope")
local state = require("atom-repeat.state")
local store = require("atom-repeat.store")

local M = {}

local group = vim.api.nvim_create_augroup("AtomRepeat", { clear = true })
local limited_motions = {
  h = true,
  j = true,
  k = true,
  l = true,
  w = true,
  b = true,
}

local function is_owned_buffer(bufnr)
  return state.owned_buffers[bufnr] == true
end

local function reset_motion_run()
  state.motion_run = { bucket_id = nil, count = 0 }
end

function M.ignore_next(count)
  for _ = 1, count or 1 do
    local token = { active = true }
    state.suppress_tokens[#state.suppress_tokens + 1] = token
    vim.defer_fn(function()
      if not token.active then
        return
      end
      token.active = false
      for index, candidate in ipairs(state.suppress_tokens) do
        if candidate == token then
          table.remove(state.suppress_tokens, index)
          break
        end
      end
    end, 100)
  end
end

function M.set_replaying(value)
  state.replaying = value
  if value then
    reset_motion_run()
  end
end

local function should_store(atom, context)
  if atom.type ~= "motion" or not limited_motions[atom.cmd] then
    reset_motion_run()
    return true
  end

  if state.motion_run.bucket_id ~= context.id then
    state.motion_run = { bucket_id = context.id, count = 0 }
  end
  state.motion_run.count = state.motion_run.count + 1
  local limit = state.config.max_consecutive_motions
  return limit == false or state.motion_run.count <= limit
end

function M.setup()
  reset_motion_run()
  vim.api.nvim_clear_autocmds({ group = group })
  vim.api.nvim_create_autocmd("CmdAtom", {
    group = group,
    callback = function(event)
      if #state.suppress_tokens > 0 then
        local token = table.remove(state.suppress_tokens, 1)
        token.active = false
        reset_motion_run()
        return
      end
      if state.replaying then
        reset_motion_run()
        return
      end

      local bufnr = vim.api.nvim_get_current_buf()
      if is_owned_buffer(bufnr) then
        reset_motion_run()
        return
      end
      local context = scope.resolve(bufnr)
      if should_store(event.data, context) then
        store.add(event.data, context)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufFilePost", "BufDelete" }, {
    group = group,
    callback = function(event)
      scope.clear_cache(event.buf)
    end,
  })
end

return M
