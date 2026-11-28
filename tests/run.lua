local atom_repeat = require("atom-repeat")
local dot = require("atom-repeat.dot")
local recipes = require("atom-repeat.recipes")
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
  if state.recipe_ui then
    require("atom-repeat.recipe_ui").close(false)
  end
  store.clear_all()
  recipes.clear_all()
  require("atom-repeat.input").reset()
  atom_repeat.invalidate_repeat()
  state.motion_run = { bucket_id = nil, count = 0 }
end

local function replay_group(value, label)
  return {
    atoms = { {
      seq = 1,
      atom = { type = "command", keys = value, cmd = label or value },
      context = { buffer_display = "test" },
      replay_kind = "keys",
      replay_value = value,
    } },
    created_at = os.time(),
    repeatable = true,
  }
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

test("public dot-repeat interface repeats Plug mappings and honors counts", function()
  local buffer = fresh_buffer({ "x" })
  vim.keymap.set("n", "<Plug>(AtomRepeatTestAppend)", function()
    local count = vim.v.count1
    vim.api.nvim_set_current_line(vim.api.nvim_get_current_line() .. string.rep("!", count))
    atom_repeat.set_repeat("<Plug>(AtomRepeatTestAppend)", { count = count })
  end)

  vim.api.nvim_feedkeys(vim.keycode("<Plug>(AtomRepeatTestAppend)"), "mx", false)
  eq("x!", vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1], "initial Plug action")
  vim.api.nvim_feedkeys(".", "mx", false)
  eq("x!!", vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1], "dot should repeat the registered action")
  vim.api.nvim_feedkeys("3.", "mx", false)
  eq("x!!!!!", vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1], "an explicit dot count should replace the default")
  eq("builtin", dot.backend(), "self-contained backend")

  vim.api.nvim_feedkeys(vim.keycode("A?<Esc>"), "nx", false)
  vim.api.nvim_feedkeys(".", "mx", false)
  eq("x!!!!!??", vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1], "another change should restore native dot")

  atom_repeat.invalidate_repeat()
  vim.keymap.del("n", "<Plug>(AtomRepeatTestAppend)")
end)

test("configuration is strict and setup is idempotent", function()
  local ok, err = pcall(atom_repeat.setup, { history_size = 0 })
  truthy(not ok and tostring(err):find("positive integer", 1, true), "invalid capacity should fail")
  ok, err = pcall(atom_repeat.setup, { unknown = true })
  truthy(not ok and tostring(err):find("unknown option", 1, true), "unknown keys should fail")
  ok, err = pcall(atom_repeat.setup, { max_consecutive_motions = -1 })
  truthy(not ok and tostring(err):find("non%-negative"), "negative motion limits should fail")
  ok, err = pcall(atom_repeat.setup, { dot = { ignore = { ["Q"] = true } } })
  truthy(not ok and tostring(err):find("list of key sequences", 1, true), "dot exclusions should be a list")
  ok, err = pcall(atom_repeat.setup, { dot = { join_delete_insert = "yes" } })
  truthy(not ok and tostring(err):find("boolean", 1, true), "joining edits requires a boolean")
  ok, err = pcall(atom_repeat.setup, { recipes = { max_items = 0 } })
  truthy(not ok and tostring(err):find("positive integer", 1, true), "invalid recipe limits should fail")
  ok, err = pcall(atom_repeat.setup, { recipes = { persist = "yes" } })
  truthy(not ok and tostring(err):find("boolean", 1, true), "invalid persistence flags should fail")
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

test("saved recipes deduplicate, trim, and persist binary keys", function()
  reset_history()
  local directory = vim.fn.tempname()
  local path = directory .. "/recipes.mpack"
  atom_repeat.setup({ recipes = { max_items = 2, persist = true, path = path } })
  local context = { id = "persist\0main", project = "persist", branch = "main" }
  local binary = "x\000" .. string.char(128) .. "y"
  recipes.add(context, replay_group("one", "one"))
  local binary_recipe = recipes.add(context, replay_group(binary, "binary"))
  recipes.add(context, replay_group("three", "three"))
  eq(2, #recipes.get_bucket(context.id).recipes, "recipe MRU limit")
  local duplicate = recipes.add(context, replay_group(binary, "binary"))
  eq(binary_recipe.id, duplicate.id, "identical recipes should reuse their identity")
  eq(2, #recipes.get_bucket(context.id).recipes, "deduplication should not grow the list")
  local named = replay_group("old")
  named.name = "keep"
  local named_id = recipes.add(context, named).id
  named = replay_group("new")
  named.name = "keep"
  eq(named_id, recipes.add(context, named).id, "replacement should retain its name and identity")
  recipes.add(context, replay_group("other"))
  recipes.add(context, replay_group(binary, "binary"))
  eq(3, #recipes.get_bucket(context.id).recipes, "the unnamed limit should not evict a named recording")
  truthy(vim.uv.fs_stat(path), "persistent recipe file should exist")

  state.recipe_buckets = {}
  state.recipes_loaded_path = nil
  state.next_recipe_id = 1
  atom_repeat.setup({ recipes = { max_items = 2, persist = true, path = path } })
  local loaded = recipes.first(context.id)
  eq(binary, loaded.atoms[1].replay_value, "MessagePack should preserve raw key bytes")
  eq(binary_recipe.id, loaded.id, "unnamed recipe identity should survive reload")
  eq("new", recipes.find(context.id, "keep").atoms[1].replay_value)
  eq(named_id, recipes.find(context.id, "keep").id, "named recipe identity should survive reload")

  atom_repeat.setup({ recipes = { persist = false } })
  vim.fn.delete(directory, "rf")
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
  eq("lhs", entry.replay_kind, "replay should run the mapping")
  eq("Q", entry.replay_value, "resolved keys must not replace the typed mapping")
  vim.keymap.del("n", "Q")
end)

test("dot repeats a mapped edit with its count, register and getchar payload", function()
  reset_history()
  fresh_buffer({ "x" })
  vim.keymap.set("n", "Q", function()
    local count, register = vim.v.count1, vim.v.register
    local char = vim.fn.getcharstr()
    vim.api.nvim_set_current_line(vim.api.nvim_get_current_line() .. (register .. char):rep(count))
  end)

  vim.api.nvim_input('"a3Q!.')
  wait_for(function()
    return vim.api.nvim_get_current_line() == "x" .. ("a!"):rep(6)
  end, "dot should repeat a preceding mapped edit even with queued input")
  eq('"a3Q!', current_bucket().entries[1].replay_value, "history retains the complete input")
  eq('"a3Q!', current_bucket().entries[2].replay_value, "history expands dot into the repeated input")

  vim.api.nvim_input('"b2.')
  wait_for(function()
    return vim.api.nvim_get_current_line() == "x" .. ("a!"):rep(6) .. "b!b!"
  end, "dot should honor an explicit count and register")
  vim.api.nvim_input("u.")
  wait_for(function()
    return #current_bucket().entries == 5
      and vim.api.nvim_get_current_line() == "x" .. ("a!"):rep(6) .. "b!b!"
  end, "dot should still repeat the mapped edit after undo")
  vim.keymap.del("n", "Q")
end)

test("undo and redo mappings remain in history without becoming the last edit", function()
  reset_history()
  local buf = fresh_buffer({ "x" })
  vim.keymap.set("n", "Q", function()
    vim.api.nvim_set_current_line(vim.api.nvim_get_current_line() .. "!")
  end, { buffer = buf })
  vim.keymap.set("n", "u", function() vim.cmd("undo") end, { buffer = buf })
  vim.keymap.set("n", "<C-r>", function() vim.cmd("redo") end, { buffer = buf })

  vim.api.nvim_input("Qu<C-r>")
  wait_for(function() return current_bucket() and #current_bucket().entries == 3 end)
  local bucket = current_bucket()
  eq("mapping", bucket.entries[2].atom.type, "undo should be an opaque mapping")
  eq("<C-R>", vim.fn.keytrans(bucket.entries[3].replay_value), "redo should remain in history")
  eq("Q", store.get_last_edit(bucket.id).replay_value)
  vim.api.nvim_input(".")
  wait_for(function() return vim.api.nvim_get_current_line() == "x!!" end)

  vim.api.nvim_input(":undo<CR>.")
  wait_for(function() return #bucket.entries == 6 end)
  eq("x!!", vim.api.nvim_get_current_line(), "Ex undo should also retain the mapped repeat")
  vim.api.nvim_input("g-g+.")
  wait_for(function() return #bucket.entries == 9 end)
  eq("x!!!", vim.api.nvim_get_current_line(), "moving across undo branches should retain the mapped repeat")
end)

test("configured dot exclusions keep an earlier edit even when native dot changes", function()
  reset_history()
  atom_repeat.setup({ dot = { ignore = { "x", "<C-L>" } } })
  local buf = fresh_buffer({ "one", "two", "three" })
  vim.keymap.set("n", "<C-l>", function()
    vim.api.nvim_set_current_line(vim.api.nvim_get_current_line() .. "?")
  end, { buffer = buf })
  vim.api.nvim_input("A!<Esc>j0x2<C-l>")
  wait_for(function() return current_bucket() and #current_bucket().entries == 5 end)
  eq("A!\027", store.get_last_edit(current_bucket().id).replay_value)
  eq({ "one!", "wo?", "three" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  vim.api.nvim_input("j0.")
  wait_for(function() return vim.api.nvim_get_current_line() == "three!" end)

  reset_history()
  buf = fresh_buffer({ "abc" })
  vim.api.nvim_input("x.")
  wait_for(function() return current_bucket() and #current_bucket().entries >= 1 end)
  eq("bc", vim.api.nvim_get_current_line(), "dot should skip an excluded first edit")
  atom_repeat.setup()
end)

test("a recorded dot keeps a skipped edit skipped during playback", function()
  reset_history()
  atom_repeat.setup({ dot = { ignore = { "x" } } })
  local buf = fresh_buffer({ "abc", "xyz" })
  vim.api.nvim_input("qax.qj0:AtomReplayLast<CR>")
  wait_for(function()
    return vim.api.nvim_win_get_cursor(0)[1] == 2 and vim.api.nvim_get_current_line() ~= "xyz"
      and state.replay_depth == 0
  end)
  eq({ "bc", "yz" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  atom_repeat.setup()
end)

test("opt-in dot joins adjacent delete operators with i across pauses and queued input", function()
  reset_history()
  atom_repeat.setup({ dot = { join_delete_insert = true } })
  local buf = fresh_buffer({ "one two", "abc def", "before", "after", "one two three", "alpha beta gamma" })
  vim.api.nvim_input("diw")
  wait_for(function() return current_bucket() and #current_bucket().entries == 1 end)
  vim.api.nvim_input("itest<Esc>j0.")
  wait_for(function() return vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "test def" end)
  local entries = current_bucket().entries
  eq("diw", entries[1].replay_value, "history retains the delete as a separate action")
  eq("itest\027", entries[2].replay_value, "history retains the insert as a separate action")
  eq("diwitest\027", entries[5].replay_value, "history expands dot to the complete pair")
  vim.api.nvim_input("j0d$iNEW<Esc>j0.")
  wait_for(function() return vim.api.nvim_buf_get_lines(buf, 3, 4, false)[1] == "NEW" end)
  eq({ "test two", "test def", "NEW", "NEW" }, vim.api.nvim_buf_get_lines(buf, 0, 4, false))
  vim.api.nvim_input('j0"adwiX<Esc>j0"b2.')
  wait_for(function() return vim.api.nvim_get_current_line() == "Xgamma" end)
  eq("alpha beta ", vim.fn.getreg("b"), "dot applies its count and register to the delete")
  atom_repeat.setup()
end)

test("joined dot keeps mapped delete, insert opener and exit keys", function()
  reset_history()
  atom_repeat.setup({ dot = { join_delete_insert = true } })
  local buf = fresh_buffer({ "remove", "one two", "remove this too", "abc def" })
  vim.keymap.set("n", "dd", function() vim.cmd.normal({ bang = true, args = { "dd" } }) end, { buffer = buf })
  vim.keymap.set("n", "i", function() return vim.api.nvim_get_current_line() == "" and "m`cc" or "m`i" end,
    { buffer = buf, expr = true })
  vim.keymap.set("i", "jj", "<Esc>", { buffer = buf })
  vim.api.nvim_input("ddinew jjj0.")
  wait_for(function() return vim.api.nvim_buf_line_count(buf) == 2 end)
  eq({ "new one two", "new abc def" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  eq("ddinew jj", current_bucket().entries[#current_bucket().entries].replay_value)
  atom_repeat.setup()
end)

test("joined dot recognizes delete operators inside a composite d mapping", function()
  reset_history()
  atom_repeat.setup({ dot = { join_delete_insert = true } })
  local buf = fresh_buffer({ "one two", "abc def" })
  vim.keymap.set("n", "d", "m`mvd", { buffer = buf })
  vim.api.nvim_input("diwitest<Esc>j0.")
  wait_for(function() return vim.api.nvim_get_current_line() == "test def" end)
  local entries = current_bucket().entries
  eq("mapping", entries[1].atom.type, "the marks and deletion form a mapping")
  eq("diwitest\027", entries[5].replay_value, "dot keeps the original d mapping")
  atom_repeat.setup()
end)

test("a motion breaks delete and insert grouping even when omitted from history", function()
  reset_history()
  atom_repeat.setup({ max_consecutive_motions = 0, dot = { join_delete_insert = true } })
  local buf = fresh_buffer({ "one two", "abc def" })
  vim.api.nvim_input("diwlitest<Esc>j0.")
  wait_for(function() return vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "testabc def" end)
  eq({ " testtwo", "testabc def" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  atom_repeat.setup()
end)

test("Insert replay preserves mapped opener, input and exit", function()
  reset_history()
  fresh_buffer({ "" })
  vim.keymap.set("n", "Q", "i")
  vim.keymap.set("i", "qq", function() return "foo" end, { expr = true })
  vim.keymap.set("i", "jj", "<Esc>")
  vim.api.nvim_input("Qqqjj")
  wait_for(function()
    local bucket = current_bucket()
    return bucket and #bucket.entries > 0
  end)
  eq("foo", vim.api.nvim_get_current_line())
  eq("Qqqjj", current_bucket().entries[1].replay_value, "history retains the original Insert keys")

  vim.keymap.set("i", "qq", "bar")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  atom_repeat.open()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.api.nvim_input("<CR>")
  wait_for(function()
    return vim.api.nvim_get_current_line() == "barfoo"
  end, "history replay should use the current Insert mapping")
  vim.keymap.del("n", "Q")
  vim.keymap.del("i", "qq")
  vim.keymap.del("i", "jj")
end)

test("a first-use operator mapping requeued by a loader is recorded in input order", function()
  reset_history()
  local buf = fresh_buffer({ "[one]", "[two]", "[three]" })
  local opts = { buffer = buf }
  vim.keymap.set("o", "ib", function()
    vim.keymap.set("o", "ib", "i]", opts)
    vim.api.nvim_feedkeys(vim.keycode("<Ignore>ib"), "i", false)
  end, { buffer = buf, expr = true })

  vim.api.nvim_input('"acibtest<Esc>j0:AtomReplayLast<CR>')
  wait_for(function()
    return vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "[test]"
  end, "replay should find the first edit even when the loader requeued the motion")
  local entries = current_bucket().entries
  eq(vim.keycode('"acibtest<Esc>'), entries[1].replay_value)
  eq("j", entries[2].replay_value, "later navigation should follow the recovered edit")
  eq(3, #entries, "the recovered edit should be recorded once")
  eq("two", vim.fn.getreg("a"), "the replay should preserve the explicit register")

  vim.api.nvim_input("j0.")
  wait_for(function()
    return vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1] == "[test]"
  end)
end)

test("remapped change keeps the text object read by a Vimscript expression", function()
  reset_history()
  local buf = fresh_buffer({ "[one]", "[two]", "'three'", '"four"' })
  local opts = { buffer = buf }
  vim.keymap.set("n", "c", "m`mvc", opts)
  vim.keymap.set("i", "jj", "<Esc>", opts)
  vim.cmd([[
    function! AtomRepeatTestReadObject() abort
      let g:atom_repeat_test_object = nr2char(getchar())
      return '@(atom-repeat-test-object)'
    endfunction
    function! AtomRepeatTestSelectObject() abort
      execute 'normal! vi' . (g:atom_repeat_test_object ==# 'b' ? ']' : getline('.')[0])
    endfunction
  ]])
  vim.keymap.set("o", "i", "AtomRepeatTestReadObject()", { buffer = buf, expr = true, remap = true })
  vim.keymap.set("o", "@(atom-repeat-test-object)", ":<C-U>call AtomRepeatTestSelectObject()<CR>", opts)

  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  vim.api.nvim_input("cibtest<Esc>")
  wait_for(function()
    return current_bucket() and #current_bucket().entries >= 1
  end)
  eq(vim.keycode("cibtest<Esc>"), current_bucket().entries[1].replay_value)
  vim.api.nvim_win_set_cursor(0, { 2, 1 })
  vim.api.nvim_input(":AtomReplayLast<CR>")
  wait_for(function() return vim.api.nvim_get_current_line() == "[test]" end)

  vim.api.nvim_win_set_cursor(0, { 3, 1 })
  vim.api.nvim_input("ciqtestjj")
  wait_for(function() return #current_bucket().entries >= 2 end)
  eq("ciqtestjj", current_bucket().entries[2].replay_value)
  vim.api.nvim_win_set_cursor(0, { 4, 1 })
  vim.api.nvim_input(".")
  wait_for(function() return vim.api.nvim_get_current_line() == '"test"' end)
  eq({ "[test]", "[test]", "'test'", '"test"' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))

  vim.cmd("delfunction AtomRepeatTestReadObject")
  vim.cmd("delfunction AtomRepeatTestSelectObject")
  vim.g.atom_repeat_test_object = nil
end)

test("remapped change preserves a Lua motion's prompt and mapped Insert exit", function()
  reset_history()
  local buf = fresh_buffer({ "one x tail", "two x tail" })
  local opts = { buffer = buf }
  vim.keymap.set("n", "c", "m`mvc", opts)
  vim.keymap.set("i", "jj", "<Esc>", opts)
  vim.keymap.set("o", "f", function()
    local target = vim.fn.getcharstr()
    vim.cmd.normal({ "vf" .. target, bang = true })
  end, opts)

  vim.api.nvim_input("cfxNEWjj")
  wait_for(function() return current_bucket() and #current_bucket().entries == 1 end)
  eq("cfxNEWjj", current_bucket().entries[1].replay_value)
  vim.api.nvim_input("j0.")
  wait_for(function() return vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "NEW tail" end)
end)

test("a lazy Normal-mode operator mapping keeps its original opener and payload", function()
  reset_history()
  local buf = fresh_buffer({ "one", "two" })
  local prior_operatorfunc = vim.go.operatorfunc
  _G.AtomRepeatTestOperator = function()
    local char = vim.fn.getcharstr()
    vim.api.nvim_set_current_line(vim.api.nvim_get_current_line() .. char)
  end
  vim.keymap.set("n", "<F12>", function()
    vim.keymap.set("n", "<F12>", function()
      vim.go.operatorfunc = "v:lua.AtomRepeatTestOperator"
      return "g@"
    end, { buffer = buf, expr = true })
    vim.api.nvim_feedkeys(vim.keycode("<Ignore><F12>"), "i", false)
  end, { buffer = buf, expr = true })

  vim.api.nvim_input("<F12>iw!")
  wait_for(function() return current_bucket() and #current_bucket().entries == 1 end)
  eq(vim.keycode("<F12>iw!"), current_bucket().entries[1].replay_value)
  vim.go.operatorfunc = ""
  vim.api.nvim_input("j0:AtomReplayLast<CR>")
  wait_for(function() return vim.api.nvim_get_current_line() == "two!" end)
  vim.go.operatorfunc = prior_operatorfunc
  _G.AtomRepeatTestOperator = nil
end)

test("CmdAtom explicitly unreplayable entries cannot run their lhs", function()
  reset_history()
  fresh_buffer()
  local context = scope.resolve(vim.api.nvim_get_current_buf())
  local entry = store.add({ type = "visual", lhs = "viw", keys = "" }, context)
  eq("unsupported", entry.replay_kind)
  eq(false, replay.validate({ entry }))
end)

test("opening history includes the preceding queued edit", function()
  reset_history()
  fresh_buffer({ "one two" })
  vim.api.nvim_input("dw:AtomHistory<CR>")
  wait_for(function()
    return state.ui ~= nil
  end)
  eq(1, #state.ui.entries)
  eq("dw", state.ui.entries[1].replay_value)
  vim.api.nvim_input("q")
  wait_for(function()
    return state.ui == nil
  end)
  eq(1, #current_bucket().entries, "history should not capture its commands")
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

test("callback mappings on navigation keys share the motion limit", function()
  reset_history()
  atom_repeat.setup({ max_consecutive_motions = 3 })
  fresh_buffer({ "x" })
  for _, key in ipairs({ "j", "k", "q" }) do
    vim.keymap.set("n", key, function() end)
  end

  for _, key in ipairs({ "j", "k", "k", "k", "k" }) do
    vim.api.nvim_input(key)
    sleep(20)
  end
  local bucket = current_bucket()
  eq(3, #bucket.entries, "callback navigation run should stop at three entries")
  eq({ "j", "k", "k" }, vim.tbl_map(function(entry)
    return entry.atom.lhs
  end, bucket.entries), "callback navigation prefix")

  vim.api.nvim_input("q")
  sleep(20)
  for _ = 1, 4 do
    vim.api.nvim_input("k")
    sleep(20)
  end
  eq(7, #current_bucket().entries, "a non-navigation callback should reset the run")
  eq("q", current_bucket().entries[4].atom.lhs, "resetting callback")

  for _, key in ipairs({ "j", "k", "q" }) do
    vim.keymap.del("n", key)
  end
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

test("history recipe supports Vim-style local cut and paste", function()
  reset_history()
  local context = scope.resolve(fresh_buffer({ "x" }))
  store.add({ type = "motion", cmd = "h", keys = "h" }, context)
  store.add({ type = "motion", cmd = "j", keys = "j" }, context)
  store.add({ type = "motion", cmd = "k", keys = "k" }, context)
  local bucket = current_bucket()
  local original = vim.tbl_map(function(entry)
    return entry.seq
  end, bucket.entries)
  vim.fn.setreg('"', "keep-me")

  atom_repeat.open()
  vim.api.nvim_input("gg2dd")
  wait_for(function()
    return state.ui and #state.ui.entries == 1
  end, "counted dd should cut two entries")
  eq({ original[3] }, vim.tbl_map(function(entry)
    return entry.seq
  end, state.ui.entries), "remaining recipe after dd")

  vim.api.nvim_input("2p")
  wait_for(function()
    return #state.ui.entries == 5
  end, "counted p should paste the local entry register twice")
  eq({ original[3], original[1], original[2], original[1], original[2] }, vim.tbl_map(function(entry)
    return entry.seq
  end, state.ui.entries), "pasted recipe order")
  eq(original, vim.tbl_map(function(entry)
    return entry.seq
  end, bucket.entries), "stored history must remain chronological")
  eq("keep-me", vim.fn.getreg('"'), "history edits must not touch Vim registers")
  require("atom-repeat.ui").close(false)
end)

test("AtomReplaySelect executes and persistently edits saved recipes", function()
  reset_history()
  atom_repeat.setup({ recipes = { max_items = 20, persist = false } })
  fresh_buffer({ "x" })
  local context = scope.resolve(vim.api.nvim_get_current_buf())
  local first = recipes.add(context, replay_group("A1\027", "append-one"))
  local second = recipes.add(context, replay_group("A2\027", "append-two"))
  atom_repeat.select()
  truthy(state.recipe_ui and #state.recipe_ui.items == 2, "recipe selector should open")
  truthy(vim.api.nvim_get_current_line():find("A2", 1, true), "MRU recipe should be first")
  vim.api.nvim_input(vim.keycode("<CR>"))
  wait_for(function()
    return state.recipe_ui == nil and vim.api.nvim_get_current_line() == "x2"
  end, "selected recipe should execute at the origin")
  eq(second.id, recipes.first(context.id).id, "executed recipe should remain MRU")

  vim.api.nvim_set_current_line("x")
  atom_repeat.replay_last()
  wait_for(function()
    return vim.api.nvim_get_current_line() == "x2"
  end, "ReplayLast should use the recipe run from the selector")

  atom_repeat.select()
  vim.fn.setreg('"', "keep-recipe-register")
  vim.api.nvim_input("dd")
  wait_for(function()
    return #recipes.get_bucket(context.id).recipes == 1
  end, "selector dd should delete from the recipe library")
  eq(first.id, recipes.first(context.id).id, "remaining recipe after selector dd")
  vim.api.nvim_input("p")
  wait_for(function()
    return #recipes.get_bucket(context.id).recipes == 2
  end, "selector p should restore a cut recipe")
  eq("keep-recipe-register", vim.fn.getreg('"'), "selector edits must not touch Vim registers")
  truthy(recipes.get_bucket(context.id).recipes[2].id ~= second.id, "pasted recipe should receive a new identity")
  require("atom-repeat.recipe_ui").close(false)

  vim.cmd("AtomReplayClear")
  truthy(not recipes.get_bucket(context.id), "AtomReplayClear should remove the current recipe bucket")
  recipes.add(context, replay_group("A3\027", "append-three"))
  recipes.add({ id = "other\0main", project = "other", branch = "main" }, replay_group("A4\027", "append-four"))
  vim.cmd("AtomReplayClear!")
  eq(0, vim.tbl_count(state.recipe_buckets), "AtomReplayClear! should remove every recipe bucket")
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
  local recipe_bucket = recipes.get_bucket(scope.resolve(origin).id)
  truthy(recipe_bucket and #recipe_bucket.recipes == 1, "successful history replay should save one recipe")
end)

test("insert atoms produced by replay and dot-repeat are not captured", function()
  reset_history()
  local origin = fresh_buffer({ "" })
  vim.api.nvim_input(vim.keycode("itest<Esc>"))
  wait_for(function()
    local bucket = current_bucket()
    return bucket and #bucket.entries == 1
  end, "initial insert should be captured")

  vim.api.nvim_buf_set_lines(origin, 0, -1, false, { "" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  atom_repeat.open()
  vim.api.nvim_input(vim.keycode("<CR>"))
  wait_for(function()
    return state.ui == nil and vim.api.nvim_get_current_line() == "test"
  end, "insert replay should execute")
  sleep(150)
  eq(1, #current_bucket().entries, "insert produced by replay should be suppressed")

  vim.api.nvim_input(".")
  wait_for(function()
    return vim.api.nvim_get_current_line() == "testestt"
  end, "dot should repeat the insert recipe")
  sleep(150)
  eq(1, #current_bucket().entries, "insert produced by dot-repeat should be suppressed")
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
  eq("lhs", entry.replay_kind, "lossy callback should use lhs")
  eq(nil, entry.atom.keys, "callback keys")

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
  vim.api.nvim_input(".")
  wait_for(function()
    return vim.api.nvim_get_current_line() == "x????"
  end, "dot should repeat the last Atom group with its stored count")
  sleep(150)
  eq(1, #current_bucket().entries, "Plug invocation should be suppressed")
  vim.keymap.del("n", "R")
  vim.keymap.del("n", "Q")
end)

test("retrospective recipes and mapped dots preserve typeahead order", function()
  reset_history()
  local buf = fresh_buffer({ "a", "b", "c", "d" })
  vim.keymap.set("n", "Q", function()
    vim.api.nvim_set_current_line(vim.api.nvim_get_current_line() .. "!")
  end, { buffer = buf })
  vim.api.nvim_input("Q.j:AtomRemember 3<CR>2.")
  wait_for(function() return vim.api.nvim_win_get_cursor(0)[1] == 4 end)
  eq({ "a!!", "b!!", "c!!", "d" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  eq(3, #current_bucket().last_group.atoms)
end)

test("AtomReplayLast runs keys queued by a replayed mapping without more input", function()
  reset_history()
  local buf = fresh_buffer({ "x" })
  vim.keymap.set("n", "<F8>", function()
    vim.schedule(function()
      vim.api.nvim_feedkeys("A!\027", "n", false)
    end)
  end, { buffer = buf })
  local context = scope.resolve(buf)
  store.add({ type = "mapping", lhs = vim.keycode("<F8>") }, context)
  store.set_last_group(context.id, { atoms = current_bucket().entries })

  vim.api.nvim_input(":AtomReplayLast<CR>")
  wait_for(function()
    return vim.api.nvim_get_current_line() == "x!"
  end, "the command and the mapping's queued edit should finish after Enter")
  eq(1, #current_bucket().entries, "the replay command should stay out of history")
end)

test("AtomReplayLast repeats a recent change without selecting or saving a recipe", function()
  reset_history()
  local buf = fresh_buffer({ "one", "two", "three" })
  local context = scope.resolve(buf)
  local saved = recipes.add(context, replay_group("yyp"))

  vim.api.nvim_input("ciwtest<Esc>j0:AtomReplayLast<CR>")
  wait_for(function()
    return vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "test"
  end, "a change followed by cursor movement should replay without a saved selection")
  eq({ "test", "test", "three" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  eq(nil, store.get_last_group(context.id), "a replay of the latest edit should not pin it")
  eq({ saved.id }, vim.tbl_map(function(recipe)
    return recipe.id
  end, recipes.get_bucket(context.id).recipes), "the saved recipe library should remain separate")

  vim.api.nvim_input("ciwnew<Esc>j0:AtomReplayLast<CR>")
  wait_for(function()
    return vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1] == "new"
  end, "the next edit should immediately become the replay target")
  eq({ "test", "new", "new" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
end)

test("AtomReplayLast finishes a plugin mapping with a pending prefix and no timeout", function()
  reset_history()
  local buf = fresh_buffer({ "line", "next" })
  local saved_timeout = vim.o.timeout
  local prefix = "<Plug>(AtomRepeatTestWait)"
  vim.keymap.set("n", prefix, function()
    vim.o.timeout = saved_timeout
  end, { buffer = buf })
  vim.keymap.set("n", prefix .. "<F6>", function() end, { buffer = buf })
  vim.keymap.set("n", "p", function()
    vim.o.timeout = false
    vim.api.nvim_feedkeys("p", "n", false)
    vim.api.nvim_feedkeys(vim.keycode(prefix), "m", false)
  end, { buffer = buf })

  local context = scope.resolve(buf)
  local yank = store.add({ type = "operator", lhs = "yy" }, context)
  local paste = store.add({ type = "mapping", lhs = "p" }, context)
  store.set_last_group(context.id, { atoms = { yank, paste } })
  vim.api.nvim_input(":AtomReplayLast<CR>")
  sleep(100)
  local finished = state.replay_depth == 0
  if not finished then
    vim.api.nvim_input("<Esc>")
  end
  truthy(finished, "replay should finish without a key to resolve the wait prefix")
  eq({ "line", "line", "next" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  eq(saved_timeout, vim.o.timeout, "the mapping should leave its waiting state")
end)

test("clear commands remove the active group without reviving a saved recipe", function()
  reset_history()
  local buf = fresh_buffer({ "line" })
  local context = scope.resolve(buf)
  local saved = recipes.add(context, replay_group("yyp"))
  store.ensure(context)
  store.set_last_group(context.id, saved)
  vim.cmd("AtomHistoryClear!")
  eq(saved.id, recipes.first(context.id).id, "history clear keeps the saved recipe available for selection")
  vim.api.nvim_input(":AtomReplayLast<CR>")
  sleep(50)
  eq({ "line" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))

  vim.cmd("AtomReplaySelect")
  vim.api.nvim_input("<CR>")
  wait_for(function()
    return store.get_last_group(context.id) ~= nil
  end)
  eq({ "line", "line" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  vim.cmd("AtomReplayClear")
  eq(nil, store.get_last_group(context.id), "recipe clear must remove the active selection as well")
  vim.api.nvim_input(":AtomReplayLast<CR>")
  sleep(50)
  eq({ "line", "line" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
end)

test("retrospective Insert capture keeps Lua prompt input across idle pauses", function()
  reset_history()
  local buf = fresh_buffer({ "x", "y" })
  vim.keymap.set("i", "<F7>", function()
    vim.fn.getchar(1) -- a peek must not duplicate the first consumed key
    local left = vim.fn.nr2char(vim.fn.getchar())
    local right = vim.fn.getcharstr()
    vim.api.nvim_put({ left .. right }, "c", false, true)
  end, { buffer = buf })
  vim.api.nvim_input("i")
  sleep(30)
  vim.api.nvim_input("<F7>(]一")
  sleep(30)
  vim.api.nvim_input("<Esc>")
  wait_for(function() return current_bucket() ~= nil end)
  eq(vim.keycode("i<F7>(]一<Esc>"), current_bucket().entries[1].replay_value)
  vim.api.nvim_input("j0.")
  wait_for(function() return vim.api.nvim_get_current_line() == "(]一y" end)
end)

test("recorded macro repeats Insert prompt input after its register is overwritten", function()
  reset_history()
  local buf = fresh_buffer({ "x", "y", "z" })
  vim.keymap.set("i", "<F6>", function()
    local suffix = vim.fn.getcharstr()
    vim.api.nvim_put({ suffix }, "c", false, true)
  end, { buffer = buf })
  vim.api.nvim_input("qai<F6>!一<Esc>q")
  wait_for(function() return current_bucket() and current_bucket().last_group ~= nil end)
  vim.fn.setreg("a", "dd")
  vim.api.nvim_input("j0.j0.")
  wait_for(function() return vim.api.nvim_get_current_line() == "!一z" end)
  eq({ "!一x", "!一y", "!一z" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
end)

test("named recording keeps prompt keys and removes the typed stop command", function()
  reset_history()
  local buf = fresh_buffer({ "one", "two", "three" })
  local context = scope.resolve(buf)
  vim.fn.setreg("z", { "keep this register" }, "V")
  local original = vim.fn.getreginfo("z")
  vim.keymap.set("n", "<F8>", function()
    local char = vim.fn.getcharstr()
    vim.api.nvim_set_current_line(vim.api.nvim_get_current_line() .. char)
  end, { buffer = buf })

  vim.api.nvim_input(":AtomRecordStart add-bang<CR><F8>!j:AtomRecordEnx<BS>d<CR>")
  wait_for(function() return recipes.find(context.id, "add-bang") ~= nil end)
  eq(vim.keycode("<F8>!j"), recipes.find(context.id, "add-bang").atoms[1].replay_value)
  eq(original, vim.fn.getreginfo("z"))
  eq({ "one!", "two", "three" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))

  store.clear_all()
  vim.api.nvim_input(":AtomReplay add-bang<CR>")
  wait_for(function() return vim.api.nvim_win_get_cursor(0)[1] == 3 end)
  eq({ "one!", "two!", "three" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  eq("add-bang", store.get_last_group(context.id).name)
end)

test("recording can be stopped from a mapping and cancelled without replacing a recipe", function()
  reset_history()
  local buf = fresh_buffer({ "one", "two" })
  local context = scope.resolve(buf)
  vim.keymap.set("n", "<F9>", "<Cmd>AtomRecordEnd<CR>", { buffer = buf })
  vim.fn.setreg("z", {})
  local original = vim.fn.getreginfo("z")
  vim.api.nvim_input(":AtomRecordStart append<CR>A!<Esc><F9>")
  wait_for(function() return recipes.find(context.id, "append") ~= nil end)
  eq(vim.keycode("A!<Esc>"), recipes.find(context.id, "append").atoms[1].replay_value)
  eq(original, vim.fn.getreginfo("z"))

  vim.api.nvim_input(":AtomRecordStart append<CR>A?<Esc>:AtomRecordCancel<CR>")
  wait_for(function() return vim.api.nvim_get_current_line() == "one!?" and vim.fn.reg_recording() == "" end)
  eq(vim.keycode("A!<Esc>"), recipes.find(context.id, "append").atoms[1].replay_value)
end)

test("recording status shows the name and unnamed recordings stay temporary", function()
  reset_history()
  local buf = fresh_buffer({ "one", "two", "three" })
  local context = scope.resolve(buf)
  eq("", atom_repeat.recording_status())

  vim.cmd("AtomRecordStart wrap%")
  eq("REC wrap%%", atom_repeat.recording_status(), "statusline rendering should escape names")
  vim.cmd("AtomRecordCancel")
  eq("", atom_repeat.recording_status())

  vim.cmd.normal({ bang = true, args = { "qa" } })
  eq("REC @a", atom_repeat.recording_status())
  vim.cmd.normal({ bang = true, args = { "q" } })
  eq("", atom_repeat.recording_status())

  vim.cmd("AtomRecordStart")
  eq("REC", atom_repeat.recording_status())
  vim.api.nvim_input("A!<Esc>:AtomRecordEnd<CR>")
  wait_for(function() return store.get_last_group(context.id) ~= nil end)
  eq("", atom_repeat.recording_status())
  eq(nil, recipes.first(context.id))
  vim.api.nvim_input("j0:AtomReplayLast<CR>")
  wait_for(function() return vim.api.nvim_get_current_line() == "two!" end)
  vim.keymap.set("n", "@@", atom_repeat.replay_temporary, { buffer = buf })
  vim.api.nvim_input("j02@@")
  wait_for(function() return vim.api.nvim_get_current_line() == "three!!" end)
  eq(nil, recipes.first(context.id), "repeating a temporary recording must not save it")

  vim.cmd("AtomHistoryClear")
  vim.fn.setreg("a", vim.keycode("A?<Esc>"))
  vim.api.nvim_input("@a2@@")
  wait_for(function() return vim.api.nvim_get_current_line() == "three!!???" end)
end)

test("one Lua mapping toggles recording without recording its own keys", function()
  reset_history()
  local buf = fresh_buffer({ "one", "two" })
  local context = scope.resolve(buf)
  vim.keymap.set("n", "<F10>", function()
    atom_repeat.toggle_recording("toggle-test")
  end, { buffer = buf })

  vim.api.nvim_input("<F10>")
  wait_for(function() return atom_repeat.recording_status() == "REC toggle-test" end)
  vim.api.nvim_input("A!<Esc><F10>")
  wait_for(function() return recipes.find(context.id, "toggle-test") ~= nil end)
  eq("", atom_repeat.recording_status())
  eq(vim.keycode("A!<Esc>"), recipes.find(context.id, "toggle-test").atoms[1].replay_value)
  vim.api.nvim_input("j0:AtomReplayLast<CR>")
  wait_for(function() return vim.api.nvim_get_current_line() == "two!" end)
  eq("", atom_repeat.recording_status())
end)

test("the history selection can be saved without executing it", function()
  reset_history()
  local buf = fresh_buffer({ "one", "two", "three" })
  vim.api.nvim_input("A!<Esc>j0:AtomHistory<CR>")
  wait_for(function() return state.ui ~= nil end)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.api.nvim_input("V2js")
  wait_for(function() return state.ui == nil end)
  eq({ "one!", "two", "three" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  eq(3, #store.get_last_group(scope.resolve(buf).id).atoms)

  vim.api.nvim_input(":AtomReplayLast<CR>")
  wait_for(function() return vim.api.nvim_win_get_cursor(0)[1] == 3 end)
  eq({ "one!", "two!", "three" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
end)

test("a recorded dot repeats the mapped action inside the macro", function()
  reset_history()
  local buf = fresh_buffer({ "a", "b", "c", "d" })
  vim.keymap.set("n", "Q", function()
    vim.api.nvim_set_current_line(vim.api.nvim_get_current_line() .. "!")
  end, { buffer = buf })
  vim.api.nvim_input("qaQj.qj.")
  wait_for(function() return vim.api.nvim_get_current_line() == "d!" end)
  eq({ "a!", "b!", "c!", "d!" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
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
