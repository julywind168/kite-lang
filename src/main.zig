const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;

pub fn main(init: std.process.Init) !void {
    const args = try std.process.Args.toSlice(init.minimal.args, init.arena.allocator());
    const file_path = if (args.len > 1) args[1] else "examples/demo.kite";

    const file_content = try std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        init.io,
        file_path,
        init.gpa,
        std.Io.Limit.limited(1024 * 1024),
    );
    defer init.gpa.free(file_content);

    var lexer = Lexer.init(file_content);
    const tokens = try lexer.tokenize(init.gpa);
    defer init.gpa.free(tokens);

    for (tokens) |token| {
        if (token.type == .eof) {
            std.debug.print("EOF\n", .{});
        } else {
            std.debug.print("{s:<16}  \"{s}\"  Ln {}, Col {}\n", .{
                @tagName(token.type), token.lexeme, token.line, token.column,
            });
        }
    }

    std.debug.print("\nTotal tokens: {d}\n", .{tokens.len});
}
