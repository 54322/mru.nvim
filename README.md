# mru.nvim

A simple Most Recently Used (MRU) file tracker for Neovim with optional persistent storage.

## Configuration

```lua
require("mru").setup {
  max_history     = 10,           -- maximum number of files to track
  ignore_patterns = { "*.tmp" },  -- gitignore-style patterns to ignore
  persistent = {
    enabled        = false,       -- enable persistent storage (opt-in)
    save_on_change = true,        -- auto-save when MRU list changes
    global_list    = false,       -- false = per-project, true = global across all projects
  },
  float = {
    width   = 0.6,               -- float window width ratio
    height  = 0.5,               -- float window height ratio
    border  = "rounded",         -- border style
    title   = " Recent Files ",  -- window title
  },
}
```

## Persistent Storage

When `persistent.enabled = true`, the plugin will:
- Store your MRU list in `~/.local/share/nvim/mru.json`
- Persist data between Neovim sessions
- Support per-project storage (default) or global storage across all projects
- Automatically save changes when files are opened/removed (if `save_on_change = true`)
- Filter out non-existent files when loading from storage

## Usage

- `<leader><Tab>` - Toggle MRU file picker
- `:ClearFileHistory` - Clear the MRU list
