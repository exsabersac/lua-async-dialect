--[[
  Task 运行时：类 Promise 的异步原语，不使用 coroutine。

  状态：pending → fulfilled | rejected（终态）。
  公开 API：new / resolved / rejected / resolve / reject / andThen /
            await_then / defer / pump。
  设计意图：转译出的状态机通过 await_then 挂起与恢复；宿主用 defer+pump
  驱动微任务，避免在 resolve 回调里同步重入过深。
]]

local Task = {}
Task.__index = Task

-- 微任务队列（FIFO）；pump 时按序执行
local queue = {}

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

function Task.new()
  return setmetatable({
    _status = "pending",
    _value = nil,
    _ok_cbs = {},
    _err_cbs = {},
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

--- 结算为成功；已结算则忽略。回调经 defer 异步触发。
function Task:resolve(v)
  if self._status ~= "pending" then return self end
  self._status = "fulfilled"
  self._value = v
  local cbs = self._ok_cbs
  self._ok_cbs = {}
  self._err_cbs = {}
  for i = 1, #cbs do
    local cb = cbs[i]
    Task.defer(function() cb(v) end)
  end
  return self
end

--- 结算为失败；已结算则忽略。
function Task:reject(e)
  if self._status ~= "pending" then return self end
  self._status = "rejected"
  self._value = e
  local cbs = self._err_cbs
  self._ok_cbs = {}
  self._err_cbs = {}
  for i = 1, #cbs do
    local cb = cbs[i]
    Task.defer(function() cb(e) end)
  end
  return self
end

--- 链式续延。ok(value) / err(reason) 均可为 nil。
--- 回调若返回 Task（同元表），则扁平接到输出 Task；抛错则 reject。
function Task:andThen(ok, err)
  local out = Task.new()
  local function on_ok(v)
    if ok then
      local ok2, r = pcall(ok, v)
      if not ok2 then
        out:reject(r)
      elseif type(r) == "table" and getmetatable(r) == Task then
        r:andThen(function(v2) out:resolve(v2) end,
                   function(e2) out:reject(e2) end)
      else
        out:resolve(r)
      end
    else
      out:resolve(v)
    end
  end
  local function on_err(e)
    if err then
      local ok2, r = pcall(err, e)
      if not ok2 then
        out:reject(r)
      elseif type(r) == "table" and getmetatable(r) == Task then
        r:andThen(function(v2) out:resolve(v2) end,
                   function(e2) out:reject(e2) end)
      else
        out:resolve(r)
      end
    else
      out:reject(e)
    end
  end
  if self._status == "fulfilled" then
    Task.defer(function() on_ok(self._value) end)
  elseif self._status == "rejected" then
    Task.defer(function() on_err(self._value) end)
  else
    self._ok_cbs[#self._ok_cbs + 1] = on_ok
    self._err_cbs[#self._err_cbs + 1] = on_err
  end
  return out
end

--- 状态机挂起点：task 结算后调用 sm:step(ok, value_or_err)，并返回其结果以便继续链式。
--- 这是 await 降级的唯一运行时入口（无 coroutine.yield）。
function Task.await_then(task, sm)
  return task:andThen(
    function(v) return sm:step(true, v) end,
    function(e) return sm:step(false, e) end
  )
end

return Task
