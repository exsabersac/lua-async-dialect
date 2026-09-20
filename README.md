# lua-async-dialect

极简 Lua 方言：C# 风格 `async function` / `await`，转译为**表状态机**（Task），**不使用** `coroutine`。

## 语法（MVP）

```
async function Name ( [Name (, Name)*] ) block end
```

语句：`local Name = exp`、`Name = exp`、裸调用、`return [exp]`

表达式：`await exp`、数字、字符串、名字、调用、`+ - * /`、括号

关键字：`async` `function` `end` `local` `return` `await`

**未实现**：if/while/for、取消、方法 `:`、表字面量、可变参数。

## 布局

```
runtime/task.lua   # Task 运行时（pending|fulfilled|rejected）
lib/lexer.lua
lib/parser.lua
lib/codegen.lua
transpile.lua      # CLI
examples/*.alua
run_demo.lua
```

## 转译

在项目根目录：

```bash
lua transpile.lua examples/hello.alua -o examples/hello.lua
lua transpile.lua examples/chain.alua -o examples/chain.lua
# 或
bash scripts/build_examples.sh
```

生成文件会 `require("runtime.task")`，请从项目根运行并保证 `package.path` 含项目根（`run_demo.lua` 已处理）。

## 运行 Demo

```bash
bash scripts/build_examples.sh
lua run_demo.lua hello   # 期望 RESULT: 30   (10+20)
lua run_demo.lua chain   # 期望 RESULT: 20   (10+5, then 15+5)
```

`delay(ms)` 在 demo 里用 `Task.defer` 模拟，立即 resolve 为 `ms` 数值（不睡真实时间）。

## 运行时要点

- `Task:andThen(ok, err)` / `:resolve` / `:reject`
- `Task.await_then(task, sm)`：结算后调用 `sm:step(ok, val)`
- `Task.defer` + `Task.pump`：微任务队列（demo/测试用）

Cancellation 不在本 MVP 范围。

## 设计说明

每个 `async function` 变成返回 Task 的函数；`await` 推进 `_state` 并 `return Task.await_then(...)`。拒绝的 Task 走 `sm:step(false, err)` → `Task.rejected(err)`。
