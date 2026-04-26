const std = @import("std");
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;

pub const Lexer = @This();

source: []const u8,
start: usize,
current: usize,
line: u32,
column: u32,
start_column: u32,

pub fn init(source: []const u8) Lexer {
    return Lexer{
        .source = source,
        .start = 0,
        .current = 0,
        .line = 1,
        .column = 1,
        .start_column = 1,
    };
}

pub fn tokenize(self: *Lexer, allocator: std.mem.Allocator) ![]Token {
    var tokens = std.ArrayList(Token).empty;
    errdefer tokens.deinit(allocator);

    while (true) {
        const token = self.nextToken();
        try tokens.append(allocator, token);
        if (token.type == .eof or token.type == .invalid) break;
    }

    return try tokens.toOwnedSlice(allocator);
}

fn nextToken(self: *Lexer) Token {
    while (true) {
        self.skipWhitespace();
        self.start = self.current;
        self.start_column = self.column;
        if (self.isAtEnd()) return self.makeToken(.eof);
        const c = self.advance();
        switch (c) {
            '(' => return self.makeToken(.lparen),
            ')' => return self.makeToken(.rparen),
            '[' => return self.makeToken(.lbracket),
            ']' => return self.makeToken(.rbracket),
            '{' => return self.makeToken(.lbrace),
            '}' => return self.makeToken(.rbrace),
            ',' => return self.makeToken(.comma),
            ':' => return self.makeToken(.colon),
            '.' => return self.makeToken(.dot),
            '_' => {
                if (isIdentChar(self.peek())) return self.identifier();
                return self.makeToken(.underscore);
            },
            '|' => {
                if (self.matchExpected('>')) return self.makeToken(.pipe_greater);
                return self.makeToken(.pipe);
            },
            '+' => return self.makeToken(.plus),
            '-' => {
                if (self.matchExpected('>')) return self.makeToken(.minus_greater);
                return self.makeToken(.minus);
            },
            '*' => return self.makeToken(.star),
            '/' => {
                if (self.matchExpected('/')) {
                    self.skipLineComment();
                } else {
                    return self.makeToken(.slash);
                }
            },
            '%' => return self.makeToken(.percent),
            '=' => {
                if (self.matchExpected('=')) return self.makeToken(.eq_eq);
                if (self.matchExpected('>')) return self.makeToken(.eq_greater);
                return self.makeToken(.eq);
            },
            '!' => {
                if (self.matchExpected('=')) return self.makeToken(.bang_eq);
                return self.makeErrorToken("unexpected character, use 'not' for logical negation");
            },
            '<' => {
                if (self.matchExpected('=')) return self.makeToken(.less_eq);
                if (self.matchExpected('>')) return self.makeToken(.less_greater);
                if (self.matchExpected('-')) return self.makeToken(.less_minus);
                return self.makeToken(.less);
            },
            '>' => {
                if (self.matchExpected('=')) return self.makeToken(.greater_eq);
                return self.makeToken(.greater);
            },
            '?' => return self.makeToken(.question),
            '"' => return self.string(),
            '0'...'9' => return self.number(),
            'a'...'z', 'A'...'Z' => return self.identifier(),
            else => return self.makeErrorToken("unexpected character"),
        }
    }
}

fn skipWhitespace(self: *Lexer) void {
    while (!self.isAtEnd()) {
        switch (self.peek()) {
            ' ', '\t', '\r', '\n' => _ = self.advance(),
            else => break,
        }
    }
}

fn skipLineComment(self: *Lexer) void {
    while (!self.isAtEnd() and self.peek() != '\n') {
        _ = self.advance();
    }
}

fn string(self: *Lexer) Token {
    while (self.peek() != '"' and !self.isAtEnd()) {
        if (self.peek() == '\\') {
            _ = self.advance();
            if (self.isAtEnd()) return self.makeErrorToken("unterminated string");
            _ = self.advance();
        } else {
            _ = self.advance();
        }
    }

    if (self.isAtEnd()) return self.makeErrorToken("unterminated string");

    _ = self.advance();
    return self.makeToken(.string);
}

fn number(self: *Lexer) Token {
    while (self.peek() >= '0' and self.peek() <= '9') {
        _ = self.advance();
    }

    if (self.peek() == '.' and self.peekNext() >= '0' and self.peekNext() <= '9') {
        _ = self.advance();
        while (self.peek() >= '0' and self.peek() <= '9') {
            _ = self.advance();
        }
    }

    return self.makeToken(.number);
}

fn identifier(self: *Lexer) Token {
    while (isIdentChar(self.peek())) {
        _ = self.advance();
    }

    while (self.peek() == '.' and isIdentChar(self.peekNext())) {
        _ = self.advance();
        _ = self.advance();
        while (isIdentChar(self.peek())) {
            _ = self.advance();
        }
    }

    const lexeme = self.source[self.start..self.current];
    return self.makeToken(keywordType(lexeme) orelse .identifier);
}

fn advance(self: *Lexer) u8 {
    const c = self.source[self.current];
    self.current += 1;
    if (c == '\n') {
        self.line += 1;
        self.column = 1;
    } else {
        self.column += 1;
    }
    return c;
}

fn peek(self: *Lexer) u8 {
    if (self.isAtEnd()) return 0;
    return self.source[self.current];
}

fn peekNext(self: *Lexer) u8 {
    if (self.current + 1 >= self.source.len) return 0;
    return self.source[self.current + 1];
}

fn isAtEnd(self: *Lexer) bool {
    return self.current >= self.source.len;
}

fn matchExpected(self: *Lexer, expected: u8) bool {
    if (self.isAtEnd()) return false;
    if (self.source[self.current] != expected) return false;
    self.current += 1;
    if (expected == '\n') {
        self.line += 1;
        self.column = 1;
    } else {
        self.column += 1;
    }
    return true;
}

fn makeToken(self: *Lexer, token_type: TokenType) Token {
    return Token{
        .type = token_type,
        .lexeme = self.source[self.start..self.current],
        .line = self.line,
        .column = self.start_column,
    };
}

fn makeErrorToken(self: *Lexer, message: []const u8) Token {
    return Token{
        .type = .invalid,
        .lexeme = message,
        .line = self.line,
        .column = self.start_column,
    };
}

fn isIdentChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => true,
        else => false,
    };
}

fn keywordType(lexeme: []const u8) ?TokenType {
    const map = std.StaticStringMap(TokenType).initComptime(.{
        .{ "let", .kw_let },
        .{ "var", .kw_var },
        .{ "fn", .kw_fn },
        .{ "extern", .kw_extern },
        .{ "struct", .kw_struct },
        .{ "type", .kw_type },
        .{ "if", .kw_if },
        .{ "else", .kw_else },
        .{ "match", .kw_match },
        .{ "true", .kw_true },
        .{ "false", .kw_false },
        .{ "void", .kw_void },
        .{ "null", .kw_null },
        .{ "pub", .kw_pub },
        .{ "with", .kw_with },
        .{ "import", .kw_import },
        .{ "export", .kw_export },
        .{ "todo", .kw_todo },
        .{ "and", .kw_and },
        .{ "or", .kw_or },
        .{ "not", .kw_not },
    });
    return map.get(lexeme);
}
