local state = require("atom-repeat.state")
local input = require("atom-repeat.input")

local M = {}

---@class AtomHistoryEntry
---@field seq integer
---@field atom vim.event.cmdatom.data
---@field context table
---@field replay_kind 'keys'|'lhs'|'unsupported'
---@field replay_value? string
---@field recorded_dots? (string|false)[] Inputs of automatic dot repeats within a recorded macro.

---@class ReplayGroup
---@field atoms AtomHistoryEntry[]
---@field created_at integer
---@field repeatable boolean

local function touch(bucket)
  state.clock = state.clock + 1
  bucket.last_used = state.clock
end

local function trim_bucket(bucket)
  local extra = #bucket.entries - state.config.history_size
  if extra > 0 then
    for _ = 1, extra do
      table.remove(bucket.entries, 1)
    end
  end
end

local function evict_buckets()
  while vim.tbl_count(state.buckets) > state.config.max_buckets do
    local oldest_id
    local oldest_clock
    for id, bucket in pairs(state.buckets) do
      if oldest_clock == nil or bucket.last_used < oldest_clock then
        oldest_id = id
        oldest_clock = bucket.last_used
      end
    end
    if not oldest_id then
      return
    end
    state.buckets[oldest_id] = nil
  end
end

local function replay_kind(atom, typed)
  if atom.keys == "" then
    return "unsupported", nil
  end
  local lhs = typed or atom.lhs
  if type(lhs) == "string" and lhs ~= "" then
    local _, _, body = input.prefix(lhs)
    if body ~= "." then
      return "lhs", lhs
    end
  end
  if type(atom.keys) == "string" then
    return "keys", atom.keys
  end
  return "unsupported", nil
end

function M.ensure(context)
  local bucket = state.buckets[context.id]
  if not bucket then
    bucket = {
      id = context.id,
      project = context.project,
      branch = context.branch,
      entries = {},
      last_group = nil,
      last_used = 0,
    }
    state.buckets[context.id] = bucket
  end

  touch(bucket)
  evict_buckets()
  return bucket
end

function M.add(atom, context, typed)
  local bucket = M.ensure(context)
  state.sequence = state.sequence + 1
  local copied = vim.deepcopy(atom)
  local kind, value = replay_kind(copied, typed)
  local entry = {
    seq = state.sequence,
    atom = copied,
    context = vim.deepcopy(context),
    replay_kind = kind,
    replay_value = value,
  }
  bucket.entries[#bucket.entries + 1] = entry
  trim_bucket(bucket)
  return entry
end

function M.get(id, should_touch)
  local bucket = state.buckets[id]
  if bucket and should_touch ~= false then
    touch(bucket)
  end
  return bucket
end

function M.snapshot(id)
  local bucket = M.get(id)
  if not bucket then
    return nil
  end
  local entries = {}
  for i, entry in ipairs(bucket.entries) do
    entries[i] = entry
  end
  return {
    id = bucket.id,
    project = bucket.project,
    branch = bucket.branch,
    entries = entries,
  }
end

function M.set_last_group(id, group)
  local bucket = M.get(id, false)
  if bucket then
    bucket.last_group = vim.deepcopy(group)
    touch(bucket)
  end
end

function M.get_last_group(id)
  local bucket = M.get(id)
  return bucket and bucket.last_group or nil
end

function M.clear(id)
  state.buckets[id] = nil
end

function M.clear_all()
  state.buckets = {}
end

function M.apply_limits()
  for _, bucket in pairs(state.buckets) do
    trim_bucket(bucket)
  end
  evict_buckets()
end

return M
