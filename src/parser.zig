const std = @import("std");
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;
const ast = @import("ast.zig");

pub const ParseError = error{
    UnexpectedToken,
    ExpectedExpression,
    ExpectedType,
    UnterminatedBlock,
    UnterminatedString,
} || std.mem.Allocator.Error;

pub const Parser = @This();

tokens: []const Token,
current: usize,
arena: std.heap.ArenaAllocator,
allow_struct_lit: bool = true,

pub fn init(tokens: []const Token, allocator: std.mem.Allocator) Parser {
    return .{
        .tokens = tokens,
        .current = 0,
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
}

pub fn deinit(self: *Parser) void {
    self.arena.deinit();
}

pub fn parse(self: *Parser) ParseError!ast.Program {
    self.skipNewlines();

    var decls: std.ArrayList(ast.Decl) = .empty;

    while (!self.check(.eof)) {
        const decl = try self.parseTopLevel();
        try decls.append(self.arena.allocator(),decl);

        if (!self.check(.eof)) {
            self.skipNewlines();
        }
    }

    return ast.Program{ .declarations = try decls.toOwnedSlice(self.arena.allocator()) };
}

// ═══════════════════════════════════════════════════════════════
// Token 辅助函数
// ═══════════════════════════════════════════════════════════════

fn peek(self: *const Parser) Token {
    if (self.current >= self.tokens.len) {
        return self.tokens[self.tokens.len - 1];
    }
    return self.tokens[self.current];
}

fn peekNext(self: *const Parser) Token {
    if (self.current + 1 >= self.tokens.len) {
        return self.tokens[self.tokens.len - 1];
    }
    return self.tokens[self.current + 1];
}

fn advance(self: *Parser) Token {
    const tok = self.peek();
    if (tok.type != .eof) {
        self.current += 1;
    }
    return tok;
}

fn check(self: *const Parser, t: TokenType) bool {
    return self.peek().type == t;
}

fn match(self: *Parser, t: TokenType) bool {
    if (self.check(t)) {
        _ = self.advance();
        return true;
    }
    return false;
}

fn consume(self: *Parser, t: TokenType, msg: []const u8) ParseError!Token {
    if (self.match(t)) {
        return self.tokens[self.current - 1];
    }
    _ = msg;
    return error.UnexpectedToken;
}

fn skipNewlines(self: *Parser) void {
    while (self.match(.newline)) {}
}

/// 跳过换行后匹配 token，失败则回退位置
fn matchAfterNL(self: *Parser, t: TokenType) bool {
    const saved = self.current;
    self.skipNewlines();
    if (self.check(t)) {
        _ = self.advance();
        return true;
    }
    self.current = saved;
    return false;
}

// ═══════════════════════════════════════════════════════════════
// 内存分配辅助
// ═══════════════════════════════════════════════════════════════

fn allocExpr(self: *Parser, expr: ast.Expr) ParseError!*ast.Expr {
    const ptr = try self.arena.allocator().create(ast.Expr);
    ptr.* = expr;
    return ptr;
}

fn allocTypeExpr(self: *Parser, te: ast.TypeExpr) ParseError!*ast.TypeExpr {
    const ptr = try self.arena.allocator().create(ast.TypeExpr);
    ptr.* = te;
    return ptr;
}

// ═══════════════════════════════════════════════════════════════
// 顶层声明解析
// ═══════════════════════════════════════════════════════════════

fn parseTopLevel(self: *Parser) ParseError!ast.Decl {
    // 检查可见性修饰符
    var visibility: ?ast.Visibility = null;
    if (self.match(.kw_pub)) {
        visibility = .pub_;
    } else if (self.match(.kw_export)) {
        visibility = .export_;
    }

    switch (self.peek().type) {
        .kw_fn => return ast.Decl{ .function = try self.parseFunctionDecl(visibility, false) },
        .kw_extern => {
            // extern 可能后跟 fn 或 struct
            if (visibility != null) {
                return error.UnexpectedToken;
            }
            return ast.Decl{ .extern_decl = try self.parseExternDecl() };
        },
        .kw_struct => {
            // pub/export struct
            return ast.Decl{ .struct_def = try self.parseStructDef(visibility) };
        },
        .kw_type => {
            if (visibility != null and visibility.? == .export_) {
                return error.UnexpectedToken; // type 只能用 pub
            }
            return ast.Decl{ .type_def = try self.parseTypeDef(visibility) };
        },
        .kw_import => {
            if (visibility != null) return error.UnexpectedToken;
            return ast.Decl{ .import_decl = try self.parseImportDecl() };
        },
        .kw_test => {
            if (visibility != null) return error.UnexpectedToken;
            return ast.Decl{ .test_decl = try self.parseTestDecl() };
        },
        else => {
            if (visibility != null) return error.UnexpectedToken;
            const expr = try self.parseExpression();
            return ast.Decl{ .expression = expr };
        },
    }
}

fn parseFunctionDecl(self: *Parser, visibility: ?ast.Visibility, is_extern: bool) ParseError!ast.FunctionDecl {
    _ = try self.consume(.kw_fn, "expected 'fn'");
    const name_tok = try self.consume(.identifier, "expected function name");
    _ = try self.consume(.lparen, "expected '('");

    const params = try self.parseParamList();

    _ = try self.consume(.rparen, "expected ')'");

    var return_type: ?*ast.TypeExpr = null;
    if (!self.check(.lbrace)) {
        return_type = try self.parseTypeExpr();
    }

    const body = try self.parseBlockExpr();

    return ast.FunctionDecl{
        .visibility = visibility,
        .is_extern = is_extern,
        .name = name_tok.lexeme,
        .params = params,
        .return_type = return_type,
        .body = body,
    };
}

fn parseExternDecl(self: *Parser) ParseError!ast.ExternDecl {
    _ = try self.consume(.kw_extern, "expected 'extern'");

    if (self.match(.kw_struct)) {
        const sd = try self.parseStructBody(null);
        const ptr = try self.arena.allocator().create(ast.StructDef);
        ptr.* = sd;
        return ast.ExternDecl{ .struct_def = ptr };
    }

    // extern fn
    _ = try self.consume(.kw_fn, "expected 'fn' after extern");
    const name_tok = try self.consume(.identifier, "expected function name");
    _ = try self.consume(.lparen, "expected '('");
    const params = try self.parseParamList();
    _ = try self.consume(.rparen, "expected ')'");

    var return_type: ?*ast.TypeExpr = null;
    if (!self.check(.newline) and !self.check(.eof)) {
        return_type = try self.parseTypeExpr();
    }

    return ast.ExternDecl{
        .function = .{
            .name = name_tok.lexeme,
            .params = params,
            .return_type = return_type,
        },
    };
}

fn parseStructDef(self: *Parser, visibility: ?ast.Visibility) ParseError!ast.StructDef {
    _ = try self.consume(.kw_struct, "expected 'struct'");
    return self.parseStructBody(visibility);
}

fn parseStructBody(self: *Parser, visibility: ?ast.Visibility) ParseError!ast.StructDef {
    const name_tok = try self.consume(.identifier, "expected struct name");
    _ = try self.consume(.lbrace, "expected '{'");

    var fields = std.ArrayList(ast.StructField).empty;

    self.skipNewlines();
    while (!self.check(.rbrace) and !self.check(.eof)) {
        const field_name = try self.consume(.identifier, "expected field name");
        _ = try self.consume(.colon, "expected ':'");
        const field_type = try self.parseTypeExpr();

        try fields.append(self.arena.allocator(),.{ .name = field_name.lexeme, .field_type = field_type });

        _ = self.match(.comma);
        self.skipNewlines();
    }

    _ = try self.consume(.rbrace, "expected '}'");

    return ast.StructDef{
        .visibility = visibility,
        .name = name_tok.lexeme,
        .fields = try fields.toOwnedSlice(self.arena.allocator()),
    };
}

fn parseTypeDef(self: *Parser, visibility: ?ast.Visibility) ParseError!ast.TypeDef {
    _ = try self.consume(.kw_type, "expected 'type'");
    const name_tok = try self.consume(.identifier, "expected type name");

    // 泛型参数
    var type_params: []const []const u8 = &.{};
    if (self.match(.lparen)) {
        var tp_list = std.ArrayList([]const u8).empty;
        while (!self.check(.rparen)) {
            const tp = try self.consume(.identifier, "expected type parameter");
            try tp_list.append(self.arena.allocator(),tp.lexeme);
            if (!self.match(.comma)) break;
        }
        _ = try self.consume(.rparen, "expected ')'");
        type_params = try tp_list.toOwnedSlice(self.arena.allocator());
    }

    _ = try self.consume(.eq, "expected '='");

    var variants = std.ArrayList(ast.Variant).empty;

    // 可选的起始 |
    _ = self.match(.pipe);

    while (true) {
        const var_name = try self.consume(.identifier, "expected variant name");

        var payload: []const *ast.TypeExpr = &.{};
        if (self.match(.lparen)) {
            payload = try self.parseTypeList();
            _ = try self.consume(.rparen, "expected ')'");
        }

        var discriminant: ?[]const u8 = null;
        if (self.match(.eq)) {
            if (self.match(.minus)) {
                const num = try self.consume(.number, "expected discriminant number");
                discriminant = try std.fmt.allocPrint(self.arena.allocator(), "-{s}", .{num.lexeme});
            } else {
                const num = try self.consume(.number, "expected discriminant number");
                discriminant = num.lexeme;
            }
        }

        try variants.append(self.arena.allocator(),.{
            .name = var_name.lexeme,
            .payload = payload,
            .discriminant = discriminant,
        });

        if (self.match(.pipe)) continue;
        break;
    }

    return ast.TypeDef{
        .visibility = visibility,
        .name = name_tok.lexeme,
        .type_params = type_params,
        .variants = try variants.toOwnedSlice(self.arena.allocator()),
    };
}

fn parseImportDecl(self: *Parser) ParseError!ast.ImportDecl {
    _ = try self.consume(.kw_import, "expected 'import'");
    const path_tok = try self.consume(.string, "expected import path string");
    return ast.ImportDecl{ .path = path_tok.lexeme };
}

fn parseTestDecl(self: *Parser) ParseError!ast.TestDecl {
    _ = try self.consume(.kw_test, "expected 'test'");
    const name_tok = try self.consume(.string, "expected test name string");
    const body = try self.parseBlockExpr();
    return ast.TestDecl{ .name = name_tok.lexeme, .body = body };
}

// ═══════════════════════════════════════════════════════════════
// 参数列表
// ═══════════════════════════════════════════════════════════════

fn parseParamList(self: *Parser) ParseError![]ast.Param {
    var params = std.ArrayList(ast.Param).empty;

    if (self.check(.rparen)) {
        return params.toOwnedSlice(self.arena.allocator());
    }

    while (true) {
        const name_tok = try self.consume(.identifier, "expected parameter name");

        var type_ann: ?*ast.TypeExpr = null;
        if (self.match(.colon)) {
            type_ann = try self.parseTypeExpr();
        }

        try params.append(self.arena.allocator(),.{ .name = name_tok.lexeme, .type_ann = type_ann });

        if (!self.match(.comma)) break;
    }

    return params.toOwnedSlice(self.arena.allocator());
}

fn parseArgList(self: *Parser) ParseError![]*ast.Expr {
    var args = std.ArrayList(*ast.Expr).empty;

    if (self.check(.rparen) or self.check(.rbracket)) {
        return args.toOwnedSlice(self.arena.allocator());
    }

    while (true) {
        const expr = try self.parseExpression();
        try args.append(self.arena.allocator(),expr);
        if (!self.match(.comma)) break;
    }

    return args.toOwnedSlice(self.arena.allocator());
}

// ═══════════════════════════════════════════════════════════════
// 表达式解析 (Pratt 递归下降)
// ═══════════════════════════════════════════════════════════════

fn parseExpression(self: *Parser) ParseError!*ast.Expr {
    // with_expr 只在 block 上下文中有效，此处不处理
    if (self.match(.kw_let) or self.match(.kw_var)) {
        return self.parseLetBinding();
    }
    return self.parseAssignmentExpr();
}

fn parseAssignmentExpr(self: *Parser) ParseError!*ast.Expr {
    var left = try self.parsePipelineExpr();

    while (self.match(.eq)) {
        const right = try self.parsePipelineExpr();
        left = try self.allocExpr(.{ .assignment = .{ .target = left, .value = right } });
    }

    return left;
}

fn parsePipelineExpr(self: *Parser) ParseError!*ast.Expr {
    var left = try self.parseLogicOrExpr();

    while (self.matchAfterNL(.pipe_greater)) {
        self.skipNewlines();
        const right = try self.parseLogicOrExpr();
        left = try self.allocExpr(.{ .binary = .{ .left = left, .op = .pipe, .right = right } });
    }

    return left;
}

fn parseLogicOrExpr(self: *Parser) ParseError!*ast.Expr {
    var left = try self.parseLogicAndExpr();

    while (self.matchAfterNL(.kw_or)) {
        const right = try self.parseLogicAndExpr();
        left = try self.allocExpr(.{ .binary = .{ .left = left, .op = .or_, .right = right } });
    }

    return left;
}

fn parseLogicAndExpr(self: *Parser) ParseError!*ast.Expr {
    var left = try self.parseComparisonExpr();

    while (self.matchAfterNL(.kw_and)) {
        const right = try self.parseComparisonExpr();
        left = try self.allocExpr(.{ .binary = .{ .left = left, .op = .and_, .right = right } });
    }

    return left;
}

fn parseComparisonExpr(self: *Parser) ParseError!*ast.Expr {
    var left = try self.parseConcatExpr();

    while (true) {
        const saved = self.current;
        self.skipNewlines();
        const op: ?ast.BinOp = if (self.match(.eq_eq))
            .eq_eq
        else if (self.match(.bang_eq))
            .bang_eq
        else if (self.match(.less_eq))
            .less_eq
        else if (self.match(.greater_eq))
            .greater_eq
        else if (self.match(.less))
            .less
        else if (self.match(.greater))
            .greater
        else
            null;

        if (op == null) {
            self.current = saved;
            break;
        }
        const right = try self.parseConcatExpr();
        left = try self.allocExpr(.{ .binary = .{ .left = left, .op = op.?, .right = right } });
    }

    return left;
}

fn parseConcatExpr(self: *Parser) ParseError!*ast.Expr {
    var left = try self.parseAddExpr();

    while (self.matchAfterNL(.less_greater)) {
        const right = try self.parseAddExpr();
        left = try self.allocExpr(.{ .binary = .{ .left = left, .op = .concat, .right = right } });
    }

    return left;
}

fn parseAddExpr(self: *Parser) ParseError!*ast.Expr {
    var left = try self.parseMultExpr();

    while (true) {
        const saved = self.current;
        self.skipNewlines();
        const op: ?ast.BinOp = if (self.match(.plus))
            .add
        else if (self.match(.minus))
            .sub
        else
            null;

        if (op == null) {
            self.current = saved;
            break;
        }
        const right = try self.parseMultExpr();
        left = try self.allocExpr(.{ .binary = .{ .left = left, .op = op.?, .right = right } });
    }

    return left;
}

fn parseMultExpr(self: *Parser) ParseError!*ast.Expr {
    var left = try self.parseUnaryExpr();

    while (true) {
        const saved = self.current;
        self.skipNewlines();
        const op: ?ast.BinOp = if (self.match(.star))
            .mul
        else if (self.match(.slash))
            .div
        else if (self.match(.percent))
            .mod
        else
            null;

        if (op == null) {
            self.current = saved;
            break;
        }
        const right = try self.parseUnaryExpr();
        left = try self.allocExpr(.{ .binary = .{ .left = left, .op = op.?, .right = right } });
    }

    return left;
}

fn parseUnaryExpr(self: *Parser) ParseError!*ast.Expr {
    if (self.match(.kw_not)) {
        const expr = try self.parseUnaryExpr();
        return self.allocExpr(.{ .unary = .{ .op = .not_, .expr = expr } });
    }

    if (self.match(.minus)) {
        const expr = try self.parseUnaryExpr();
        return self.allocExpr(.{ .unary = .{ .op = .neg, .expr = expr } });
    }

    return self.parsePostfixExpr();
}

fn parsePostfixExpr(self: *Parser) ParseError!*ast.Expr {
    const expr = try self.parseAtom();
    return self.parsePostfixRest(expr);
}

fn parsePostfixRest(self: *Parser, base: *ast.Expr) ParseError!*ast.Expr {
    var expr = base;

    while (true) {
        if (self.match(.lparen)) {
            const args = try self.parseArgList();
            _ = try self.consume(.rparen, "expected ')'");
            expr = try self.allocExpr(.{ .call = .{ .callee = expr, .args = args } });
        } else if (self.match(.lbracket)) {
            const index_expr = try self.parseExpression();
            _ = try self.consume(.rbracket, "expected ']'");
            expr = try self.allocExpr(.{ .index = .{ .object = expr, .index_expr = index_expr } });
        } else if (self.match(.dot)) {
            const field_tok = try self.consume(.identifier, "expected field name");
            expr = try self.allocExpr(.{ .field_access = .{ .object = expr, .field = field_tok.lexeme } });
        } else if (self.match(.question)) {
            expr = try self.allocExpr(.{ .error_prop = expr });
        } else if (self.match(.bang)) {
            expr = try self.allocExpr(.{ .force_unwrap = expr });
        } else {
            break;
        }
    }

    return expr;
}

fn parseAtom(self: *Parser) ParseError!*ast.Expr {
    const tok = self.peek();

    switch (tok.type) {
        .number => {
            _ = self.advance();
            return self.allocExpr(.{ .literal = .{ .kind = .number, .value = tok.lexeme } });
        },
        .string => {
            _ = self.advance();
            return self.allocExpr(.{ .literal = .{ .kind = .string, .value = tok.lexeme } });
        },
        .kw_true => {
            _ = self.advance();
            return self.allocExpr(.{ .literal = .{ .kind = .true_, .value = "true" } });
        },
        .kw_false => {
            _ = self.advance();
            return self.allocExpr(.{ .literal = .{ .kind = .false_, .value = "false" } });
        },
        .kw_void => {
            _ = self.advance();
            return self.allocExpr(.{ .literal = .{ .kind = .void_, .value = "void" } });
        },
        .identifier => {
            // 尝试匿名函数: name => body
            if (self.peekNext().type == .eq_greater) {
                const name_tok = self.advance();
                _ = self.advance(); // =>
                const body = try self.parseExpressionOrBlock();
                return self.allocExpr(.{ .anon_func = .{
                    .params = &.{.{ .name = name_tok.lexeme, .type_ann = null }},
                    .return_type = null,
                    .body = body,
                } });
            }

            // 尝试匿名函数(带返回类型): name: Type => body
            if (self.peekNext().type == .colon) {
                const saved = self.current;
                const name_tok = self.advance();
                _ = self.advance(); // :
                if (self.tryParseAnonFuncAfterColon(name_tok.lexeme)) |expr| {
                    return expr;
                }
                self.current = saved;
            }

            // 标识符引用 (可能后跟 postfix 或 struct literal)
            const name = self.advance().lexeme;

            // 检查结构体字面量: Name { fields }
            // 仅在 flag 启用时才解析 (match/if 等需要先消费 { 的上下文中禁用)
            if (self.allow_struct_lit and self.peek().type == .lbrace and !isAfterArrow(self)) {
                return self.parseStructLiteral(name);
            }

            const expr = try self.allocExpr(.{ .identifier = name });
            return self.parsePostfixRest(expr);
        },
        .lparen => {
            // 尝试匿名函数: (params) => body
            const saved = self.current;
            if (self.tryParseAnonFuncParens()) |expr| {
                return expr;
            }
            self.current = saved;

            // 分组表达式
            _ = self.advance(); // (
            const expr = try self.parseExpression();
            _ = try self.consume(.rparen, "expected ')'");
            return self.allocExpr(.{ .grouping = expr });
        },
        .lbrace => {
            // 检查匿名结构体字面量: { field: value, ... }
            // 需要 lookahead: { identifier : ... 才是结构体字面量
            if (self.isAnonStructLiteral()) {
                return self.parseStructLiteral(null);
            }
            return self.parseBlockExpr();
        },
        .lbracket => {
            return self.parseArrayLiteral();
        },
        .kw_if => {
            return self.parseIfExpr();
        },
        .kw_match => {
            return self.parseMatchExpr();
        },
        .kw_todo => {
            _ = self.advance();
            var msg: ?[]const u8 = null;
            if (self.peek().type == .string) {
                msg = self.advance().lexeme;
            }
            return self.allocExpr(.{ .todo_expr = msg });
        },
        .kw_echo => {
            _ = self.advance();
            const expr = try self.parseExpression();
            return self.allocExpr(.{ .echo_expr = expr });
        },
        else => return error.ExpectedExpression,
    }
}

/// 从 start 索引向前跳过换行，返回第一个非换行 token 的索引
fn skipNLAt(self: *const Parser, start: usize) usize {
    var i = start;
    while (i < self.tokens.len and self.tokens[i].type == .newline) : (i += 1) {}
    return i;
}

/// 匿名结构体字面量以 { identifier: 开始
fn isAnonStructLiteral(self: *const Parser) bool {
    const i = self.skipNLAt(self.current + 1);
    if (i < self.tokens.len and self.tokens[i].type == .identifier) {
        const j = self.skipNLAt(i + 1);
        return j < self.tokens.len and self.tokens[j].type == .colon;
    }
    return false;
}

fn peekNextNext(self: *const Parser) Token {
    const i = self.skipNLAt(self.current + 2);
    if (i < self.tokens.len) return self.tokens[i];
    return self.tokens[self.tokens.len - 1];
}

/// 检查是否紧跟在 => 之后 (此时 { 应解析为 block 而非结构体字面量)
fn isAfterArrow(self: *const Parser) bool {
    var i: usize = self.current;
    while (i > 0) {
        i -= 1;
        if (self.tokens[i].type == .newline) continue;
        return self.tokens[i].type == .eq_greater;
    }
    return false;
}

/// 尝试解析匿名函数剩余部分: Type => body
fn tryParseAnonFuncAfterColon(self: *Parser, param_name: []const u8) ?*ast.Expr {
    const ret_type = self.parseTypeExpr() catch return null;
    if (!self.match(.eq_greater)) return null;
    const body = self.parseExpressionOrBlock() catch return null;
    return self.allocExpr(.{ .anon_func = .{
        .params = &.{.{ .name = param_name, .type_ann = null }},
        .return_type = ret_type,
        .body = body,
    } }) catch null;
}

/// 尝试解析括号匿名函数: (params) [return_type] => body
fn tryParseAnonFuncParens(self: *Parser) ?*ast.Expr {
    _ = self.advance(); // (

    var params = std.ArrayList(ast.Param).empty;

    if (!self.check(.rparen)) {
        while (true) {
            if (self.peek().type != .identifier) return null;
            const name = self.advance().lexeme;
            var type_ann: ?*ast.TypeExpr = null;
            if (self.match(.colon)) {
                type_ann = self.parseTypeExpr() catch return null;
            }
            params.append(self.arena.allocator(),.{ .name = name, .type_ann = type_ann }) catch return null;

            if (!self.match(.comma)) break;
        }
    }

    if (!self.match(.rparen)) return null;

    // 可选返回类型
    var return_type: ?*ast.TypeExpr = null;
    if (self.match(.colon)) {
        return_type = self.parseTypeExpr() catch return null;
    }

    // 期望 =>
    if (!self.match(.eq_greater)) return null;

    const body = self.parseExpressionOrBlock() catch return null;

    return self.allocExpr(.{ .anon_func = .{
        .params = params.items,
        .return_type = return_type,
        .body = body,
    } }) catch null;
}

fn parseExpressionOrBlock(self: *Parser) ParseError!*ast.Expr {
    if (self.check(.lbrace)) {
        return self.parseBlockExpr();
    }
    return self.parseExpression();
}

// ═══════════════════════════════════════════════════════════════
// 绑定与块表达式
// ═══════════════════════════════════════════════════════════════

fn parseLetBinding(self: *Parser) ParseError!*ast.Expr {
    const mutable = self.tokens[self.current - 1].type == .kw_var;
    const name_tok = try self.consume(.identifier, "expected variable name");

    var type_ann: ?*ast.TypeExpr = null;
    if (self.match(.colon)) {
        type_ann = try self.parseTypeExpr();
    }

    _ = try self.consume(.eq, "expected '='");

    const value = try self.parseExpression();

    return self.allocExpr(.{ .let_binding = .{
        .mutable = mutable,
        .name = name_tok.lexeme,
        .type_ann = type_ann,
        .value = value,
    } });
}

fn parseBlockExpr(self: *Parser) ParseError!*ast.Expr {
    _ = try self.consume(.lbrace, "expected '{'");
    const stmts = try self.parseBlockStmts();
    _ = try self.consume(.rbrace, "expected '}'");
    return self.allocExpr(.{ .block = .{ .stmts = stmts } });
}

fn parseBlockStmts(self: *Parser) ParseError![]*ast.Expr {
    self.skipNewlines();

    var stmts = std.ArrayList(*ast.Expr).empty;

    while (!self.check(.rbrace) and !self.check(.eof)) {
        // 处理 with 表达式 (消费 block 剩余部分)
        if (self.match(.kw_with)) {
            const name_tok = try self.consume(.identifier, "expected identifier after 'with'");
            _ = try self.consume(.less_minus, "expected '<-'");
            const value = try self.parseAssignmentExpr();
            _ = try self.consume(.newline, "expected newline after with binding");
            const body_stmts = try self.parseBlockStmts();
            try stmts.append(self.arena.allocator(),try self.allocExpr(.{ .with_expr = .{
                .name = name_tok.lexeme,
                .value = value,
                .body_stmts = body_stmts,
            } }));
            break; // with 消费了 block 剩余部分
        }

        const expr = try self.parseExpression();
        try stmts.append(self.arena.allocator(),expr);

        self.skipNewlines();

        // 跳过换行后若遇到 with，继续循环处理
        if (self.check(.kw_with)) continue;
    }

    return stmts.toOwnedSlice(self.arena.allocator());
}

// ═══════════════════════════════════════════════════════════════
// 控制流表达式
// ═══════════════════════════════════════════════════════════════

fn parseIfExpr(self: *Parser) ParseError!*ast.Expr {
    _ = try self.consume(.kw_if, "expected 'if'");
    // 禁止 identifier { 被解析为结构体字面量，{ 属于 if 分支体
    self.allow_struct_lit = false;
    defer self.allow_struct_lit = true;
    const condition = try self.parseExpression();
    const then_body = try self.parseBlockExpr();

    var else_body: ?*ast.Expr = null;
    if (self.match(.kw_else)) {
        if (self.check(.kw_if)) {
            else_body = try self.parseIfExpr();
        } else {
            else_body = try self.parseBlockExpr();
        }
    }

    return self.allocExpr(.{ .if_expr = .{ .condition = condition, .then_body = then_body, .else_body = else_body } });
}

fn parseMatchExpr(self: *Parser) ParseError!*ast.Expr {
    _ = try self.consume(.kw_match, "expected 'match'");
    // 禁止 identifier { 被解析为结构体字面量，{ 属于 match 分支体
    self.allow_struct_lit = false;
    defer self.allow_struct_lit = true;
    const value = try self.parseExpression();
    _ = try self.consume(.lbrace, "expected '{'");

    var cases = std.ArrayList(ast.MatchCase).empty;

    self.skipNewlines();
    while (!self.check(.rbrace) and !self.check(.eof)) {
        _ = try self.consume(.pipe, "expected '|'");
        const pattern = try self.parsePattern();

        var guard: ?*ast.Expr = null;
        if (self.match(.kw_if)) {
            guard = try self.parseExpression();
        }

        _ = try self.consume(.eq_greater, "expected '=>'");
        const body = try self.parseExpression();

        try cases.append(self.arena.allocator(),.{ .pattern = pattern, .guard = guard, .body = body });

        self.skipNewlines();
    }

    _ = try self.consume(.rbrace, "expected '}'");

    return self.allocExpr(.{ .match_expr = .{ .value = value, .cases = try cases.toOwnedSlice(self.arena.allocator()) } });
}

// ═══════════════════════════════════════════════════════════════
// 字面量
// ═══════════════════════════════════════════════════════════════

fn parseStructLiteral(self: *Parser, type_name: ?[]const u8) ParseError!*ast.Expr {
    if (type_name == null) {
        _ = try self.consume(.lbrace, "expected '{'");
    } else if (!self.match(.lbrace)) {
        // 不应发生，调用者已检查
        return error.UnexpectedToken;
    }

    var fields = std.ArrayList(ast.FieldInit).empty;

    self.skipNewlines();
    while (!self.check(.rbrace) and !self.check(.eof)) {
        const field_name = try self.consume(.identifier, "expected field name");
        _ = try self.consume(.colon, "expected ':'");
        const value = try self.parseExpression();

        try fields.append(self.arena.allocator(),.{ .name = field_name.lexeme, .value = value });

        _ = self.match(.comma);
        self.skipNewlines();
    }

    _ = try self.consume(.rbrace, "expected '}'");

    return self.allocExpr(.{ .struct_literal = .{
        .type_name = type_name,
        .fields = try fields.toOwnedSlice(self.arena.allocator()),
    } });
}

fn parseArrayLiteral(self: *Parser) ParseError!*ast.Expr {
    _ = try self.consume(.lbracket, "expected '['");
    const elements = try self.parseArgList();
    _ = try self.consume(.rbracket, "expected ']'");
    return self.allocExpr(.{ .array_literal = elements });
}

// ═══════════════════════════════════════════════════════════════
// 类型表达式解析
// ═══════════════════════════════════════════════════════════════

fn parseTypeExpr(self: *Parser) ParseError!*ast.TypeExpr {
    const tok = self.peek();

    switch (tok.type) {
        .identifier => {
            const name_tok = self.advance();

            // 检查泛型: Foo(T, U)
            if (self.match(.lparen)) {
                const type_args = try self.parseTypeList();
                _ = try self.consume(.rparen, "expected ')'");
                return self.allocTypeExpr(.{ .generic = .{ .name = name_tok.lexeme, .args = type_args } });
            }

            // 检查基础类型关键字
            if (try self.tryPrimitiveType(name_tok.lexeme)) |pt| {
                return self.allocTypeExpr(.{ .primitive = pt });
            }

            return self.allocTypeExpr(.{ .named = name_tok.lexeme });
        },
        .lbracket => {
            _ = self.advance(); // [
            const inner = try self.parseTypeExpr();
            _ = try self.consume(.rbracket, "expected ']'");
            return self.allocTypeExpr(.{ .array = inner });
        },
        .lparen => {
            _ = self.advance(); // (

            var params: []*ast.TypeExpr = &.{};
            if (!self.check(.rparen)) {
                params = try self.parseTypeList();
            }

            _ = try self.consume(.rparen, "expected ')'");
            _ = try self.consume(.minus_greater, "expected '->'");

            const ret = try self.parseTypeExpr();

            return self.allocTypeExpr(.{ .function = .{ .params = params, .return_type = ret } });
        },
        else => return error.ExpectedType,
    }
}

fn tryPrimitiveType(self: *Parser, name: []const u8) ParseError!?ast.PrimitiveType {
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
    _ = self;
    return map.get(name);
}

fn parseTypeList(self: *Parser) ParseError![]*ast.TypeExpr {
    var types = std.ArrayList(*ast.TypeExpr).empty;

    while (true) {
        const te = try self.parseTypeExpr();
        try types.append(self.arena.allocator(),te);
        if (!self.match(.comma)) break;
    }

    return types.toOwnedSlice(self.arena.allocator());
}

// ═══════════════════════════════════════════════════════════════
// 模式解析
// ═══════════════════════════════════════════════════════════════

fn parsePattern(self: *Parser) ParseError!ast.Pattern {
    const tok = self.peek();

    switch (tok.type) {
        .underscore => {
            _ = self.advance();
            return ast.Pattern{ .wildcard = {} };
        },
        .identifier => {
            const name_tok = self.advance();

            // 检查构造器模式: Name(args)
            if (self.match(.lparen)) {
                var args = std.ArrayList(ast.Pattern).empty;
                if (!self.check(.rparen)) {
                    while (true) {
                        try args.append(self.arena.allocator(),try self.parsePattern());
                        if (!self.match(.comma)) break;
                    }
                }
                _ = try self.consume(.rparen, "expected ')'");
                return ast.Pattern{ .constructor = .{ .name = name_tok.lexeme, .args = try args.toOwnedSlice(self.arena.allocator()) } };
            }

            return ast.Pattern{ .identifier = name_tok.lexeme };
        },
        .number => {
            const num = self.advance();
            return ast.Pattern{ .literal = .{ .kind = .number, .value = num.lexeme } };
        },
        .string => {
            const s = self.advance();
            return ast.Pattern{ .literal = .{ .kind = .string, .value = s.lexeme } };
        },
        .kw_true => {
            _ = self.advance();
            return ast.Pattern{ .literal = .{ .kind = .true_, .value = "true" } };
        },
        .kw_false => {
            _ = self.advance();
            return ast.Pattern{ .literal = .{ .kind = .false_, .value = "false" } };
        },
        .kw_void => {
            _ = self.advance();
            return ast.Pattern{ .literal = .{ .kind = .void_, .value = "void" } };
        },
        else => return error.ExpectedExpression,
    }
}
