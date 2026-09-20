-- Minimal lexer for the async/await dialect.

local Lexer = {}
Lexer.__index = Lexer

local KEYWORDS = {
  ["async"] = true, ["function"] = true, ["end"] = true,
  ["local"] = true, ["return"] = true, ["await"] = true,
}

function Lexer.new(src)
  return setmetatable({ src = src, i = 1, line = 1, col = 1 }, Lexer)
end

function Lexer:peek()
  return self.src:sub(self.i, self.i)
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
    elseif c == "-" and self.src:sub(self.i + 1, self.i + 1) == "-" then
      while self:peek() ~= "" and self:peek() ~= "\n" do
        self:advance()
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
  if self:peek() == "." and self.src:sub(self.i + 1, self.i + 1):match("%d") then
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
  if c == "(" or c == ")" or c == "," or c == "+" or c == "-" or c == "*" or c == "/" then
    self:advance()
    return { type = c, value = c, line = line, col = col }
  end
  if c == "=" then
    self:advance()
    return { type = "=", value = "=", line = line, col = col }
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
