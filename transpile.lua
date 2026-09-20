#!/usr/bin/env lua
--[[
  CLI 转译器：.alua → .lua（嵌入式方言 / splice）
  管线：Splice 扫描 → 对 async 区域 Lexer → Parser → Codegen；其余原样拷贝。
  用法：lua transpile.lua <input.alua> [-o out.lua] [--stdout]
]]

local function dirname(path)
  return path:match("^(.*)/[^/]+$") or "."
end

local function change_ext(path, newext)
  if path:match("%.alua$") then
    return path:gsub("%.alua$", newext)
  end
  return path .. newext
end

local script_dir = dirname(arg[0])
package.path = script_dir .. "/?.lua;" .. script_dir .. "/?/init.lua;" .. package.path

local Splice = require("lib.splice")

local input, output, to_stdout
local i = 1
while i <= #arg do
  local a = arg[i]
  if a == "-o" then
    i = i + 1
    output = arg[i]
  elseif a == "--stdout" then
    to_stdout = true
  elseif a:sub(1, 1) == "-" then
    io.stderr:write("Unknown flag: " .. a .. "\n")
    os.exit(1)
  else
    input = a
  end
  i = i + 1
end

if not input then
  io.stderr:write("Usage: lua transpile.lua <input.alua> [-o out.lua] [--stdout]\n")
  os.exit(1)
end

local f, err = io.open(input, "r")
if not f then
  io.stderr:write("Cannot open " .. input .. ": " .. tostring(err) .. "\n")
  os.exit(1)
end
local src = f:read("*a")
f:close()

local ok, result = pcall(function()
  return Splice.transpile(src, {
    task_require = 'require("runtime.task")',
  })
end)

if not ok then
  io.stderr:write("Transpile error: " .. tostring(result) .. "\n")
  os.exit(1)
end

local code = result

if to_stdout and not output then
  io.write(code)
  if code:sub(-1) ~= "\n" then io.write("\n") end
  os.exit(0)
end

if not output then
  output = change_ext(input, ".lua")
end

local outf, oerr = io.open(output, "w")
if not outf then
  io.stderr:write("Cannot write " .. output .. ": " .. tostring(oerr) .. "\n")
  os.exit(1)
end
outf:write(code)
if code:sub(-1) ~= "\n" then outf:write("\n") end
outf:close()
io.stderr:write("Wrote " .. output .. "\n")
