#!/usr/bin/env lua
--[[
  Demo 入口：配置 package.path，提供 delay（支持可选 CancellationToken /
  ambient Cancellation.current()），加载转译后的示例并 pump 至结算。
  用法：lua run_demo.lua [hello|chain|mixed|pipeline|branching|
                          cancel_scope|when_all|try_catch|all]
]]

local root = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local Task = require("runtime.task")
local Cancellation = require("runtime.cancellation")
local errors = require("runtime.errors")

-- 全局供示例使用
_G.Task = Task
_G.Cancellation = Cancellation

--- delay(ms, ct?)：若 ct（或 ambient）已取消则立即 canceled；
--- 否则 defer 兑现为 ms，并在 ct 上 register 以便中途取消。
function delay(ms, ct)
  if ct == nil then
    ct = Cancellation.current()
  end
  local t = Task.new()
  if ct and ct ~= Cancellation.none and ct:is_cancellation_requested() then
    t:cancel(errors.canceled(ct))
    return t
  end
  local unreg = nil
  if ct and ct ~= Cancellation.none then
    unreg = ct:register(function()
      t:cancel(errors.canceled(ct))
    end)
  end
  Task.defer(function()
    if t._status ~= "pending" then
      return
    end
    if unreg then unreg() end
    t:resolve(ms)
  end)
  return t
end

local demos = {
  hello = {
    file = "examples/hello.lua",
    run = function() return hello() end,
    expect = 30,
  },
  chain = {
    file = "examples/chain.lua",
    run = function() return main() end,
    expect = 20,
  },
  mixed = {
    file = "examples/mixed_lua.lua",
    run = function() return run_mixed() end,
    expect = 42,
  },
  pipeline = {
    file = "examples/pipeline.lua",
    run = function() return run_pipeline() end,
    expect = 110,
  },
  branching = {
    file = "examples/branching.lua",
    run = function() return run_branch(1) end,
    expect = 35,
  },
  cancel_scope = {
    file = "examples/cancel_scope.lua",
    run = function() return run_cancel_scope() end,
    expect = "canceled",
  },
  when_all = {
    file = "examples/when_all.lua",
    run = function() return run_when_all() end,
    expect = 60,
  },
  try_catch = {
    file = "examples/try_catch.lua",
    run = function() return run_try_catch() end,
    expect = "caught-fin",
  },
}

local function run_one(which)
  local demo = demos[which]
  if not demo then
    error("unknown demo: " .. tostring(which))
  end
  local chunk = assert(loadfile(root .. "/" .. demo.file))
  chunk()
  local result_task = demo.run()
  local printed = false
  local got
  local got_status
  result_task:andThen(function(v)
    print("RESULT:", v)
    got = v
    got_status = "fulfilled"
    printed = true
  end, function(e)
    print("ERROR:", e)
    got = e
    got_status = "rejected"
    printed = true
  end, function(c)
    print("CANCELED:", c and c.message or c)
    got = c
    got_status = "canceled"
    printed = true
  end)
  local guard = 0
  while not printed and guard < 10000 do
    Task.pump()
    guard = guard + 1
  end
  if not printed then
    error("Demo did not finish (queue stuck?): " .. which)
  end
  if demo.expect ~= nil then
    if demo.expect_status then
      if got_status ~= demo.expect_status then
        error(string.format("Demo %s expected status %s, got %s",
          which, demo.expect_status, tostring(got_status)))
      end
    end
    if got ~= demo.expect then
      error(string.format("Demo %s expected %s, got %s", which, tostring(demo.expect), tostring(got)))
    end
  end
end

local which = arg[1] or "hello"

local ok, err = pcall(function()
  if which == "all" then
    local order = {
      "hello", "chain", "mixed", "pipeline", "branching",
      "cancel_scope", "when_all", "try_catch",
    }
    for _, name in ipairs(order) do
      print("== " .. name .. " ==")
      run_one(name)
    end
  else
    run_one(which)
  end
end)

if not ok then
  io.stderr:write("Demo failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
