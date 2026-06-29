const ziglet = @import("ziglet");
const CommandContext = ziglet.CommandContext;
const std = @import("std");
const printColored = ziglet.utils.terminal.printColored;

pub fn mkdirCommand(ctx: CommandContext) !void {
    var cwd = std.Io.Dir.cwd();
    const io = ctx.init.io;

    const args = ctx.args;

    if (args.len == 0) {
        printColored(io, &.{.yellow}, "Usage: zio mkdir <dir_name>\n", .{});
    }

    for (args) |name| {
        cwd.createDir(io, name, .default_dir) catch |err| {
            switch (err) {
                error.PathAlreadyExists => {
                    printColored(io, &.{.red}, "Error: Directory '{s}' already exists.\n", .{name});
                    return;
                },
                else => {
                    printColored(io, &.{.red}, "Failed to create directory '{s}': {s}\n", .{ name, @errorName(err) });
                    return;
                },
            }
        };

        printColored(io, &.{.green}, "Created directory: '{s}'\n", .{name});
    }
}
