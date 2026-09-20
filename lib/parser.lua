--[[
  递归下降语法分析：token 流 → AST。
  用于 splice 抽出的单个 async function 区域；
  支持比较 / 逻辑 / 拼接 / 索引 / 方法调用 / 表构造 / if / while / for。
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

function Parser:parse_expr()
  return self:parse_or()
end

function Parser:parse_or()
  local left = self:parse_and()
  while self:match("or") do
    local right = self:parse_and()
    left = { tag = "binop", op = "or", left = left, right = right }
  end
  return left
end

function Parser:parse_and()
  local left = self:parse_cmp()
  while self:match("and") do
    local right = self:parse_cmp()
    left = { tag = "binop", op = "and", left = left, right = right }
  end
  return left
end

local CMP_OPS = {
  ["=="] = true, ["~="] = true, ["<"] = true, ["<="] = true,
  [">"] = true, [">="] = true,
}

function Parser:parse_cmp()
  local left = self:parse_concat()
  local t = self:cur().type
  if CMP_OPS[t] then
    local op = self:advance().type
    local right = self:parse_concat()
    left = { tag = "binop", op = op, left = left, right = right }
  end
  return left
end

function Parser:parse_concat()
  local left = self:parse_add()
  -- .. 右结合
  if self:match("..") then
    local right = self:parse_concat()
    left = { tag = "binop", op = "..", left = left, right = right }
  end
  return left
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
  if self:match("await") then
    local e = self:parse_unary()
    return { tag = "await", expr = e }
  end
  if self:match("not") then
    local e = self:parse_unary()
    return { tag = "unop", op = "not", expr = e }
  end
  if self:match("#") then
    local e = self:parse_unary()
    return { tag = "unop", op = "#", expr = e }
  end
  if self:cur().type == "-" then
    self:advance()
    local e = self:parse_unary()
    return { tag = "unop", op = "-", expr = e }
  end
  return self:parse_postfix()
end

function Parser:parse_args()
  local args = {}
  if self:cur().type ~= ")" then
    args[#args + 1] = self:parse_expr()
    while self:match(",") do
      args[#args + 1] = self:parse_expr()
    end
  end
  self:expect(")")
  return args
end

function Parser:parse_table()
  self:expect("{")
  local fields = {}
  while self:cur().type ~= "}" do
    if self:cur().type == "[" then
      self:advance()
      local key = self:parse_expr()
      self:expect("]")
      self:expect("=")
      local val = self:parse_expr()
      fields[#fields + 1] = { kind = "key", key = key, value = val }
    elseif self:cur().type == "name" and self.tokens[self.i + 1] and self.tokens[self.i + 1].type == "=" then
      local key = self:advance().value
      self:expect("=")
      local val = self:parse_expr()
      fields[#fields + 1] = { kind = "name", name = key, value = val }
    else
      local val = self:parse_expr()
      fields[#fields + 1] = { kind = "list", value = val }
    end
    if not self:match(",") and not self:match(";") then
      break
    end
  end
  self:expect("}")
  return { tag = "table", fields = fields }
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
  if t.type == "true" or t.type == "false" or t.type == "nil" then
    self:advance()
    return { tag = "literal", value = t.type }
  end
  if t.type == "name" then
    self:advance()
    return { tag = "name", name = t.value }
  end
  if self:match("(") then
    local e = self:parse_expr()
    self:expect(")")
    return e
  end
  if self:cur().type == "{" then
    return self:parse_table()
  end
  error(string.format("Unexpected token %s at %d:%d", t.type, t.line or 0, t.col or 0))
end

function Parser:parse_postfix()
  local node = self:parse_primary()
  while true do
    if self:cur().type == "(" then
      self:advance()
      local args = self:parse_args()
      node = { tag = "call", callee = node, args = args }
    elseif self:match(".") then
      local name = self:expect("name").value
      node = { tag = "index", object = node, key = { tag = "string", value = name }, dot = true }
    elseif self:match("[") then
      local key = self:parse_expr()
      self:expect("]")
      node = { tag = "index", object = node, key = key, dot = false }
    elseif self:match(":") then
      local method = self:expect("name").value
      self:expect("(")
      local args = self:parse_args()
      node = { tag = "method", object = node, method = method, args = args }
    else
      break
    end
  end
  return node
end

function Parser:is_expr_start()
  local ct = self:cur().type
  return ct == "name" or ct == "number" or ct == "string" or ct == "("
      or ct == "await" or ct == "-" or ct == "not" or ct == "#"
      or ct == "{" or ct == "true" or ct == "false" or ct == "nil"
end

function Parser:block_end()
  local ct = self:cur().type
  return ct == "end" or ct == "else" or ct == "elseif" or ct == "until" or ct == "eof"
end

function Parser:parse_block()
  local stmts = {}
  while not self:block_end() do
    stmts[#stmts + 1] = self:parse_stmt()
  end
  return stmts
end

function Parser:parse_if()
  self:expect("if")
  local cond = self:parse_expr()
  self:expect("then")
  local then_body = self:parse_block()
  local elseifs = {}
  while self:match("elseif") do
    local c = self:parse_expr()
    self:expect("then")
    local b = self:parse_block()
    elseifs[#elseifs + 1] = { cond = c, body = b }
  end
  local else_body = nil
  if self:match("else") then
    else_body = self:parse_block()
  end
  self:expect("end")
  return { tag = "if", cond = cond, then_body = then_body, elseifs = elseifs, else_body = else_body }
end

function Parser:parse_while()
  self:expect("while")
  local cond = self:parse_expr()
  self:expect("do")
  local body = self:parse_block()
  self:expect("end")
  return { tag = "while", cond = cond, body = body }
end

function Parser:parse_for()
  self:expect("for")
  local name = self:expect("name").value
  self:expect("=")
  local a = self:parse_expr()
  self:expect(",")
  local b = self:parse_expr()
  local c = nil
  if self:match(",") then
    c = self:parse_expr()
  end
  self:expect("do")
  local body = self:parse_block()
  self:expect("end")
  return { tag = "for", name = name, start = a, stop = b, step = c, body = body }
end

function Parser:parse_lvalue_suffix(base)
  -- base is already a name node; parse . / [] for assignment target
  local node = base
  while true do
    if self:match(".") then
      local name = self:expect("name").value
      node = { tag = "index", object = node, key = { tag = "string", value = name }, dot = true }
    elseif self:match("[") then
      local key = self:parse_expr()
      self:expect("]")
      node = { tag = "index", object = node, key = key, dot = false }
    else
      break
    end
  end
  return node
end

function Parser:parse_stmt()
  if self:match("local") then
    local name = self:expect("name").value
    self:expect("=")
    local exp = self:parse_expr()
    return { tag = "local", name = name, expr = exp }
  end
  if self:cur().type == "if" then
    return self:parse_if()
  end
  if self:cur().type == "while" then
    return self:parse_while()
  end
  if self:cur().type == "for" then
    return self:parse_for()
  end
  if self:match("return") then
    local exp = nil
    if self:is_expr_start() then
      exp = self:parse_expr()
    end
    return { tag = "return", expr = exp }
  end
  -- 赋值或表达式语句
  if self:cur().type == "name" then
    local save = self.i
    local name_tok = self:advance()
    local base = { tag = "name", name = name_tok.value }
    local lval = self:parse_lvalue_suffix(base)
    if self:match("=") then
      local exp = self:parse_expr()
      if lval.tag == "name" then
        return { tag = "assign", name = lval.name, expr = exp }
      else
        return { tag = "assign_index", target = lval, expr = exp }
      end
    end
    -- 回退：表达式语句
    self.i = save
    local exp = self:parse_expr()
    return { tag = "expr_stmt", expr = exp }
  end
  if self:is_expr_start() then
    local exp = self:parse_expr()
    return { tag = "expr_stmt", expr = exp }
  end
  local t = self:cur()
  error(string.format("Unexpected statement start %s at %d:%d", t.type, t.line or 0, t.col or 0))
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

--- 解析整文件：零或多个 async function（兼容旧用法；splice 优先）
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
