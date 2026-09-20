--[[
  取消：CancellationTokenSource / CancellationToken / ambient Cancellation。
  无 coroutine；ambient 为协作式栈，并行 when_all 时请显式传 ct。
]]

local Task = require("runtime.task")
local errors = require("runtime.errors")

local Cancellation = {}

-- ── Token ──────────────────────────────────────────────────────────

local Token = {}
Token.__index = Token

local function token_new(src)
  return setmetatable({
    _src = src,
    _regs = {},
    _reg_id = 0,
  }, Token)
end

function Token:is_cancellation_requested()
  return self._src._canceled
end

function Token:throw_if_cancellation_requested()
  if self._src._canceled then
    error(errors.canceled(self), 0)
  end
end

--- register(cb) -> unregister()
function Token:register(cb)
  if type(cb) ~= "function" then
    error("CancellationToken:register expects function")
  end
  if self._src._canceled then
    Task.defer(function() cb() end)
    return function() end
  end
  self._reg_id = self._reg_id + 1
  local id = self._reg_id
  self._regs[id] = cb
  return function()
    self._regs[id] = nil
  end
end

function Token:_fire()
  local regs = self._regs
  self._regs = {}
  for _, cb in pairs(regs) do
    Task.defer(function()
      local ok, err = pcall(cb)
      if not ok then
        -- 回调错误不阻断其它回调
        io.stderr:write("CancellationToken register callback error: " .. tostring(err) .. "\n")
      end
    end)
  end
end

-- none singleton：永不取消
local none_src = { _canceled = false }
local none = token_new(none_src)
function none:register(_cb)
  return function() end
end
function none:throw_if_cancellation_requested() end
Cancellation.none = none
Token.none = none

-- ── CTS ────────────────────────────────────────────────────────────

local CTS = {}
CTS.__index = CTS

function CTS.new()
  local self = setmetatable({
    _canceled = false,
    _token = nil,
    _timer_cancel = nil,
  }, CTS)
  self._token = token_new(self)
  return self
end

function CTS:token()
  return self._token
end

function CTS:cancel(reason)
  if self._canceled then return end
  self._canceled = true
  self._reason = reason
  if self._timer_cancel then
    local tc = self._timer_cancel
    self._timer_cancel = nil
    pcall(tc)
  end
  self._token:_fire()
end

--- 在 ms 后 cancel。与 Task.delay 共用调度（宿主 timer 或内部堆）。
function CTS:cancel_after(ms)
  if self._canceled then return end
  local done = false
  local delay_task = Task.delay(ms, Cancellation.none)
  delay_task:andThen(function()
    if done then return end
    done = true
    self:cancel()
  end, function()
    done = true
  end, function()
    done = true
  end)
  self._timer_cancel = function()
    done = true
  end
end

Cancellation.CancellationTokenSource = CTS
Cancellation.CancellationToken = Token

-- ── Ambient stack ──────────────────────────────────────────────────

local stack = {}

function Cancellation.current()
  local n = #stack
  if n == 0 then return none end
  return stack[n]
end

function Cancellation.push(ct)
  stack[#stack + 1] = ct or none
end

function Cancellation.pop()
  if #stack > 0 then
    stack[#stack] = nil
  end
end

--- 同步压栈执行 fn；若 fn 返回 Task，则在 Task 结算后再弹栈。
function Cancellation.with_token(ct, fn)
  Cancellation.push(ct or none)
  local ok, result = pcall(fn)
  if not ok then
    Cancellation.pop()
    error(result, 0)
  end
  if type(result) == "table" and getmetatable(result) == Task then
    local out = Task.new()
    result:andThen(
      function(v)
        Cancellation.pop()
        out:resolve(v)
      end,
      function(e)
        Cancellation.pop()
        out:reject(e)
      end,
      function(c)
        Cancellation.pop()
        out:cancel(c)
      end
    )
    return out
  end
  Cancellation.pop()
  return result
end

--- 创建链接到 ambient 父 token 的 CTS，在 ambient 下执行 fn(cts)。
--- fn 可返回 Task；scope 返回的 Task 在结算时清理 ambient 与父链接。
function Cancellation.scope(fn)
  local cts = CTS.new()
  local parent = Cancellation.current()
  local unreg = nil
  if parent and parent ~= none then
    if parent:is_cancellation_requested() then
      cts:cancel()
    else
      unreg = parent:register(function()
        cts:cancel()
      end)
    end
  end

  local function cleanup()
    if unreg then
      unreg()
      unreg = nil
    end
    Cancellation.pop()
  end

  Cancellation.push(cts:token())
  local ok, result = pcall(fn, cts)
  if not ok then
    cleanup()
    return Task.rejected(result)
  end

  if type(result) == "table" and getmetatable(result) == Task then
    local out = Task.new()
    result:andThen(
      function(v)
        cleanup()
        out:resolve(v)
      end,
      function(e)
        cleanup()
        out:reject(e)
      end,
      function(c)
        cleanup()
        out:cancel(c)
      end
    )
    return out
  end

  cleanup()
  return Task.resolved(result)
end

Cancellation.cancel_scope = Cancellation.scope
Cancellation.canceled_error = errors.canceled
Cancellation.is_canceled = errors.is_canceled

return Cancellation
