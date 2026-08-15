local M = {}

local root_cache = {}

local function read_file(path)
  local fd = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local stat = vim.uv.fs_fstat(fd)
  local value = stat and vim.uv.fs_read(fd, stat.size, 0) or nil
  vim.uv.fs_close(fd)
  return value
end

local function global_cwd()
  local ok, cwd = pcall(vim.fn.getcwd, -1, -1)
  if not ok or cwd == "" then
    cwd = vim.uv.cwd()
  end
  return vim.fs.normalize(cwd or ".")
end

local function worktree_root(bufnr, name)
  local cached = root_cache[bufnr]
  if cached and cached.name == name then
    return cached.root
  end

  local root
  if name ~= "" then
    root = vim.fs.root(name, ".git")
    if root then
      root = vim.fs.normalize(root)
    end
  end
  root_cache[bufnr] = { name = name, root = root }
  return root
end

local function git_dir(root)
  local dotgit = root .. "/.git"
  local stat = vim.uv.fs_stat(dotgit)
  if not stat then
    return nil
  end
  if stat.type == "directory" then
    return dotgit
  end

  local contents = read_file(dotgit)
  local path = contents and contents:match("^gitdir:%s*(.-)%s*$")
  if not path then
    return nil
  end
  if not vim.startswith(path, "/") then
    path = vim.fs.dirname(dotgit) .. "/" .. path
  end
  return vim.fs.normalize(path)
end

local function head_identity(root)
  local dir = git_dir(root)
  local head = dir and read_file(dir .. "/HEAD") or nil
  head = head and vim.trim(head) or "unknown"
  local ref = head:match("^ref:%s*(.+)$")
  if ref then
    return ref:match("^refs/heads/(.+)$") or ref
  end
  return head ~= "" and head or "unknown"
end

local function relative_path(name, root)
  if name == "" then
    return "[No Name]"
  end
  local normalized = vim.fs.normalize(name)
  local prefix = root .. "/"
  if vim.startswith(normalized, prefix) then
    return normalized:sub(#prefix + 1)
  end
  return vim.fs.basename(normalized)
end

function M.resolve(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or ""
  local root = worktree_root(bufnr, name)
  local branch
  local is_git = root ~= nil
  if is_git then
    branch = head_identity(root)
  else
    root = global_cwd()
    branch = "nongit"
  end

  return {
    id = root .. "\0" .. branch,
    project = root,
    branch = branch,
    is_git = is_git,
    bufnr = bufnr,
    buffer_name = name,
    buffer_display = relative_path(name, root),
  }
end

function M.clear_cache(bufnr)
  if bufnr then
    root_cache[bufnr] = nil
  else
    root_cache = {}
  end
end

return M
