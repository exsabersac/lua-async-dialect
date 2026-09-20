--[[
  代码生成：async function → 返回 Task 的表状态机（无 coroutine）。

  核心降级：
  1. 语句中的 await 按求值顺序拆出，换成临时名 _awN；
  2. 在每个 await 边界切开状态；
  3. 状态内同步执行代码，遇 await 则推进 _state 并 return Task.await_then(...);
  4. 局部量放在 sm._locals，跨 await 存活。
]]

local Codegen = {}

local function quote_string(s)
  return string.format("%q", s)
end

--- 生成不含 await 的表达式 Lua；await 必须已在语句层降级
local function emit_expr(e, ctx)
  if e.tag == "number" then
    return tostring(e.value)
  elseif e.tag == "string" then
    return quote_string(e.value)
  elseif e.tag == "name" then
    if ctx.params[e.name] or ctx.locals[e.name] then
      return "self._locals." .. e.name
    end
    -- 自由名：全局 / 上值（如 delay、其他 async 函数）
    return e.name
  elseif e.tag == "binop" then
    return "(" .. emit_expr(e.left, ctx) .. " " .. e.op .. " " .. emit_expr(e.right, ctx) .. ")"
  elseif e.tag == "unop" then
    return "(" .. e.op .. emit_expr(e.expr, ctx) .. ")"
  elseif e.tag == "call" then
    local args = {}
    for i = 1, #e.args do
      args[i] = emit_expr(e.args[i], ctx)
    end
    return emit_expr(e.callee, ctx) .. "(" .. table.concat(args, ", ") .. ")"
  elseif e.tag == "await" then
    error("await must be handled at statement level")
  else
    error("unknown expr tag: " .. tostring(e.tag))
  end
end

-- 收集表达式中的 await 节点（调试/分析用；实际降级走 lower_awaits）
local function collect_awaits(expr, list)
  if not expr then return end
  if expr.tag == "await" then
    list[#list + 1] = expr
    collect_awaits(expr.expr, list)
  elseif expr.tag == "binop" then
    collect_awaits(expr.left, list)
    collect_awaits(expr.right, list)
  elseif expr.tag == "unop" then
    collect_awaits(expr.expr, list)
  elseif expr.tag == "call" then
    collect_awaits(expr.callee, list)
    for i = 1, #expr.args do
      collect_awaits(expr.args[i], list)
    end
  end
end

--- 把表达式里的 await 换成 name 临时量；返回改写后的表达式与
--- 按求值顺序的 { tmp, expr } 列表（expr 为 await 的内层，已递归降级）。
local function lower_awaits(expr, tmp_id)
  local awaits = {}
  local function walk(e)
    if not e then return e end
    if e.tag == "await" then
      local inner = walk(e.expr)
      local id = tmp_id[1]
      tmp_id[1] = id + 1
      local tmp = "_aw" .. id
      awaits[#awaits + 1] = { tmp = tmp, expr = inner }
      return { tag = "name", name = tmp }
    elseif e.tag == "binop" then
      return { tag = "binop", op = e.op, left = walk(e.left), right = walk(e.right) }
    elseif e.tag == "unop" then
      return { tag = "unop", op = e.op, expr = walk(e.expr) }
    elseif e.tag == "call" then
      local args = {}
      for i = 1, #e.args do args[i] = walk(e.args[i]) end
      return { tag = "call", callee = walk(e.callee), args = args }
    else
      return e
    end
  end
  local rewritten = walk(expr)
  return rewritten, awaits
end

local function emit_async_fn(fn, lines)
  local ctx = { params = {}, locals = {} }
  for _, p in ipairs(fn.params) do
    ctx.params[p] = true
    ctx.locals[p] = true
  end

  -- 将函数体展平为微操作序列，再在 await / return 处切成状态
  local tmp_id = { 0 }
  -- ops: { kind="code", line=... } | { kind="await", tmp=..., expr=... }
  --    | { kind="return", expr=... }

  local ops = {}
  local function add_code(lua_line)
    ops[#ops + 1] = { kind = "code", line = lua_line }
  end

  for _, stmt in ipairs(fn.body) do
    if stmt.tag == "local" then
      ctx.locals[stmt.name] = true
      local rewritten, awaits = lower_awaits(stmt.expr, tmp_id)
      for _, a in ipairs(awaits) do
        ctx.locals[a.tmp] = true
        ops[#ops + 1] = { kind = "await", tmp = a.tmp, expr = a.expr }
      end
      add_code("self._locals." .. stmt.name .. " = " .. emit_expr(rewritten, ctx))
    elseif stmt.tag == "assign" then
      ctx.locals[stmt.name] = true
      local rewritten, awaits = lower_awaits(stmt.expr, tmp_id)
      for _, a in ipairs(awaits) do
        ctx.locals[a.tmp] = true
        ops[#ops + 1] = { kind = "await", tmp = a.tmp, expr = a.expr }
      end
      add_code("self._locals." .. stmt.name .. " = " .. emit_expr(rewritten, ctx))
    elseif stmt.tag == "expr_stmt" then
      local rewritten, awaits = lower_awaits(stmt.expr, tmp_id)
      for _, a in ipairs(awaits) do
        ctx.locals[a.tmp] = true
        ops[#ops + 1] = { kind = "await", tmp = a.tmp, expr = a.expr }
      end
      add_code(emit_expr(rewritten, ctx))
    elseif stmt.tag == "return" then
      if stmt.expr then
        local rewritten, awaits = lower_awaits(stmt.expr, tmp_id)
        for _, a in ipairs(awaits) do
          ctx.locals[a.tmp] = true
          ops[#ops + 1] = { kind = "await", tmp = a.tmp, expr = a.expr }
        end
        ops[#ops + 1] = { kind = "return", expr = rewritten }
      else
        ops[#ops + 1] = { kind = "return", expr = nil }
      end
    else
      error("unknown stmt: " .. tostring(stmt.tag))
    end
  end

  -- 在每个 await 边界 flush 当前状态
  local states = {}
  local cur = { codes = {}, await = nil, ret = nil }
  local function flush_state()
    states[#states + 1] = cur
    cur = { codes = {}, await = nil, ret = nil }
  end

  for _, op in ipairs(ops) do
    if op.kind == "code" then
      cur.codes[#cur.codes + 1] = op.line
    elseif op.kind == "await" then
      cur.await = op
      flush_state()
    elseif op.kind == "return" then
      cur.ret = op
      flush_state()
    end
  end
  if #cur.codes > 0 or cur.await or cur.ret then
    flush_state()
  end
  -- 空函数体 → resolve nil；末状态若无 return/await 则补 return nil
  if #states == 0 then
    states[1] = { codes = {}, await = nil, ret = { kind = "return", expr = nil } }
  elseif not states[#states].ret and not states[#states].await then
    states[#states].ret = { kind = "return", expr = nil }
  end

  local param_list = table.concat(fn.params, ", ")
  lines[#lines + 1] = "function " .. fn.name .. "(" .. param_list .. ")"
  lines[#lines + 1] = "  local sm = { _state = 0, _locals = {} }"
  for _, p in ipairs(fn.params) do
    lines[#lines + 1] = "  sm._locals." .. p .. " = " .. p
  end
  lines[#lines + 1] = "  function sm:step(ok, val)"
  lines[#lines + 1] = "    if not ok then return Task.rejected(val) end"
  lines[#lines + 1] = "    local s = self._state"

  for si, st in ipairs(states) do
    local idx = si - 1
    local prefix = (si == 1) and "    if" or "    elseif"
    lines[#lines + 1] = prefix .. " s == " .. idx .. " then"
    -- 状态 0：初始 step(true)，val 无用。
    -- 状态 k>0：val 是上一状态 await 的结果，写入对应 _aw 临时量。
    if si > 1 then
      local prev = states[si - 1]
      if prev.await then
        lines[#lines + 1] = "      self._locals." .. prev.await.tmp .. " = val"
      end
    end
    for _, code in ipairs(st.codes) do
      lines[#lines + 1] = "      " .. code
    end
    if st.await then
      lines[#lines + 1] = "      self._state = " .. si
      lines[#lines + 1] = "      return Task.await_then(" .. emit_expr(st.await.expr, ctx) .. ", self)"
    elseif st.ret then
      if st.ret.expr then
        lines[#lines + 1] = "      return Task.resolved(" .. emit_expr(st.ret.expr, ctx) .. ")"
      else
        lines[#lines + 1] = "      return Task.resolved(nil)"
      end
    else
      lines[#lines + 1] = "      return Task.resolved(nil)"
    end
  end

  lines[#lines + 1] = "    end"
  lines[#lines + 1] = "  end"
  lines[#lines + 1] = "  return sm:step(true)"
  lines[#lines + 1] = "end"
  lines[#lines + 1] = ""
end

--- 生成完整 Lua 源：require Task + 各 async 函数的状态机
function Codegen.generate(ast, opts)
  opts = opts or {}
  local task_require = opts.task_require or 'require("runtime.task")'
  local lines = {}
  lines[#lines + 1] = "-- Generated by lua-async-dialect transpiler (no coroutines)"
  lines[#lines + 1] = "local Task = " .. task_require
  lines[#lines + 1] = ""
  for _, fn in ipairs(ast.funcs) do
    emit_async_fn(fn, lines)
  end
  return table.concat(lines, "\n")
end

return Codegen
