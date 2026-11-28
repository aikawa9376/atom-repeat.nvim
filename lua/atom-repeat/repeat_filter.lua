local input = require("atom-repeat.input")
local state = require("atom-repeat.state")

local M = {}

local undo_keys = { u = true, U = true, ["<C-R>"] = true, ["g-"] = true, ["g+"] = true }
local undo_commands = { undo = true, redo = true, earlier = true, later = true }

function M.body(entry)
  local keys = entry.replay_kind == "lhs" and entry.replay_value or entry.atom.lhs or ""
  local _, _, body = input.prefix(keys)
  return body
end

local function undo_atom(atom)
  if atom.type == "normal" and undo_keys[atom.cmd] then
    return true
  end
  if atom.type == "excmd" and atom.text then
    local ok, command = pcall(vim.api.nvim_parse_cmd, atom.text, {})
    return ok and command.nextcmd == "" and undo_commands[command.cmd]
  end
  -- Mappings such as undo followed by a cursor move can have multiple children.
  local found = false
  for _, child in ipairs(atom.atoms or {}) do
    if child.changed then
      if not undo_atom(child) then
        return false
      end
      found = true
    end
  end
  return found
end

function M.skip(entry)
  -- Ctrl keys can arrive either as a control byte or as a modifier keycode.
  local body = vim.fn.keytrans(M.body(entry))
  if undo_keys[body] or undo_atom(entry.atom) then
    return "undo"
  end
  if state.config.dot.ignore[body] then
    return "ignored"
  end
end

return M
