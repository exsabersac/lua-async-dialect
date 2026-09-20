#!/usr/bin/env lua
--[[
  Demo 入口：配置 package.path，提供 delay（委托 Task.delay），
  加载转译后的示例并用 pump + 虚拟时钟 advance 至结算。
  用法：lua run_demo.lua [hello|chain|mixed|pipeline|branching|
                          cancel_scope|when_all|when_any|try_catch|
                          delay_timer|forget|all]
]]

local root = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local Task = require("runtime.task")
local Cancellation = require("runtime.cancellation")
local errors = require("runtime.errors")

-- 全局供示例使用
_G.Task = Task
_G.Cancellation = Cancellation

--- delay(ms, ct?)：委托 Task.delay（内部堆 / 宿主 timer + 取消）
function delay(ms, ct)
  return Task.delay(ms, ct)
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
  when_any = {
    file = "examples/when_any.lua",
    run = function() return run_when_any() end,
    expect = 5,
  },
  try_catch = {
    file = "examples/try_catch.lua",
    run = function() return run_try_catch() end,
    expect = "caught-fin",
  },
  delay_timer = {
    file = "examples/delay_timer.lua",
    run = function() return run_delay_timer() end,
    expect = 30,
  },
  forget = {
    file = "examples/forget.lua",
    run = function() return run_forget() end,
    expect = "ok",
  },
}

local function drain_until(printed_fn)
  local guard = 0
  while not printed_fn() and guard < 10000 do
    Task.pump()
    if printed_fn() then break end
    local wait = Task.next_timer_delay()
    if wait == nil then
      -- 无定时器：再泵一次微任务后退出循环条件由 guard 处理
      Task.pump()
      if not printed_fn() then
        -- 可能卡在 pending 且无进展
        guard = guard + 1
        if guard > 10 and Task.next_timer_delay() == nil then
          -- 允许纯微任务多转几轮；若队列已空则失败
          break
        end
      end
    else
      -- 虚拟时钟跳到下一到期点（至少推进 0）
      Task.advance(wait)
    end
    guard = guard + 1
  end
end

local function run_one(which)
  local demo = demos[which]
  if not demo then
    error("unknown demo: " .. tostring(which))
  end
  -- 每个 demo 隔离：清空调度器 + 重置未处理 hook（forget 会自设）
  Task.reset_scheduler()
  Task.set_unhandled_rejection(function(reason, _task)
    -- demo 默认：打印但不使进程失败（forget 会覆盖）
    local msg = type(reason) == "table" and reason.message or tostring(reason)
    io.stderr:write("[demo unhandled] " .. msg .. "\n")
  end)

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

  drain_until(function() return printed end)

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
      "cancel_scope", "when_all", "when_any", "try_catch",
      "delay_timer", "forget",
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
