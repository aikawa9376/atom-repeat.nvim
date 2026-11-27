local M = {}

local namespace = vim.api.nvim_create_namespace("atom-repeat-input")
local chunks = {}
local first = 1
local prompt_chunk
local wrapped_readers = {}

function M.reset()
  chunks = {}
  first = 1
  prompt_chunk = nil
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

function M.setup(group, capture_lua_prompts)
  M.reset()
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
      chunks[#chunks + 1] = chunk
      if capture_lua_prompts and chunk.mapped and chunk.mode:match("^[iR]") then
        prompt_chunk = chunk
      end
    end
  end, namespace)
  vim.api.nvim_create_autocmd("SafeState", {
    group = group,
    callback = function()
      prompt_chunk = nil
      if first > #chunks or vim.api.nvim_get_mode().mode ~= "n" then
        return
      end
      -- CmdAtom can be queued until after SafeState, e.g. with pasted typeahead.
      local batch, last = chunks, #chunks
      vim.schedule(function()
        if chunks == batch and #chunks == last then
          -- The event queue drains before the next SafeState. Keep this batch
          -- available to any CmdAtom handlers already scheduled.
          vim.schedule(function()
            if chunks == batch and #chunks == last then
              M.reset()
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

local function take(start, last, keys)
  local mapped, ignored = false, false
  local repeated
  for i = start, last do
    repeated = repeated or chunks[i].repeated
    mapped = mapped or chunks[i].mapped
    ignored = ignored or chunks[i].ignored
  end
  first = last + 1
  if first > #chunks then
    M.reset()
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
  if not atom.lhs or atom.lhs == "" then
    return
  end
  local lhs = atom.type == "visual" and visual_lhs(atom, atom.lhs) or atom.lhs
  local _, _, body = M.prefix(lhs)
  local insert = atom.type == "insert" or atom.type == "mapping" and lhs:sub(-1) == "\027"
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
        if last and (body_length or chunk.mapped) then
          return take(start, last, typed_keys(start, last, prefix))
        end
      end
      if length or body_length then
        local expected = length and lhs or body
        local offset = (length or body_length) + 1
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
          return take(start, matched, typed_keys(start, matched, prefix))
        end
        -- Visual keys can be normalized (e.g. "~" becomes "g~"), or
        -- omitted when a motion didn't move at the original cursor.
        if atom.type == "visual" then
          local last = visual_end(matched, bufnr)
          if last > matched then
            return take(start, last, typed_keys(start, last, prefix))
          end
        end
        -- The suffix can be getchar() input, which only CmdAtom observes.
        -- With no match past the opener, require either a mapping or a full
        -- match so stale keys from an aborted operation aren't used.
        if chunk.mapped or matched > start then
          local keys = prefix ~= "" and prefix .. body or expected
          return take(start, matched, keys)
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
