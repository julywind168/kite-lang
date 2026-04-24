const std = @import("std");

pub const TokenType = enum {
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
    bang,
    less,
    greater,
    question,

    eq_eq,
    bang_eq,
    less_eq,
    greater_eq,
    amp_amp,
    pipe_pipe,
    pipe_greater,
    less_greater,
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
    kw_null,
    kw_pub,
    kw_for,
    kw_while,
    kw_return,
    kw_import,
    kw_export,
    kw_const,

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
