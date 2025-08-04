local api, fn = vim.api, vim.fn

local M = {
  config = {
    max_history     = 10,
    ignore_patterns = {},  -- gitignore-style patterns
    float = {
      width   = 0.6,
      height  = 0.5,
      border  = "rounded",
      title   = " Recent Files ",
    },
  },
  items  = {},  -- MRU queue
  win_id = nil,
  buf_id = nil,
}

-- convert gitignore-style pattern to lua pattern
local function pattern_to_lua(pattern)
  -- escape lua pattern characters except * and ?
  local escaped = pattern:gsub("[%(%)%.%+%-%^%$%%%[%]%{%}]", "%%%1")
  -- convert * to .* and ? to .
  escaped = escaped:gsub("%*", ".*"):gsub("%?", ".")
  return escaped
end

-- check if path matches any ignore pattern
local function matches_ignore_pattern(filepath)
  for _, pattern in ipairs(M.config.ignore_patterns) do
    local lua_pattern = pattern_to_lua(pattern)
    
    -- handle leading slash patterns (absolute from root)
    if pattern:match("^/") then
      if filepath:match("^" .. lua_pattern:sub(2)) then
        return true
      end
    else
      -- handle patterns that can match anywhere in path
      if filepath:match(lua_pattern) or 
         filepath:match("/" .. lua_pattern) or
         filepath:match("/" .. lua_pattern .. "/") then
        return true
      end
    end
  end
  return false
end

-- decide if we should track this buffer
local function should_track(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  -- skip unnamed buffers
  if name == "" then
    return false
  end
  
  -- check ignore patterns
  if matches_ignore_pattern(name) then
    return false
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

-- compute shortest unique paths for display
local function get_display_paths(filepaths)
  if #filepaths <= 1 then
    return vim.tbl_map(function(path) return vim.fn.fnamemodify(path, ":t") end, filepaths)
  end
  
  local display_paths = {}
  local basenames = {}
  
  -- group files by basename
  for i, filepath in ipairs(filepaths) do
    local basename = vim.fn.fnamemodify(filepath, ":t")
    if not basenames[basename] then
      basenames[basename] = {}
    end
    table.insert(basenames[basename], {index = i, path = filepath})
  end
  
  -- for each file, determine shortest unique path
  for basename, files in pairs(basenames) do
    if #files == 1 then
      -- unique basename, just show filename
      display_paths[files[1].index] = basename
    else
      -- multiple files with same basename, find shortest unique paths
      for _, file in ipairs(files) do
        local path_parts = vim.split(file.path, "/")
        local shortest_path = basename
        
        -- build path from right to left until unique
        for j = #path_parts - 1, 1, -1 do
          local candidate = table.concat(vim.list_slice(path_parts, j), "/")
          
          -- check if this candidate is unique among conflicting files
          local unique = true
          for _, other_file in ipairs(files) do
            if other_file.index ~= file.index then
              local other_parts = vim.split(other_file.path, "/")
              local other_candidate = table.concat(vim.list_slice(other_parts, j), "/")
              if candidate == other_candidate then
                unique = false
                break
              end
            end
          end
          
          if unique then
            shortest_path = candidate
            break
          end
        end
        
        display_paths[file.index] = shortest_path
      end
    end
  end
  
  return display_paths
end

-- update line indicators based on cursor position
function M.update_indicators()
  if not (M.win_id and api.nvim_win_is_valid(M.win_id)) then return end
  if not M.display_paths then return end
  
  local current_row = api.nvim_win_get_cursor(M.win_id)[1]
  local formatted_lines = {}
  
  for i, path in ipairs(M.display_paths) do
    local indicator = (i == current_row) and ">" or " "
    formatted_lines[i] = indicator .. " " .. path
  end
  
  api.nvim_buf_set_lines(M.buf_id, 0, -1, false, formatted_lines)
end

-- wrap-around navigation
function M.cycle_next()
  if not (M.win_id and api.nvim_win_is_valid(M.win_id)) then return end
  local total = #M.items
  local cur   = api.nvim_win_get_cursor(M.win_id)[1]
  local nxt   = (cur == total) and 1 or (cur + 1)
  api.nvim_win_set_cursor(M.win_id, {nxt, 0})
  M.update_indicators()
end

function M.cycle_prev()
  if not (M.win_id and api.nvim_win_is_valid(M.win_id)) then return end
  local total = #M.items
  local cur   = api.nvim_win_get_cursor(M.win_id)[1]
  local prv   = (cur == 1) and total or (cur - 1)
  api.nvim_win_set_cursor(M.win_id, {prv, 0})
  M.update_indicators()
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

    -- compute float geometry (centered)
    local cfg = M.config.float
    local W = math.floor(vim.o.columns * cfg.width)
    local H = math.floor(vim.o.lines   * cfg.height)
    local R = math.floor((vim.o.lines  - H) / 2)
    local C = math.floor((vim.o.columns - W) / 2)

    -- open floating window
    M.win_id = api.nvim_open_win(M.buf_id, true, {
      relative = "editor",
      width    = W,
      height   = H,
      row      = R,
      col      = C,
      style    = "minimal",
      border   = cfg.border,
      title    = cfg.title,
      title_pos = "center",
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
    
    -- update indicators on cursor movement
    api.nvim_create_autocmd("CursorMoved", {
      buffer = buf,
      callback = M.update_indicators,
    })
  end

  -- populate buffer with shortest unique paths and position cursor
  local display_paths = get_display_paths(M.items)
  M.display_paths = display_paths  -- store for updating indicators
  
  -- update display with indicators
  M.update_indicators()
  
  -- hide cursor completely for cleaner look
  vim.api.nvim_win_set_option(M.win_id, "cursorline", false)
  vim.api.nvim_win_set_option(M.win_id, "cursorcolumn", false)
  
  local start_line = (#M.items > 1) and 2 or 1
  api.nvim_win_set_cursor(M.win_id, {start_line, 0})
end

-- open selection and close
function M.open_selection()
  local row = api.nvim_win_get_cursor(M.win_id)[1]
  local filepath = M.items[row]
  M.close_window()
  vim.cmd("edit " .. fn.fnameescape(filepath))
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
