local ok, mru = pcall(require, 'mru')
if not ok then
  vim.notify('mru.nvim: could not load module', vim.log.levels.ERROR)
  return
end

mru.setup()
