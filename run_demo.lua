#!/usr/bin/env lua
-- Demo runner: package.path, delay via Task.defer, pump until done.

local root = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local Task = require("runtime.task")

-- delay(ms): for MVP, ignore real time; schedule resolve with Task.defer.
-- Returns the ms value so demos can use it in arithmetic.
function delay(ms)
  local t = Task.new()
  Task.defer(function()
    t:resolve(ms)
  end)
  return t
end

-- Which demo: "hello" (default) or "chain"
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

mod_or_err()  -- defines hello / add_one / main in global env

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

-- Pump microtasks until settled
local guard = 0
while not printed and guard < 10000 do
  Task.pump()
  guard = guard + 1
end

if not printed then
  io.stderr:write("Demo did not finish (queue stuck?)\n")
  os.exit(1)
end
