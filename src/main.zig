const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;

pub fn main(init: std.process.Init) !void {
    const args = try std.process.Args.toSlice(init.minimal.args, init.arena.allocator());
    const file_path = if (args.len > 1) args[1] else "examples/demo.kite";

    // 读取源文件
    const file_content = try std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        init.io,
        file_path,
        init.gpa,
        std.Io.Limit.limited(1024 * 1024),
    );
    defer init.gpa.free(file_content);

    // Lexer: token 化
    var lexer = Lexer.init(file_content);
    const tokens = try lexer.tokenize(init.gpa);
    defer init.gpa.free(tokens);

    // Parser: 生成 AST
    var parser = Parser.init(tokens, init.gpa);
    defer parser.deinit();

    const program = parser.parse() catch |err| {
        const tok = parser.tokens[parser.current];
        std.debug.print("语法错误 (Ln {d}, Col {d}): {s} 附近, 错误码: {s}\n", .{
            tok.line,
            tok.column,
            tok.lexeme,
            @errorName(err),
        });
        return;
    };

    // 打印 AST
    std.debug.print("=== Kite AST ({s}) [{d} decls] ===\n\n", .{ file_path, program.declarations.len });
    try program.dumpToStdout(init.gpa);
}
