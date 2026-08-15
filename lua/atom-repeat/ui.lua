local capture = require("atom-repeat.capture")
local replay = require("atom-repeat.replay")
local scope = require("atom-repeat.scope")
local state = require("atom-repeat.state")
local store = require("atom-repeat.store")

local M = {}

local mark_namespace = vim.api.nvim_create_namespace("atom-repeat-origin")
local highlight_namespace = vim.api.nvim_create_namespace("atom-repeat-highlights")
local ui_group = vim.api.nvim_create_augroup("AtomRepeatUI", { clear = false })
local generation = 0

local function notify(message, level)
  vim.notify("atom-repeat: " .. message, level or vim.log.levels.INFO)
end

local function printable(value)
  if type(value) ~= "string" then
    return ""
  end
  return vim.fn.keytrans(value):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
end

local function truncate(value, width)
  if vim.fn.strdisplaywidth(value) <= width then
    return value
  end
  local result = ""
  for index = 0, vim.fn.strchars(value) - 1 do
    local candidate = result .. vim.fn.strcharpart(value, index, 1)
    if vim.fn.strdisplaywidth(candidate .. "…") > width then
      break
    end
    result = candidate
  end
  return result .. "…"
end

local function pad(value, width)
  value = truncate(value, width)
  return value .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(value)))
end

local function action(entry)
  local atom = entry.atom
  if atom.lhs then
    local lhs = printable(atom.lhs)
    local expansion = atom.keys ~= "" and printable(atom.keys) or "<callback>"
    return lhs .. " → " .. expansion
  end
  if atom.type == "insert" and atom.text ~= nil then
    return vim.inspect(atom.text)
  end
  if atom.keys and atom.keys ~= "" then
    return printable(atom.keys)
  end
  if atom.cmd then
    return printable(atom.cmd)
  end
  if atom.text then
    return vim.inspect(atom.text)
  end
  return "<unsupported>"
end

local type_highlights = {
  command = "Statement",
  ex = "Statement",
  insert = "String",
  jump = "Identifier",
  mapping = "Special",
  motion = "Function",
  mouse = "Comment",
  operator = "Operator",
  scroll = "Comment",
  visual = "Type",
}

local function format_entry(entry)
  local sequence = ("%6d"):format(entry.seq)
  local atom_type = pad(entry.atom.type or "unknown", 10)
  local atom_action = pad(action(entry), 48)
  local buffer = entry.context.buffer_display
  local line = sequence .. "  " .. atom_type .. " " .. atom_action .. " " .. buffer
  local type_start = #sequence + 2
  local action_start = type_start + #atom_type + 1
  local buffer_start = action_start + #atom_action + 1
  return line, {
    { 0, #sequence, "LineNr" },
    { type_start, type_start + #(entry.atom.type or "unknown"), type_highlights[entry.atom.type] or "Type" },
    { action_start, action_start + #truncate(action(entry), 48), entry.atom.type == "insert" and "String" or "Normal" },
    { buffer_start, #line, "Comment" },
  }
end

local function delete_origin_mark(session)
  if session.origin_mark and vim.api.nvim_buf_is_valid(session.origin_buf) then
    pcall(vim.api.nvim_buf_del_extmark, session.origin_buf, mark_namespace, session.origin_mark)
  end
  session.origin_mark = nil
end

local function destroy(session, focus_origin)
  if state.ui == session then
    state.ui = nil
  end
  delete_origin_mark(session)
  state.owned_buffers[session.buf] = nil
  if vim.api.nvim_win_is_valid(session.win) then
    pcall(vim.api.nvim_win_close, session.win, true)
  end
  if focus_origin and vim.api.nvim_win_is_valid(session.origin_win) then
    pcall(vim.api.nvim_set_current_win, session.origin_win)
  end
end

function M.close(focus_origin)
  if state.ui then
    destroy(state.ui, focus_origin ~= false)
  end
end

local function render(session, snapshot)
  session.bucket_id = snapshot.id
  session.project = snapshot.project
  session.branch = snapshot.branch
  session.entries = snapshot.entries

  local lines = {}
  local highlights = {}
  for index, entry in ipairs(snapshot.entries) do
    lines[index], highlights[index] = format_entry(entry)
  end
  vim.bo[session.buf].modifiable = true
  vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, lines)
  vim.bo[session.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(session.buf, highlight_namespace, 0, -1)
  for row, spans in ipairs(highlights) do
    for _, span in ipairs(spans) do
      if span[2] > span[1] then
        vim.api.nvim_buf_set_extmark(session.buf, highlight_namespace, row - 1, span[1], {
          end_col = span[2],
          hl_group = span[3],
          hl_mode = "combine",
        })
      end
    end
  end
  vim.wo[session.win].winbar = (" atom-repeat: %s [%s] "):format(snapshot.project, snapshot.branch):gsub("%%", "%%%%")
  if #lines > 0 then
    vim.api.nvim_win_set_cursor(session.win, { #lines, 0 })
  end
end

local function current_origin_position(session)
  if not vim.api.nvim_win_is_valid(session.origin_win) or not vim.api.nvim_buf_is_valid(session.origin_buf) then
    return nil, "the origin window or buffer no longer exists"
  end
  if vim.api.nvim_win_get_buf(session.origin_win) ~= session.origin_buf then
    return nil, "the origin window no longer shows the original buffer"
  end
  local current_scope = scope.resolve(session.origin_buf)
  if current_scope.id ~= session.bucket_id then
    return nil, "the origin project or branch changed while history was open"
  end
  local position = vim.api.nvim_buf_get_extmark_by_id(session.origin_buf, mark_namespace, session.origin_mark, {})
  if #position == 0 then
    return nil, "the origin cursor mark no longer exists"
  end
  return position
end

local function normalize_mode()
  local mode = vim.api.nvim_get_mode().mode
  if mode:sub(1, 1) ~= "n" then
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  end
end

local function replay_range(first, last)
  local session = state.ui
  if not session then
    return
  end
  first, last = math.min(first, last), math.max(first, last)
  if first < 1 or last > #session.entries then
    notify("the selected range does not contain replayable history rows", vim.log.levels.ERROR)
    return
  end

  local entries = {}
  for index = first, last do
    entries[#entries + 1] = session.entries[index]
  end
  local valid, validation_error = replay.validate(entries)
  if not valid then
    notify(validation_error, vim.log.levels.ERROR)
    return
  end
  local position, origin_error = current_origin_position(session)
  if not position then
    notify(origin_error, vim.log.levels.ERROR)
    return
  end

  local bucket_id = session.bucket_id
  local origin_win = session.origin_win
  local group = {
    atoms = vim.deepcopy(entries),
    created_at = os.time(),
    repeatable = true,
  }
  destroy(session, false)
  normalize_mode()
  vim.api.nvim_set_current_win(origin_win)
  vim.api.nvim_win_set_cursor(origin_win, { position[1] + 1, position[2] })
  replay.run(group.atoms, 1, function(ok, replay_error)
    if ok then
      store.set_last_group(bucket_id, group)
    else
      notify("replay stopped: " .. tostring(replay_error), vim.log.levels.ERROR)
    end
  end)
end

local function install_buffer_maps(bufnr)
  vim.keymap.set("n", "q", function()
    capture.ignore_next()
    M.close(true)
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Close atom history" })
  vim.keymap.set("n", "<CR>", function()
    capture.ignore_next()
    replay_range(vim.api.nvim_win_get_cursor(0)[1], vim.api.nvim_win_get_cursor(0)[1])
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Replay atom" })
  vim.keymap.set("x", "<CR>", function()
    local anchor = vim.fn.line("v")
    local cursor = vim.api.nvim_win_get_cursor(0)[1]
    capture.ignore_next()
    replay_range(anchor, cursor)
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Replay selected atoms" })
end

local function refresh(session)
  local snapshot = store.snapshot(session.bucket_id)
  if not snapshot or #snapshot.entries == 0 then
    destroy(session, true)
    notify("no history for the current project and branch")
    return
  end
  render(session, snapshot)
  vim.api.nvim_set_current_win(session.win)
end

function M.open()
  local current_buf = vim.api.nvim_get_current_buf()
  if state.ui and current_buf == state.ui.buf and vim.api.nvim_win_is_valid(state.ui.win) then
    refresh(state.ui)
    return
  end
  if state.ui then
    destroy(state.ui, false)
  end

  local origin_win = vim.api.nvim_get_current_win()
  local origin_buf = vim.api.nvim_get_current_buf()
  local context = scope.resolve(origin_buf)
  local snapshot = store.snapshot(context.id)
  if not snapshot or #snapshot.entries == 0 then
    notify("no history for the current project and branch")
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(origin_win)
  local mark = vim.api.nvim_buf_set_extmark(origin_buf, mark_namespace, cursor[1] - 1, cursor[2], {
    right_gravity = false,
  })
  local available = math.max(1, vim.o.lines - 2)
  local height = math.min(state.config.ui.height, available)
  vim.cmd(("botright %dnew"):format(height))

  generation = generation + 1
  local session = {
    win = vim.api.nvim_get_current_win(),
    buf = vim.api.nvim_get_current_buf(),
    origin_win = origin_win,
    origin_buf = origin_buf,
    origin_mark = mark,
  }
  state.ui = session
  state.owned_buffers[session.buf] = true

  vim.api.nvim_buf_set_name(session.buf, ("atom-repeat://history/%d"):format(generation))
  vim.bo[session.buf].buftype = "nofile"
  vim.bo[session.buf].bufhidden = "wipe"
  vim.bo[session.buf].swapfile = false
  vim.bo[session.buf].buflisted = false
  vim.bo[session.buf].undolevels = -1
  vim.bo[session.buf].filetype = "atom-repeat"
  vim.wo[session.win].wrap = false
  vim.wo[session.win].number = false
  vim.wo[session.win].relativenumber = false
  vim.wo[session.win].signcolumn = "no"
  vim.wo[session.win].foldcolumn = "0"
  render(session, snapshot)
  install_buffer_maps(session.buf)

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = ui_group,
    buffer = session.buf,
    once = true,
    callback = function()
      if state.ui == session then
        state.ui = nil
      end
      delete_origin_mark(session)
      state.owned_buffers[session.buf] = nil
    end,
  })
end

function M.resize()
  if state.ui and vim.api.nvim_win_is_valid(state.ui.win) then
    local available = math.max(1, vim.o.lines - 2)
    pcall(vim.api.nvim_win_set_height, state.ui.win, math.min(state.config.ui.height, available))
  end
end

return M
