local state = require("atom-repeat.state")

local M = {}

local VERSION = 1

local function notify(message, level)
  vim.notify("atom-repeat: " .. message, level or vim.log.levels.WARN)
end

local function read_file(path)
  local fd = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local stat = vim.uv.fs_fstat(fd)
  local contents = stat and vim.uv.fs_read(fd, stat.size, 0) or nil
  vim.uv.fs_close(fd)
  return contents
end

local function valid_atom(entry)
  return type(entry) == "table"
    and (entry.replay_kind == "keys" or entry.replay_kind == "lhs")
    and type(entry.replay_value) == "string"
    and entry.replay_value ~= ""
end

local function valid_recipe(recipe)
  if type(recipe) ~= "table" or type(recipe.id) ~= "number" or type(recipe.atoms) ~= "table" or #recipe.atoms == 0 then
    return false
  end
  if recipe.name ~= nil and type(recipe.name) ~= "string" then
    return false
  end
  for _, entry in ipairs(recipe.atoms) do
    if not valid_atom(entry) then
      return false
    end
  end
  return true
end

local function sanitize(data)
  if type(data) ~= "table" or data.version ~= VERSION or type(data.buckets) ~= "table" then
    return nil, "unsupported or invalid recipe file"
  end
  local buckets = {}
  local highest_id = 0
  for id, bucket in pairs(data.buckets) do
    if type(id) == "string" and type(bucket) == "table" and type(bucket.recipes) == "table" then
      local clean = {
        id = id,
        project = type(bucket.project) == "string" and bucket.project or "",
        branch = type(bucket.branch) == "string" and bucket.branch or "",
        recipes = {},
      }
      for _, recipe in ipairs(bucket.recipes) do
        if valid_recipe(recipe) then
          clean.recipes[#clean.recipes + 1] = recipe
          highest_id = math.max(highest_id, recipe.id)
        end
      end
      buckets[id] = clean
    end
  end
  return buckets, math.max(tonumber(data.next_recipe_id) or 1, highest_id + 1)
end

local function encoded_state()
  return vim.mpack.encode({
    version = VERSION,
    next_recipe_id = state.next_recipe_id,
    buckets = state.recipe_buckets,
  })
end

function M.save()
  if not state.config.recipes.persist then
    return true
  end
  local path = state.config.recipes.path
  local directory = vim.fs.dirname(path)
  local ok, err = pcall(vim.fn.mkdir, directory, "p")
  if not ok then
    notify("could not create recipe directory: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  local encoded_ok, contents = pcall(encoded_state)
  if not encoded_ok then
    notify("could not encode recipes: " .. tostring(contents), vim.log.levels.ERROR)
    return false
  end
  local temporary = path .. ".tmp." .. tostring(vim.uv.os_getpid())
  local fd, open_error = vim.uv.fs_open(temporary, "w", 384)
  if not fd then
    notify("could not open recipe file: " .. tostring(open_error), vim.log.levels.ERROR)
    return false
  end
  local offset = 0
  local write_error
  while offset < #contents do
    local written
    written, write_error = vim.uv.fs_write(fd, contents:sub(offset + 1), offset)
    if not written or written == 0 then
      break
    end
    offset = offset + written
  end
  if not write_error and offset == #contents then
    local synced, sync_error = vim.uv.fs_fsync(fd)
    if not synced then
      write_error = sync_error
    end
  elseif not write_error then
    write_error = "short write"
  end
  vim.uv.fs_close(fd)
  if write_error then
    vim.uv.fs_unlink(temporary)
    notify("could not write recipe file: " .. tostring(write_error), vim.log.levels.ERROR)
    return false
  end
  local renamed, rename_error = vim.uv.fs_rename(temporary, path)
  if not renamed then
    vim.uv.fs_unlink(temporary)
    notify("could not replace recipe file: " .. tostring(rename_error), vim.log.levels.ERROR)
    return false
  end
  return true
end

local function trim(bucket)
  local changed = false
  local unnamed = 0
  local index = 1
  while index <= #bucket.recipes do
    if bucket.recipes[index].name then
      index = index + 1
    elseif unnamed < state.config.recipes.max_items then
      unnamed = unnamed + 1
      index = index + 1
    else
      table.remove(bucket.recipes, index)
      changed = true
    end
  end
  return changed
end

function M.setup()
  local path = state.config.recipes.persist and state.config.recipes.path or false
  if state.recipes_loaded_path ~= path then
    if path then
      state.recipe_buckets = {}
      state.next_recipe_id = 1
    end
    state.recipes_loaded_path = path
    if path then
      local contents = read_file(path)
      if contents then
        local decoded_ok, data = pcall(vim.mpack.decode, contents)
        if decoded_ok then
          local buckets, next_id = sanitize(data)
          if buckets then
            state.recipe_buckets = buckets
            state.next_recipe_id = next_id
          else
            notify("ignoring invalid recipe file: " .. tostring(next_id))
          end
        else
          notify("ignoring unreadable recipe file: " .. tostring(data))
        end
      end
    end
  end
  local changed = false
  for _, bucket in pairs(state.recipe_buckets) do
    changed = trim(bucket) or changed
  end
  if changed then
    M.save()
  end
end

local function same_recipe(left, right)
  if #left.atoms ~= #right.atoms then
    return false
  end
  for index, entry in ipairs(left.atoms) do
    local other = right.atoms[index]
    if entry.replay_kind ~= other.replay_kind or entry.replay_value ~= other.replay_value
      or not vim.deep_equal(entry.recorded_dots, other.recorded_dots) then
      return false
    end
  end
  return true
end

local function bucket_for(context, create)
  local bucket = state.recipe_buckets[context.id]
  if not bucket and create then
    bucket = {
      id = context.id,
      project = context.project,
      branch = context.branch,
      recipes = {},
    }
    state.recipe_buckets[context.id] = bucket
  end
  return bucket
end

function M.add(context, group)
  local bucket = bucket_for(context, true)
  local recipe
  for index, candidate in ipairs(bucket.recipes) do
    if group.name and candidate.name == group.name then
      recipe = vim.deepcopy(group)
      recipe.id = candidate.id
      table.remove(bucket.recipes, index)
      break
    elseif not group.name and not candidate.name and same_recipe(candidate, group) then
      recipe = table.remove(bucket.recipes, index)
      break
    end
  end
  if not recipe then
    recipe = vim.deepcopy(group)
    recipe.id = state.next_recipe_id
    state.next_recipe_id = state.next_recipe_id + 1
  end
  recipe.last_used_at = os.time()
  table.insert(bucket.recipes, 1, recipe)
  trim(bucket)
  M.save()
  return recipe
end

function M.find(id, name)
  local bucket = state.recipe_buckets[id]
  for _, recipe in ipairs(bucket and bucket.recipes or {}) do
    if recipe.name == name then
      return recipe
    end
  end
end

function M.get_bucket(id)
  return state.recipe_buckets[id]
end

function M.first(id)
  local bucket = state.recipe_buckets[id]
  return bucket and bucket.recipes[1] or nil
end

function M.touch(id, recipe_id)
  local bucket = state.recipe_buckets[id]
  if not bucket then
    return nil
  end
  for index, recipe in ipairs(bucket.recipes) do
    if recipe.id == recipe_id then
      recipe = table.remove(bucket.recipes, index)
      recipe.last_used_at = os.time()
      table.insert(bucket.recipes, 1, recipe)
      M.save()
      return recipe
    end
  end
end

function M.replace(id, ordered)
  local bucket = state.recipe_buckets[id]
  if bucket then
    bucket.recipes = vim.deepcopy(ordered)
    trim(bucket)
    M.save()
  end
end

function M.allocate_id()
  local id = state.next_recipe_id
  state.next_recipe_id = state.next_recipe_id + 1
  return id
end

function M.clear(id)
  state.recipe_buckets[id] = nil
  M.save()
end

function M.clear_all()
  state.recipe_buckets = {}
  M.save()
end

return M
