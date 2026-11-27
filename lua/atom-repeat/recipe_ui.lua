local capture = require("atom-repeat.capture")
local dot = require("atom-repeat.dot")
local recipes = require("atom-repeat.recipes")
local replay = require("atom-repeat.replay")
local scope = require("atom-repeat.scope")
local state = require("atom-repeat.state")
local store = require("atom-repeat.store")

local M = {}

local mark_namespace = vim.api.nvim_create_namespace("atom-repeat-recipe-origin")
local highlight_namespace = vim.api.nvim_create_namespace("atom-repeat-recipe-highlights")
local ui_group = vim.api.nvim_create_augroup("AtomRepeatRecipeUI", { clear = false })
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

local function atom_preview(entry)
  if entry.replay_value then
    return printable(entry.replay_value)
  end
  local atom = entry.atom or {}
  if atom.lhs then
    return printable(atom.lhs)
  end
  if atom.type == "insert" and atom.text ~= nil then
    return vim.inspect(atom.text)
  end
  if atom.keys and atom.keys ~= "" then
    return printable(atom.keys)
  end
  return atom.cmd and printable(atom.cmd) or printable(entry.replay_value)
end

local function preview(recipe)
  local parts = {}
  for index, entry in ipairs(recipe.atoms) do
    if index > 4 then
      parts[#parts + 1] = "…"
      break
    end
    parts[#parts + 1] = atom_preview(entry)
  end
  return table.concat(parts, " · ")
end

local function format_recipe(recipe)
  local id = ("R%-5d"):format(recipe.id)
  local timestamp = os.date("%Y-%m-%d %H:%M", recipe.created_at or recipe.last_used_at or 0)
  local count = ("%3d atoms"):format(#recipe.atoms)
  local text = truncate(preview(recipe), 72)
  local line = id .. "  " .. timestamp .. "  " .. count .. "  " .. text
  local time_start = #id + 2
  local count_start = time_start + #timestamp + 2
  local text_start = count_start + #count + 2
  return line, {
    { 0, #id, "Identifier" },
    { time_start, time_start + #timestamp, "Comment" },
    { count_start, count_start + #count, "Number" },
    { text_start, #line, "Normal" },
  }
end

local function delete_origin_mark(session)
  if session.origin_mark and vim.api.nvim_buf_is_valid(session.origin_buf) then
    pcall(vim.api.nvim_buf_del_extmark, session.origin_buf, mark_namespace, session.origin_mark)
  end
  session.origin_mark = nil
end

local function destroy(session, focus_origin)
  if state.recipe_ui == session then
    state.recipe_ui = nil
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
  if state.recipe_ui then
    destroy(state.recipe_ui, focus_origin ~= false)
  end
end

local function render(session, cursor_line)
  local lines = {}
  local highlights = {}
  for index, recipe in ipairs(session.items) do
    lines[index], highlights[index] = format_recipe(recipe)
  end
  if #lines == 0 then
    lines[1] = "  (empty recipe library; press p/P to restore recipes)"
    highlights[1] = { { 0, #lines[1], "Comment" } }
  end
  vim.bo[session.buf].modifiable = true
  vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, lines)
  vim.bo[session.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(session.buf, highlight_namespace, 0, -1)
  for row, spans in ipairs(highlights) do
    for _, span in ipairs(spans) do
      vim.api.nvim_buf_set_extmark(session.buf, highlight_namespace, row - 1, span[1], {
        end_col = span[2],
        hl_group = span[3],
        hl_mode = "combine",
      })
    end
  end
  vim.wo[session.win].winbar = (" atom recipes: %s [%s] "):format(session.project, session.branch):gsub("%%", "%%%%")
  cursor_line = math.max(1, math.min(cursor_line or 1, #lines))
  vim.api.nvim_win_set_cursor(session.win, { cursor_line, 0 })
end

local function normalized_range(first, last)
  first, last = math.min(first, last), math.max(first, last)
  if first < 1 or last > #state.recipe_ui.items then
    return nil, nil
  end
  return first, last
end

local function persist(session)
  recipes.replace(session.bucket_id, session.items)
end

local function yank_range(first, last)
  local session = state.recipe_ui
  first, last = normalized_range(first, last)
  if not first then
    return
  end
  session.entry_register = {}
  for index = first, last do
    session.entry_register[#session.entry_register + 1] = vim.deepcopy(session.items[index])
  end
end

local function delete_range(first, last)
  local session = state.recipe_ui
  first, last = normalized_range(first, last)
  if not first then
    return
  end
  yank_range(first, last)
  for _ = first, last do
    table.remove(session.items, first)
  end
  persist(session)
  render(session, math.min(first, #session.items))
end

local function paste(after, first, last)
  local session = state.recipe_ui
  if #session.entry_register == 0 then
    notify("the recipe UI register is empty", vim.log.levels.WARN)
    return
  end
  local insertion
  if first then
    first, last = normalized_range(first, last)
    if not first then
      return
    end
    for _ = first, last do
      table.remove(session.items, first)
    end
    insertion = first
  elseif #session.items == 0 then
    insertion = 1
  else
    local cursor = vim.api.nvim_win_get_cursor(0)[1]
    insertion = after and cursor + 1 or cursor
  end

  local inserted = {}
  for _ = 1, vim.v.count1 do
    for _, recipe in ipairs(session.entry_register) do
      local copy = vim.deepcopy(recipe)
      copy.id = recipes.allocate_id()
      inserted[#inserted + 1] = copy
    end
  end
  for offset, recipe in ipairs(inserted) do
    table.insert(session.items, insertion + offset - 1, recipe)
  end
  persist(session)
  render(session, insertion + #inserted - 1)
end

local function origin_position(session)
  if not vim.api.nvim_win_is_valid(session.origin_win) or not vim.api.nvim_buf_is_valid(session.origin_buf) then
    return nil, "the recipe origin window or buffer no longer exists"
  end
  if vim.api.nvim_win_get_buf(session.origin_win) ~= session.origin_buf then
    return nil, "the recipe origin window no longer shows the original buffer"
  end
  if scope.resolve(session.origin_buf).id ~= session.bucket_id then
    return nil, "the origin project or branch changed while recipes were open"
  end
  local position = vim.api.nvim_buf_get_extmark_by_id(session.origin_buf, mark_namespace, session.origin_mark, {})
  if #position == 0 then
    return nil, "the recipe origin cursor mark no longer exists"
  end
  return position
end

local function execute_current()
  local session = state.recipe_ui
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local recipe = session.items[row]
  if not recipe then
    return
  end
  local valid, validation_error = replay.validate(recipe.atoms)
  if not valid then
    notify(validation_error, vim.log.levels.ERROR)
    return
  end
  local position, position_error = origin_position(session)
  if not position then
    notify(position_error, vim.log.levels.ERROR)
    return
  end
  local bucket_id = session.bucket_id
  local context = scope.resolve(session.origin_buf)
  local origin_win = session.origin_win
  local recipe_id = recipe.id
  local group = vim.deepcopy(recipe)
  destroy(session, false)
  if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "n" then
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  end
  vim.api.nvim_set_current_win(origin_win)
  vim.api.nvim_win_set_cursor(origin_win, { position[1] + 1, position[2] })
  replay.run(group.atoms, 1, function(ok, replay_error)
    if ok then
      recipes.touch(bucket_id, recipe_id)
      store.ensure(context)
      store.set_last_group(bucket_id, group)
      dot.set("<Plug>(AtomReplayLast)", { count = 1 })
    else
      notify("replay stopped: " .. tostring(replay_error), vim.log.levels.ERROR)
    end
  end)
end

local function install_maps(bufnr)
  vim.keymap.set("n", "q", function()
    capture.ignore_next()
    M.close(true)
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Close atom recipes" })
  vim.keymap.set("n", "<CR>", function()
    capture.ignore_next()
    execute_current()
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Replay selected recipe" })
  vim.keymap.set("n", "dd", function()
    local cursor = vim.api.nvim_win_get_cursor(0)[1]
    capture.ignore_next()
    delete_range(cursor, math.min(#state.recipe_ui.items, cursor + vim.v.count1 - 1))
  end, { buffer = bufnr, silent = true, desc = "Cut recipes" })
  vim.keymap.set({ "x" }, "d", function()
    local anchor, cursor = vim.fn.line("v"), vim.api.nvim_win_get_cursor(0)[1]
    capture.ignore_next()
    delete_range(anchor, cursor)
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Cut selected recipes" })
  vim.keymap.set("n", "yy", function()
    local cursor = vim.api.nvim_win_get_cursor(0)[1]
    capture.ignore_next()
    yank_range(cursor, math.min(#state.recipe_ui.items, cursor + vim.v.count1 - 1))
  end, { buffer = bufnr, silent = true, desc = "Yank recipes" })
  vim.keymap.set("x", "y", function()
    local anchor, cursor = vim.fn.line("v"), vim.api.nvim_win_get_cursor(0)[1]
    capture.ignore_next()
    yank_range(anchor, cursor)
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Yank selected recipes" })
  vim.keymap.set("n", "p", function()
    capture.ignore_next()
    paste(true)
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Paste recipes after cursor" })
  vim.keymap.set("n", "P", function()
    capture.ignore_next()
    paste(false)
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Paste recipes before cursor" })
  vim.keymap.set({ "x" }, "p", function()
    local anchor, cursor = vim.fn.line("v"), vim.api.nvim_win_get_cursor(0)[1]
    capture.ignore_next()
    paste(true, anchor, cursor)
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Replace selected recipes" })
  vim.keymap.set({ "x" }, "P", function()
    local anchor, cursor = vim.fn.line("v"), vim.api.nvim_win_get_cursor(0)[1]
    capture.ignore_next()
    paste(false, anchor, cursor)
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Replace selected recipes" })
end

function M.open(context)
  local bucket = recipes.get_bucket(context.id)
  if not bucket or #bucket.recipes == 0 then
    notify("no saved replay recipes for the current project and branch")
    return
  end
  require("atom-repeat.ui").close(false)
  M.close(false)

  local origin_win = vim.api.nvim_get_current_win()
  local origin_buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(origin_win)
  local mark = vim.api.nvim_buf_set_extmark(origin_buf, mark_namespace, cursor[1] - 1, cursor[2], { right_gravity = false })
  local height = math.min(state.config.ui.height, math.max(1, vim.o.lines - 2))
  vim.cmd(("botright %dnew"):format(height))

  generation = generation + 1
  local session = {
    win = vim.api.nvim_get_current_win(),
    buf = vim.api.nvim_get_current_buf(),
    origin_win = origin_win,
    origin_buf = origin_buf,
    origin_mark = mark,
    bucket_id = context.id,
    project = context.project,
    branch = context.branch,
    items = vim.deepcopy(bucket.recipes),
    entry_register = {},
  }
  state.recipe_ui = session
  state.owned_buffers[session.buf] = true
  vim.api.nvim_buf_set_name(session.buf, ("atom-repeat://recipes/%d"):format(generation))
  vim.bo[session.buf].buftype = "nofile"
  vim.bo[session.buf].bufhidden = "wipe"
  vim.bo[session.buf].swapfile = false
  vim.bo[session.buf].buflisted = false
  vim.bo[session.buf].undolevels = -1
  vim.bo[session.buf].filetype = "atom-repeat-recipes"
  vim.wo[session.win].wrap = false
  vim.wo[session.win].number = false
  vim.wo[session.win].relativenumber = false
  vim.wo[session.win].signcolumn = "no"
  vim.wo[session.win].foldcolumn = "0"
  render(session, 1)
  install_maps(session.buf)
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = ui_group,
    buffer = session.buf,
    once = true,
    callback = function()
      if state.recipe_ui == session then
        state.recipe_ui = nil
      end
      delete_origin_mark(session)
      state.owned_buffers[session.buf] = nil
    end,
  })
end

function M.resize()
  if state.recipe_ui and vim.api.nvim_win_is_valid(state.recipe_ui.win) then
    pcall(vim.api.nvim_win_set_height, state.recipe_ui.win, math.min(state.config.ui.height, math.max(1, vim.o.lines - 2)))
  end
end

return M
