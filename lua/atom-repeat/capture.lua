local scope = require("atom-repeat.scope")
local state = require("atom-repeat.state")
local store = require("atom-repeat.store")
local dot = require("atom-repeat.dot")
local input = require("atom-repeat.input")

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

M.ignore_next = input.ignore

function M.begin_replay()
  state.replay_depth = state.replay_depth + 1
  reset_motion_run()
end

function M.end_replay()
  state.replay_depth = state.replay_depth - 1
end

local function limited_motion(atom)
  if atom.type == "motion" then
    return limited_motions[atom.cmd] or limited_motions[atom.lhs]
  end
  return atom.type == "mapping" and atom.keys == nil and limited_motions[atom.lhs]
end

local function should_store(atom, context)
  if not limited_motion(atom) then
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
  input.setup(group, state.config.capture_lua_prompts)
  vim.api.nvim_create_autocmd("RecordingEnter", { group = group, callback = dot.start_recording })
  vim.api.nvim_create_autocmd("RecordingLeave", {
    group = group,
    callback = function(event)
      local dots = dot.finish_recording()
      local contents = vim.v.event.regcontents
      if state.replay_depth > 0 or is_owned_buffer(event.buf) or not contents or contents == "" then
        return
      end
      -- Register contents have unescaped UTF-8 bytes. Convert through key
      -- notation to recover the internal bytes accepted by nvim_feedkeys().
      local keys = vim.keycode(vim.fn.keytrans(contents))
      local context = scope.resolve(event.buf)
      local entry = {
        atom = { type = "macro", lhs = keys },
        context = context,
        replay_kind = "lhs",
        replay_value = keys,
        recorded_dots = dots,
      }
      store.ensure(context)
      store.set_last_group(context.id, { atoms = { entry }, created_at = os.time(), repeatable = true })
      dot.set("<Plug>(AtomReplayLast)", { count = 1 })
    end,
  })
  vim.api.nvim_create_autocmd("CmdAtom", {
    group = group,
    callback = function(event)
      if state.replay_depth > 0 then
        reset_motion_run()
        return
      end

      local atom, bufnr = event.data, event.buf
      local keys, mapped, ignored = input.take(atom, bufnr)
      if ignored or is_owned_buffer(bufnr) or not vim.api.nvim_buf_is_valid(bufnr) then
        reset_motion_run()
        return
      end
      -- Recording controls would start or stop a fresh recording during replay.
      if atom.type == "normal" and atom.cmd == "q"
        and (atom.keys == "q" or (atom.cmdarg or ""):match('^[%w"]$')) then
        return
      end
      local context = scope.resolve(bufnr)
      if should_store(atom, context) then
        local entry = store.add(atom, context, keys)
        dot.observe(bufnr, entry, mapped)
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
