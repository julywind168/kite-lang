# Kite 语法设计

## 设计原则

Kite 是一种通用的**强类型、无 GC、函数式风格**语言，语法设计上借鉴了 **Gleam** 的简洁性但保留部分命令式语言的实用特性。

核心取舍：

- **表达式优先** — 万物皆表达式，块最后一行自动返回
- **不可变优先** — `let` 默认不可变，可变用 `var`
- **显式优于隐式** — 类型标注可省略但不推断，控制流无隐式 fall-through
- **C ABI 友好** — 结构体内存布局可预测，外部声明零开销

参考语言：Gleam（语法风格）、Rust（类型系统）、Zig（C 互操作）。

---

## 关键字

Kite 共 **21** 个关键字：

| 关键字 | 用途 |
|--------|------|
| `let` | 不可变绑定 |
| `var` | 可变绑定 |
| `fn` | 函数定义 |
| `with` | 回调语法糖（等价 Gleam `use`） |
| `extern` | 外部 C ABI 声明 |
| `struct` | 结构体定义 |
| `type` | 和类型定义（Sum Type），支持判别值 |
| `if` / `else` | 条件表达式 |
| `match` | 模式匹配 |
| `pub` | 公开可见性 |
| `import` | 模块导入 |
| `export` | 导出顶层 `fn` / `struct` |
| `test` | 顶层测试声明 |
| `todo` | 未完成占位符 |
| `echo` | 调试打印 |
| `and` / `or` / `not` | 逻辑运算符 |
| `true` / `false` | 布尔字面量 |
| `void` | 空类型/单元值 |

---

## 表达式优先级

从低到高：

| 优先级 | 运算符 | 结合性 |
|--------|--------|--------|
| 1 | `=` （赋值） | 右结合 |
| 2 | `\|>` （管道） | 左结合 |
| 3 | `or` | 左结合 |
| 4 | `and` | 左结合 |
| 5 | `==` `!=` `<` `>` `<=` `>=` | 左结合 |
| 6 | `<>` （字符串拼接） | 左结合 |
| 7 | `+` `-` | 左结合 |
| 8 | `*` `/` `%` | 左结合 |
| 9 | `not` `-` （一元） | 右结合 |
| 10 | `()` `[]` `.` `?` `!` （后缀） | 左结合 |

---

## 基础类型

### 整数

| 类型 | 位宽 | 说明 |
|------|------|------|
| `i8` | 8 | 有符号整数 |
| `i16` | 16 | 有符号整数 |
| `i32` | 32 | 有符号整数（默认整型） |
| `i64` | 64 | 有符号整数 |
| `u8` | 8 | 无符号整数 |
| `u16` | 16 | 无符号整数 |
| `u32` | 32 | 无符号整数 |
| `u64` | 64 | 无符号整数 |
| `usize` | arch | 指针宽度整数（用于索引/长度） |

### 浮点

| 类型 | 位宽 | 说明 |
|------|------|------|
| `f32` | 32 | 单精度浮点（默认） |
| `f64` | 64 | 双精度浮点 |

### 其他原语

| 类型 | 说明 |
|------|------|
| `bool` | 布尔值 |
| `char` | 单字符 |
| `string` | UTF-8 字符串 |
| `void` | 空类型/单元值 |

### 复合类型

```
[Type]                   -- 数组
(Type, ...) -> Type      -- 函数类型
Identifier(Type, ...)    -- 泛型类型如 Option(t)
```

---

## 顶层声明

### 函数

```
fn add(x: i32, y: i32) i32 {
    x + y              -- 最后一行自动返回
}

pub fn make_vec() Vector3 {
    { x: 0.0, y: 0.0, z: 0.0 }
}

export fn run() {
    echo "running"
}
```

### 结构体

```
pub struct Player {
    name: string,
    health: f32,
    position: Vector3
}

export struct Api {
    version: string
}
```

### 变体类型 (Sum Type)

变体可选带判别值（`= number`），用于 C ABI 映射。判别值可显式指定，未指定的从 0 自动递增。

```
type Option = Some(t) | None
type Result(t, e) = Ok(t) | Err(e)
type EntityState = Idle | Moving(Vector3) | Destroyed

// 带判别值：映射到 C int，兼容 ABI
type FileError = NotFound = 1 | PermissionDenied = 5 | IoError(string) = -1
type ParseError = UnexpectedChar | UnterminatedString | InvalidNumber = 100
```

### 外部声明（C ABI）

```
extern struct Vector3 { x: f32, y: f32, z: f32 }
extern fn InitWindow(width: i32, height: i32, title: string)
```

### 模块

```
import "game/math.kite"
export fn run() { ... }
```

`export` 是顶层声明修饰符，只用于 `fn` 和 `struct`，不再写成 `export <expression>`。

### 测试

`test` 是顶层声明，用于定义由测试运行器发现和执行的测试用例。

```
test "read_config returns not found" {
    let result = read_config("missing.conf")
    result == Err(NotFound)
}
```

---

## 错误处理

Kite 使用 `Result` 类型配合 `?` 运算符处理错误，无异常机制。

### Result 类型

标准库预定义泛型 `Result`：

```
type Result(t, e) = Ok(t) | Err(e)
```

### ? 错误传播

`?` 后置于可能失败的表达式。若结果为 `Err(e)` 则立即从当前函数返回该错误；若为 `Ok(v)` 则提取值 `v` 继续执行。

```
fn read_config(path: string) Result(string, FileError) {
    let file = open_file(path)?      -- Err 时提前返回
    let content = file.read_all()?   -- Ok 时解包继续
    content
}
```

### ! 强制解包

`!` 也是后缀操作符，用于“必须成功”的场景。若结果为失败值，则立即触发运行时中止；若成功，则提取内部值继续执行。

```
fn load_default_config() string {
    open_file("default.conf")!.read_all()!
}
```

### 错误集 C 互操作

和类型变体上的判别值即为 C ABI 层错误码，编译器保证：

- 带判别值的 type 在 FFI 边界直接映射为 `int`（C 侧 `int32_t`）
- 显式赋值的判别值保持不变
- 未赋值的按定义顺序从 0 自动递增

```
// Kite 侧
type WindowError = None = 0 | InvalidSize = 1 | CreateFailed = -1

// C 侧等价于
// #define WINDOW_ERROR_NONE          0
// #define WINDOW_ERROR_INVALID_SIZE  1
// #define WINDOW_ERROR_CREATE_FAILED -1
```

---

## 表达式

### 绑定

```
let x = 42                    -- 不可变，类型推断
let y: f32 = 3.14             -- 带类型标注
var counter = 0               -- 可变绑定
counter = counter + 1         -- 赋值
```

### 条件

```
let msg = if health > 0 {
    "alive"
} else {
    "dead"
}
```

### 模式匹配

```
match state {
    | Idle => "waiting"
    | Moving(v) if v.x > 0.0 => "moving right"
    | Moving(_) => "moving"
    | _ => "unknown"
}
```

### 结构体字面量

非空结构体字面量可以直接写成 `{ field: value, ... }`。当 `{` 后面紧跟 `identifier:` 时，解析为结构体字面量；否则按 block 表达式处理。

```
let origin = { x: 0.0, y: 0.0, z: 0.0 }
let player = {
    name: "kite",
    health: 100.0,
    position: origin,
}
let empty = Empty {}
```

为避免与空 block `{}` 冲突，空结构体字面量仍需显式写出类型名。

### 匿名函数

```
let add = (x, y) => x + y
let double = x => x * 2
let filter = s => {
    match s {
        | Moving(_) => true
        | _ => false
    }
}
```

### 管道

```
let result = entities
    |> List.map(s => update_state(s))
    |> List.filter(s => not is_destroyed(s))
```

### with 回调语法糖

```
with db <- connect_database("game.db")
with user <- db.find_user("player_1")
let profile = user.load_profile()
db.save_profile(profile)
profile
```

`with` 会消费当前 block 剩余的表达式，并把它们改写成回调体；因此它适合作为当前 block 尾部的顺铺语法糖，而不是中间穿插的普通表达式。

### 占位符

```
fn not_ready(yet: i32) bool {
    todo "等设计确定后再实现"
}

fn empty_stub() {
    todo
}
```

### 调试打印

`echo` 对表达式求值并输出到 stderr，返回原值——方便插入管道或调用链中调试。

```
let x = echo f() + echo g()
let result = entities |> List.map(s => echo update_state(s))
```

### 索引与字段访问

```
let first = entities[0]
let len = entities.length
let pos = player.position.x
let next = entities[0]?.position
```

### 块表达式

```
let result = {
    let a = f()
    let b = g(a)
    a + b     -- 块的值
}
```

顶层声明、块内部表达式、以及 `match` 分支之间，换行是必要分隔符；调用参数、数组元素、结构体字段等仍使用显式分隔符（`,`、`|` 等）。如果某一行以 `with` 开头，那么它会接管当前 block 后续的整段尾部。

---

## 词法细节

| 操作符 | 含义 |
|--------|------|
| `=` | 赋值 |
| `==` `!=` | 相等 / 不等 |
| `<` `>` `<=` `>=` | 比较 |
| `<>` | 字符串/序列拼接 |
| `\|>` | 管道 |
| `=>` | 匿名函数箭头 / match 分支 |
| `->` | 函数类型箭头 |
| `<-` | with 绑定 |
| `.` | 字段访问 |
| `?` | 错误传播 |
| `!` | 强制解包 / 强制成功 |

注释：`// 行注释`，无块注释。

字符串：双引号，支持 `\n` `\t` `\r` `\\` `\"` 转义。

标识符：`[a-zA-Z][a-zA-Z0-9_]*`。
成员访问与命名空间风格调用统一使用 `.` 后缀语法，例如 `player.position.x`、`List.map(items, f)`。
