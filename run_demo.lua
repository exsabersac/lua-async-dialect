#!/usr/bin/env lua
--[[
  Demo 入口：配置 package.path，提供 delay（Task.defer 模拟），
  加载转译后的示例，andThen 打印结果，并 pump 微任务直至结算。
  用法：lua run_demo.lua [hello|chain]
]]

local root = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local Task = require("runtime.task")

-- delay(ms)：MVP 不睡真实时间；defer 里 resolve 为 ms，便于算术演示
function delay(ms)
  local t = Task.new()
  Task.defer(function()
    t:resolve(ms)
  end)
  return t
end

local which = arg[1] or "hello"

local ok_load, mod_or_err = pcall(function()
  if which == "hello" then
    return assert(loadfile(root .. "/examples/hello.lua"))
  elseif which == "chain" then
    return assert(loadfile(root .. "/examples/chain.lua"))
  else
    error("unknown demo: " .. tostring(which) .. " (use hello|chain)")
  end
end)

if not ok_load then
  io.stderr:write("Load failed (transpile first?): " .. tostring(mod_or_err) .. "\n")
  os.exit(1)
end

mod_or_err()  -- 在全局环境定义 hello / add_one / main

local result_task
if which == "hello" then
  result_task = hello()
else
  result_task = main()
end

local printed = false
result_task:andThen(function(v)
  print("RESULT:", v)
  printed = true
end, function(e)
  print("ERROR:", e)
  printed = true
end)

-- 排空微任务直到结果回调执行（有守卫防止死循环）
local guard = 0
while not printed and guard < 10000 do
  Task.pump()
  guard = guard + 1
end

if not printed then
  io.stderr:write("Demo did not finish (queue stuck?)\n")
  os.exit(1)
end
