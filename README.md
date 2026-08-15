# atom-repeat.nvim

`atom-repeat.nvim` turns Neovim's semantic [`CmdAtom`](https://neovim.io/doc/user/autocmd.html#CmdAtom)
events into retrospective macros. Edit normally, open the recent action history,
select the useful part, and replay it at the cursor where you opened the history.

Unlike a traditional macro, recording does not have to be started in advance.
The plugin stores resolved action keys and structured CmdAtom metadata, not a
raw stream of keystrokes.

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

Counts are supported, for example `3dd` and `2p`. These edits affect only the
open replay recipe and never touch Vim registers or the stored chronological
history. Close with `q` to discard them; `<CR>` replays the displayed order.

After a history or saved-recipe replay succeeds, pressing `.` repeats that replay.
An explicit count replaces the stored count, so `3.` runs the recipe three
times. The plugin's dot handler falls back to Neovim's native `.` after another
change. If normal-mode `.` already has a user mapping, atom-repeat leaves it
untouched and reports that its dot backend is disabled.

The last replay is also available as a regular `<Plug>` target:

```lua
vim.keymap.set("n", "g.", "<Plug>(AtomReplayLast)")
```

Counts are supported by the `<Plug>` mapping, so `3g.` replays the last group
three times. `:AtomReplayLast` always replays it once.

Every successfully replayed history recipe is also saved in a per-project,
per-branch MRU library. Open it with `:AtomReplaySelect`; the newest recipe is
shown first. Press `<CR>` to run one at the cursor where the selector was
opened. The selector supports the same `dd`, `yy`, `p`, and `P` editing model,
and those library edits are persisted immediately.

## Configuration

```lua
require("atom-repeat").setup({
  history_size = 500, -- entries retained per project/branch bucket
  max_buckets = 20,  -- least-recently-used bucket limit
  -- Keep the first 3 atoms in a consecutive h/j/k/l/w/b run.
  -- Use false for unlimited history, or 0 to omit these motions.
  max_consecutive_motions = 3,
  recipes = {
    max_items = 20, -- saved recipes per project/branch
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

Saved recipes use binary-safe MessagePack so resolved raw key bytes survive a
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
| `:AtomReplayLast` | Replay the current bucket's last successful group once |
| `:AtomReplaySelect` | Select and execute a saved replay recipe |
| `:AtomReplayClear` | Delete saved recipes for the current project/branch |
| `:AtomReplayClear!` | Delete every saved recipe |
| `:AtomHistoryClear` | Clear the current project/branch bucket |
| `:AtomHistoryClear!` | Clear every in-memory Atom history bucket |

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

- Every top-level CmdAtom is one history row. Composite `atoms` remain nested
  and are not flattened.
- Non-empty resolved `keys` are fed without remapping. When `keys` is empty and
  `lhs` is available (for example, a Lua callback mapping), `lhs` is fed with
  current mappings enabled.
- Consequently, a changed callback mapping runs its current callback. If the
  mapping was removed, the LHS is interpreted as normal input in the current
  mode.
- A selection containing an entry with neither `keys` nor `lhs` is rejected
  before any action runs. Runtime errors stop the remaining queue; earlier
  changes are not rolled back.
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

- A Lua callback or `<Cmd>` mapping can only be repeated by invoking its current
  LHS; direct API side effects cannot be converted into deterministic keys.
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
