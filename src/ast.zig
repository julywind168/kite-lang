const std = @import("std");

/// 可见性修饰符
pub const Visibility = enum { pub_, export_ };

/// 字面量类型
pub const LiteralKind = enum {
    number,
    string,
    true_,
    false_,
    void_,
};

/// 二元运算符
pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    eq_eq,
    bang_eq,
    less,
    greater,
    less_eq,
    greater_eq,
    concat,
    and_,
    or_,
    pipe,
};

/// 一元运算符
pub const UnaryOp = enum {
    not_,
    neg,
};

/// 基础类型
pub const PrimitiveType = enum {
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    f32,
    f64,
    bool_,
    string_,
    char_,
    void_,
    usize_,
};

/// 类型表达式
pub const TypeExpr = union(enum) {
    primitive: PrimitiveType,
    named: []const u8,
    array: *TypeExpr,
    function: struct {
        params: []const *TypeExpr,
        return_type: *TypeExpr,
    },
    generic: struct {
        name: []const u8,
        args: []const *TypeExpr,
    },
};

/// 函数参数
pub const Param = struct {
    name: []const u8,
    type_ann: ?*TypeExpr,
};

/// 结构体字段
pub const StructField = struct {
    name: []const u8,
    field_type: *TypeExpr,
};

/// 结构体字段初始化
pub const FieldInit = struct {
    name: []const u8,
    value: *Expr,
};

/// 模式
pub const Pattern = union(enum) {
    literal: struct {
        kind: LiteralKind,
        value: []const u8,
    },
    identifier: []const u8,
    wildcard: void,
    constructor: struct {
        name: []const u8,
        args: []const Pattern,
    },
};

/// match 分支
pub const MatchCase = struct {
    pattern: Pattern,
    guard: ?*Expr,
    body: *Expr,
};

/// 变体 (sum type variant)
pub const Variant = struct {
    name: []const u8,
    payload: []const *TypeExpr,
    discriminant: ?[]const u8,
};

/// 表达式 (前向声明用)
pub const Expr = union(enum) {
    literal: struct {
        kind: LiteralKind,
        value: []const u8,
    },
    identifier: []const u8,
    binary: struct {
        left: *Expr,
        op: BinOp,
        right: *Expr,
    },
    unary: struct {
        op: UnaryOp,
        expr: *Expr,
    },
    call: struct {
        callee: *Expr,
        args: []const *Expr,
    },
    index: struct {
        object: *Expr,
        index_expr: *Expr,
    },
    field_access: struct {
        object: *Expr,
        field: []const u8,
    },
    error_prop: *Expr,
    force_unwrap: *Expr,
    assignment: struct {
        target: *Expr,
        value: *Expr,
    },
    block: struct {
        stmts: []const *Expr,
    },
    if_expr: struct {
        condition: *Expr,
        then_body: *Expr,
        else_body: ?*Expr,
    },
    match_expr: struct {
        value: *Expr,
        cases: []const MatchCase,
    },
    todo_expr: ?[]const u8,
    echo_expr: *Expr,
    anon_func: struct {
        params: []const Param,
        return_type: ?*TypeExpr,
        body: *Expr,
    },
    struct_literal: struct {
        type_name: ?[]const u8,
        fields: []const FieldInit,
    },
    array_literal: []const *Expr,
    let_binding: struct {
        mutable: bool,
        name: []const u8,
        type_ann: ?*TypeExpr,
        value: *Expr,
    },
    with_expr: struct {
        name: []const u8,
        value: *Expr,
        body_stmts: []const *Expr,
    },
    grouping: *Expr,
};

/// 函数声明
pub const FunctionDecl = struct {
    visibility: ?Visibility,
    is_extern: bool,
    name: []const u8,
    params: []const Param,
    return_type: ?*TypeExpr,
    body: *Expr,
};

/// 外部声明
pub const ExternDecl = union(enum) {
    function: struct {
        name: []const u8,
        params: []const Param,
        return_type: ?*TypeExpr,
    },
    struct_def: *StructDef,
};

/// 结构体定义
pub const StructDef = struct {
    visibility: ?Visibility,
    name: []const u8,
    fields: []const StructField,
};

/// 类型定义 (sum type)
pub const TypeDef = struct {
    visibility: ?Visibility,
    name: []const u8,
    type_params: []const []const u8,
    variants: []const Variant,
};

/// 导入声明
pub const ImportDecl = struct {
    path: []const u8,
};

/// 测试声明
pub const TestDecl = struct {
    name: []const u8,
    body: *Expr,
};

/// 顶层声明
pub const Decl = union(enum) {
    function: FunctionDecl,
    extern_decl: ExternDecl,
    struct_def: StructDef,
    type_def: TypeDef,
    import_decl: ImportDecl,
    test_decl: TestDecl,
    expression: *Expr,

    pub fn dump(self: Decl, writer: anytype, indent: u32) !void {
        try writeIndent(writer, indent);
        switch (self) {
            .function => |f| {
                try writer.print("fn {s}", .{f.name});
                if (f.visibility) |v| try writer.print(" [{s}]", .{@tagName(v)});
                try writer.writeAll("(");
                for (f.params, 0..) |p, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.writeAll(p.name);
                    if (p.type_ann) |ta| {
                        try writer.writeAll(": ");
                        try dumpTypeExpr(ta, writer);
                    }
                }
                try writer.writeAll(")");
                if (f.return_type) |rt| {
                    try writer.writeAll(" -> ");
                    try dumpTypeExpr(rt, writer);
                }
                try writer.writeAll("\n");
                try dumpExpr(f.body, writer, indent + 1);
            },
            .extern_decl => |e| {
                try writer.writeAll("extern ");
                switch (e) {
                    .function => |ef| {
                        try writer.print("fn {s}", .{ef.name});
                        if (ef.return_type) |rt| {
                            try writer.writeAll(" -> ");
                            try dumpTypeExpr(rt, writer);
                        }
                    },
                    .struct_def => |sd| {
                        try writer.print("struct {s}", .{sd.name});
                    },
                }
                try writer.writeAll("\n");
            },
            .struct_def => |s| {
                if (s.visibility) |v| try writer.print("[{s}] ", .{@tagName(v)});
                try writer.print("struct {s}\n", .{s.name});
                for (s.fields) |fld| {
                    try writeIndent(writer, indent + 1);
                    try writer.print("{s}: ", .{fld.name});
                    try dumpTypeExpr(fld.field_type, writer);
                    try writer.writeAll("\n");
                }
            },
            .type_def => |t| {
                if (t.visibility) |v| try writer.print("[{s}] ", .{@tagName(v)});
                try writer.print("type {s}", .{t.name});
                if (t.type_params.len > 0) {
                    try writer.writeAll("(");
                    for (t.type_params, 0..) |tp, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writer.writeAll(tp);
                    }
                    try writer.writeAll(")");
                }
                try writer.writeAll(" = ");
                for (t.variants, 0..) |v, i| {
                    if (i > 0) try writer.writeAll(" | ");
                    try writer.writeAll(v.name);
                    if (v.payload.len > 0) {
                        try writer.writeAll("(");
                        for (v.payload, 0..) |p, j| {
                            if (j > 0) try writer.writeAll(", ");
                            try dumpTypeExpr(p, writer);
                        }
                        try writer.writeAll(")");
                    }
                    if (v.discriminant) |d| {
                        try writer.print(" = {s}", .{d});
                    }
                }
                try writer.writeAll("\n");
            },
            .import_decl => |i| {
                try writer.print("import \"{s}\"\n", .{i.path});
            },
            .test_decl => |t| {
                try writer.print("test \"{s}\"\n", .{t.name});
                try dumpExpr(t.body, writer, indent + 1);
            },
            .expression => |e| {
                try dumpExpr(e, writer, indent);
            },
        }
    }
};

/// 程序根节点
pub const Program = struct {
    declarations: []const Decl,

    pub fn dump(self: Program, writer: anytype) !void {
        for (self.declarations) |decl| {
            try decl.dump(writer, 0);
            try writer.writeAll("\n");
        }
    }

    pub fn dumpToStdout(self: Program, gpa: std.mem.Allocator) !void {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try self.dump(&aw.writer);
        std.debug.print("{s}\n", .{aw.writer.buffer[0..aw.writer.end]});
    }
};

fn writeIndent(writer: anytype, indent: u32) !void {
    var i: u32 = 0;
    while (i < indent) : (i += 1) {
        try writer.writeAll("  ");
    }
}

pub fn dumpExpr(expr: *Expr, writer: anytype, indent: u32) !void {
    try writeIndent(writer, indent);
    switch (expr.*) {
        .literal => |l| {
            try writer.print("lit({s}: {s})\n", .{ @tagName(l.kind), l.value });
        },
        .identifier => |name| {
            try writer.print("ident({s})\n", .{name});
        },
        .binary => |b| {
            try writer.print("binary({s})\n", .{@tagName(b.op)});
            try dumpExpr(b.left, writer, indent + 1);
            try dumpExpr(b.right, writer, indent + 1);
        },
        .unary => |u| {
            try writer.print("unary({s})\n", .{@tagName(u.op)});
            try dumpExpr(u.expr, writer, indent + 1);
        },
        .call => |c| {
            try writer.writeAll("call\n");
            try dumpExpr(c.callee, writer, indent + 1);
            for (c.args) |arg| {
                try dumpExpr(arg, writer, indent + 1);
            }
        },
        .index => |ix| {
            try writer.writeAll("index\n");
            try dumpExpr(ix.object, writer, indent + 1);
            try dumpExpr(ix.index_expr, writer, indent + 1);
        },
        .field_access => |fa| {
            try writer.print("field({s})\n", .{fa.field});
            try dumpExpr(fa.object, writer, indent + 1);
        },
        .error_prop => |e| {
            try writer.writeAll("error_prop(?)\n");
            try dumpExpr(e, writer, indent + 1);
        },
        .force_unwrap => |e| {
            try writer.writeAll("force_unwrap(!)\n");
            try dumpExpr(e, writer, indent + 1);
        },
        .assignment => |a| {
            try writer.writeAll("assign\n");
            try dumpExpr(a.target, writer, indent + 1);
            try dumpExpr(a.value, writer, indent + 1);
        },
        .block => |b| {
            try writer.print("block ({d} stmts)\n", .{b.stmts.len});
            for (b.stmts) |stmt| {
                try dumpExpr(stmt, writer, indent + 1);
            }
        },
        .if_expr => |ie| {
            try writer.writeAll("if\n");
            try dumpExpr(ie.condition, writer, indent + 1);
            try writeIndent(writer, indent);
            try writer.writeAll("then:\n");
            try dumpExpr(ie.then_body, writer, indent + 1);
            if (ie.else_body) |eb| {
                try writeIndent(writer, indent);
                try writer.writeAll("else:\n");
                try dumpExpr(eb, writer, indent + 1);
            }
        },
        .match_expr => |m| {
            try writer.print("match ({d} cases)\n", .{m.cases.len});
            try dumpExpr(m.value, writer, indent + 1);
            for (m.cases) |case| {
                try writeIndent(writer, indent + 1);
                try writer.writeAll("| ");
                try dumpPattern(case.pattern, writer);
                if (case.guard) |_| {
                    try writer.writeAll(" if ...");
                }
                try writer.writeAll(" =>\n");
                try dumpExpr(case.body, writer, indent + 2);
            }
        },
        .todo_expr => |msg| {
            if (msg) |m| {
                try writer.print("todo \"{s}\"\n", .{m});
            } else {
                try writer.writeAll("todo\n");
            }
        },
        .echo_expr => |e| {
            try writer.writeAll("echo\n");
            try dumpExpr(e, writer, indent + 1);
        },
        .anon_func => |af| {
            try writer.print("anon_func ({d} params)\n", .{af.params.len});
            if (af.return_type) |rt| {
                try writeIndent(writer, indent + 1);
                try writer.writeAll("-> ");
                try dumpTypeExpr(rt, writer);
                try writer.writeAll("\n");
            }
            try dumpExpr(af.body, writer, indent + 1);
        },
        .struct_literal => |sl| {
            if (sl.type_name) |tn| {
                try writer.print("struct_lit {s}\n", .{tn});
            } else {
                try writer.writeAll("struct_lit (anon)\n");
            }
            for (sl.fields) |f| {
                try writeIndent(writer, indent + 1);
                try writer.print("{s}:\n", .{f.name});
                try dumpExpr(f.value, writer, indent + 2);
            }
        },
        .array_literal => |arr| {
            try writer.print("array ({d} elems)\n", .{arr.len});
            for (arr) |elem| {
                try dumpExpr(elem, writer, indent + 1);
            }
        },
        .let_binding => |lb| {
            const kw = if (lb.mutable) "var" else "let";
            try writer.print("{s} {s}", .{ kw, lb.name });
            if (lb.type_ann) |ta| {
                try writer.writeAll(": ");
                try dumpTypeExpr(ta, writer);
            }
            try writer.writeAll(" =\n");
            try dumpExpr(lb.value, writer, indent + 1);
        },
        .with_expr => |w| {
            try writer.print("with {s} <-\n", .{w.name});
            try dumpExpr(w.value, writer, indent + 1);
            try writeIndent(writer, indent);
            try writer.print("body ({d} stmts):\n", .{w.body_stmts.len});
            for (w.body_stmts) |stmt| {
                try dumpExpr(stmt, writer, indent + 1);
            }
        },
        .grouping => |g| {
            try writer.writeAll("grouping\n");
            try dumpExpr(g, writer, indent + 1);
        },
    }
}

pub fn dumpTypeExpr(te: *TypeExpr, writer: anytype) !void {
    switch (te.*) {
        .primitive => |p| try writer.writeAll(@tagName(p)),
        .named => |n| try writer.writeAll(n),
        .array => |a| {
            try writer.writeAll("[");
            try dumpTypeExpr(a, writer);
            try writer.writeAll("]");
        },
        .function => |f| {
            try writer.writeAll("(");
            for (f.params, 0..) |p, i| {
                if (i > 0) try writer.writeAll(", ");
                try dumpTypeExpr(p, writer);
            }
            try writer.writeAll(") -> ");
            try dumpTypeExpr(f.return_type, writer);
        },
        .generic => |g| {
            try writer.print("{s}(", .{g.name});
            for (g.args, 0..) |a, i| {
                if (i > 0) try writer.writeAll(", ");
                try dumpTypeExpr(a, writer);
            }
            try writer.writeAll(")");
        },
    }
}

fn dumpPattern(pat: Pattern, writer: anytype) !void {
    switch (pat) {
        .literal => |l| try writer.print("{s}", .{l.value}),
        .identifier => |n| try writer.writeAll(n),
        .wildcard => try writer.writeAll("_"),
        .constructor => |c| {
            try writer.writeAll(c.name);
            if (c.args.len > 0) {
                try writer.writeAll("(");
                for (c.args, 0..) |a, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try dumpPattern(a, writer);
                }
                try writer.writeAll(")");
            }
        },
    }
}
