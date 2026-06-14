const std = @import("std");
const ast = @import("ast.zig");

pub const Type = union(enum) {
    primitive: ast.PrimitiveType,
    named: []const u8,
    array: *Type,
    function: struct { params: []const Type, return_type: *Type },
    unknown: void,
};

pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    scopes: std.ArrayListUnmanaged(std.StringHashMap(Symbol)),
    errors: std.ArrayListUnmanaged(Error),

    structs: std.StringHashMap(*ast.StructDef),
    type_defs: std.StringHashMap(*ast.TypeDef),
    function_sigs: std.StringHashMap(FunctionSig),

    current_return_type: ?Type,
    in_loop: bool,

    pub const Symbol = struct {
        type: Type,
        mutable: bool,
    };

    pub const FunctionSig = struct {
        param_types: []const Type,
        return_type: Type,
        defined: bool,
    };

    pub const Error = struct {
        message: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) TypeChecker {
        const arena_ptr = allocator.create(std.heap.ArenaAllocator) catch unreachable;
        arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
        const a = arena_ptr.allocator();
        var result = TypeChecker{
            .allocator = allocator,
            .arena = arena_ptr,
            .scopes = .empty,
            .errors = .empty,
            .structs = std.StringHashMap(*ast.StructDef).init(a),
            .type_defs = std.StringHashMap(*ast.TypeDef).init(a),
            .function_sigs = std.StringHashMap(FunctionSig).init(a),
            .current_return_type = null,
            .in_loop = false,
        };
        result.scopes.append(a, std.StringHashMap(Symbol).init(a)) catch {};
        return result;
    }

    pub fn deinit(self: *TypeChecker) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }

    fn alloc(self: *TypeChecker) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn check(self: *TypeChecker, program: ast.Program) bool {
        self.collectDeclarations(program);
        self.checkDeclarations(program);
        return self.errors.items.len == 0;
    }

    pub fn reportErrors(self: *TypeChecker) void {
        for (self.errors.items) |err| {
            std.debug.print("type error: {s}\n", .{err.message});
        }
    }

    fn addError(self: *TypeChecker, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.alloc(), fmt, args) catch return;
        self.errors.append(self.alloc(), .{ .message = msg }) catch {};
    }

    // ── 第一遍：收集顶层声明 ──

    fn collectDeclarations(self: *TypeChecker, program: ast.Program) void {
        for (program.declarations) |*decl| {
            switch (decl.*) {
                .struct_def => |*sd| {
                    self.structs.put(sd.name, @constCast(&decl.struct_def)) catch {};
                },
                .type_def => |*td| {
                    self.type_defs.put(td.name, @constCast(&decl.type_def)) catch {};
                },
                .function => |*fd| {
                    var param_types = std.ArrayList(Type).empty;
                    for (fd.params) |p| {
                        if (p.type_ann) |ta| {
                    param_types.append(self.alloc(), self.resolveTypeExpr(ta) catch Type{ .unknown = {} }) catch {};
                            } else {
                            param_types.append(self.alloc(), Type{ .unknown = {} }) catch {};
                        }
                    }
                    const ret_type = if (fd.return_type) |rt|
                        self.resolveTypeExpr(rt) catch Type{ .unknown = {} }
                    else
                        Type{ .primitive = .void_ };
                    self.function_sigs.put(fd.name, .{
                        .param_types = param_types.items,
                        .return_type = ret_type,
                        .defined = true,
                    }) catch {};
                },
                .extern_decl => |ed| {
                    switch (ed) {
                        .function => |ef| {
                    var param_types = std.ArrayList(Type).empty;
                            for (ef.params) |p| {
                                if (p.type_ann) |ta| {
                    param_types.append(self.alloc(), self.resolveTypeExpr(ta) catch Type{ .unknown = {} }) catch {};
                                    } else {
                                    param_types.append(self.alloc(), Type{ .unknown = {} }) catch {};
                                }
                            }
                            const ret_type = if (ef.return_type) |rt|
                                self.resolveTypeExpr(rt) catch Type{ .unknown = {} }
                            else
                                Type{ .primitive = .void_ };
                            self.function_sigs.put(ef.name, .{
                                .param_types = param_types.items,
                                .return_type = ret_type,
                                .defined = false,
                            }) catch {};
                        },
                        .struct_def => |sd| {
                            self.structs.put(sd.name, sd) catch {};
                        },
                    }
                },
                else => {},
            }
        }
    }

    // ── 第二遍：类型检查 ──

    fn checkDeclarations(self: *TypeChecker, program: ast.Program) void {
        for (program.declarations) |decl| {
            switch (decl) {
                .function => |fd| {
                    self.current_return_type = if (fd.return_type) |rt|
                        self.resolveTypeExpr(rt) catch Type{ .unknown = {} }
                    else
                        Type{ .primitive = .void_ };
                    self.checkFunctionBody(fd);
                },
                .test_decl => |td| {
                    self.current_return_type = null;
                    self.pushScope() catch {};
                    _ = self.checkExpr(td.body);
                    self.popScope();
                },
                .expression => |e| {
                    self.current_return_type = null;
                    _ = self.checkExpr(e);
                },
                else => {},
            }
        }
    }

    fn checkFunctionBody(self: *TypeChecker, fd: ast.FunctionDecl) void {
        self.pushScope() catch {};
        for (fd.params) |p| {
            const ptype = if (p.type_ann) |ta|
                self.resolveTypeExpr(ta) catch Type{ .unknown = {} }
            else
                Type{ .unknown = {} };
            self.define(p.name, .{ .type = ptype, .mutable = false }) catch {};
        }
        const body_type = self.checkExpr(fd.body);
        if (self.current_return_type) |ret| {
            if (!typesEqual(body_type, ret) and body_type != .unknown and ret != .unknown) {
                self.addError("function '{s}' return type mismatch: expected {any}, got {any}", .{
                    fd.name, ret, body_type,
                });
            }
        }
        self.popScope();
    }

    // ── 作用域管理 ──

    fn pushScope(self: *TypeChecker) !void {
        try self.scopes.append(self.alloc(), std.StringHashMap(Symbol).init(self.alloc()));
    }

    fn popScope(self: *TypeChecker) void {
        _ = self.scopes.pop();
    }

    fn lookup(self: *TypeChecker, name: []const u8) ?Symbol {
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name)) |sym| return sym;
        }
        return null;
    }

    fn define(self: *TypeChecker, name: []const u8, sym: Symbol) !void {
        try self.scopes.items[self.scopes.items.len - 1].put(name, sym);
    }

    fn allocType(self: *TypeChecker, t: Type) *Type {
        const ptr = self.alloc().create(Type) catch unreachable;
        ptr.* = t;
        return ptr;
    }

    // ── 类型检查表达式 ──

    fn checkExpr(self: *TypeChecker, expr: *ast.Expr) Type {
        switch (expr.*) {
            .literal => |l| {
                return switch (l.kind) {
                    .number => Type{ .primitive = .f32 },
                    .string => Type{ .primitive = .string_ },
                    .true_, .false_ => Type{ .primitive = .bool_ },
                    .void_ => Type{ .primitive = .void_ },
                };
            },
            .identifier => |name| {
                if (self.lookup(name)) |sym| return sym.type;
                if (self.function_sigs.contains(name)) return Type{ .function = .{
                    .params = &.{},
                    .return_type = self.allocType(Type{ .unknown = {} }),
                } };
                self.addError("undefined variable: '{s}'", .{name});
                return Type{ .unknown = {} };
            },
            .binary => |b| {
                const lt = self.checkExpr(b.left);
                const rt = self.checkExpr(b.right);
                return switch (b.op) {
                    .add, .sub, .mul, .div, .mod => {
                        if (isNumeric(lt) and isNumeric(rt)) {
                            return promoteNumeric(lt, rt);
                        }
                        self.addError("arithmetic operand type mismatch: {any} and {any}", .{ lt, rt });
                        return Type{ .unknown = {} };
                    },
                    .eq_eq, .bang_eq, .less, .greater, .less_eq, .greater_eq => {
                        if (!typesCompatible(lt, rt)) {
                            self.addError("comparison operand type mismatch: {any} and {any}", .{ lt, rt });
                        }
                        return Type{ .primitive = .bool_ };
                    },
                    .and_, .or_ => {
                        if (lt != .unknown and lt != .primitive) {
                            self.addError("logical operator requires bool, got {any}", .{lt});
                        }
                        if (rt != .unknown and rt != .primitive) {
                            self.addError("logical operator requires bool, got {any}", .{rt});
                        }
                        return Type{ .primitive = .bool_ };
                    },
                    .concat => {
                        if (lt == .primitive and rt == .primitive) return Type{ .primitive = .string_ };
                        return Type{ .unknown = {} };
                    },
                    .pipe => {
                        return self.checkPipe(lt, b.right);
                    },
                };
            },
            .unary => |u| {
                const inner = self.checkExpr(u.expr);
                return switch (u.op) {
                    .neg => {
                        if (isNumeric(inner)) return inner;
                        self.addError("negation requires numeric type, got {any}", .{inner});
                        return Type{ .unknown = {} };
                    },
                    .not_ => {
                        if (inner != .unknown and inner != .primitive) {
                            self.addError("logical not requires bool, got {any}", .{inner});
                        }
                        return Type{ .primitive = .bool_ };
                    },
                };
            },
            .call => |c| {
                // 先检查 callee 本身
                _ = self.checkExpr(c.callee);
                return self.checkCall(c.callee, c.args);
            },
            .index => |ix| {
                const obj_type = self.checkExpr(ix.object);
                const idx_type = self.checkExpr(ix.index_expr);
                if (idx_type != .unknown and idx_type != .primitive) {
                    self.addError("index requires integer type, got {any}", .{idx_type});
                }
                if (obj_type == .array) {
                    return obj_type.array.*;
                }
                return Type{ .unknown = {} };
            },
            .field_access => |fa| {
                const obj_type = self.checkExpr(fa.object);
                return self.checkFieldAccess(obj_type, fa.field);
            },
            .error_prop => |e| {
                const inner = self.checkExpr(e);
                if (self.current_return_type) |ret| {
                    if (ret == .primitive and ret.primitive == .void_) {
                        self.addError("? error propagation requires Result return type", .{});
                    }
                }
                // unwrap Result<T, E> → T if possible
                if (inner == .named) {
                    const name = inner.named;
                    if (self.type_defs.get(name)) |td| {
                        if (td.variants.len >= 2) {
                            if (std.mem.eql(u8, td.variants[0].name, "Ok") and td.variants[0].payload.len == 1) {
                                return self.resolveTypeExpr(td.variants[0].payload[0]) catch Type{ .unknown = {} };
                            }
                        }
                    }
                }
                return Type{ .unknown = {} };
            },
            .force_unwrap => |e| {
                const inner = self.checkExpr(e);
                if (inner == .named) {
                    const name = inner.named;
                    if (self.type_defs.get(name)) |td| {
                        if (td.variants.len >= 2) {
                            if (std.mem.eql(u8, td.variants[0].name, "Ok") and td.variants[0].payload.len == 1) {
                                return self.resolveTypeExpr(td.variants[0].payload[0]) catch Type{ .unknown = {} };
                            }
                        }
                    }
                }
                return Type{ .unknown = {} };
            },
            .assignment => |a| {
                const target_type = self.checkAssignmentTarget(a.target);
                const value_type = self.checkExpr(a.value);
                if (!typesCompatible(target_type, value_type)) {
                    self.addError("assignment type mismatch: {any} = {any}", .{ target_type, value_type });
                }
                return value_type;
            },
            .block => |b| {
                self.pushScope() catch {};
                var last = Type{ .primitive = .void_ };
                for (b.stmts) |stmt| {
                    last = self.checkExpr(stmt);
                }
                self.popScope();
                return last;
            },
            .if_expr => |ie| {
                const cond_type = self.checkExpr(ie.condition);
                if (cond_type != .unknown and cond_type != .primitive) {
                    self.addError("if condition requires bool, got {any}", .{cond_type});
                }
                const then_type = self.checkExpr(ie.then_body);
                const else_type = if (ie.else_body) |eb| self.checkExpr(eb) else Type{ .primitive = .void_ };
                if (!typesCompatible(then_type, else_type)) {
                    self.addError("if branch type mismatch: then={any}, else={any}", .{ then_type, else_type });
                }
                return then_type;
            },
            .match_expr => |m| {
                _ = self.checkExpr(m.value);
                var result_type: ?Type = null;
                for (m.cases) |case| {
                    if (case.guard) |g| {
                        const gtype = self.checkExpr(g);
                        if (gtype != .unknown and gtype != .primitive) {
                            self.addError("match guard requires bool, got {any}", .{gtype});
                        }
                    }
                    const body_type = self.checkExpr(case.body);
                    if (result_type) |rt| {
                        if (!typesCompatible(rt, body_type)) {
                            self.addError("match branch type mismatch: {any} vs {any}", .{ rt, body_type });
                        }
                    } else {
                        result_type = body_type;
                    }
                }
                return result_type orelse Type{ .unknown = {} };
            },
            .todo_expr => { return Type{ .unknown = {} }; },
            .echo_expr => |e| { return self.checkExpr(e); },
            .anon_func => |af| {
                self.pushScope() catch {};
                for (af.params) |p| {
                    const ptype = if (p.type_ann) |ta|
                        self.resolveTypeExpr(ta) catch Type{ .unknown = {} }
                    else
                        Type{ .unknown = {} };
                    self.define(p.name, .{ .type = ptype, .mutable = false }) catch {};
                }
                const prev_ret = self.current_return_type;
                self.current_return_type = if (af.return_type) |rt|
                    self.resolveTypeExpr(rt) catch Type{ .unknown = {} }
                else
                    null;
                const body_type = self.checkExpr(af.body);
                self.current_return_type = prev_ret;
                self.popScope();
                return body_type;
            },
            .struct_literal => |sl| {
                if (sl.type_name) |tn| {
                    return self.checkTypedStructLiteral(tn, sl.fields);
                }
                return self.checkAnonStructLiteral(sl.fields);
            },
            .array_literal => |arr| {
                var elem_type: ?Type = null;
                for (arr) |elem| {
                    const et = self.checkExpr(elem);
                    if (elem_type) |et2| {
                        if (!typesCompatible(et2, et)) {
                            self.addError("array element type mismatch: {any} vs {any}", .{ et2, et });
                        }
                    } else {
                        elem_type = et;
                    }
                }
                const inner = self.allocType(elem_type orelse Type{ .unknown = {} });
                return Type{ .array = inner };
            },
            .let_binding => |lb| {
                const value_type = self.checkExpr(lb.value);
                if (lb.type_ann) |ta| {
                    const ann_type = self.resolveTypeExpr(ta) catch Type{ .unknown = {} };
                    if (!typesCompatible(ann_type, value_type) and value_type != .unknown) {
                        self.addError("variable '{s}' type annotation mismatch: annotated={any}, value={any}", .{
                            lb.name, ann_type, value_type,
                        });
                    }
                }
                const sym = Symbol{ .type = value_type, .mutable = lb.mutable };
                self.define(lb.name, sym) catch {};
                return value_type;
            },
            .with_expr => |w| {
                const value_type = self.checkExpr(w.value);
                self.define(w.name, .{ .type = value_type, .mutable = false }) catch {};
                var last = Type{ .primitive = .void_ };
                for (w.body_stmts) |stmt| {
                    last = self.checkExpr(stmt);
                }
                return last;
            },
            .grouping => |g| { return self.checkExpr(g); },
        }
    }

    fn checkPipe(self: *TypeChecker, left_type: Type, right: *ast.Expr) Type {
        if (right.* != .call) {
            self.addError("|> right side must be a function call", .{});
            return Type{ .unknown = {} };
        }
        const callee_type = self.checkExpr(right.call.callee);
        // 管道将左侧值作为第一个参数传入
        _ = callee_type;
        _ = left_type;
        for (right.call.args) |arg| {
            _ = self.checkExpr(arg);
        }
        return Type{ .unknown = {} };
    }

    fn checkCall(self: *TypeChecker, callee: *ast.Expr, args: []const *ast.Expr) Type {
        // 先检查参数
        var arg_types = std.ArrayList(Type).empty;
        for (args) |arg| {
            arg_types.append(self.alloc(), self.checkExpr(arg)) catch {};
        }

        // 直接函数名调用: foo(...)
        const func_name = if (callee.* == .identifier) callee.identifier else null;
        if (func_name) |name| {
            if (self.function_sigs.get(name)) |sig| {
                if (sig.param_types.len != args.len) {
                    self.addError("function '{s}' argument count mismatch: expected {d}, got {d}", .{
                        name, sig.param_types.len, args.len,
                    });
                } else {
                    for (sig.param_types, 0..) |expected, i| {
                        const got = arg_types.items[i];
                        if (!typesCompatible(expected, got) and got != .unknown) {
                            self.addError("function '{s}' arg {d} type mismatch: expected {any}, got {any}", .{
                                name, i + 1, expected, got,
                            });
                        }
                    }
                }
                return sig.return_type;
            }
        }

        // 方法调用: obj.method(...)
        if (callee.* == .field_access) {
            const obj_type = self.checkExpr(callee.field_access.object);
            _ = obj_type;
        }

        // 匿名函数或未知 callee
        return Type{ .unknown = {} };
    }

    fn checkAssignmentTarget(self: *TypeChecker, target: *ast.Expr) Type {
        if (target.* != .identifier) {
            self.addError("assignment target must be an identifier", .{});
            return Type{ .unknown = {} };
        }
        const name = target.identifier;
        const sym = self.lookup(name) orelse {
            self.addError("undefined variable: '{s}'", .{name});
            return Type{ .unknown = {} };
        };
        if (!sym.mutable) {
            self.addError("cannot mutate immutable variable '{s}'", .{name});
        }
        return sym.type;
    }

    fn checkTypedStructLiteral(self: *TypeChecker, type_name: []const u8, fields: []const ast.FieldInit) Type {
        const sd = self.structs.get(type_name) orelse {
            self.addError("undefined struct: '{s}'", .{type_name});
            return Type{ .unknown = {} };
        };
        for (fields) |f| {
            const value_type = self.checkExpr(f.value);
            var found = false;
            for (sd.fields) |sf| {
                if (std.mem.eql(u8, sf.name, f.name)) {
                    const expected = self.resolveTypeExpr(sf.field_type) catch Type{ .unknown = {} };
                    if (!typesCompatible(expected, value_type) and value_type != .unknown) {
                        self.addError("field '{s}' type mismatch: expected {any}, got {any}", .{
                            f.name, expected, value_type,
                        });
                    }
                    found = true;
                    break;
                }
            }
            if (!found) {
                self.addError("struct '{s}' has no field '{s}'", .{ type_name, f.name });
            }
        }
        return Type{ .named = type_name };
    }

    fn checkAnonStructLiteral(self: *TypeChecker, fields: []const ast.FieldInit) Type {
        for (fields) |f| {
            _ = self.checkExpr(f.value);
        }
        return Type{ .unknown = {} };
    }

    fn checkFieldAccess(self: *TypeChecker, obj_type: Type, field: []const u8) Type {
        if (obj_type != .named) return Type{ .unknown = {} };
        if (self.structs.get(obj_type.named)) |sd| {
            for (sd.fields) |sf| {
                if (std.mem.eql(u8, sf.name, field)) {
                    return self.resolveTypeExpr(sf.field_type) catch Type{ .unknown = {} };
                }
            }
            self.addError("struct '{s}' has no field '{s}'", .{ obj_type.named, field });
        }
        return Type{ .unknown = {} };
    }

    // ── 类型解析与工具 ──

    fn resolveTypeExpr(self: *TypeChecker, te: *ast.TypeExpr) !Type {
        return resolveTypeExprImpl(te, self.structs, self.type_defs, self.alloc());
    }
};

fn resolveTypeExprImpl(te: *ast.TypeExpr, structs: std.StringHashMap(*ast.StructDef), type_defs: std.StringHashMap(*ast.TypeDef), allocator: std.mem.Allocator) !Type {
    switch (te.*) {
        .primitive => |p| return Type{ .primitive = p },
        .named => |n| {
            if (structs.contains(n) or type_defs.contains(n)) {
                return Type{ .named = n };
            }
            if (tryPrimitiveByName(n)) |p| return Type{ .primitive = p };
            return Type{ .unknown = {} };
        },
        .array => |inner| {
            const inner_type = try resolveTypeExprImpl(inner, structs, type_defs, allocator);
            const ptr = try allocator.create(Type);
            ptr.* = inner_type;
            return Type{ .array = ptr };
        },
        .function => |f| {
            var params = std.ArrayList(Type).empty;
            for (f.params) |p| {
                try params.append(allocator, try resolveTypeExprImpl(p, structs, type_defs, allocator));
            }
            const ret_ptr = try allocator.create(Type);
            ret_ptr.* = try resolveTypeExprImpl(f.return_type, structs, type_defs, allocator);
            return Type{ .function = .{ .params = params.items, .return_type = ret_ptr } };
        },
        .generic => |g| {
            return Type{ .named = g.name };
        },
    }
}

fn tryPrimitiveByName(name: []const u8) ?ast.PrimitiveType {
    const map = std.StaticStringMap(ast.PrimitiveType).initComptime(.{
        .{ "i8", .i8 },
        .{ "i16", .i16 },
        .{ "i32", .i32 },
        .{ "i64", .i64 },
        .{ "u8", .u8 },
        .{ "u16", .u16 },
        .{ "u32", .u32 },
        .{ "u64", .u64 },
        .{ "f32", .f32 },
        .{ "f64", .f64 },
        .{ "bool", .bool_ },
        .{ "string", .string_ },
        .{ "char", .char_ },
        .{ "void", .void_ },
        .{ "usize", .usize_ },
    });
    return map.get(name);
}

pub fn typeToStr(t: Type, buf: []u8) []const u8 {
    _ = buf;
    return switch (t) {
        .primitive => |p| @tagName(p),
        .named => |n| n,
        .array => |a| {
            return @tagName(a.*);
        },
        .function => "function",
        .unknown => "unknown",
    };
}

fn isNumeric(t: Type) bool {
    return switch (t) {
        .primitive => |p| switch (p) {
            .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .f32, .f64, .usize_ => true,
            else => false,
        },
        else => false,
    };
}

fn promoteNumeric(a: Type, b: Type) Type {
    if (a == .unknown) return b;
    if (b == .unknown) return a;
    return a;
}

fn typesCompatible(a: Type, b: Type) bool {
    if (a == .unknown or b == .unknown) return true;
    return typesEqual(a, b);
}

pub fn typesEqual(a: Type, b: Type) bool {
    if (@as(std.meta.Tag(Type), a) != @as(std.meta.Tag(Type), b)) return false;
    switch (a) {
        .primitive => |ap| return switch (b) {
            .primitive => |bp| ap == bp,
            else => false,
        },
        .named => |an| return switch (b) {
            .named => |bn| std.mem.eql(u8, an, bn),
            else => false,
        },
        .array => |aa| return switch (b) {
            .array => |ba| typesEqual(aa.*, ba.*),
            else => false,
        },
        .function => |af| return switch (b) {
            .function => |bf| {
                if (af.params.len != bf.params.len) return false;
                for (af.params, bf.params) |ap, bp| {
                    if (!typesEqual(ap, bp)) return false;
                }
                return typesEqual(af.return_type.*, bf.return_type.*);
            },
            else => false,
        },
        .unknown => return true,
    }
}

