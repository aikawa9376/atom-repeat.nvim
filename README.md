# atom-repeat.nvim

`atom-repeat.nvim` turns Neovim's [`CmdAtom`](https://neovim.io/doc/user/autocmd.html#CmdAtom)
events into retrospective macros. Edit normally, open the recent action history,
and replay a selection at another cursor position. Input such as nvim-surround's
`ysiw)` runs through the current mappings, including the keys the plugin asked for.

Use `:AtomRemember 3` after three actions to make them a macro. Move to the next
target and press `.` to run all three, or `2.` to run the whole sequence twice.
Remembering the actions does not execute them.

If you explicitly record with `qa … q`, finishing the recording also makes
those keystrokes available to `.` and `:AtomReplayLast`. The plugin snapshots
the newly recorded bytes, so you can reuse register `a` afterward.

Use `:AtomRecordStart wrap` before editing and `:AtomRecordEnd` to save the
recording as `wrap`. You can play it back at another cursor position with
`:AtomReplay wrap` or `:AtomReplayLast`. Omit the name to keep the recording as
the active macro for this session. Replay it with `:AtomReplayLast` or `.`.
Names are single words and belong to the current project and branch.
Recording the same name again replaces that recipe when you save it.
`:AtomRecordCancel` discards the current recording.

Bind one key to start and finish an Atom recording.

```lua
local atom_repeat = require("atom-repeat")
vim.keymap.set("n", "<leader>qr", atom_repeat.toggle_recording)
```

`toggle_recording("wrap")` uses `wrap` as the recipe name when starting.

Bind `@@` to replay the active temporary recording. It runs native `@@`
when there is no active temporary recording.

```lua
vim.keymap.set("n", "@@", require("atom-repeat").replay_temporary)
```

Add this component to a lualine section such as `lualine_x`.

```lua
{ function() return require("atom-repeat").recording_status() end }
```

It shows `REC wrap` for a named recording, `REC` for a temporary recording,
and `REC @a` for a native recording in register `a`.

Recording starts at setup. The plugin keeps one row per completed action and
can also repeat a mapped edit with `.` without explicit registration by the
other plugin.

## Requirements

- A Neovim build that provides the `CmdAtom` event (currently a Neovim 0.13
  development feature).
- No runtime dependencies.

`setup()` reports an error immediately when `CmdAtom` is unavailable.

## Installation

Load the plugin as early as the history needs to begin. With lazy.nvim:

```lua
{
  "aikawa/atom-repeat.nvim",
  lazy = false,
  config = function()
    require("atom-repeat").setup()
  end,
}
```

Lazy-loading on `BufReadPost` is also supported; actions that happened before
`setup()` was called cannot be recovered:

```lua
{
  "aikawa/atom-repeat.nvim",
  event = "BufReadPost",
  config = function()
    require("atom-repeat").setup()
  end,
}
```

## Usage

1. Edit normally.
2. Put the cursor where the recorded actions should run.
3. Run `:AtomHistory`.
4. Press `<CR>` on one entry, or select a range of lines with `V` and press
   `<CR>`.

The history opens in a bottom horizontal split. Entries are shown oldest first,
and the cursor starts on the newest entry. Press `q` to close without replaying.

The snapshot can be edited with a history-local Vim-style register:

| Mapping | Action |
| --- | --- |
| `dd` / Visual `d` | Cut entries from the replay recipe |
| `yy` / Visual `y` | Copy entries |
| `p` / `P` | Paste entries after / before the cursor |
| `s` / Visual `s` | Save the current row or selection as a recipe |

Counts are supported, for example `3dd` and `2p`. These edits affect only the
open replay recipe and never touch Vim registers or the stored chronological
history. Close with `q` to discard them; `<CR>` replays the displayed order.

Press `.` after a captured mapped edit to run the mapping again. A count or
register supplied to `.` overrides the prefix of the original edit. Ordinary
edits still use Neovim's native dot repeat. After a history or saved-recipe
replay succeeds, `.` repeats that recipe and `3.` runs it three times.

Undo and redo keep the previous automatic repeat target. They stay available
in history. Add keys to `dot.ignore` to skip other actions when choosing the
automatic dot target or the latest edit for `:AtomReplayLast`.

Set `dot.join_delete_insert = true` to repeat a deletion immediately followed
by `i` as a single action with `.` or when `:AtomReplayLast` uses the latest
edit. For example, after `diwitest<Esc>`, move to
another word and press `.` to replace it with `test`. The same rule covers
deletions such as `dw`, `d$`, and `dd`. A motion or another action between
the deletion and insertion breaks the pair. A count or register given to dot
applies to the deletion. To replay the pair from history, select both rows.

Existing Normal-mode `.` mappings keep precedence. You can bind
`<Plug>(AtomRepeatDot)` to another key for automatic mapped-edit repeat.

The last replay is also available as a regular `<Plug>` target:

```lua
vim.keymap.set("n", "g.", "<Plug>(AtomReplayLast)")
```

Counts are supported by the `<Plug>` mapping, so `3g.` replays the last group
three times. `:AtomReplayLast` runs the active group once, or repeats the
latest captured edit when there is no active group. For example, type
`ciwtest<Esc>`, move to another word, and run `:AtomReplayLast`.

`:AtomReplaySelect` lists saved recipes. Use `:AtomRemember 1` to save the latest
history action. Running a saved recipe from the selector makes it the active
group.

Every successfully replayed history recipe is also saved in a per-project,
per-branch MRU library. Open it with `:AtomReplaySelect`; the newest recipe is
shown first. Press `<CR>` to run one at the cursor where the selector was
opened. The selector supports the same `dd`, `yy`, `p`, and `P` editing model,
and those library edits are persisted immediately.

## Configuration

```lua
require("atom-repeat").setup({
  capture_lua_prompts = true, -- include getchar/getcharstr input from Lua Insert mappings
  history_size = 500, -- entries retained per project/branch bucket
  max_buckets = 20,  -- least-recently-used bucket limit
  -- Keep all motions. Use 3 for the first three per run or 0 to omit them.
  max_consecutive_motions = false,
  dot = {
    ignore = {}, -- additional exact key sequences, e.g. { "<Leader>rf" }
    join_delete_insert = false,
  },
  recipes = {
    max_items = 20, -- unnamed recipes per project/branch
    persist = true,
    -- path = vim.fs.joinpath(vim.fn.stdpath("state"),
    --   "atom-repeat", "recipes.mpack"),
  },
  ui = {
    height = 12,     -- bottom split height
  },
})
```

Unknown options and invalid values are errors. Capacity and height must be
positive integers; the motion limit is a non-negative integer or `false`.
Calling `setup()` again preserves history, replaces plugin-owned interfaces
without duplication, and immediately applies smaller capacity limits.

`dot.ignore` accepts key notation such as `<F5>`. Each entry matches a
complete action with its leading count and register removed. Undo and redo
are excluded by default, including mappings on `u`, `U`, `<C-r>`, `g-`,
and `g+`, and Ex undo history commands.

Saved recipes use binary-safe MessagePack so raw key bytes survive a
restart. The file is atomically replaced at
`stdpath("state")/atom-repeat/recipes.mpack` by default. Set
`recipes.persist = false` for a session-only recipe library.

`h`, `j`, `k`, `l`, `w`, and `b` share one consecutive-motion run. A different
Atom resets the run. Single-key Lua callback mappings on those LHS keys count
as navigation too. Counts belong to one Atom, so `3j` consumes one slot.

Commands:

| Command | Action |
| --- | --- |
| `:AtomHistory` | Open or refresh the current history snapshot |
| `:AtomRemember [N]` | Save the last N history actions for dot repeat (default 1) |
| `:AtomRecordStart [name]` | Start an explicit recording |
| `:AtomRecordEnd` | Finish and activate the recording |
| `:AtomRecordCancel` | Discard the current recording |
| `:AtomReplay {name}` | Run a named recipe at the cursor |
| `:AtomReplayLast` | Replay the active group or latest captured edit once |
| `:AtomReplaySelect` | Select and execute a saved replay recipe |
| `:AtomReplayClear` | Clear the saved recipes and active group for the current project/branch |
| `:AtomReplayClear!` | Clear all saved recipes and active groups |
| `:AtomHistoryClear` | Clear the history and active group for the current project/branch |
| `:AtomHistoryClear!` | Clear all in-memory history and active groups |

Clearing history keeps the saved recipes available in `:AtomReplaySelect`.

Public Lua API:

```lua
require("atom-repeat").open()
require("atom-repeat").replay_last()
require("atom-repeat").select()
```

These history APIs require `setup()` to have run first.

Other plugins can use the same dot-repeat backend without depending on
vim-repeat. Register a replayable `<Plug>` mapping after it successfully changes
the buffer:

```lua
vim.keymap.set("n", "<Plug>(MyAction)", function()
  -- Make the change, honoring vim.v.count1 as appropriate.
  require("atom-repeat").set_repeat("<Plug>(MyAction)", {
    count = vim.v.count,
    register = vim.v.register, -- optional
  })
end)
```

`set_repeat(sequence, opts)` returns `false` when the dot backend cannot be
installed. `invalidate_repeat()` clears the registered plugin action. Call
`set_repeat()` after making the change, as the registration is tied to the
current buffer and its `changedtick`. This repeat-only API initializes lazily
and does not require the CmdAtom history setup. The lower-level standalone API
is also available as `require("atom-repeat.dot").setup()` and `.set()`.

If tpope/vim-repeat already owns `.`, atom-repeat reuses `repeat#set()` instead
of installing a second dispatcher. Other existing `.` mappings are preserved.

## Replay semantics

- Each captured top-level CmdAtom is one row. Macro recording controls are omitted. Composite `atoms` remain nested
  and are not flattened.
- Replay prefers the input (`lhs`) and enables mappings. `vim.on_key()` supplies
  typed prefixes and Insert-mode input when it can be matched to the atom.
  A changed mapping runs its current definition. A removed mapping is
  interpreted as ordinary input in the current mode.
- Resolved `keys` are fed without remapping when the atom has no input or
  represents a native dot repeat. Previously saved recipes keep their
  stored replay strategy.
- An explicit empty `keys` field marks an unreplayable action. Selecting such
  a row or one with no usable input rejects the whole selection. A runtime error
  stops the queue and any changes already made stay in the buffer.
- Replay starts in Normal mode at an extmark tracking the cursor position where
  history was opened. A Visual CmdAtom recreates its own selection from its
  stored resolved keys. An existing Visual selection is not substituted.
- Undo boundaries are whatever each replayed action normally creates.

History is partitioned by Git worktree and branch. Detached HEADs use the
commit ID. Non-Git buffers use the global working directory and a `nongit`
branch label. The worktree HEAD is checked for every captured Atom, so an
external branch switch takes effect immediately. Raw Atom history is
memory-only; successful replay recipes remain available across restarts when
persistence is enabled.

## Limitations

- Replay uses the current buffer, plugin state, and mappings. Terminal-mode
  input and edits completed later by an asynchronous callback have no reliable
  action boundary. With `capture_lua_prompts` enabled, setup wraps the Lua
  `vim.fn.getchar` and `vim.fn.getcharstr` functions to observe characters
  consumed by Insert mappings. Direct Vimscript calls and functions cached
  before setup can bypass these hooks. Explicit macro recording also captures
  prompt input through Neovim's own recorder.
- Arbitrary Ex actions are replayed when explicitly selected, including actions
  with external or destructive side effects.
- Entry count is bounded, but individual payload size is not. Large insert or
  paste actions retain their complete `keys`, `text`, and structured metadata.
- Neovim does not expose native redo registration, so dot integration uses a
  small vim-repeat-style dispatcher and a replayable `<Plug>` mapping.
- History is a snapshot while the split is open. Run `:AtomHistory` again to
  refresh it.

## Testing

The test suite uses only a CmdAtom-capable Neovim:

```sh
make test
make test NVIM=/path/to/nvim
```

## License

MIT
