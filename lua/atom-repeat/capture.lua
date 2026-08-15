local scope = require("atom-repeat.scope")
local state = require("atom-repeat.state")
local store = require("atom-repeat.store")

local M = {}

local group = vim.api.nvim_create_augroup("AtomRepeat", { clear = true })

local function is_owned_buffer(bufnr)
  return state.owned_buffers[bufnr] == true
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
end

function M.setup()
  vim.api.nvim_clear_autocmds({ group = group })
  vim.api.nvim_create_autocmd("CmdAtom", {
    group = group,
    callback = function(event)
      if #state.suppress_tokens > 0 then
        local token = table.remove(state.suppress_tokens, 1)
        token.active = false
        return
      end
      if state.replaying then
        return
      end

      local bufnr = vim.api.nvim_get_current_buf()
      if is_owned_buffer(bufnr) then
        return
      end
      store.add(event.data, scope.resolve(bufnr))
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
