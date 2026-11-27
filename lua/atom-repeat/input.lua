local M = {}

local namespace = vim.api.nvim_create_namespace("atom-repeat-input")
local chunks = {}
local first = 1
local prompt_chunk
local wrapped_readers = {}
local ignore_key = vim.keycode("<Ignore>")
local pending_operator
local completed_operators = {}
local record_operator
local recovered_exit

local function reset_chunks()
  chunks = {}
  first = 1
  prompt_chunk = nil
  pending_operator = nil
  completed_operators = {}
end

function M.reset()
  reset_chunks()
  recovered_exit = nil
end

-- getchar() bypasses on_key. For Lua Insert mappings associate a consumed
-- character with the mapping that read it, including consecutive reads.
local function setup_readers(enabled)
  for _, name in ipairs({ "getchar", "getcharstr" }) do
    local installed = wrapped_readers[name]
    if enabled and not installed then
      local original = vim.fn[name]
      local function read(...)
        local target = prompt_chunk
        local peek = select(1, ...) == 1
        local result = original(...)
        local active = wrapped_readers[name]
        if target and active and active.read == read and not peek and result ~= 0 and result ~= "" then
          local char = type(result) == "number" and vim.fn.nr2char(result) or result
          target.payload = (target.payload or "") .. char
        end
        return result
      end
      wrapped_readers[name] = { original = original, read = read }
      vim.fn[name] = read
    elseif not enabled and installed then
      if vim.fn[name] == installed.read then
        vim.fn[name] = installed.original
      end
      wrapped_readers[name] = nil
    end
  end
end

local function finish_operator()
  local operator = pending_operator
  if not operator then
    return
  end
  pending_operator = nil
  if vim.api.nvim_get_current_buf() ~= operator.buf then
    return
  end
  local changed = operator.name ~= "y" and vim.b.changedtick ~= operator.tick
  if changed or operator.yanked then
    operator.last = #chunks
    operator.changed = changed
    operator.undoseq = vim.fn.undotree().seq_cur
    completed_operators[#completed_operators + 1] = operator
  end
end

local function watch_operator(chunk)
  -- Expressions such as lazy.nvim's first-use mappings can requeue an
  -- operator's text object without marking the requeued keys as typed.
  if chunk.key ~= ignore_key or not vim.startswith(chunk.mode, "no") then
    return
  end
  local operator = vim.v.operator
  if not (operator == "c" or operator == "d" or operator == "y") then
    return
  end
  local function earlier(index, mode)
    local key = index >= first and chunks[index]
    return key and key.buf == chunk.buf and key.mode == mode and key.typed or ""
  end
  local function include_count(start, mode)
    for index = start - 1, first, -1 do
      local key = earlier(index, mode)
      if not key:match("^%d$") then
        break
      end
      if key ~= "0" then
        start = index
      end
    end
    return start
  end
  local motion = include_count(#chunks, chunk.mode)
  if earlier(motion - 1, "n") ~= operator then
    return
  end
  local start = include_count(motion - 1, "n")
  local _, register = M.prefix(earlier(start - 2, "n") .. earlier(start - 1, "n"))
  if register then
    start = include_count(start - 2, "n")
  end
  pending_operator = { start = start, buf = chunk.buf, name = operator, tick = vim.b.changedtick }
end

function M.setup(group, capture_lua_prompts, on_missing_operator)
  M.reset()
  record_operator = on_missing_operator
  setup_readers(capture_lua_prompts)
  vim.on_key(function(key, typed)
    prompt_chunk = nil
    if typed ~= "" then
      local chunk = {
        key = key,
        typed = typed,
        buf = vim.api.nvim_get_current_buf(),
        mode = vim.api.nvim_get_mode().mode,
        mapped = key ~= typed,
      }
      if chunk.mode == "n" then
        finish_operator()
        if recovered_exit and recovered_exit.buf == chunk.buf and recovered_exit.lhs == typed then
          recovered_exit = nil
        end
      end
      chunks[#chunks + 1] = chunk
      watch_operator(chunk)
      if capture_lua_prompts and chunk.mapped and chunk.mode:match("^[iR]") then
        prompt_chunk = chunk
      end
    end
  end, namespace)
  vim.api.nvim_create_autocmd("TextYankPost", {
    group = group,
    callback = function(event)
      if pending_operator and pending_operator.buf == event.buf and vim.v.event.operator == "y" then
        pending_operator.yanked = true
      end
    end,
  })
  vim.api.nvim_create_autocmd("SafeState", {
    group = group,
    callback = function()
      prompt_chunk = nil
      if first > #chunks or vim.api.nvim_get_mode().mode ~= "n" then
        return
      end
      finish_operator()
      -- CmdAtom can be queued until after SafeState, e.g. with pasted typeahead.
      local batch, last = chunks, #chunks
      vim.schedule(function()
        if chunks == batch and #chunks == last then
          -- The event queue drains before the next SafeState. Keep this batch
          -- available to any CmdAtom handlers already scheduled.
          vim.schedule(function()
            if chunks == batch and #chunks == last then
              M.flush()
              reset_chunks()
            end
          end)
        end
      end)
    end,
  })
end

function M.ignore()
  if first <= #chunks then
    local chunk = chunks[#chunks]
    chunk.ignored = true
    return chunk
  end
end

function M.pending(only_mappings)
  for i = first, #chunks do
    if not chunks[i].ignored and (not only_mappings or chunks[i].mapped) then
      return true
    end
  end
  return false
end

-- A count may be before or after a register in the typed input.
function M.prefix(keys)
  local count, rest = keys:match("^([1-9]%d*)(.*)$")
  count, rest = count or "", rest or keys
  local register, body = rest:match('^"([%w"+*_.:%%#/%-])(.*)$')
  if register then
    local after, action = body:match("^([1-9]%d*)(.*)$")
    return count .. (after or ""), register, action or body
  end
  return count, nil, rest
end

local function typed_keys(start, last, prefix)
  local keys = { prefix }
  for i = start, last do
    keys[#keys + 1] = chunks[i].typed .. (chunks[i].payload or "")
  end
  local raw = table.concat(keys)
  -- on_key and getcharstr return literal UTF-8. A continuation byte 0x80
  -- must be escaped when passed back to nvim_feedkeys alongside keycodes.
  if raw:find("\128", 1, true) and raw:find("[\194-\244]") then
    return vim.keycode(vim.fn.keytrans(raw))
  end
  return raw
end

function M.command_keys()
  local last = #chunks
  if last < first or vim.fn.state("S") == "" then
    return ""
  end
  if chunks[last].mode == "c" and (chunks[last].key == "\r" or chunks[last].key == "\n") then
    local start = last
    while start > first and chunks[start].mode == "c" do
      start = start - 1
    end
    return typed_keys(start, last, "")
  end
  if chunks[last].mode == "n" and chunks[last].mapped then
    return typed_keys(last, last, "")
  end
  return ""
end

local function is_mapped_exit(operator)
  local exit = chunks[operator.last]
  return operator.name == "c" and exit.mapped and exit.key == "\027"
end

local function flush_operators(before)
  while completed_operators[1] and completed_operators[1].last < before do
    local operator = table.remove(completed_operators, 1)
    if operator.start >= first then
      local keys = typed_keys(operator.start, operator.last, "")
      first = operator.last + 1
      if is_mapped_exit(operator) then
        recovered_exit = { buf = operator.buf, lhs = chunks[operator.last].typed, undoseq = operator.undoseq }
      end
      record_operator({
        type = "operator",
        lhs = keys,
        operator = operator.name,
        changed = operator.changed,
        undoseq = operator.undoseq,
      }, operator.buf)
    end
  end
end

function M.flush()
  flush_operators(math.huge)
end

local function take(start, last, keys, atom)
  flush_operators(start)
  local operator = completed_operators[1]
  if operator and operator.start >= first and operator.start <= last and operator.last >= start
    and atom.operator == operator.name and atom.undoseq == operator.undoseq then
    -- The native atom can contain the loader's resolved motion. Keep the
    -- native metadata and replace its input with the original mapping.
    table.remove(completed_operators, 1)
    keys = typed_keys(operator.start, operator.last, "")
    start, last = operator.start, operator.last
  end
  local mapped, ignored = false, false
  local repeated
  for i = start, last do
    repeated = repeated or chunks[i].repeated
    mapped = mapped or chunks[i].mapped
    ignored = ignored or chunks[i].ignored
  end
  first = last + 1
  if first > #chunks then
    reset_chunks()
  end
  return repeated or keys, mapped, ignored
end

local function extends(keys, chunk, offset)
  local typed = chunk.typed
  if chunk.mode == "c" and typed == "\r" and keys:sub(offset, offset) == "\n" then
    return 1
  end
  if keys:sub(offset, offset + #typed - 1) == typed then
    return #typed
  end
end

local function visual_lhs(atom, lhs)
  local parts, resolved = {}, {}
  for _, child in ipairs(atom.atoms or {}) do
    parts[#parts + 1] = child.lhs or child.keys or ""
    resolved[#resolved + 1] = child.keys or ""
  end
  local prefix = table.concat(parts)
  -- A Visual mapping can replace the composite LHS with just the last
  -- mapping and its payload. The child atoms still describe the selection.
  if prefix ~= "" and vim.startswith(atom.keys or "", table.concat(resolved)) and not vim.startswith(lhs, prefix) then
    return prefix .. lhs
  end
  return lhs
end

local function insert_end(start, bufnr)
  for i = start + 1, #chunks do
    local chunk = chunks[i]
    if chunk.buf ~= bufnr or chunk.mode == "n" then
      return
    end
    local mode = chunk.mode:sub(1, 1)
    if (mode == "i" or mode == "R") and (chunk.key == "\027" or chunk.key == "\003") then
      return i
    end
  end
end

local function insert_keys(start, last, prefix, lhs, change)
  if change then
    local insert_start = start + 1
    while not chunks[insert_start].mode:match("^[iR]") do
      insert_start = insert_start + 1
    end
    local suffix = typed_keys(insert_start, last, "")
    if vim.endswith(lhs, suffix) then
      -- A motion may consume keys that on_key never saw. Keep them when
      -- CmdAtom agrees with the observed operator and Insert keys.
      local opener = typed_keys(start, insert_start - 1, "")
      local before_insert = lhs:sub(1, #lhs - #suffix)
      local exit = chunks[last]
      if exit.mapped and not vim.startswith(before_insert, opener) and vim.startswith(before_insert, exit.typed) then
        before_insert = chunks[start].typed .. before_insert:sub(#exit.typed + 1)
      end
      if vim.startswith(before_insert, opener) then
        return prefix .. before_insert .. suffix
      end
    end
  end
  return typed_keys(start, last, prefix)
end

local function loaded_operator_lhs(body, atom, start)
  local chunk, motion = chunks[start], chunks[start + 1]
  local operator = atom.operator
  if chunk.key == ignore_key and operator and vim.startswith(body, operator)
    and motion and motion.buf == chunk.buf and vim.startswith(motion.mode, "no") then
    -- A lazy Normal-mode mapping can start an operator with untyped
    -- keys. Match its observed motion before replacing the native prefix.
    local rest = body:sub(#operator + 1)
    if vim.startswith(rest, motion.typed) then
      return chunk.typed .. rest
    end
  end
end

local function visual_end(start, bufnr)
  local last = start
  for i = start + 1, #chunks do
    local chunk = chunks[i]
    local mode = chunk.mode:sub(1, 1)
    if chunk.buf ~= bufnr or not ("vV\022c"):find(mode, 1, true) then
      break
    end
    last = i
  end
  return last
end

function M.take(atom, bufnr)
  if pending_operator and vim.api.nvim_get_mode().mode == "n" then
    finish_operator()
  end
  if not atom.lhs or atom.lhs == "" then
    return
  end
  if atom.type == "mapping" and not atom.changed and atom.keys == nil then
    local recovered = completed_operators[1]
    if recovered and recovered.buf == bufnr and recovered.undoseq == atom.undoseq
      and is_mapped_exit(recovered) and chunks[recovered.last].typed == atom.lhs then
      flush_operators(recovered.last + 1)
    end
    -- A delayed atom for the mapped Insert exit can arrive after its
    -- enclosing operator has already been recovered and its keys cleared.
    if recovered_exit and recovered_exit.buf == bufnr and recovered_exit.undoseq == atom.undoseq
      and recovered_exit.lhs == atom.lhs then
      recovered_exit = nil
      return nil, nil, true
    end
  end
  local lhs = atom.type == "visual" and visual_lhs(atom, atom.lhs) or atom.lhs
  local _, _, body = M.prefix(lhs)
  local operator = atom.atoms and atom.atoms[#atom.atoms] or atom
  local change = operator.operator == "c"
  local insert = change or atom.type == "insert" or atom.type == "mapping" and lhs:sub(-1) == "\027"
  local prefix = ""
  for start = first, #chunks do
    local chunk = chunks[start]
    if chunk.buf == bufnr and chunk.mode == "n" then
      local _, _, remaining = M.prefix(prefix .. chunk.typed)
      local body_length = extends(body, chunk, 1)
      local length = extends(lhs, chunk, 1)
      -- Insert atoms can report a synthetic leading count and even replace a
      -- mapped opener with text from a later Insert-mode mapping.
      if insert and remaining ~= "" then
        local last = insert_end(start, bufnr)
        if last and (body_length or chunk.mapped or change and chunk.typed == "c") then
          return take(start, last, insert_keys(start, last, prefix, body, change), atom)
        end
      end
      local loaded_lhs = loaded_operator_lhs(body, atom, start)
      if length or body_length or loaded_lhs then
        local expected = loaded_lhs or (length and lhs or body)
        local offset = (loaded_lhs and #chunk.typed or length or body_length) + 1
        local matched = start
        while offset <= #expected and matched < #chunks do
          local following = chunks[matched + 1]
          if following.buf ~= bufnr or following.mode == "n" and chunk.mapped then
            break
          end
          local size = extends(expected, following, offset)
          if not size then
            break
          end
          offset = offset + size
          matched = matched + 1
        end

        if offset > #expected then
          return take(start, matched, typed_keys(start, matched, prefix), atom)
        end
        -- Visual keys can be normalized (e.g. "~" becomes "g~"), or
        -- omitted when a motion didn't move at the original cursor.
        if atom.type == "visual" then
          local last = visual_end(matched, bufnr)
          if last > matched then
            return take(start, last, typed_keys(start, last, prefix), atom)
          end
        end
        -- The suffix can be getchar() input, which only CmdAtom observes.
        -- With no match past the opener, require either a mapping or a full
        -- match so stale keys from an aborted operation aren't used.
        if chunk.mapped or matched > start then
          local keys = prefix ~= "" and prefix .. (loaded_lhs or body) or expected
          return take(start, matched, keys, atom)
        end
      end
      local candidate = prefix .. chunk.typed
      prefix = (remaining == "" or candidate:match('^%d*"$')) and candidate or ""
    else
      prefix = ""
    end
  end
  return lhs
end

return M
