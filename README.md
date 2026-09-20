# lua-async-dialect

极简 Lua **异步方言**：用接近 C# 的 `async function` / `await` 写法，由转译器生成**表驱动状态机**（Task），**不使用** `coroutine`。

目标：在标准 Lua 上获得可组合的异步流程，同时把控制流显式落成状态与回调，便于审阅、调试，也避免协程与宿主事件循环纠缠。

## 目标与非目标

| 做 | 不做（MVP） |
| --- | --- |
| C# 风格 `async` / `await` 语法糖 | `if` / `while` / `for` |
| 转译为 Task 状态机 | 取消（cancellation） |
| 纯 Lua 运行时（`andThen` / `defer` / `pump`） | 方法调用 `:`、表字面量、可变参数 |
| 无 `coroutine` | 完整 Lua 语法兼容 |

详细设计见 [`docs/设计说明.md`](docs/设计说明.md)；MVP 文法见 [`docs/语法.md`](docs/语法.md)。

## MVP 语法速览

```
async function Name ( [Name (, Name)*] ) block end
```

- **语句**：`local Name = exp`、`Name = exp`、裸表达式（通常是调用）、`return [exp]`
- **表达式**：`await exp`、数字、字符串、名字、调用、`+ - * /`、括号、一元 `-`
- **关键字**：`async` `function` `end` `local` `return` `await`
- **注释**：`--` 行注释（与 Lua 相同）

**未实现**：控制流（if/while/for）、取消、方法 `:`、表字面量、可变参数、多返回值等。

## 仓库布局

```
runtime/task.lua     # Task 运行时（pending | fulfilled | rejected）
lib/lexer.lua        # 词法分析
lib/parser.lua       # 递归下降解析 → AST
lib/codegen.lua      # AST → 状态机 Lua
transpile.lua        # CLI：.alua → .lua
examples/*.alua      # 方言源文件
examples/*.lua       # 转译产物（可提交以便直接跑 demo）
run_demo.lua         # 加载示例并 pump 微任务队列
scripts/build_examples.sh
docs/设计说明.md
docs/语法.md
```

## 如何转译

在项目根目录：

```bash
lua transpile.lua examples/hello.alua -o examples/hello.lua
lua transpile.lua examples/chain.alua -o examples/chain.lua
# 或一次性：
bash scripts/build_examples.sh
```

也可用 `--stdout` 把生成代码打到标准输出。

生成文件会 `require("runtime.task")`。请从**项目根**运行，并保证 `package.path` 含项目根（`run_demo.lua` / `transpile.lua` 已处理相对路径）。

## 如何运行 Demo

```bash
bash scripts/build_examples.sh
lua run_demo.lua hello   # 期望 RESULT: 30   (10+20)
lua run_demo.lua chain   # 期望 RESULT: 20   (10+5, then 15+5)
```

`delay(ms)` 在 demo 里用 `Task.defer` 模拟：不睡真实时间，微任务里把 Task resolve 为数值 `ms`，便于算术演示。

## 运行时要点

- **状态**：`pending` → `fulfilled` / `rejected`
- **API**：`Task:andThen(ok, err)`、`:resolve` / `:reject`、`Task.resolved` / `Task.rejected`
- **与状态机衔接**：`Task.await_then(task, sm)` —— Task 结算后调用 `sm:step(ok, val)`
- **微任务**：`Task.defer` 入队，`Task.pump` 排空（demo / 测试用）

## 当前状态

- MVP 转译与 Task 运行时可用；示例 `hello` / `chain` 可通过。
- **尚无取消**：没有 `cancel_scope`、ambient cancellation token，也没有在 await 点检查取消。规划见设计说明「未来」一节，**本仓库当前不实现**。

## 设计一句话

每个 `async function` 变成返回 Task 的普通函数；每个 `await` 推进 `_state` 并 `return Task.await_then(...)`；拒绝路径走 `sm:step(false, err)` → `Task.rejected(err)`。全程无协程。
