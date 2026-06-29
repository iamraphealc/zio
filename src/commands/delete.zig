const ziglet = @import("ziglet");
const CommandContext = ziglet.CommandContext;
const std = @import("std");
const printColored = ziglet.utils.terminal.printColored;

pub fn deleteCommand(ctx: CommandContext) !void {
    var cwd = std.Io.Dir.cwd();
    const args = ctx.args;
    const io = ctx.init.io;

    if (args.len == 0) {
        printColored(io, &.{.yellow}, "Usage: zio delete <file_name>\n", .{});
    }

    for (args) |value| {
        cwd.deleteFile(io, value) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    printColored(io, &.{.red}, "Error: File '{s}' not found.\n", .{value});
                    return;
                },
                else => {
                    printColored(io, &.{.red}, "Error: Could not delete file '{s}': {s}.\n", .{ value, @errorName(err) });
                    return;
                },
            }
        };
        printColored(io, &.{.green}, "Deleted file: '{s}'\n", .{value});
    }
}
