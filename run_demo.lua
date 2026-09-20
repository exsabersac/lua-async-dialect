#!/usr/bin/env lua
--[[
  Demo 入口：配置 package.path，提供 delay（Task.defer 模拟），
  加载转译后的示例，andThen 打印结果，并 pump 微任务直至结算。
  用法：lua run_demo.lua [hello|chain|mixed|pipeline|branching|all]
]]

local root = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local Task = require("runtime.task")

function delay(ms)
  local t = Task.new()
  Task.defer(function()
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
  result_task:andThen(function(v)
    print("RESULT:", v)
    got = v
    printed = true
  end, function(e)
    print("ERROR:", e)
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
  if demo.expect ~= nil and got ~= demo.expect then
    error(string.format("Demo %s expected %s, got %s", which, tostring(demo.expect), tostring(got)))
  end
end

local which = arg[1] or "hello"

local ok, err = pcall(function()
  if which == "all" then
    local order = { "hello", "chain", "mixed", "pipeline", "branching" }
    for _, name in ipairs(order) do
      print("== " .. name .. " ==")
      -- 每个 demo 在独立全局环境更干净，但 MVP 共用；重新 load 覆盖同名
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
