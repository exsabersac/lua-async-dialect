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
| **try / catch / finally / rethrow**（跨 await） | 嵌套 `local async function`（仅顶层；从 Lua 调用 async 即可） |
| **取消**：CTS / Token / ambient `Cancellation.scope` + `current` | SynchronizationContext / IAsyncEnumerable（见上线清单） |
| **WhenAll / WhenAny** | |
| Task：`fulfilled` / `rejected` / **`canceled`** | |
| **Delay**：内部定时器堆 + 虚拟时钟 / 宿主 `set_timer` | |
| **forget** / 未观察拒绝钩子 / `from_exception` | |

详细设计见 [`docs/设计说明.md`](docs/设计说明.md)；文法见 [`docs/语法.md`](docs/语法.md)；上线范围见 [`docs/上线清单.md`](docs/上线清单.md)。

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

-- 推荐：scope + ambient（Task.delay / delay 读 Cancellation.current()）
local t = Cancellation.scope(function(cts)
  Task.defer(function() cts:cancel() end)
  return do_work()  -- async function
end)

-- 显式 token 仍可用：Task.delay(ms, cts:token())
```

取消错误：`{ canceled = true, token = ..., message = "OperationCanceled" }`（见 `runtime/errors.lua`）。

## Delay 与定时器

```lua
-- 默认：虚拟毫秒时钟 + 内部堆（测试 / demo 用 Task.advance）
local t = Task.delay(100)
Task.advance(100)
Task.pump()

-- 生产宿主：注入真实定时器 fn(callback, ms) -> cancel_fn?
Task.set_timer(function(cb, ms)
  local id = your_host.schedule(ms, cb)
  return function() your_host.cancel(id) end
end)

-- 或注入时钟（返回毫秒）：Task.set_clock(function() return ... end)
```

`run_demo.lua` 中全局 `delay(...)` 仅是 `Task.delay` 的薄封装。

## 组合子与辅助

- `Task.when_all({t1,t2,...})`：全部结算后汇总；**reject 优先于 cancel 优先于成功**（近似 C# WhenAll）。
- `Task.when_any(...)`：先到先得，值为 `{ index, value, status, task }`。
- `Task.from_exception(e)` / `Task.faulted(e)` / `Task.from_canceled(token?)`
- `task:forget()`：火忘式观察，抑制未处理拒绝（**慎用**，类 C# async void）。
- `Task.set_unhandled_rejection(handler)`：无观察者的 reject/cancel。

## 从 Lua 调用 async（嵌套说明）

顶层 `async function foo()` 转译后是普通 Lua 函数，返回 Task。宿主透传区可随意：

```lua
local function wrapper()
  return foo():andThen(function(v) return v + 1 end)
end
```

不支持在透传区写 `local async function`（splice 只认顶层 `async function` 关键字形式）。

## 仓库布局

```
runtime/task.lua          # Task + delay/定时器 + when_* + forget
runtime/cancellation.lua  # CTS / Token / ambient / scope
runtime/errors.lua        # canceled 错误形状
lib/splice.lua            # 嵌入式扫描 + 拼接
lib/lexer.lua / parser.lua / codegen.lua
transpile.lua             # CLI
examples/*.alua
run_demo.lua
docs/设计说明.md  docs/语法.md  docs/上线清单.md
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
lua run_demo.lua when_any      # RESULT: 5
lua run_demo.lua try_catch     # RESULT: caught-fin
lua run_demo.lua delay_timer   # RESULT: 30
lua run_demo.lua forget        # RESULT: ok
lua run_demo.lua all
```

## 设计一句话

`.alua` = Lua 宿主文件；每个 `async function` 变成返回 Task 的普通函数；每个 `await` 推进 `_state` 并 `return Task.await_then(...)`；取消与 try 区域通过状态跳转保留；Delay 走定时器堆或宿主 timer；全程无协程。
