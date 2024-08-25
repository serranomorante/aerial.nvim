local callbacks = require("aerial.backends.coc.callbacks")
local util = require("aerial.backends.util")

local M = {}

M.is_supported = function(bufnr)
  if not bufnr or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end

  if vim.g.coc_service_initialized == 0 then
    return false, "COC has not been initialized"
  end

  local ok, val = pcall(vim.api.nvim_buf_get_var, bufnr or 0, "coc_enabled")
  if not ok or val == 0 then
    return false, "COC has been disabled for this buffer."
  end

  local response
  vim.fn.CocActionAsync("hasProvider", "documentSymbol", function(err, result)
    response = { err = err, result = result }
  end)

  local wait_result = vim.wait(1000, function()
    return response ~= nil and response ~= vim.NIL
  end, 10)

  if wait_result then
    if response.err ~= nil and response.err ~= vim.NIL then
      vim.notify(
        string.format("Error requesting document symbols: %s", response.err),
        vim.log.levels.WARN
      )
    else
      return response.result == true
    end
  else
    vim.notify("Timeout when requesting document symbols", vim.log.levels.WARN)
  end
end

M.fetch_symbols = function(bufnr)
  if not bufnr or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  vim.fn.CocActionAsync("documentSymbols", bufnr, function(error, results)
    callbacks.symbol_callback(error, results, { bufnr = bufnr })
  end)
end

M.fetch_symbols_sync = function(bufnr, opts)
  if not bufnr or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  opts = vim.tbl_extend("keep", opts or {}, {
    timeout = 4000,
  })

  local response
  vim.fn.CocActionAsync("documentSymbols", bufnr, function(error, symbols)
    response = symbols
  end)

  local wait_result = vim.wait(opts.timeout, function()
    return response ~= nil and response ~= vim.NIL
  end, 10)

  -- if not request_success then
  --   vim.notify("Error requesting document symbols", vim.log.levels.WARN)
  -- end

  if wait_result then
    -- if response.err then
    --   vim.notify(
    --     string.format("Error requesting document symbols: %s", response.err),
    --     vim.log.levels.WARN
    --   )
    -- else
    callbacks.handle_symbols(response, bufnr)
    -- end
  else
    vim.notify("Timeout when requesting document symbols", vim.log.levels.WARN)
  end
end

M.attach = function(bufnr)
  util.add_change_watcher(bufnr, "coc")
end

M.detach = function(bufnr)
  util.remove_change_watcher(bufnr, "coc")
end

return M
