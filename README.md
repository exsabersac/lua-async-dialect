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
| Lua 宿主 + 嵌入 async 块（splice） | 取消（cancellation） |
| async 体内：比较 / 逻辑 / `..` / `.` `[]` / `:` / 表构造 | 完整 Lua 语法兼容 |
| `if` / `while` / 数值 `for`，分支与循环内可 `await` | `coroutine` |
| Task 运行时（`andThen` / `defer` / `pump`） | |

详细设计见 [`docs/设计说明.md`](docs/设计说明.md)；文法见 [`docs/语法.md`](docs/语法.md)。

## async 体内语法速览

```
async function Name ( [Name (, Name)*] ) block end
```

- **语句**：`local` / 赋值 / 表达式语句 / `return` / `if`/`elseif`/`else` / `while` / 数值 `for`
- **表达式**：`await`、字面量、名字、调用、`obj:method()`、`a.b` / `a[i]`、表 `{...}`、
  `+ - * /`、`..`、比较、`and`/`or`/`not`、`#`
- **注释**：`--` 与 `--[[ ]]`（splice 扫描与 lexer 均识别）

## 仓库布局

```
runtime/task.lua     # Task 运行时
lib/splice.lua       # 嵌入式扫描 + 拼接转译
lib/lexer.lua        # async 区域词法
lib/parser.lua       # async 区域语法 → AST
lib/codegen.lua      # AST → 状态机 Lua
transpile.lua        # CLI：.alua → .lua
examples/*.alua      # 方言源文件（可混写普通 Lua）
examples/*.lua       # 转译产物
run_demo.lua         # 运行示例
scripts/build_examples.sh
docs/设计说明.md
docs/语法.md
```

## 如何转译

```bash
bash scripts/build_examples.sh
# 或单个：
lua transpile.lua examples/mixed_lua.alua -o examples/mixed_lua.lua
```

## 如何运行 Demo

```bash
bash scripts/build_examples.sh
lua run_demo.lua hello      # RESULT: 30
lua run_demo.lua chain      # RESULT: 20
lua run_demo.lua mixed      # RESULT: 42
lua run_demo.lua pipeline   # RESULT: 110
lua run_demo.lua branching  # RESULT: 35
lua run_demo.lua all        # 全部跑一遍
```

`delay(ms)` 在 demo 里用 `Task.defer` 模拟：不睡真实时间，resolve 为数值 `ms`。

## 示例说明

| 文件 | 内容 |
| --- | --- |
| `hello.alua` / `chain.alua` | 纯 async（透传区仅有注释） |
| `mixed_lua.alua` | 宿主表与辅助函数 + async 内 await 与拼接 |
| `pipeline.alua` | fetch 桩（`Task.resolved`）+ 变换 + await 链 |
| `branching.alua` | `if`/`else` 与 `while` 内 await |

## 运行时要点

- **状态**：`pending` → `fulfilled` / `rejected`
- **衔接**：`Task.await_then(task, sm)` → `sm:step(ok, val)`
- **微任务**：`Task.defer` / `Task.pump`

## 设计一句话

`.alua` = Lua 宿主文件；每个 `async function` 变成返回 Task 的普通函数；每个 `await` 推进 `_state` 并 `return Task.await_then(...)`；`if`/`while` 通过状态跳转保留结构。全程无协程。
