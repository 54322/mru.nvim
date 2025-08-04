local api, fn = vim.api, vim.fn

local M = {
  config = {
    max_history      = 10,
    ignore_filetypes = {},
    float = {
      width   = 0.5,
      height  = 0.4,
      row     = 0.3,
      col     = 0.25,
      border  = "rounded",
    },
  },
  items  = {},  -- MRU queue
  win_id = nil,
  buf_id = nil,
}

-- decide if we should track this buffer
local function should_track(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  -- skip unnamed buffers
  if name == "" then
    return false
  end
  -- skip any file in /private (or under it)
  if name:match("^/private/") then
    return false
  end
  -- now check your ignore_filetypes
  local ft = vim.api.nvim_buf_get_option(bufnr, "filetype")
  for _, ign in ipairs(M.config.ignore_filetypes) do
    if ft == ign then
      return false
    end
  end
  return true
end

-- bump file into MRU queue on BufEnter
function M.on_buf_enter(ev)
  local bufnr = ev.buf
  if not should_track(bufnr) then return end
  local fp = api.nvim_buf_get_name(bufnr)

  -- dedupe
  for i,f in ipairs(M.items) do
    if f == fp then
      table.remove(M.items, i)
      break
    end
  end

  -- push front & trim tail
  table.insert(M.items, 1, fp)
  if #M.items > M.config.max_history then
    M.items[#M.items] = nil
  end
end

-- wrap-around navigation
function M.cycle_next()
  if not (M.win_id and api.nvim_win_is_valid(M.win_id)) then return end
  local total = #M.items
  local cur   = api.nvim_win_get_cursor(M.win_id)[1]
  local nxt   = (cur == total) and 1 or (cur + 1)
  api.nvim_win_set_cursor(M.win_id, {nxt, 0})
end

function M.cycle_prev()
  if not (M.win_id and api.nvim_win_is_valid(M.win_id)) then return end
  local total = #M.items
  local cur   = api.nvim_win_get_cursor(M.win_id)[1]
  local prv   = (cur == 1) and total or (cur - 1)
  api.nvim_win_set_cursor(M.win_id, {prv, 0})
end

-- delete the entry under cursor
function M.delete_entry()
  if not (M.win_id and api.nvim_win_is_valid(M.win_id)) then return end
  local row = api.nvim_win_get_cursor(M.win_id)[1]
  table.remove(M.items, row)
  if #M.items == 0 then
    M.close_window()
  else
    M.update_window()
  end
end

-- open the floating window (or refresh)
function M.update_window()
  if not (M.win_id and api.nvim_win_is_valid(M.win_id)) then
    -- create scratch buffer
    M.buf_id = api.nvim_create_buf(false, true)
    api.nvim_buf_set_option(M.buf_id, "bufhidden", "wipe")

    -- compute float geometry
    local cfg = M.config.float
    local W = math.floor(vim.o.columns * cfg.width)
    local H = math.floor(vim.o.lines   * cfg.height)
    local R = math.floor((vim.o.lines  - H) * cfg.row)
    local C = math.floor((vim.o.columns - W) * cfg.col)

    -- open floating window
    M.win_id = api.nvim_open_win(M.buf_id, true, {
      relative = "editor",
      width    = W,
      height   = H,
      row      = R,
      col      = C,
      style    = "minimal",
      border   = cfg.border,
    })

    -- mappings inside the float:
    local buf = M.buf_id
    -- wrap-around Tab / Shift-Tab
    api.nvim_buf_set_keymap(buf, "n", "<Tab>",   "<Cmd>lua require('mru').cycle_next()<CR>",
      { nowait=true, silent=true, noremap=true })
    api.nvim_buf_set_keymap(buf, "n", "<S-Tab>", "<Cmd>lua require('mru').cycle_prev()<CR>",
      { nowait=true, silent=true, noremap=true })

    -- Enter or <Space> (leader) to open
    api.nvim_buf_set_keymap(buf, "n", "<CR>",    "<Cmd>lua require('mru').open_selection()<CR>",
      { nowait=true, silent=true, noremap=true })
    api.nvim_buf_set_keymap(buf, "n", "<Space>", "<Cmd>lua require('mru').open_selection()<CR>",
      { nowait=true, silent=true, noremap=true })

    -- dd to delete
    api.nvim_buf_set_keymap(buf, "n", "dd",
      "<Cmd>lua require('mru').delete_entry()<CR>",
      { nowait=true, silent=true, noremap=true })

    -- q/Esc to close
    api.nvim_buf_set_keymap(buf, "n", "q",    "<Cmd>lua require('mru').close_window()<CR>",
      { nowait=true, silent=true, noremap=true })
    api.nvim_buf_set_keymap(buf, "n", "<Esc>", "<Cmd>lua require('mru').close_window()<CR>",
      { nowait=true, silent=true, noremap=true })
  end

  -- populate buffer and position cursor
  api.nvim_buf_set_lines(M.buf_id, 0, -1, false, M.items)
  local start_line = (#M.items > 1) and 2 or 1
  api.nvim_win_set_cursor(M.win_id, {start_line, 0})
end

-- open selection and close
function M.open_selection()
  local line = api.nvim_get_current_line()
  M.close_window()
  vim.cmd("edit " .. fn.fnameescape(line))
end

-- close the float
function M.close_window()
  if M.win_id and api.nvim_win_is_valid(M.win_id) then
    api.nvim_win_close(M.win_id, true)
  end
  M.win_id = nil
  M.buf_id = nil
end

-- toggle float on/off
function M.toggle()
  if M.win_id and api.nvim_win_is_valid(M.win_id) then
    M.close_window()
  else
    if vim.tbl_isempty(M.items) then
      vim.notify("No recent files yet", vim.log.levels.INFO)
      return
    end
    M.update_window()
  end
end

-- clear history
function M.clear()
  M.items = {}
  M.close_window()
  vim.notify("Recent-files history cleared", vim.log.levels.INFO)
end

-- setup: wire up autocmd, keymap, command
function M.setup(user_cfg)
  if user_cfg then
    M.config = vim.tbl_deep_extend("force", M.config, user_cfg)
  end

  local grp = api.nvim_create_augroup("FileHistoryGroup", { clear = true })
  api.nvim_create_autocmd("BufEnter", {
    group    = grp,
    callback = M.on_buf_enter,
  })

  vim.keymap.set("n", "<leader><Tab>", M.toggle, {
    desc   = "MRU Files",
    silent = true,
  })

  api.nvim_create_user_command("ClearFileHistory", M.clear, {
    desc = "Clear the recent-files MRU list",
  })
end

return M
