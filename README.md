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

The plugin deliberately does not replace native dot-repeat. Map the provided
`<Plug>` target if a short repeat key is wanted:

```lua
vim.keymap.set("n", "g.", "<Plug>(AtomReplayLast)")
```

Counts are supported by the `<Plug>` mapping, so `3g.` replays the last group
three times. `:AtomReplayLast` always replays it once.

## Configuration

```lua
require("atom-repeat").setup({
  history_size = 500, -- entries retained per project/branch bucket
  max_buckets = 20,  -- least-recently-used bucket limit
  ui = {
    height = 12,     -- bottom split height
  },
})
```

Unknown options and non-positive integer values are errors. Calling `setup()`
again preserves history, replaces plugin-owned interfaces without duplication,
and immediately applies smaller capacity limits.

Commands:

| Command | Action |
| --- | --- |
| `:AtomHistory` | Open or refresh the current history snapshot |
| `:AtomReplayLast` | Replay the current bucket's last successful group once |
| `:AtomHistoryClear` | Clear the current project/branch bucket |
| `:AtomHistoryClear!` | Clear every bucket and saved replay group |

Public Lua API:

```lua
require("atom-repeat").open()
require("atom-repeat").replay_last()
```

Both functions require `setup()` to have run first.

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
external branch switch takes effect immediately. History and last replay groups
are memory-only and disappear when Neovim exits.

## Limitations

- A Lua callback or `<Cmd>` mapping can only be repeated by invoking its current
  LHS; direct API side effects cannot be converted into deterministic keys.
- Arbitrary Ex actions are replayed when explicitly selected, including actions
  with external or destructive side effects.
- Entry count is bounded, but individual payload size is not. Large insert or
  paste actions retain their complete `keys`, `text`, and structured metadata.
- Native `.` registration is not available through the current public Neovim
  API, so atom-repeat uses its own last-group backend.
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
