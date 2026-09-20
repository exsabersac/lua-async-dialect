# lua-async-dialect

极简 Lua **嵌入式异步方言**：`.alua` 文件以**标准 Lua 为宿主**（像 Makefile 嵌入 recipe），仅对顶层 `async function ... end` 区域做解析与降级；其余文本**原样透传**。转译产物是**表驱动 Task 状态机**，**不使用** `coroutine`。

## 嵌入式模型（一句话）

| 区域 | 处理 |
| --- | --- |
| 普通 Lua（`local`、表、`function`、`if`/`for`、方法等） | **原样拷贝**到输出 |
| `async function Name(...) ... end` | lex → parse → codegen 成状态机函数 |
| 若存在任一 async | 输出顶部插入一次 `local Task = require("runtime.task")` |

## 目标与非目标

| 做 | 不做 |
| --- | --- |
| Lua 宿主 + 嵌入 async 块（splice） | 完整 Lua 语法兼容（async 体内无匿名 function 表达式等） |
| async 体内：比较 / 逻辑 / `..` / `.` `[]` / `:` / 表 / `if` `while` `for` | `coroutine` |
| **try / catch / finally / rethrow**（跨 await） | 编译期自动注入 ambient（后续阶段） |
| **取消**：CTS / Token / ambient `Cancellation.scope` + `current` | |
| **WhenAll / WhenAny** | |
| Task：`fulfilled` / `rejected` / **`canceled`** | |

详细设计见 [`docs/设计说明.md`](docs/设计说明.md)；文法见 [`docs/语法.md`](docs/语法.md)。

## async 体内语法速览

```
async function Name ( [Name (, Name)*] ) block end
```

- **语句**：`local` / 赋值 / 表达式 / `return` / `rethrow` / `if` / `while` / 数值 `for` / **`try`…`catch`…`finally`…`end`**
- **表达式**：`await`、字面量、名字、调用、`obj:method()`、索引、表、算术、比较、`and`/`or`/`not`、`#`
- **注释**：`--` 与 `--[[ ]]`

## 取消（运行时）

```lua
local Cancellation = require("runtime.cancellation")

-- 推荐：scope + ambient（delay 读 Cancellation.current()）
local t = Cancellation.scope(function(cts)
  Task.defer(function() cts:cancel() end)
  return do_work()  -- async function
end)

-- 显式 token 仍可用：delay(ms, cts:token())
```

取消错误：`{ canceled = true, token = ..., message = "OperationCanceled" }`（见 `runtime/errors.lua`）。

## 组合子

- `Task.when_all({t1,t2,...})`：全部结算后汇总；**reject 优先于 cancel 优先于成功**（近似 C# WhenAll）。
- `Task.when_any(...)`：先到先得，值为 `{ index, value, status, task }`。

## 仓库布局

```
runtime/task.lua          # Task + when_all / when_any + canceled
runtime/cancellation.lua  # CTS / Token / ambient / scope
runtime/errors.lua        # canceled 错误形状
lib/splice.lua            # 嵌入式扫描 + 拼接
lib/lexer.lua / parser.lua / codegen.lua
transpile.lua             # CLI
examples/*.alua
run_demo.lua
docs/设计说明.md  docs/语法.md
```

## 如何转译与运行

```bash
bash scripts/build_examples.sh
lua run_demo.lua hello         # RESULT: 30
lua run_demo.lua chain         # RESULT: 20
lua run_demo.lua mixed         # RESULT: 42
lua run_demo.lua pipeline      # RESULT: 110
lua run_demo.lua branching     # RESULT: 35
lua run_demo.lua cancel_scope  # RESULT: canceled
lua run_demo.lua when_all      # RESULT: 60
lua run_demo.lua try_catch     # RESULT: caught-fin
lua run_demo.lua all
```

`delay(ms, ct?)` 在 demo 里用 `Task.defer` 模拟（不睡真实时间）；支持 ambient / 显式取消。

## 设计一句话

`.alua` = Lua 宿主文件；每个 `async function` 变成返回 Task 的普通函数；每个 `await` 推进 `_state` 并 `return Task.await_then(...)`；取消与 try 区域通过状态跳转保留；全程无协程。
