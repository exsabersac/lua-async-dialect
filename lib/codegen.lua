--[[
  代码生成：async function → 返回 Task 的表状态机（无 coroutine）。

  控制流（if / while / for / try-catch-finally）与 await 共存：
  先降到带 label / branch / goto 的线性 ops，再切成状态；
  sm:step 内用 while 循环处理同步跳转，遇 await 则 return Task.await_then。
  await 失败/取消：若在 try 区域则跳到 catch/finally，否则外层 Task
  rejected 或 canceled。
]]

local Codegen = {}

local function quote_string(s)
  return string.format("%q", s)
end

local function emit_expr(e, ctx)
  if e.tag == "number" then
    return tostring(e.value)
  elseif e.tag == "string" then
    return quote_string(e.value)
  elseif e.tag == "literal" then
    return e.value
  elseif e.tag == "name" then
    if ctx.params[e.name] or ctx.locals[e.name] then
      return "self._locals." .. e.name
    end
    return e.name
  elseif e.tag == "binop" then
    return "(" .. emit_expr(e.left, ctx) .. " " .. e.op .. " " .. emit_expr(e.right, ctx) .. ")"
  elseif e.tag == "unop" then
    if e.op == "not" then
      return "(not " .. emit_expr(e.expr, ctx) .. ")"
    elseif e.op == "#" then
      return "(#" .. emit_expr(e.expr, ctx) .. ")"
    else
      return "(" .. e.op .. emit_expr(e.expr, ctx) .. ")"
    end
  elseif e.tag == "call" then
    local args = {}
    for i = 1, #e.args do
      args[i] = emit_expr(e.args[i], ctx)
    end
    return emit_expr(e.callee, ctx) .. "(" .. table.concat(args, ", ") .. ")"
  elseif e.tag == "method" then
    local args = {}
    for i = 1, #e.args do
      args[i] = emit_expr(e.args[i], ctx)
    end
    return emit_expr(e.object, ctx) .. ":" .. e.method .. "(" .. table.concat(args, ", ") .. ")"
  elseif e.tag == "index" then
    if e.dot and e.key.tag == "string" then
      return emit_expr(e.object, ctx) .. "." .. e.key.value
    end
    return emit_expr(e.object, ctx) .. "[" .. emit_expr(e.key, ctx) .. "]"
  elseif e.tag == "table" then
    local parts = {}
    for _, f in ipairs(e.fields) do
      if f.kind == "list" then
        parts[#parts + 1] = emit_expr(f.value, ctx)
      elseif f.kind == "name" then
        parts[#parts + 1] = f.name .. " = " .. emit_expr(f.value, ctx)
      elseif f.kind == "key" then
        parts[#parts + 1] = "[" .. emit_expr(f.key, ctx) .. "] = " .. emit_expr(f.value, ctx)
      end
    end
    return "{" .. table.concat(parts, ", ") .. "}"
  elseif e.tag == "await" then
    error("await must be handled at statement level")
  else
    error("unknown expr tag: " .. tostring(e.tag))
  end
end

--- 把表达式里的 await 换成 name 临时量
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
    elseif e.tag == "method" then
      local args = {}
      for i = 1, #e.args do args[i] = walk(e.args[i]) end
      return { tag = "method", object = walk(e.object), method = e.method, args = args }
    elseif e.tag == "index" then
      return { tag = "index", object = walk(e.object), key = walk(e.key), dot = e.dot }
    elseif e.tag == "table" then
      local fields = {}
      for i, f in ipairs(e.fields) do
        if f.kind == "list" then
          fields[i] = { kind = "list", value = walk(f.value) }
        elseif f.kind == "name" then
          fields[i] = { kind = "name", name = f.name, value = walk(f.value) }
        elseif f.kind == "key" then
          fields[i] = { kind = "key", key = walk(f.key), value = walk(f.value) }
        end
      end
      return { tag = "table", fields = fields }
    else
      return e
    end
  end
  return walk(expr), awaits
end

local function emit_async_fn(fn, lines)
  local ctx = { params = {}, locals = {} }
  for _, p in ipairs(fn.params) do
    ctx.params[p] = true
    ctx.locals[p] = true
  end

  local tmp_id = { 0 }
  local label_id = { 0 }
  local function fresh_label(prefix)
    local id = label_id[1]
    label_id[1] = id + 1
    return (prefix or "L") .. id
  end

  -- try 处理器栈：{ catch_l, finally_l, join_l, in_finally }
  local handler_stack = {}
  local function current_handler()
    return handler_stack[#handler_stack]
  end

  local ops = {}
  local function add_code(lua_line)
    ops[#ops + 1] = { kind = "code", line = lua_line }
  end

  local function fail_info_for_await()
    local h = current_handler()
    if not h then return nil end
    if h.catch_l then
      return { target = h.catch_l, mode = "catch" }
    elseif h.finally_l then
      return { target = h.finally_l, mode = "propagate" }
    end
    return nil
  end

  local function emit_await_op(tmp, expr)
    ops[#ops + 1] = {
      kind = "await",
      tmp = tmp,
      expr = expr,
      fail = fail_info_for_await(),
    }
  end

  local function emit_awaits_then(expr, after_fn)
    local rewritten, awaits = lower_awaits(expr, tmp_id)
    for _, a in ipairs(awaits) do
      ctx.locals[a.tmp] = true
      emit_await_op(a.tmp, a.expr)
    end
    after_fn(rewritten)
  end

  --- return：若有 finally，则挂起返回值并 goto finally
  local function emit_return(expr_node)
    local h = current_handler()
    -- 找最外层仍需执行的 finally（从内到外）
    local finally_target = nil
    for i = #handler_stack, 1, -1 do
      local hh = handler_stack[i]
      if hh.finally_l and not hh.in_finally then
        finally_target = hh.finally_l
        break
      end
    end
    if finally_target then
      if expr_node then
        add_code("self._return_val = " .. emit_expr(expr_node, ctx))
      else
        add_code("self._return_val = nil")
      end
      add_code("self._has_return = true")
      add_code("self._propagate = false")
      ops[#ops + 1] = { kind = "goto", target = finally_target }
    else
      ops[#ops + 1] = { kind = "return", expr = expr_node }
    end
  end

  local lower_stmts

  local function lower_stmt(stmt)
    if stmt.tag == "local" then
      ctx.locals[stmt.name] = true
      emit_awaits_then(stmt.expr, function(rewritten)
        add_code("self._locals." .. stmt.name .. " = " .. emit_expr(rewritten, ctx))
      end)
    elseif stmt.tag == "assign" then
      ctx.locals[stmt.name] = true
      emit_awaits_then(stmt.expr, function(rewritten)
        add_code("self._locals." .. stmt.name .. " = " .. emit_expr(rewritten, ctx))
      end)
    elseif stmt.tag == "assign_index" then
      local rewritten_e, awaits_e = lower_awaits(stmt.expr, tmp_id)
      for _, a in ipairs(awaits_e) do
        ctx.locals[a.tmp] = true
        emit_await_op(a.tmp, a.expr)
      end
      local tgt, awaits_t = lower_awaits(stmt.target, tmp_id)
      for _, a in ipairs(awaits_t) do
        ctx.locals[a.tmp] = true
        emit_await_op(a.tmp, a.expr)
      end
      add_code(emit_expr(tgt, ctx) .. " = " .. emit_expr(rewritten_e, ctx))
    elseif stmt.tag == "expr_stmt" then
      emit_awaits_then(stmt.expr, function(rewritten)
        add_code(emit_expr(rewritten, ctx))
      end)
    elseif stmt.tag == "return" then
      if stmt.expr then
        emit_awaits_then(stmt.expr, function(rewritten)
          emit_return(rewritten)
        end)
      else
        emit_return(nil)
      end
    elseif stmt.tag == "rethrow" then
      local h = current_handler()
      local finally_target = nil
      for i = #handler_stack, 1, -1 do
        local hh = handler_stack[i]
        if hh.finally_l and not hh.in_finally then
          finally_target = hh.finally_l
          break
        end
      end
      if stmt.expr then
        emit_awaits_then(stmt.expr, function(rewritten)
          add_code("self._err = " .. emit_expr(rewritten, ctx))
          add_code("if type(self._err) == \"table\" and self._err.canceled then self._err_kind = \"canceled\" else self._err_kind = \"rejected\" end")
        end)
      end
      -- else keep existing self._err from catch
      add_code("self._propagate = true")
      add_code("self._has_return = false")
      if finally_target then
        ops[#ops + 1] = { kind = "goto", target = finally_target }
      else
        ops[#ops + 1] = { kind = "propagate_err" }
      end
    elseif stmt.tag == "if" then
      local join_l = fresh_label("endif")
      local function emit_branch_chain(cond, then_body, elseifs, else_body, idx)
        emit_awaits_then(cond, function(rewritten)
          local this_then = fresh_label("th")
          local this_else = fresh_label("el")
          ops[#ops + 1] = {
            kind = "branch",
            cond = rewritten,
            then_t = this_then,
            else_t = this_else,
          }
          ops[#ops + 1] = { kind = "label", name = this_then }
          lower_stmts(then_body)
          ops[#ops + 1] = { kind = "goto", target = join_l }
          ops[#ops + 1] = { kind = "label", name = this_else }
          if elseifs and idx <= #elseifs then
            local ei = elseifs[idx]
            emit_branch_chain(ei.cond, ei.body, elseifs, else_body, idx + 1)
          else
            if else_body then
              lower_stmts(else_body)
            end
            ops[#ops + 1] = { kind = "goto", target = join_l }
          end
        end)
      end
      emit_branch_chain(stmt.cond, stmt.then_body, stmt.elseifs or {}, stmt.else_body, 1)
      ops[#ops + 1] = { kind = "label", name = join_l }
    elseif stmt.tag == "while" then
      local head = fresh_label("wh")
      local body_l = fresh_label("wb")
      local exit_l = fresh_label("we")
      ops[#ops + 1] = { kind = "label", name = head }
      emit_awaits_then(stmt.cond, function(rewritten)
        ops[#ops + 1] = {
          kind = "branch",
          cond = rewritten,
          then_t = body_l,
          else_t = exit_l,
        }
      end)
      ops[#ops + 1] = { kind = "label", name = body_l }
      lower_stmts(stmt.body)
      ops[#ops + 1] = { kind = "goto", target = head }
      ops[#ops + 1] = { kind = "label", name = exit_l }
    elseif stmt.tag == "for" then
      ctx.locals[stmt.name] = true
      local uid = label_id[1]
      label_id[1] = uid + 1
      local step_name = "_fs" .. uid
      local stop_tmp = "_ft" .. uid
      ctx.locals[step_name] = true
      ctx.locals[stop_tmp] = true
      emit_awaits_then(stmt.start, function(rs)
        add_code("self._locals." .. stmt.name .. " = " .. emit_expr(rs, ctx))
      end)
      emit_awaits_then(stmt.stop, function(rs)
        add_code("self._locals." .. stop_tmp .. " = " .. emit_expr(rs, ctx))
      end)
      local step_expr = stmt.step or { tag = "number", value = 1 }
      emit_awaits_then(step_expr, function(st)
        add_code("self._locals." .. step_name .. " = " .. emit_expr(st, ctx))
      end)
      local head = fresh_label("fh")
      local body_l = fresh_label("fb")
      local exit_l = fresh_label("fe")
      ops[#ops + 1] = { kind = "label", name = head }
      local cond_code = string.format(
        "((self._locals.%s > 0 and self._locals.%s <= self._locals.%s) or (self._locals.%s <= 0 and self._locals.%s >= self._locals.%s))",
        step_name, stmt.name, stop_tmp, step_name, stmt.name, stop_tmp
      )
      ops[#ops + 1] = {
        kind = "branch",
        raw_cond = cond_code,
        then_t = body_l,
        else_t = exit_l,
      }
      ops[#ops + 1] = { kind = "label", name = body_l }
      lower_stmts(stmt.body)
      add_code("self._locals." .. stmt.name .. " = self._locals." .. stmt.name .. " + self._locals." .. step_name)
      ops[#ops + 1] = { kind = "goto", target = head }
      ops[#ops + 1] = { kind = "label", name = exit_l }
    elseif stmt.tag == "try" then
      local catch_l = stmt.catch_body and fresh_label("catch") or nil
      local finally_l = stmt.finally_body and fresh_label("fin") or nil
      local join_l = fresh_label("tryend")

      handler_stack[#handler_stack + 1] = {
        catch_l = catch_l,
        finally_l = finally_l,
        join_l = join_l,
        in_finally = false,
      }
      lower_stmts(stmt.body)
      handler_stack[#handler_stack] = nil

      -- 正常离开 try body
      if finally_l then
        add_code("self._propagate = false")
        ops[#ops + 1] = { kind = "goto", target = finally_l }
      else
        add_code("self._err = nil")
        ops[#ops + 1] = { kind = "goto", target = join_l }
      end

      if stmt.catch_body then
        ops[#ops + 1] = { kind = "label", name = catch_l }
        if stmt.catch_name then
          ctx.locals[stmt.catch_name] = true
          add_code("self._locals." .. stmt.catch_name .. " = self._err")
        end
        handler_stack[#handler_stack + 1] = {
          catch_l = nil,
          finally_l = finally_l,
          join_l = join_l,
          in_finally = false,
        }
        lower_stmts(stmt.catch_body)
        handler_stack[#handler_stack] = nil
        if finally_l then
          add_code("self._propagate = false")
          ops[#ops + 1] = { kind = "goto", target = finally_l }
        else
          add_code("self._err = nil")
          ops[#ops + 1] = { kind = "goto", target = join_l }
        end
      end

      if stmt.finally_body then
        ops[#ops + 1] = { kind = "label", name = finally_l }
        handler_stack[#handler_stack + 1] = {
          catch_l = nil,
          finally_l = nil,
          join_l = join_l,
          in_finally = true,
        }
        lower_stmts(stmt.finally_body)
        handler_stack[#handler_stack] = nil
        ops[#ops + 1] = { kind = "finally_exit", join = join_l }
      end

      ops[#ops + 1] = { kind = "label", name = join_l }
    else
      error("unknown stmt: " .. tostring(stmt.tag))
    end
  end

  lower_stmts = function(stmts)
    for _, s in ipairs(stmts) do
      lower_stmt(s)
    end
  end

  lower_stmts(fn.body)

  local blocks = {}
  local label_to_block = {}
  local cur = { codes = {}, edge = nil }

  local function flush_block()
    blocks[#blocks + 1] = cur
    cur = { codes = {}, edge = nil }
  end

  for _, op in ipairs(ops) do
    if op.kind == "label" then
      if #cur.codes > 0 or cur.edge then
        if not cur.edge then
          cur.edge = { kind = "goto", target = op.name }
        end
        flush_block()
      end
      label_to_block[op.name] = #blocks
    elseif op.kind == "code" then
      cur.codes[#cur.codes + 1] = op.line
    elseif op.kind == "await" or op.kind == "return" or op.kind == "goto"
        or op.kind == "branch" or op.kind == "finally_exit" or op.kind == "propagate_err" then
      cur.edge = op
      flush_block()
    end
  end
  if #cur.codes > 0 or cur.edge then
    flush_block()
  end
  if #blocks == 0 then
    blocks[1] = { codes = {}, edge = { kind = "return", expr = nil } }
  elseif not blocks[#blocks].edge then
    blocks[#blocks].edge = { kind = "return", expr = nil }
  end

  local function resolve_label(name)
    local i = label_to_block[name]
    if i == nil then error("unknown label: " .. tostring(name)) end
    while i >= #blocks do
      blocks[#blocks + 1] = { codes = {}, edge = { kind = "return", expr = nil } }
    end
    return i
  end

  for _, bl in ipairs(blocks) do
    local e = bl.edge
    if e then
      if e.kind == "goto" then resolve_label(e.target)
      elseif e.kind == "branch" then
        resolve_label(e.then_t)
        resolve_label(e.else_t)
      elseif e.kind == "finally_exit" then
        resolve_label(e.join)
      elseif e.kind == "await" and e.fail then
        resolve_label(e.fail.target)
      end
    end
  end

  for i, bl in ipairs(blocks) do
    if bl.edge and bl.edge.kind == "await" then
      if i >= #blocks then
        blocks[#blocks + 1] = { codes = {}, edge = { kind = "return", expr = nil } }
      end
      bl.edge.resume = i
    end
  end

  local param_list = table.concat(fn.params, ", ")
  lines[#lines + 1] = "function " .. fn.name .. "(" .. param_list .. ")"
  lines[#lines + 1] = "  local sm = { _state = 0, _locals = {}, _await_tmp = nil, _fail_to = nil, _fail_mode = nil, _err = nil, _err_kind = nil, _propagate = false, _has_return = false, _return_val = nil }"
  for _, p in ipairs(fn.params) do
    lines[#lines + 1] = "  sm._locals." .. p .. " = " .. p
  end
  lines[#lines + 1] = "  function sm:step(ok, val)"
  lines[#lines + 1] = "    if ok ~= true then"
  lines[#lines + 1] = "      if self._fail_to ~= nil then"
  lines[#lines + 1] = "        self._err = val"
  lines[#lines + 1] = "        self._err_kind = (ok == \"canceled\") and \"canceled\" or \"rejected\""
  lines[#lines + 1] = "        if self._fail_mode == \"propagate\" then self._propagate = true end"
  lines[#lines + 1] = "        self._state = self._fail_to"
  lines[#lines + 1] = "        self._fail_to = nil"
  lines[#lines + 1] = "        self._fail_mode = nil"
  lines[#lines + 1] = "        self._await_tmp = nil"
  lines[#lines + 1] = "      else"
  lines[#lines + 1] = "        if ok == \"canceled\" then return Task.canceled(val) end"
  lines[#lines + 1] = "        return Task.rejected(val)"
  lines[#lines + 1] = "      end"
  lines[#lines + 1] = "    else"
  lines[#lines + 1] = "      if self._await_tmp then"
  lines[#lines + 1] = "        self._locals[self._await_tmp] = val"
  lines[#lines + 1] = "        self._await_tmp = nil"
  lines[#lines + 1] = "      end"
  lines[#lines + 1] = "    end"
  lines[#lines + 1] = "    while true do"
  lines[#lines + 1] = "      local s = self._state"

  for si, st in ipairs(blocks) do
    local idx = si - 1
    local prefix = (si == 1) and "      if" or "      elseif"
    lines[#lines + 1] = prefix .. " s == " .. idx .. " then"
    for _, code in ipairs(st.codes) do
      lines[#lines + 1] = "        " .. code
    end
    local e = st.edge
    if e and e.kind == "await" then
      lines[#lines + 1] = "        self._state = " .. e.resume
      lines[#lines + 1] = "        self._await_tmp = " .. quote_string(e.tmp)
      if e.fail then
        local fail_idx = resolve_label(e.fail.target)
        lines[#lines + 1] = "        self._fail_to = " .. fail_idx
        lines[#lines + 1] = "        self._fail_mode = " .. quote_string(e.fail.mode)
      else
        lines[#lines + 1] = "        self._fail_to = nil"
        lines[#lines + 1] = "        self._fail_mode = nil"
      end
      lines[#lines + 1] = "        return Task.await_then(" .. emit_expr(e.expr, ctx) .. ", self)"
    elseif e and e.kind == "return" then
      if e.expr then
        lines[#lines + 1] = "        return Task.resolved(" .. emit_expr(e.expr, ctx) .. ")"
      else
        lines[#lines + 1] = "        return Task.resolved(nil)"
      end
    elseif e and e.kind == "goto" then
      lines[#lines + 1] = "        self._state = " .. resolve_label(e.target)
    elseif e and e.kind == "branch" then
      local t1 = resolve_label(e.then_t)
      local t2 = resolve_label(e.else_t)
      local cond = e.raw_cond or emit_expr(e.cond, ctx)
      lines[#lines + 1] = "        if " .. cond .. " then"
      lines[#lines + 1] = "          self._state = " .. t1
      lines[#lines + 1] = "        else"
      lines[#lines + 1] = "          self._state = " .. t2
      lines[#lines + 1] = "        end"
    elseif e and e.kind == "finally_exit" then
      local join_i = resolve_label(e.join)
      lines[#lines + 1] = "        if self._has_return then"
      lines[#lines + 1] = "          local rv = self._return_val"
      lines[#lines + 1] = "          self._has_return = false"
      lines[#lines + 1] = "          self._return_val = nil"
      lines[#lines + 1] = "          self._err = nil"
      lines[#lines + 1] = "          return Task.resolved(rv)"
      lines[#lines + 1] = "        elseif self._propagate then"
      lines[#lines + 1] = "          local ek = self._err_kind"
      lines[#lines + 1] = "          local ev = self._err"
      lines[#lines + 1] = "          self._propagate = false"
      lines[#lines + 1] = "          self._err = nil"
      lines[#lines + 1] = "          if ek == \"canceled\" then return Task.canceled(ev) end"
      lines[#lines + 1] = "          return Task.rejected(ev)"
      lines[#lines + 1] = "        else"
      lines[#lines + 1] = "          self._err = nil"
      lines[#lines + 1] = "          self._state = " .. join_i
      lines[#lines + 1] = "        end"
    elseif e and e.kind == "propagate_err" then
      lines[#lines + 1] = "        local ek = self._err_kind"
      lines[#lines + 1] = "        local ev = self._err"
      lines[#lines + 1] = "        self._propagate = false"
      lines[#lines + 1] = "        self._err = nil"
      lines[#lines + 1] = "        if ek == \"canceled\" then return Task.canceled(ev) end"
      lines[#lines + 1] = "        return Task.rejected(ev)"
    else
      lines[#lines + 1] = "        return Task.resolved(nil)"
    end
  end

  lines[#lines + 1] = "      else"
  lines[#lines + 1] = "        return Task.rejected(\"bad state \" .. tostring(s))"
  lines[#lines + 1] = "      end"
  lines[#lines + 1] = "    end"
  lines[#lines + 1] = "  end"
  lines[#lines + 1] = "  return sm:step(true)"
  lines[#lines + 1] = "end"
  lines[#lines + 1] = ""
end

function Codegen.generate_function(fn)
  local lines = {}
  emit_async_fn(fn, lines)
  return table.concat(lines, "\n")
end

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
