--[[
  Task 运行时：类 Promise / TAP 的异步原语，不使用 coroutine。

  状态：pending → fulfilled | rejected | canceled（终态）。
  - fulfilled / rejected：成功与错误
  - canceled：协作取消（OperationCanceled），与 rejected 区分

  公开 API：new / resolved / rejected / canceled / resolve / reject / cancel /
            andThen / await_then / defer / pump / when_all / when_any /
            set_timer / get_timer。
]]

local errors = require("runtime.errors")

local Task = {}
Task.__index = Task

-- 微任务队列（FIFO）；pump 时按序执行
local queue = {}

-- 可选宿主定时器：timer_fn(ms, cb) -> cancel_fn
local host_timer = nil

function Task.set_timer(timer_fn)
  host_timer = timer_fn
end

function Task.get_timer()
  return host_timer
end

--- 将 fn 排入微任务队列（不立即执行）
function Task.defer(fn)
  queue[#queue + 1] = fn
end

--- 排空微任务队列；demo / 测试里循环调用直到业务 Task 结算
function Task.pump()
  while #queue > 0 do
    local fn = table.remove(queue, 1)
    fn()
  end
end

function Task.is_canceled_reason(e)
  return errors.is_canceled(e)
end

function Task.new()
  return setmetatable({
    _status = "pending",
    _value = nil,
    _ok_cbs = {},
    _err_cbs = {},
    _cancel_cbs = {},
  }, Task)
end

function Task.resolved(v)
  local t = Task.new()
  t._status = "fulfilled"
  t._value = v
  return t
end

function Task.rejected(e)
  local t = Task.new()
  t._status = "rejected"
  t._value = e
  return t
end

--- 已取消的 Task；token_or_reason 可为 CancellationToken 或 errors.canceled 表
function Task.canceled(token_or_reason)
  local t = Task.new()
  t._status = "canceled"
  t._value = errors.canceled(token_or_reason)
  return t
end

local function fire_cbs(cbs, arg)
  for i = 1, #cbs do
    local cb = cbs[i]
    Task.defer(function() cb(arg) end)
  end
end

--- 结算为成功；已结算则忽略。回调经 defer 异步触发。
function Task:resolve(v)
  if self._status ~= "pending" then return self end
  self._status = "fulfilled"
  self._value = v
  local cbs = self._ok_cbs
  self._ok_cbs, self._err_cbs, self._cancel_cbs = {}, {}, {}
  fire_cbs(cbs, v)
  return self
end

--- 结算为失败；已结算则忽略。
function Task:reject(e)
  if self._status ~= "pending" then return self end
  self._status = "rejected"
  self._value = e
  local cbs = self._err_cbs
  self._ok_cbs, self._err_cbs, self._cancel_cbs = {}, {}, {}
  fire_cbs(cbs, e)
  return self
end

--- 结算为取消；已结算则忽略。
function Task:cancel(token_or_reason)
  if self._status ~= "pending" then return self end
  self._status = "canceled"
  self._value = errors.canceled(token_or_reason)
  local cbs = self._cancel_cbs
  self._ok_cbs, self._err_cbs, self._cancel_cbs = {}, {}, {}
  fire_cbs(cbs, self._value)
  return self
end

local function attach_flatten(out, r)
  if type(r) == "table" and getmetatable(r) == Task then
    r:andThen(
      function(v2) out:resolve(v2) end,
      function(e2) out:reject(e2) end,
      function(c2) out:cancel(c2) end
    )
  else
    out:resolve(r)
  end
end

--- 链式续延。ok / err / cancel 均可为 nil。
--- 缺省 cancel 回调时向下游传播 canceled（不落入 err）。
--- 回调若返回 Task，则扁平接到输出 Task；抛错则 reject。
function Task:andThen(ok, err, cancel)
  local out = Task.new()
  local function on_ok(v)
    if ok then
      local ok2, r = pcall(ok, v)
      if not ok2 then
        if errors.is_canceled(r) then out:cancel(r) else out:reject(r) end
      else
        attach_flatten(out, r)
      end
    else
      out:resolve(v)
    end
  end
  local function on_err(e)
    if err then
      local ok2, r = pcall(err, e)
      if not ok2 then
        if errors.is_canceled(r) then out:cancel(r) else out:reject(r) end
      else
        attach_flatten(out, r)
      end
    else
      out:reject(e)
    end
  end
  local function on_cancel(c)
    if cancel then
      local ok2, r = pcall(cancel, c)
      if not ok2 then
        if errors.is_canceled(r) then out:cancel(r) else out:reject(r) end
      else
        attach_flatten(out, r)
      end
    else
      out:cancel(c)
    end
  end
  if self._status == "fulfilled" then
    Task.defer(function() on_ok(self._value) end)
  elseif self._status == "rejected" then
    Task.defer(function() on_err(self._value) end)
  elseif self._status == "canceled" then
    Task.defer(function() on_cancel(self._value) end)
  else
    self._ok_cbs[#self._ok_cbs + 1] = on_ok
    self._err_cbs[#self._err_cbs + 1] = on_err
    self._cancel_cbs[#self._cancel_cbs + 1] = on_cancel
  end
  return out
end

--- 状态机挂起点：task 结算后调用 sm:step(ok, value_or_err)
--- ok 为 true | false | "canceled"
function Task.await_then(task, sm)
  return task:andThen(
    function(v) return sm:step(true, v) end,
    function(e) return sm:step(false, e) end,
    function(c) return sm:step("canceled", c) end
  )
end

local function normalize_task_list(tasks)
  if type(tasks) == "table" and getmetatable(tasks) == Task then
    return { tasks }
  end
  if type(tasks) ~= "table" then
    error("Task.when_all/when_any expects task array or varargs")
  end
  -- varargs packed as array; also accept already-array
  local list = tasks
  if #list == 0 and tasks[1] == nil then
    -- empty
    return {}
  end
  return list
end

--- WhenAll（近似 C#）：等待全部结算。
--- 策略：任一 rejected → 结果 rejected（取首个 reject reason）；
--- 否则任一 canceled → 结果 canceled；否则 fulfilled，值为各结果构成的数组。
--- 接受数组或 varargs。
function Task.when_all(...)
  local n = select("#", ...)
  local tasks
  if n == 1 then
    local a = ...
    if type(a) == "table" and getmetatable(a) ~= Task then
      tasks = a
    else
      tasks = { a }
    end
  else
    tasks = { ... }
  end
  tasks = normalize_task_list(tasks)

  local out = Task.new()
  local count = #tasks
  if count == 0 then
    out:resolve({})
    return out
  end

  local values = {}
  local remaining = count
  local first_reject = nil
  local first_cancel = nil
  local settled = false

  local function check()
    if settled then return end
    if remaining > 0 then return end
    settled = true
    if first_reject ~= nil then
      out:reject(first_reject)
    elseif first_cancel ~= nil then
      out:cancel(first_cancel)
    else
      out:resolve(values)
    end
  end

  for i = 1, count do
    local t = tasks[i]
    if type(t) ~= "table" or getmetatable(t) ~= Task then
      error("Task.when_all: element " .. i .. " is not a Task")
    end
    t:andThen(
      function(v)
        values[i] = v
        remaining = remaining - 1
        check()
      end,
      function(e)
        if first_reject == nil then first_reject = e end
        remaining = remaining - 1
        check()
      end,
      function(c)
        if first_cancel == nil then first_cancel = c end
        remaining = remaining - 1
        check()
      end
    )
  end
  return out
end

--- WhenAny：第一个结算的任务获胜。
--- 兑现值为 { index = i, value = v, status = "fulfilled"|"rejected"|"canceled", task = t }
function Task.when_any(...)
  local n = select("#", ...)
  local tasks
  if n == 1 then
    local a = ...
    if type(a) == "table" and getmetatable(a) ~= Task then
      tasks = a
    else
      tasks = { a }
    end
  else
    tasks = { ... }
  end
  tasks = normalize_task_list(tasks)

  local out = Task.new()
  local count = #tasks
  if count == 0 then
    out:reject("Task.when_any: empty task list")
    return out
  end

  local done = false
  for i = 1, count do
    local t = tasks[i]
    if type(t) ~= "table" or getmetatable(t) ~= Task then
      error("Task.when_any: element " .. i .. " is not a Task")
    end
    t:andThen(
      function(v)
        if done then return end
        done = true
        out:resolve({ index = i, value = v, status = "fulfilled", task = t })
      end,
      function(e)
        if done then return end
        done = true
        out:resolve({ index = i, value = e, status = "rejected", task = t })
      end,
      function(c)
        if done then return end
        done = true
        out:resolve({ index = i, value = c, status = "canceled", task = t })
      end
    )
  end
  return out
end

return Task
