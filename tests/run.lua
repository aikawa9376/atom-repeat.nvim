local atom_repeat = require("atom-repeat")
local replay = require("atom-repeat.replay")
local scope = require("atom-repeat.scope")
local state = require("atom-repeat.state")
local store = require("atom-repeat.store")

local failures = {}
local passed = 0

local function fail(message)
  error(message, 2)
end

local function eq(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    fail(("%s\nexpected: %s\nactual:   %s"):format(message or "values differ", vim.inspect(expected), vim.inspect(actual)))
  end
end

local function truthy(value, message)
  if not value then
    fail(message or "expected a truthy value")
  end
end

local suite

local function sleep(milliseconds)
  local running = coroutine.running()
  vim.defer_fn(function()
    local ok, err = coroutine.resume(running)
    if not ok then
      print("fatal test runner error\n" .. tostring(err))
      vim.cmd("cquit 1")
    end
  end, milliseconds)
  coroutine.yield()
end

local function wait_for(predicate, message)
  local deadline = vim.uv.hrtime() + 1500 * 1000000
  while not predicate() do
    if vim.uv.hrtime() >= deadline then
      fail(message or "timed out")
    end
    sleep(10)
  end
end

local function test(name, callback)
  local ok, err = xpcall(callback, debug.traceback)
  if ok then
    passed = passed + 1
    print("ok - " .. name)
  else
    failures[#failures + 1] = name .. "\n" .. err
    print("not ok - " .. name)
  end
end

local function reset_history()
  if state.ui then
    require("atom-repeat.ui").close(false)
  end
  store.clear_all()
  state.suppress_tokens = {}
  state.replaying = false
  state.motion_run = { bucket_id = nil, count = 0 }
end

local function fresh_buffer(lines)
  vim.cmd("enew!")
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or { "" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  return bufnr
end

local function current_bucket()
  return store.get(scope.resolve(vim.api.nvim_get_current_buf()).id, false)
end

local function run_suite()
atom_repeat.setup({ history_size = 500, max_buckets = 20, ui = { height = 12 } })

test("configuration is strict and setup is idempotent", function()
  local ok, err = pcall(atom_repeat.setup, { history_size = 0 })
  truthy(not ok and tostring(err):find("positive integer", 1, true), "invalid capacity should fail")
  ok, err = pcall(atom_repeat.setup, { unknown = true })
  truthy(not ok and tostring(err):find("unknown option", 1, true), "unknown keys should fail")
  ok, err = pcall(atom_repeat.setup, { max_consecutive_motions = -1 })
  truthy(not ok and tostring(err):find("non%-negative"), "negative motion limits should fail")
  atom_repeat.setup({ max_consecutive_motions = 0 })
  atom_repeat.setup({ max_consecutive_motions = false })

  reset_history()
  state.config = require("atom-repeat.config").resolve({ history_size = 5, max_buckets = 2 })
  store.add({ type = "motion", keys = "w" }, {
    id = "preserved\0main",
    project = "preserved",
    branch = "main",
    buffer_display = "file",
  })
  atom_repeat.setup({ history_size = 5, max_buckets = 2 })
  truthy(store.get("preserved\0main", false), "setup should preserve history")
end)

test("scope resolves Git HEAD on every lookup and supports gitfiles", function()
  reset_history()
  local base = vim.fn.tempname()
  local repository = base .. "/repo"
  vim.fn.mkdir(repository .. "/.git", "p")
  vim.fn.writefile({ "ref: refs/heads/feature/test" }, repository .. "/.git/HEAD")
  local buffer = fresh_buffer({ "x" })
  vim.api.nvim_buf_set_name(buffer, repository .. "/file.lua")
  local first = scope.resolve(buffer)
  eq(repository, first.project, "worktree root")
  eq("feature/test", first.branch, "symbolic branch")

  vim.fn.writefile({ "0123456789abcdef" }, repository .. "/.git/HEAD")
  eq("0123456789abcdef", scope.resolve(buffer).branch, "detached HEAD should refresh")

  local metadata = base .. "/metadata"
  local worktree = base .. "/worktree"
  vim.fn.mkdir(metadata, "p")
  vim.fn.mkdir(worktree, "p")
  vim.fn.writefile({ "gitdir: ../metadata" }, worktree .. "/.git")
  vim.fn.writefile({ "ref: refs/heads/worktree" }, metadata .. "/HEAD")
  local other = fresh_buffer({ "x" })
  vim.api.nvim_buf_set_name(other, worktree .. "/file.lua")
  local worktree_scope = scope.resolve(other)
  eq(worktree, worktree_scope.project, "gitfile worktree root")
  eq("worktree", worktree_scope.branch, "gitfile HEAD")
  vim.fn.delete(base, "rf")
end)

test("ring buffers and bucket LRU enforce both limits", function()
  reset_history()
  atom_repeat.setup({ history_size = 2, max_buckets = 2 })
  local function context(id)
    return { id = id, project = id, branch = "main", buffer_display = "file" }
  end
  store.add({ type = "motion", keys = "h" }, context("a"))
  store.add({ type = "motion", keys = "j" }, context("a"))
  store.add({ type = "motion", keys = "k" }, context("a"))
  eq(2, #store.get("a", false).entries, "ring size")
  eq("j", store.get("a", false).entries[1].atom.keys, "ring evicts oldest entry")

  store.add({ type = "motion", keys = "w" }, context("b"))
  store.get("a")
  store.add({ type = "motion", keys = "e" }, context("c"))
  truthy(store.get("a", false), "recent bucket should remain")
  truthy(not store.get("b", false), "least-recent bucket should be evicted")
  truthy(store.get("c", false), "new bucket should remain")
  atom_repeat.setup()
end)

test("CmdAtom capture preserves structured mappings", function()
  reset_history()
  fresh_buffer({ "one two three" })
  vim.keymap.set("n", "Q", "dww")
  vim.api.nvim_input("Q")
  wait_for(function()
    local bucket = current_bucket()
    return bucket and #bucket.entries == 1
  end, "mapping atom was not captured")
  local entry = current_bucket().entries[1]
  eq("mapping", entry.atom.type, "composite type")
  eq("Q", entry.atom.lhs, "mapping lhs")
  eq("dww", entry.atom.keys, "resolved keys")
  eq(2, #entry.atom.atoms, "nested atoms")
  eq("keys", entry.replay_kind, "keys strategy wins when available")
  vim.keymap.del("n", "Q")
end)

test("simple navigation runs retain only the configured prefix", function()
  reset_history()
  atom_repeat.setup({ max_consecutive_motions = 3 })
  local lines = {}
  for index = 1, 9 do
    lines[index] = "alpha beta gamma"
  end
  fresh_buffer(lines)
  vim.api.nvim_win_set_cursor(0, { 5, 6 })
  for _, key in ipairs({ "h", "j", "k", "l", "w", "b" }) do
    vim.api.nvim_input(key)
    sleep(20)
  end
  local bucket = current_bucket()
  eq(3, #bucket.entries, "only the first three navigation atoms should remain")
  eq({ "h", "j", "k" }, vim.tbl_map(function(entry)
    return entry.atom.cmd
  end, bucket.entries), "the retained navigation prefix")

  vim.api.nvim_input("x")
  sleep(20)
  vim.api.nvim_input("h")
  wait_for(function()
    return #current_bucket().entries == 5
  end, "a non-navigation atom should reset the run")
  eq("h", current_bucket().entries[5].atom.cmd, "motion after reset")

  reset_history()
  atom_repeat.setup({ max_consecutive_motions = false })
  fresh_buffer(lines)
  vim.api.nvim_win_set_cursor(0, { 5, 6 })
  for _, key in ipairs({ "h", "j", "k", "l" }) do
    vim.api.nvim_input(key)
    sleep(20)
  end
  eq(4, #current_bucket().entries, "false should disable the motion limit")
  atom_repeat.setup()
end)

test("search commands and search repeats are captured as separate atoms", function()
  reset_history()
  fresh_buffer({ "alpha beta alpha" })
  vim.api.nvim_input("/beta\r")
  wait_for(function()
    local bucket = current_bucket()
    return bucket and #bucket.entries == 1
  end, "slash search atom was not captured")
  local search = current_bucket().entries[1].atom
  eq("motion", search.type, "slash search type")
  eq("/", search.cmd, "slash search command")
  eq("beta", search.text, "slash search text")

  vim.api.nvim_input("n")
  wait_for(function()
    return #current_bucket().entries == 2
  end, "search repeat atom was not captured")
  eq("n", current_bucket().entries[2].atom.cmd, "search repeat command")
end)

test("history columns use display width and receive highlights", function()
  reset_history()
  local context = scope.resolve(fresh_buffer({ "x" }))
  context.buffer_display = "project/file.lua"
  store.add({ type = "mapping", keys = "", lhs = "j" }, context)
  store.add({ type = "insert", keys = "itest\027", text = "testdesu" }, context)
  atom_repeat.open()
  local lines = vim.api.nvim_buf_get_lines(state.ui.buf, 0, -1, false)
  local columns = {}
  for index, line in ipairs(lines) do
    local byte_start = assert(line:find("project/file.lua", 1, true))
    columns[index] = vim.fn.strdisplaywidth(line:sub(1, byte_start - 1))
  end
  eq(columns[1], columns[2], "buffer column should align across multibyte actions")
  local namespace = vim.api.nvim_get_namespaces()["atom-repeat-highlights"]
  truthy(namespace ~= nil, "highlight namespace should exist")
  local marks = vim.api.nvim_buf_get_extmarks(state.ui.buf, namespace, 0, -1, {})
  truthy(#marks >= 8, "each visible column should be highlighted")
  require("atom-repeat.ui").close(false)
end)

test("history UI replays keys at the origin and does not capture itself", function()
  reset_history()
  local origin = fresh_buffer({ "one two three" })
  vim.api.nvim_input("dw")
  wait_for(function()
    local bucket = current_bucket()
    return bucket and #bucket.entries == 1
  end)
  vim.api.nvim_buf_set_lines(origin, 0, -1, false, { "one two three" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  atom_repeat.open()
  truthy(state.ui and #state.ui.entries == 1, "history UI should open")
  truthy(vim.api.nvim_get_current_line():find("operator", 1, true), "formatted history line")
  vim.api.nvim_input(vim.keycode("<CR>"))
  wait_for(function()
    return state.ui == nil and vim.api.nvim_buf_get_lines(origin, 0, -1, false)[1] == "two three"
  end, "selected keys were not replayed")
  sleep(150)
  eq(1, #current_bucket().entries, "UI and replay actions should be suppressed")
  truthy(current_bucket().last_group, "successful replay should register a last group")
end)

test("Visual-line history selection replays the range in chronological order", function()
  reset_history()
  local origin = fresh_buffer({ "abc def" })
  vim.api.nvim_input("w")
  wait_for(function()
    local bucket = current_bucket()
    return bucket and #bucket.entries == 1
  end)
  vim.api.nvim_input("x")
  wait_for(function()
    return #current_bucket().entries == 2
  end)

  vim.api.nvim_buf_set_lines(origin, 0, -1, false, { "abc def" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  atom_repeat.open()
  vim.api.nvim_input("ggVj" .. vim.keycode("<CR>"))
  wait_for(function()
    return state.ui == nil and vim.api.nvim_buf_get_lines(origin, 0, -1, false)[1] == "abc ef"
  end, "Visual-selected entries did not replay chronologically")
  sleep(150)
  eq(2, #current_bucket().entries, "Visual UI actions should be suppressed")
end)

test("history replay is rejected after the origin branch changes", function()
  reset_history()
  local base = vim.fn.tempname()
  local repository = base .. "/repo"
  vim.fn.mkdir(repository .. "/.git", "p")
  vim.fn.writefile({ "ref: refs/heads/main" }, repository .. "/.git/HEAD")
  local origin = fresh_buffer({ "abc def" })
  vim.api.nvim_buf_set_name(origin, repository .. "/file.lua")
  vim.api.nvim_input("w")
  wait_for(function()
    local bucket = current_bucket()
    return bucket and #bucket.entries == 1
  end)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  atom_repeat.open()
  vim.fn.writefile({ "ref: refs/heads/other" }, repository .. "/.git/HEAD")
  vim.api.nvim_input(vim.keycode("<CR>"))
  sleep(100)
  truthy(state.ui ~= nil, "history UI should remain open after branch mismatch")
  eq({ 1, 0 }, vim.api.nvim_win_get_cursor(state.ui.origin_win), "origin cursor should not move")
  require("atom-repeat.ui").close(false)
  vim.fn.delete(base, "rf")
end)

test("callback lhs replay and Plug count use the current mapping", function()
  reset_history()
  local origin = fresh_buffer({ "x" })
  vim.keymap.set("n", "Q", function()
    local line = vim.api.nvim_get_current_line()
    vim.api.nvim_set_current_line(line .. "!")
  end)
  vim.api.nvim_input("Q")
  wait_for(function()
    local bucket = current_bucket()
    return bucket and #bucket.entries == 1
  end)
  local entry = current_bucket().entries[1]
  eq("lhs", entry.replay_kind, "empty-key callback should use lhs")
  eq("", entry.atom.keys, "callback keys")

  vim.keymap.set("n", "Q", function()
    local line = vim.api.nvim_get_current_line()
    vim.api.nvim_set_current_line(line .. "?")
  end)
  vim.api.nvim_buf_set_lines(origin, 0, -1, false, { "x" })
  atom_repeat.open()
  vim.api.nvim_input(vim.keycode("<CR>"))
  wait_for(function()
    return state.ui == nil and vim.api.nvim_get_current_line() == "x?"
  end)
  wait_for(function()
    return current_bucket().last_group ~= nil
  end)

  vim.api.nvim_set_current_line("x")
  vim.keymap.set("n", "R", "<Plug>(AtomReplayLast)")
  vim.api.nvim_input("2R")
  wait_for(function()
    return vim.api.nvim_get_current_line() == "x??"
  end, "counted Plug replay")
  sleep(150)
  eq(1, #current_bucket().entries, "Plug invocation should be suppressed")
  vim.keymap.del("n", "R")
  vim.keymap.del("n", "Q")
end)

test("replay validation aborts and runtime errors stop the queue", function()
  local valid, message = replay.validate({ {
    seq = 99,
    replay_kind = "unsupported",
  } })
  truthy(not valid and message:find("99", 1, true), "unsupported entry should fail before replay")

  fresh_buffer({ "x" })
  vim.keymap.set("n", "E", function()
    error("expected replay failure")
  end)
  local result
  replay.run({
    { replay_kind = "lhs", replay_value = "E", seq = 1 },
    { replay_kind = "keys", replay_value = "A!\027", seq = 2 },
  }, 1, function(ok, err)
    result = { ok, err }
  end)
  wait_for(function()
    return result ~= nil
  end)
  truthy(not result[1], "runtime error should fail the replay")
  truthy(result[2]:find("expected replay failure", 1, true), "runtime error should be reported")
  eq("x", vim.api.nvim_get_current_line(), "entries after a failure must not execute")
  vim.keymap.del("n", "E")
end)

test("clear commands remove current or all buckets without resetting sequence", function()
  reset_history()
  atom_repeat.setup()
  local context = scope.resolve(fresh_buffer({ "x" }))
  store.add({ type = "motion", keys = "w" }, context)
  local sequence = state.sequence
  vim.cmd("AtomHistoryClear")
  truthy(not store.get(context.id, false), "current bucket should be cleared")

  store.add({ type = "motion", keys = "w" }, context)
  store.add({ type = "motion", keys = "w" }, {
    id = "other\0main",
    project = "other",
    branch = "main",
    buffer_display = "file",
  })
  vim.cmd("AtomHistoryClear!")
  eq(0, vim.tbl_count(state.buckets), "all buckets should be cleared")
  truthy(state.sequence > sequence, "sequence IDs should not reset")
  sleep(150)
end)

if #failures > 0 then
  print(("\n%d passed, %d failed"):format(passed, #failures))
  for _, failure in ipairs(failures) do
    print("\n" .. failure)
  end
  vim.cmd("cquit 1")
else
  print(("\n%d tests passed"):format(passed))
  vim.cmd("qa!")
end
end

vim.schedule(function()
  suite = coroutine.create(run_suite)
  local ok, err = coroutine.resume(suite)
  if not ok then
    print("fatal test runner error\n" .. tostring(err))
    vim.cmd("cquit 1")
  end
end)
