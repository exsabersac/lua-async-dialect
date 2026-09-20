--[[
  递归下降语法分析：token 流 → AST。
  文件级只接受 async function；await 为一元运算符。
  AST 节点用 tag 字段区分（async_fn / local / await / binop 等）。
]]

local Parser = {}
Parser.__index = Parser

function Parser.new(tokens)
  return setmetatable({ tokens = tokens, i = 1 }, Parser)
end

function Parser:cur()
  return self.tokens[self.i]
end

function Parser:advance()
  local t = self.tokens[self.i]
  self.i = self.i + 1
  return t
end

function Parser:match(typ)
  if self:cur().type == typ then
    return self:advance()
  end
  return nil
end

function Parser:expect(typ)
  local t = self:cur()
  if t.type ~= typ then
    error(string.format("Expected %s, got %s at %d:%d", typ, t.type, t.line or 0, t.col or 0))
  end
  return self:advance()
end

-- expression → 加减层（最低优先级）
function Parser:parse_expr()
  return self:parse_add()
end

function Parser:parse_add()
  local left = self:parse_mul()
  while self:cur().type == "+" or self:cur().type == "-" do
    local op = self:advance().type
    local right = self:parse_mul()
    left = { tag = "binop", op = op, left = left, right = right }
  end
  return left
end

function Parser:parse_mul()
  local left = self:parse_unary()
  while self:cur().type == "*" or self:cur().type == "/" do
    local op = self:advance().type
    local right = self:parse_unary()
    left = { tag = "binop", op = op, left = left, right = right }
  end
  return left
end

function Parser:parse_unary()
  -- await 右结合：await await x
  if self:match("await") then
    local e = self:parse_unary()
    return { tag = "await", expr = e }
  end
  if self:cur().type == "-" then
    self:advance()
    local e = self:parse_unary()
    return { tag = "unop", op = "-", expr = e }
  end
  return self:parse_primary()
end

function Parser:parse_primary()
  local t = self:cur()
  if t.type == "number" then
    self:advance()
    return { tag = "number", value = t.value }
  end
  if t.type == "string" then
    self:advance()
    return { tag = "string", value = t.value }
  end
  if t.type == "name" then
    self:advance()
    local node = { tag = "name", name = t.value }
    -- 支持 f()() 链式调用
    while self:cur().type == "(" do
      self:advance()
      local args = {}
      if self:cur().type ~= ")" then
        args[#args + 1] = self:parse_expr()
        while self:match(",") do
          args[#args + 1] = self:parse_expr()
        end
      end
      self:expect(")")
      node = { tag = "call", callee = node, args = args }
    end
    return node
  end
  if self:match("(") then
    local e = self:parse_expr()
    self:expect(")")
    -- 允许 (expr)(args)
    local node = e
    while self:cur().type == "(" do
      self:advance()
      local args = {}
      if self:cur().type ~= ")" then
        args[#args + 1] = self:parse_expr()
        while self:match(",") do
          args[#args + 1] = self:parse_expr()
        end
      end
      self:expect(")")
      node = { tag = "call", callee = node, args = args }
    end
    return node
  end
  error(string.format("Unexpected token %s at %d:%d", t.type, t.line or 0, t.col or 0))
end

function Parser:parse_stmt()
  if self:match("local") then
    local name = self:expect("name").value
    self:expect("=")
    local exp = self:parse_expr()
    return { tag = "local", name = name, expr = exp }
  end
  if self:match("return") then
    local exp = nil
    local ct = self:cur().type
    if ct ~= "end" and ct ~= "eof" and ct ~= "local" and ct ~= "return"
       and ct ~= "async" and ct ~= "function" then
      -- 启发式：下一 token 像表达式开头则解析 return 值
      if ct == "name" or ct == "number" or ct == "string" or ct == "(" or ct == "await" or ct == "-" then
        exp = self:parse_expr()
      end
    end
    return { tag = "return", expr = exp }
  end
  -- 赋值或裸表达式语句
  if self:cur().type == "name" then
    local save = self.i
    local name = self:advance().value
    if self:match("=") then
      local exp = self:parse_expr()
      return { tag = "assign", name = name, expr = exp }
    end
    -- 回退：按表达式语句解析（通常是调用）
    self.i = save
    local exp = self:parse_expr()
    return { tag = "expr_stmt", expr = exp }
  end
  if self:cur().type == "await" or self:cur().type == "(" then
    local exp = self:parse_expr()
    return { tag = "expr_stmt", expr = exp }
  end
  local t = self:cur()
  error(string.format("Unexpected statement start %s at %d:%d", t.type, t.line or 0, t.col or 0))
end

function Parser:parse_block()
  local stmts = {}
  while true do
    local ct = self:cur().type
    if ct == "end" or ct == "eof" then break end
    stmts[#stmts + 1] = self:parse_stmt()
  end
  return stmts
end

function Parser:parse_async_function()
  self:expect("async")
  self:expect("function")
  local name = self:expect("name").value
  self:expect("(")
  local params = {}
  if self:cur().type ~= ")" then
    params[#params + 1] = self:expect("name").value
    while self:match(",") do
      params[#params + 1] = self:expect("name").value
    end
  end
  self:expect(")")
  local body = self:parse_block()
  self:expect("end")
  return { tag = "async_fn", name = name, params = params, body = body }
end

--- 解析整文件：零或多个 async function
function Parser:parse_file()
  local fns = {}
  while self:cur().type ~= "eof" do
    if self:cur().type == "async" then
      fns[#fns + 1] = self:parse_async_function()
    else
      local t = self:cur()
      error(string.format("Expected async function, got %s at %d:%d", t.type, t.line or 0, t.col or 0))
    end
  end
  return { tag = "file", funcs = fns }
end

return Parser
