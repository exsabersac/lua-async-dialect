--[[
  词法分析器：把 async 区域源码切成 token 流（带 line/col）。
  覆盖嵌入式方言 async 函数体内所需语法；不实现完整 Lua 词法。
]]

local Lexer = {}
Lexer.__index = Lexer

local KEYWORDS = {
  ["async"] = true, ["function"] = true, ["end"] = true,
  ["local"] = true, ["return"] = true, ["await"] = true,
  ["if"] = true, ["then"] = true, ["else"] = true, ["elseif"] = true,
  ["while"] = true, ["do"] = true, ["for"] = true,
  ["and"] = true, ["or"] = true, ["not"] = true,
  ["true"] = true, ["false"] = true, ["nil"] = true,
  ["repeat"] = true, ["until"] = true,
}

function Lexer.new(src)
  return setmetatable({ src = src, i = 1, line = 1, col = 1 }, Lexer)
end

function Lexer:peek()
  return self.src:sub(self.i, self.i)
end

function Lexer:peek_at(n)
  return self.src:sub(self.i + n, self.i + n)
end

function Lexer:advance()
  local c = self.src:sub(self.i, self.i)
  self.i = self.i + 1
  if c == "\n" then
    self.line = self.line + 1
    self.col = 1
  else
    self.col = self.col + 1
  end
  return c
end

function Lexer:skip_ws_and_comments()
  while true do
    local c = self:peek()
    if c == "" then return end
    if c == " " or c == "\t" or c == "\r" or c == "\n" then
      self:advance()
    elseif c == "-" and self:peek_at(1) == "-" then
      self:advance()
      self:advance()
      -- 长注释 --[=*[ ... ]=*]
      if self:peek() == "[" then
        local j = self.i + 1
        local eq = 0
        while self.src:sub(j, j) == "=" do
          eq = eq + 1
          j = j + 1
        end
        if self.src:sub(j, j) == "[" then
          -- consume opening
          while self.i < j + 1 do self:advance() end
          local close = "]" .. string.rep("=", eq) .. "]"
          while true do
            if self:peek() == "" then
              error(string.format("Unterminated long comment at %d:%d", self.line, self.col))
            end
            if self.src:sub(self.i, self.i + #close - 1) == close then
              for _ = 1, #close do self:advance() end
              break
            end
            self:advance()
          end
        else
          -- 行注释
          while self:peek() ~= "" and self:peek() ~= "\n" do
            self:advance()
          end
        end
      else
        while self:peek() ~= "" and self:peek() ~= "\n" do
          self:advance()
        end
      end
    else
      return
    end
  end
end

function Lexer:read_number()
  local start = self.i
  local line, col = self.line, self.col
  while self:peek():match("%d") do self:advance() end
  if self:peek() == "." and self:peek_at(1):match("%d") then
    self:advance()
    while self:peek():match("%d") do self:advance() end
  end
  local text = self.src:sub(start, self.i - 1)
  return { type = "number", value = tonumber(text), line = line, col = col }
end

function Lexer:read_string()
  local q = self:advance()
  local line, col = self.line, self.col - 1
  local buf = {}
  while true do
    local c = self:peek()
    if c == "" then error(string.format("Unterminated string at %d:%d", line, col)) end
    if c == q then
      self:advance()
      break
    end
    if c == "\\" then
      self:advance()
      local n = self:advance()
      if n == "n" then buf[#buf + 1] = "\n"
      elseif n == "t" then buf[#buf + 1] = "\t"
      elseif n == "\\" then buf[#buf + 1] = "\\"
      elseif n == '"' or n == "'" then buf[#buf + 1] = n
      else buf[#buf + 1] = n end
    else
      buf[#buf + 1] = self:advance()
    end
  end
  return { type = "string", value = table.concat(buf), line = line, col = col }
end

function Lexer:read_ident()
  local start = self.i
  local line, col = self.line, self.col
  while self:peek():match("[%w_]") do self:advance() end
  local text = self.src:sub(start, self.i - 1)
  if KEYWORDS[text] then
    return { type = text, value = text, line = line, col = col }
  end
  return { type = "name", value = text, line = line, col = col }
end

function Lexer:next()
  self:skip_ws_and_comments()
  local c = self:peek()
  if c == "" then
    return { type = "eof", value = nil, line = self.line, col = self.col }
  end
  local line, col = self.line, self.col
  if c:match("%d") then return self:read_number() end
  if c == '"' or c == "'" then return self:read_string() end
  if c:match("[%a_]") then return self:read_ident() end

  -- multi-char operators
  local two = c .. self:peek_at(1)
  if two == "==" or two == "~=" or two == "<=" or two == ">=" or two == ".." then
    self:advance()
    self:advance()
    return { type = two, value = two, line = line, col = col }
  end

  local singles = {
    ["("] = true, [")"] = true, ["["] = true, ["]"] = true,
    ["{"] = true, ["}"] = true, [","] = true, [";"] = true,
    ["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true,
    ["="] = true, ["<"] = true, [">"] = true, ["."] = true,
    [":"] = true, ["#"] = true,
  }
  if singles[c] then
    self:advance()
    return { type = c, value = c, line = line, col = col }
  end

  error(string.format("Unexpected character %q at %d:%d", c, line, col))
end

function Lexer:tokenize()
  local toks = {}
  while true do
    local t = self:next()
    toks[#toks + 1] = t
    if t.type == "eof" then break end
  end
  return toks
end

return Lexer
