local backends = require("aerial.backends")
local config = require("aerial.config")
-- local data = require("aerial.data")

local M = {}

local function convert_symbols(result)
  local s = {}
  -- local kinds_index = require("outline.symbols").str_to_kind
  -- rebuild coc.nvim symbol list hierarchy according to the 'level' key
  for _, value in pairs(result) do
    value.children = {}
    value.kind = value.kind
    if #s == 0 then
      table.insert(s, value)
      goto continue
    end
    if value.level == s[#s].level then
      if value.level == 0 then
        table.insert(s, value)
        goto continue
      end
      local tmp = s[#s]
      table.remove(s)
      table.insert(s[#s].children, tmp)
      table.insert(s, value)
    elseif value.level == s[#s].level + 1 then
      table.insert(s[#s].children, value)
    elseif value.level == s[#s].level + 2 then
      local tmp = s[#s].children[#s[#s].children]
      table.remove(s[#s].children)
      table.insert(s, tmp)
      table.insert(s[#s].children, value)
    elseif value.level < s[#s].level then
      while value.level < s[#s].level do
        local tmp = s[#s]
        table.remove(s)
        table.insert(s[#s].children, tmp)
      end
      if s[#s].level ~= 0 then
        local tmp = s[#s]
        table.remove(s)
        table.insert(s[#s].children, tmp)
        table.insert(s, value)
      else
        table.insert(s, value)
      end
    end
    ::continue::
  end
  local top = s[#s]
  while top and top.level ~= 0 do
    table.remove(s)
    table.insert(s[#s].children, top)
    top = s[#s]
  end
  return s
end

local function get_symbol_kind_name(kind_number)
  return vim.lsp.protocol.SymbolKind[kind_number] or "Unknown"
end

local function convert_range(range)
  if not range then
    return nil
  end
  return {
    lnum = range.start.line + 1,
    col = range.start.character,
    end_lnum = range["end"].line + 1,
    end_col = range["end"].character,
  }
end

local function symbols_at_same_position(a, b)
  if a.lnum ~= b.lnum or a.col ~= b.col then
    return false
  elseif type(a.selection_range) ~= type(b.selection_range) then
    return false
  elseif a.selection_range then
    if
      a.selection_range.lnum ~= b.selection_range.lnum
      or a.selection_range.col ~= b.selection_range.col
    then
      return false
    end
  end
  return true
end

---@param symbols table
---@param bufnr integer
local function process_symbols(symbols, bufnr)
  local include_kind = config.get_filter_kind_map(bufnr)
  local max_line = vim.api.nvim_buf_line_count(bufnr)
  local function _process_symbols(symbols_, parent, list, level)
    for _, symbol in ipairs(symbols_) do
      local kind = symbol.kind
      local range
      if symbol.location then -- SymbolInformation type
        range = symbol.location.range
      elseif symbol.range then -- DocumentSymbol type
        range = symbol.range
      end
      local include_item = range and include_kind[kind]

      -- Check symbol.name because some LSP servers return a nil name
      if include_item and symbol.text then
        local name = symbol.text
        -- Some LSP servers return multiline symbols with newlines
        local nl = string.find(symbol.text, "\n")
        if nl then
          name = string.sub(name, 1, nl - 1)
        end
        local item = vim.tbl_deep_extend("error", {
          kind = kind,
          name = name,
          level = level,
          parent = parent,
          selection_range = convert_range(symbol.selectionRange),
        }, convert_range(range))
        -- Some language servers give number values that are wildly incorrect
        -- See https://github.com/stevearc/aerial.nvim/issues/101
        item.end_lnum = math.min(item.end_lnum, max_line)

        -- if fix_start_col then
        --   -- If the start col is off the end of the line, move it to the start of the line
        --   local line = vim.api.nvim_buf_get_lines(bufnr, item.lnum - 1, item.lnum, false)[1]
        --   if line and item.col >= vim.api.nvim_strwidth(line) then
        --     item.col = line:match("^%s*"):len()
        --   end
        -- end

        -- Skip this symbol if it's in the same location as the last one.
        -- This can happen on C++ macros
        -- (see https://github.com/stevearc/aerial.nvim/issues/13)
        local last_item = vim.tbl_isempty(list) and {} or list[#list]
        if not symbols_at_same_position(last_item, item) then
          if symbol.children then
            item.children = _process_symbols(symbol.children, item, {}, level + 1)
          end
          if
            not config.post_parse_symbol
            or config.post_parse_symbol(bufnr, item, {
                backend_name = "coc",
                lang = "undefined",
                symbols = symbols,
                symbol = symbol,
              })
              ~= false
          then
            table.insert(list, item)
          end
        elseif symbol.children then
          -- If this duplicate symbol has children (unlikely), make sure those get
          -- merged into the previous symbol's children
          last_item.children = last_item.children or {}
          vim.list_extend(
            last_item.children,
            _process_symbols(symbol.children, last_item, {}, level + 1)
          )
        end
      elseif symbol.children then
        _process_symbols(symbol.children, parent, list, level)
      end
    end
    table.sort(list, function(a, b)
      a = a.selection_range and a.selection_range or a
      b = b.selection_range and b.selection_range or b
      if a.lnum == b.lnum then
        return a.col < b.col
      else
        return a.lnum < b.lnum
      end
    end)
    return list
  end

  return _process_symbols(symbols, nil, {}, 0)
end

M.handle_symbols = function(result, bufnr)
  local symbols = process_symbols(convert_symbols(result), bufnr)
  backends.set_symbols(
    bufnr,
    symbols,
    { backend_name = "coc", symbols = symbols, lang = "undefined" }
  )
end

local results = {}
M.symbol_callback = function(_err, result, context)
  if not result or result == vim.NIL then
    return
  end
  local bufnr = context.bufnr
  -- Don't update if there are diagnostics errors, unless config option is set
  -- or we have no symbols for this buffer
  -- if
  -- not config.lsp.update_when_errors
  -- data.has_symbols(bufnr)
  -- and get_error_count(bufnr, client_id) > 0
  -- then
  -- return
  -- end

  -- Debounce this callback to avoid unnecessary re-rendering
  if results[bufnr] == nil then
    vim.defer_fn(function()
      local r = results[bufnr]
      results[bufnr] = nil
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      M.handle_symbols(r, bufnr)
    end, 100)
  end
  results[bufnr] = result
end

return M
