# Kite Language 开发计划书 (Project Plan)

## 1. 核心定位
Kite 是一种专为高性能游戏引擎设计的**强类型、无 GC、函数式风格**编程语言。
- **内核 (Kernel):** 使用 Zig 编写，支持 AOT 编译。
- **脚本 (Script):** 字节码解释执行 + Cranelift JIT 即时编译。
- **内存模型:** 基于 Perceus 算法的静态引用计数 (Static RC)。
- **C 互操作:** 像 Zig 一样实现与 C 语言的零开销集成。

---

## 2. 核心架构设计 (System Architecture)

### 2.1 内存模型：Perceus 优化
AI 在编写内存相关逻辑时必须遵循：
- **引用计数 (RC):** 在 AST/IR 转换阶段，自动在对象生命周期末尾插入销毁代码。
- **原地更新 (In-place Update):** 如果对象的 RC 为 1 且即将被修改，编译器应生成“直接修改”指令而非“复制并修改”。
- **闭包处理:** 闭包捕获的变量采用引用计数管理，禁止或受限处理循环引用（建议先实现非循环引用模型）。

### 2.2 执行后端：双端架构
- **解释器:** 基于寄存器 (Register-based) 的虚拟机，追求快速启动。
- **JIT 后端:** 利用 **Cranelift**。由于语言强类型，JIT 过程中无需昂贵的类型猜测。
- **Interop 逻辑:** 内核与脚本共享 C ABI。脚本中的结构体与内核中的 Zig 结构体在内存布局上完全对齐。

---

## 3. 阶段性开发任务 (Milestones)

### 第一阶段：编译器前端 (Frontend)
- [ ] **Zig 环境初始化:** 配置 `build.zig`。
- [ ] **Lexer (词法分析):** 支持强类型语法、箭头函数 `->`、管道符 `|>`。
- [ ] **Parser (语法分析):** 递归下降解析器，生成 AST。
- [ ] **Semantic Analysis:** 类型检查器 (Type Checker) 与符号表管理。

### 第二阶段：Perceus 与中间表示 (IR)
- [ ] **IR 设计:** 设计一种中间表示，能清晰表达所有权转移。
- [ ] **Perceus 实现:** 实现 Liveness Analysis（存活性分析），在 IR 层面插入 RC 指令。
- [ ] **C 语言集成:** 内置 Clang 解析器，支持直接 `@import("header.h")`。

### 第三阶段：虚拟机与字节码 (VM)
- [ ] **Bytecode Gen:** 将优化后的 IR 转换为字节码。
- [ ] **Zig VM:** 编写高性能字节码解释器，实现 FFI 调用。

### 第四阶段：Cranelift JIT 集成 (JIT)
- [ ] **Cranelift 绑定:** 集成 Cranelift C-API。
- [ ] **Native Code Gen:** 将热点函数转化为原生机器码。

---

## 4. 给 AI Coding 的提示词准则 (Prompts Guidelines)

### 编写 Zig 代码时：
> "请使用 Zig 0.16+ 风格。必须显式传递 `Allocator`。在处理字节码或内存布局时，请确保符合 C ABI 对齐标准。"

### 编写 Perceus 逻辑时：
> "在执行对象更新操作前，请务必生成检查引用计数的逻辑。如果引用计数等于 1，请实现原地修改优化以提高性能。"

### 编写 C 集成时：
> "利用 Zig 的原生能力解析 C 头文件。确保生成的脚本侧结构体与 C 侧完全一一对应，实现零开销数据共享。"

---

## 5. 技术堆栈总结
- **语言:** Zig (编译器与 VM)
- **代码后端:** Cranelift (JIT/AOT)
- **解析技术:** 手写递归下降解析器 + libclang (用于 C 处理)
- **内存算法:** Perceus (Static Reference Counting)