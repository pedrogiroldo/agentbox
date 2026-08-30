-- Git worktree switcher.
--
-- snacks.nvim ships no worktree source of its own (grep for "worktree" in it
-- returns nothing), and the rule for this config is "no new plugins", so this
-- builds a custom snacks.picker source instead of pulling one in.
local M = {}

-- After switching, reopen the same relative file in the new worktree when it
-- exists there. Set to false to only change the working directory.
M.follow_file = true

---Run git and return trimmed stdout, or nil plus the error message.
---@param args string[]
---@param cwd? string
---@return string?, string?
local function git(args, cwd)
  local res = vim.system(vim.list_extend({ "git" }, args), { cwd = cwd, text = true }):wait()
  if res.code ~= 0 then
    return nil, vim.trim(res.stderr or "git failed")
  end
  return vim.trim(res.stdout or "")
end

---Root of the worktree the current directory belongs to.
---@return string?
function M.root()
  local out = git({ "rev-parse", "--show-toplevel" }, vim.fn.getcwd())
  return out and out ~= "" and vim.fs.normalize(out) or nil
end

---Deepest directory containing every worktree, used to keep the paths shown in
---the picker short. Worktrees are usually siblings, so this is normally their
---shared parent and each entry renders as just its directory name.
---@param list WorktreeEntry[]
---@return string?
function M.common_parent(list)
  local prefix ---@type string?
  for _, wt in ipairs(list) do
    local dir = vim.fs.dirname(wt.path)
    if not prefix then
      prefix = dir
    else
      while prefix ~= "/" and prefix ~= "." and dir ~= prefix and dir:sub(1, #prefix + 1) ~= prefix .. "/" do
        prefix = vim.fs.dirname(prefix)
      end
    end
  end
  return (prefix ~= "/" and prefix ~= ".") and prefix or nil
end

---@param path string
---@param base string?
---@return string
function M.shorten(path, base)
  if base and path:sub(1, #base + 1) == base .. "/" then
    return path:sub(#base + 2)
  end
  return vim.fn.fnamemodify(path, ":~")
end

---@class WorktreeEntry
---@field path string
---@field head? string
---@field branch? string
---@field detached? boolean
---@field bare? boolean
---@field locked? boolean
---@field prunable? boolean

---Parse `git worktree list --porcelain`.
---@return WorktreeEntry[]?, string?
function M.list()
  local out, err = git({ "worktree", "list", "--porcelain" }, vim.fn.getcwd())
  if not out then
    return nil, err
  end

  local list, cur = {}, nil ---@type WorktreeEntry[], WorktreeEntry?
  for line in (out .. "\n"):gmatch("([^\n]*)\n") do
    local key, val = line:match("^(%S+)%s*(.*)$")
    if key == "worktree" then
      cur = { path = vim.fs.normalize(val) }
      list[#list + 1] = cur
    elseif cur and key == "HEAD" then
      cur.head = val
    elseif cur and key == "branch" then
      cur.branch = (val:gsub("^refs/heads/", ""))
    elseif cur and key == "detached" then
      cur.detached = true
    elseif cur and key == "bare" then
      cur.bare = true
    elseif cur and key == "locked" then
      cur.locked = true
    elseif cur and key == "prunable" then
      cur.prunable = true
    end
  end
  return list
end

---Switch the working directory to `wt`, optionally carrying the current file over.
---@param wt WorktreeEntry
function M.switch(wt)
  local from = M.root()
  if from == wt.path then
    return
  end

  -- Work out the current file's path relative to the worktree we're leaving,
  -- before the cd changes what is relative to what.
  local rel ---@type string?
  if M.follow_file and from then
    local buf = vim.api.nvim_get_current_buf()
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.bo[buf].buftype == "" and name ~= "" then
      local path = vim.fs.normalize(name)
      if path:sub(1, #from + 1) == from .. "/" then
        rel = path:sub(#from + 2)
      end
    end
  end

  vim.cmd.cd(vim.fn.fnameescape(wt.path))

  local carried ---@type string?
  if rel then
    local target = wt.path .. "/" .. rel
    if vim.uv.fs_stat(target) then
      vim.cmd.edit(vim.fn.fnameescape(target))
      carried = rel
    end
  end

  local label = wt.branch or (wt.head and wt.head:sub(1, 7)) or vim.fn.fnamemodify(wt.path, ":t")
  Snacks.notify(("Worktree: **%s**\n`%s`%s"):format(label, wt.path, carried and ("\n→ " .. carried) or ""), {
    title = "Worktree",
    level = vim.log.levels.INFO,
  })
end

---Snacks picker source definition, registered under `sources.git_worktrees`.
---@return snacks.picker.Config
function M.source()
  return {
    finder = function()
      local list = M.list()
      if not list then
        return {}
      end
      local root = M.root()
      local base = M.common_parent(list)
      local items = {}
      for _, wt in ipairs(list) do
        local label = wt.branch or (wt.detached and "detached") or vim.fn.fnamemodify(wt.path, ":t")
        items[#items + 1] = {
          text = label .. " " .. wt.path, -- what the matcher searches
          file = wt.path, -- lets preview = "directory" and <c-y> work
          dir = true,
          wt = wt,
          label = label,
          short = M.shorten(wt.path, base),
          current = root ~= nil and wt.path == root,
        }
      end
      return items
    end,

    format = function(item)
      local wt = item.wt
      local ret = {}
      ret[#ret + 1] = { item.current and "● " or "  ", "SnacksPickerGitBranchCurrent" }
      ret[#ret + 1] = {
        item.label,
        wt.detached and "SnacksPickerGitDetached" or "SnacksPickerGitBranch",
      }
      if wt.detached and wt.head then
        ret[#ret + 1] = { " " .. wt.head:sub(1, 7), "SnacksPickerGitCommit" }
      end
      ret[#ret + 1] = { " " }
      ret[#ret + 1] = { item.short, "SnacksPickerDir" }
      for _, flag in ipairs({ wt.bare and "bare", wt.locked and "locked", wt.prunable and "prunable" }) do
        ret[#ret + 1] = { " " .. flag, "SnacksPickerDimmed" }
      end
      return ret
    end,

    preview = "directory",
    confirm = function(picker, item)
      picker:close()
      if item then
        M.switch(item.wt)
      end
    end,
    -- Land on the list, not the search box: fewer keystrokes, and on a phone it
    -- avoids raising the software keyboard just to pick from four entries.
    focus = "list",
    layout = { preset = "select" },
  }
end

---Open the worktree picker.
function M.pick()
  -- Check up front rather than opening an empty picker on top of git's raw
  -- "fatal: not a git repository" text.
  local list, err = M.list()
  if not list then
    local msg = (err or ""):match("not a git repository") and "Not inside a git repository" or err
    return Snacks.notify.warn(msg or "Could not list worktrees", { title = "Worktree" })
  end
  if #list == 1 then
    return Snacks.notify.info("Only one worktree: **" .. (list[1].branch or "detached") .. "**", { title = "Worktree" })
  end
  Snacks.picker.pick({ source = "git_worktrees", title = "Git Worktrees" })
end

return M
