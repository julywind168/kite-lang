const std = @import("std");

pub const TokenType = enum {
    newline,
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,
    comma,
    colon,
    dot,
    pipe,
    underscore,
    plus,
    minus,
    star,
    slash,
    percent,
    eq,
    less,
    greater,
    question,
    bang,

    eq_eq,
    bang_eq,
    less_eq,
    greater_eq,
    pipe_greater,
    less_greater,
    less_minus,
    minus_greater,
    eq_greater,

    kw_let,
    kw_var,
    kw_fn,
    kw_extern,
    kw_struct,
    kw_type,
    kw_if,
    kw_else,
    kw_match,
    kw_true,
    kw_false,
    kw_void,
    kw_pub,
    kw_with,
    kw_import,
    kw_export,
    kw_test,
    kw_todo,
    kw_echo,
    kw_and,
    kw_or,
    kw_not,

    number,
    string,
    identifier,

    eof,
    invalid,
};

pub const Token = struct {
    type: TokenType,
    lexeme: []const u8,
    line: u32,
    column: u32,

    pub fn format(
        self: Token,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("{s: <16}  {s}  Ln {}, Col {}", .{
            @tagName(self.type),
            self.lexeme,
            self.line,
            self.column,
        });
    }
};
