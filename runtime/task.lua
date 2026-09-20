-- Task: promise-like runtime without coroutines.
-- Status: pending | fulfilled | rejected

local Task = {}
Task.__index = Task

local queue = {}

function Task.defer(fn)
  queue[#queue + 1] = fn
end

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

-- ok(value) / err(reason); either may be nil
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

-- When task settles, call sm:step(ok, value_or_err) and return its result (for chaining).
function Task.await_then(task, sm)
  return task:andThen(
    function(v) return sm:step(true, v) end,
    function(e) return sm:step(false, e) end
  )
end

return Task
