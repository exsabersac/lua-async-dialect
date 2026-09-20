--[[
  Splice 转译：.alua = Lua 宿主 + 嵌入的 async function 区域。

  扫描源码，在顶层找出 `async function Name(...) ... end`，
  仅对这些区域做 lex/parse/codegen；其余文本原样拷贝。
  若存在任一 async 函数，在输出顶部插入一次 Task require。
]]

local Lexer = require("lib.lexer")
local Parser = require("lib.parser")
local Codegen = require("lib.codegen")

local Splice = {}

local function is_ident_char(c)
  return c:match("[%w_]") ~= nil
end

--- 从位置 i 起若匹配完整标识符 word 则返回结束下标+1，否则 nil
local function match_word(src, i, word)
  local n = #word
  if src:sub(i, i + n - 1) ~= word then return nil end
  local before = i > 1 and src:sub(i - 1, i - 1) or ""
  local after = src:sub(i + n, i + n)
  if before ~= "" and is_ident_char(before) then return nil end
  if after ~= "" and is_ident_char(after) then return nil end
  return i + n
end

--- 跳过字符串或长括号串，返回新下标
local function skip_string(src, i)
  local c = src:sub(i, i)
  if c == '"' or c == "'" then
    i = i + 1
    while i <= #src do
      local ch = src:sub(i, i)
      if ch == "\\" then
        i = i + 2
      elseif ch == c then
        return i + 1
      else
        i = i + 1
      end
    end
    error("Unterminated string in splice scan")
  end
  -- long string [[ or [=[
  if c == "[" then
    local j = i + 1
    local eq = 0
    while src:sub(j, j) == "=" do
      eq = eq + 1
      j = j + 1
    end
    if src:sub(j, j) == "[" then
      local close = "]" .. string.rep("=", eq) .. "]"
      local k = j + 1
      while k <= #src do
        if src:sub(k, k + #close - 1) == close then
          return k + #close
        end
        k = k + 1
      end
      error("Unterminated long string in splice scan")
    end
  end
  return nil
end

local function skip_comment(src, i)
  if src:sub(i, i + 1) ~= "--" then return nil end
  i = i + 2
  if src:sub(i, i) == "[" then
    local j = i + 1
    local eq = 0
    while src:sub(j, j) == "=" do
      eq = eq + 1
      j = j + 1
    end
    if src:sub(j, j) == "[" then
      local close = "]" .. string.rep("=", eq) .. "]"
      local k = j + 1
      while k <= #src do
        if src:sub(k, k + #close - 1) == close then
          return k + #close
        end
        k = k + 1
      end
      error("Unterminated long comment in splice scan")
    end
  end
  while i <= #src and src:sub(i, i) ~= "\n" do
    i = i + 1
  end
  return i
end

--- 找下一个「有意义」token 起点，跳过空白/注释/字符串时推进 i
--- 返回 i, kind 其中 kind 为 "word"|nil；若遇到字符串则跳过
-- Lua 块开启：function / if / do / try / repeat。
-- while/for 本身不加深，由其后的 do 加深（while x do ... end 只对应一个 end）。
local OPEN_KEYWORDS = {
  ["function"] = true,
  ["if"] = true,
  ["do"] = true,
  ["try"] = true,  -- try/catch/finally ... end
}

--- 扫描并返回 chunks: { {kind="text", text=...} | {kind="async", text=...} }
function Splice.find_regions(src)
  local regions = {}
  local i = 1
  local n = #src
  local text_start = 1
  local depth = 0  -- block nesting (function/if/while/for/do / repeat)

  while i <= n do
    -- comments
    local ni = skip_comment(src, i)
    if ni then i = ni; goto continue end

    -- strings
    ni = skip_string(src, i)
    if ni then i = ni; goto continue end

    local c = src:sub(i, i)

    -- identifiers / keywords
    if c:match("[%a_]") then
      local j = i
      while j <= n and is_ident_char(src:sub(j, j)) do j = j + 1 end
      local word = src:sub(i, j - 1)

      if depth == 0 and word == "async" then
        -- look ahead for "function"
        local k = j
        while k <= n and src:sub(k, k):match("[ \t\r\n]") do k = k + 1 end
        -- skip comments between async and function
        local ck = skip_comment(src, k)
        while ck do
          k = ck
          while k <= n and src:sub(k, k):match("[ \t\r\n]") do k = k + 1 end
          ck = skip_comment(src, k)
        end
        local after_fn = match_word(src, k, "function")
        if after_fn then
          -- flush text before async
          if i > text_start then
            regions[#regions + 1] = { kind = "text", text = src:sub(text_start, i - 1) }
          end
          -- scan async function body with nesting starting at 1 after "function"
          local start = i
          local d = 1  -- function opens a block
          local p = after_fn
          -- skip to end of param list first? Not required: nested function/if still count.
          -- But we must not count the outer "function" again — we already set d=1.
          while p <= n do
            local pc = skip_comment(src, p)
            if pc then p = pc; goto cont2 end
            pc = skip_string(src, p)
            if pc then p = pc; goto cont2 end

            local ch = src:sub(p, p)
            if ch:match("[%a_]") then
              local q = p
              while q <= n and is_ident_char(src:sub(q, q)) do q = q + 1 end
              local w = src:sub(p, q - 1)
              if OPEN_KEYWORDS[w] then
                d = d + 1
              elseif w == "repeat" then
                d = d + 1
              elseif w == "end" then
                d = d - 1
                if d == 0 then
                  local finish = q
                  regions[#regions + 1] = { kind = "async", text = src:sub(start, finish - 1) }
                  text_start = finish
                  i = finish
                  depth = 0
                  goto continue
                end
              elseif w == "until" then
                d = d - 1
                if d == 0 then
                  error("async function closed by until?")
                end
              end
              p = q
            else
              p = p + 1
            end
            ::cont2::
          end
          error("Unterminated async function starting at byte " .. start)
        end
      end

      -- normal keyword nesting outside async
      if OPEN_KEYWORDS[word] then
        depth = depth + 1
      elseif word == "repeat" then
        depth = depth + 1
      elseif word == "end" then
        depth = depth - 1
        if depth < 0 then depth = 0 end
      elseif word == "until" then
        depth = depth - 1
        if depth < 0 then depth = 0 end
      end
      i = j
      goto continue
    end

    i = i + 1
    ::continue::
  end

  if text_start <= n then
    regions[#regions + 1] = { kind = "text", text = src:sub(text_start, n) }
  end
  return regions
end

function Splice.transpile(src, opts)
  opts = opts or {}
  local task_require = opts.task_require or 'require("runtime.task")'
  local regions = Splice.find_regions(src)
  local has_async = false
  for _, r in ipairs(regions) do
    if r.kind == "async" then has_async = true; break end
  end

  local out = {}
  if has_async then
    out[#out + 1] = "-- Generated by lua-async-dialect splice transpiler (no coroutines)\n"
    out[#out + 1] = "local Task = " .. task_require .. "\n"
  end

  for _, r in ipairs(regions) do
    if r.kind == "text" then
      out[#out + 1] = r.text
    else
      local tokens = Lexer.new(r.text):tokenize()
      local fn = Parser.new(tokens):parse_async_function()
      local code = Codegen.generate_function(fn)
      -- ensure trailing newline
      if code:sub(-1) ~= "\n" then code = code .. "\n" end
      out[#out + 1] = code
    end
  end

  return table.concat(out)
end

return Splice
