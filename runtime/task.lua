--[[
  Task 运行时：类 Promise / TAP 的异步原语，不使用 coroutine。

  状态：pending → fulfilled | rejected | canceled（终态）。

  公开 API（节选）：
    new / resolved / rejected / canceled / resolve / reject / cancel /
    andThen / await_then / defer / pump /
    when_all / when_any /
    set_timer / get_timer / set_clock / now / advance / next_timer_delay /
    delay / from_exception / faulted / from_canceled /
    forget / set_unhandled_rejection / on_unhandled_rejection
]]

local errors = require("runtime.errors")

local Task = {}
Task.__index = Task

-- ── 微任务队列 ─────────────────────────────────────────────────────
local queue = {}

-- ── 时钟（默认虚拟毫秒；Task.advance 推进）─────────────────────────
-- clock_fn：() -> number（毫秒）。nil 表示使用 virtual_ms。
local clock_fn = nil
local virtual_ms = 0

function Task.set_clock(fn)
  clock_fn = fn
end

function Task.get_clock()
  return clock_fn
end

--- 当前时间（毫秒）。默认虚拟时钟从 0 起，由 Task.advance 推进。
function Task.now()
  if clock_fn then
    return clock_fn()
  end
  return virtual_ms
end

-- ── 宿主定时器（可选）─────────────────────────────────────────────
-- host_timer(callback, ms) -> cancel_fn?  由宿主提供真实 sleep/定时
local host_timer = nil

function Task.set_timer(timer_fn)
  host_timer = timer_fn
end

function Task.get_timer()
  return host_timer
end

-- ── 内部定时器堆（无宿主 timer 时）────────────────────────────────
-- 条目：{ due = ms, cb = fn, canceled = bool }
local timers = {}

local function heap_sift_up(i)
  while i > 1 do
    local p = math.floor(i / 2)
    if timers[p].due <= timers[i].due then break end
    timers[p], timers[i] = timers[i], timers[p]
    i = p
  end
end

local function heap_sift_down(i)
  local n = #timers
  while true do
    local l = i * 2
    local r = l + 1
    local smallest = i
    if l <= n and timers[l].due < timers[smallest].due then smallest = l end
    if r <= n and timers[r].due < timers[smallest].due then smallest = r end
    if smallest == i then break end
    timers[i], timers[smallest] = timers[smallest], timers[i]
    i = smallest
  end
end

local function heap_push(entry)
  timers[#timers + 1] = entry
  heap_sift_up(#timers)
end

local function heap_pop()
  local n = #timers
  if n == 0 then return nil end
  local top = timers[1]
  timers[1] = timers[n]
  timers[n] = nil
  if n > 1 then heap_sift_down(1) end
  return top
end

local function heap_peek()
  return timers[1]
end

--- 调度 ms 后执行 cb。返回 cancel 函数。
--- 优先用宿主 Task.set_timer；否则写入内部堆，由 pump/advance 触发。
local function schedule_ms(ms, cb)
  ms = tonumber(ms) or 0
  if ms < 0 then ms = 0 end
  if host_timer then
    local cancel_fn = host_timer(cb, ms)
    if type(cancel_fn) == "function" then
      return cancel_fn
    end
    return function() end
  end
  local entry = { due = Task.now() + ms, cb = cb, canceled = false }
  heap_push(entry)
  return function()
    entry.canceled = true
  end
end

--- 触发所有 due <= now 的内部定时器（跳过已 cancel）
local function fire_due_timers()
  local now = Task.now()
  local fired = 0
  while true do
    local top = heap_peek()
    if not top or top.due > now then break end
    heap_pop()
    if not top.canceled then
      fired = fired + 1
      -- 定时器回调本身入微任务，保持与 defer 一致的异步边界
      local cb = top.cb
      queue[#queue + 1] = function() cb() end
    end
  end
  return fired
end

--- 距下一个未取消定时器的毫秒数；无则 nil
function Task.next_timer_delay()
  -- 清掉已取消的堆顶
  while true do
    local top = heap_peek()
    if not top then return nil end
    if top.canceled then
      heap_pop()
    else
      local d = top.due - Task.now()
      if d < 0 then d = 0 end
      return d
    end
  end
end

--- 虚拟时钟前进 ms 毫秒并触发到期定时器（仅默认虚拟时钟可用）。
--- 若已 set_clock，则只触发当前 now 下到期的定时器（不改外部钟）。
function Task.advance(ms)
  ms = tonumber(ms) or 0
  if not clock_fn then
    virtual_ms = virtual_ms + ms
  end
  fire_due_timers()
  return virtual_ms
end

--- 测试 / demo 隔离：清空微任务与内部定时器，虚拟时钟归零。
function Task.reset_scheduler()
  while #queue > 0 do table.remove(queue) end
  while #timers > 0 do table.remove(timers) end
  if not clock_fn then
    virtual_ms = 0
  end
end

--- 将 fn 排入微任务队列（不立即执行）
function Task.defer(fn)
  queue[#queue + 1] = fn
end

--- 排空微任务，并触发已到期的内部定时器；循环直至双空。
function Task.pump()
  local guard = 0
  while guard < 100000 do
    guard = guard + 1
    if #queue > 0 then
      local fn = table.remove(queue, 1)
      fn()
    else
      local fired = fire_due_timers()
      if fired == 0 then
        break
      end
    end
  end
end

-- ── 未观察拒绝 ─────────────────────────────────────────────────────
local unhandled_handler = nil

function Task.set_unhandled_rejection(handler)
  unhandled_handler = handler
end

function Task.on_unhandled_rejection(reason, task)
  if unhandled_handler then
    local ok, err = pcall(unhandled_handler, reason, task)
    if not ok then
      io.stderr:write("Task unhandled_rejection handler error: " .. tostring(err) .. "\n")
    end
  else
    local msg
    if type(reason) == "table" and reason.message then
      msg = reason.message
    else
      msg = tostring(reason)
    end
    io.stderr:write("Task unhandled rejection: " .. msg .. "\n")
  end
end

local function schedule_unhandled_check(task, reason)
  Task.defer(function()
    if task._handled then return end
    Task.on_unhandled_rejection(reason, task)
  end)
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
    _handled = false, -- andThen / forget / 成功路径观察
  }, Task)
end

function Task.resolved(v)
  local t = Task.new()
  t._status = "fulfilled"
  t._value = v
  t._handled = true
  return t
end

function Task.rejected(e)
  local t = Task.new()
  t._status = "rejected"
  t._value = e
  -- 已结算且尚无观察者：下一轮 microtask 检查
  schedule_unhandled_check(t, e)
  return t
end

--- 已取消的 Task；token_or_reason 可为 CancellationToken 或 errors.canceled 表
function Task.canceled(token_or_reason)
  local t = Task.new()
  t._status = "canceled"
  t._value = errors.canceled(token_or_reason)
  schedule_unhandled_check(t, t._value)
  return t
end

--- 别名：从异常构造已失败 Task（C# Task.FromException）
function Task.from_exception(e)
  return Task.rejected(e)
end

Task.faulted = Task.from_exception

--- 别名：已取消 Task（C# Task.FromCanceled）
function Task.from_canceled(token)
  return Task.canceled(token)
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
  if #cbs > 0 then
    self._handled = true
  end
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
  if #cbs > 0 then
    self._handled = true
    fire_cbs(cbs, e)
  else
    fire_cbs(cbs, e)
    if not self._handled then
      schedule_unhandled_check(self, e)
    end
  end
  return self
end

--- 结算为取消；已结算则忽略。
function Task:cancel(token_or_reason)
  if self._status ~= "pending" then return self end
  self._status = "canceled"
  self._value = errors.canceled(token_or_reason)
  local cbs = self._cancel_cbs
  self._ok_cbs, self._err_cbs, self._cancel_cbs = {}, {}, {}
  if #cbs > 0 then
    self._handled = true
    fire_cbs(cbs, self._value)
  else
    fire_cbs(cbs, self._value)
    if not self._handled then
      schedule_unhandled_check(self, self._value)
    end
  end
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
  self._handled = true
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

--- fire-and-forget：标记已观察并吞掉 reject/cancel，避免未处理拒绝。
--- 类似 C# async void：错误不会自动上浮，请只在明确不关心结果时使用。
--- 亦可 Task.forget(task)（同一函数，task 作 self）。
function Task:forget()
  self._handled = true
  self:andThen(
    function() end,
    function() end,
    function() end
  )
  return self
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

--- delay(ms, ct?)：ms 后兑现为 ms；支持 CancellationToken / ambient。
--- 无宿主 timer 时走内部堆 + virtual clock（配合 Task.advance / pump）。
function Task.delay(ms, ct)
  local Cancellation = require("runtime.cancellation")
  if ct == nil then
    ct = Cancellation.current()
  end
  local t = Task.new()
  if ct and ct ~= Cancellation.none and ct:is_cancellation_requested() then
    t:cancel(errors.canceled(ct))
    return t
  end
  local unreg = nil
  local cancel_timer = nil
  local settled = false
  local function cleanup()
    if unreg then
      unreg()
      unreg = nil
    end
    if cancel_timer then
      pcall(cancel_timer)
      cancel_timer = nil
    end
  end
  if ct and ct ~= Cancellation.none then
    unreg = ct:register(function()
      if settled then return end
      settled = true
      cleanup()
      t:cancel(errors.canceled(ct))
    end)
  end
  cancel_timer = schedule_ms(ms, function()
    if settled or t._status ~= "pending" then return end
    settled = true
    cleanup()
    t:resolve(ms)
  end)
  return t
end

local function normalize_task_list(tasks)
  if type(tasks) == "table" and getmetatable(tasks) == Task then
    return { tasks }
  end
  if type(tasks) ~= "table" then
    error("Task.when_all/when_any expects task array or varargs")
  end
  local list = tasks
  if #list == 0 and tasks[1] == nil then
    return {}
  end
  return list
end

--- WhenAll（近似 C#）：等待全部结算。
--- 策略：任一 rejected → 结果 rejected（取首个 reject reason）；
--- 否则任一 canceled → 结果 canceled；否则 fulfilled，值为各结果构成的数组。
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
