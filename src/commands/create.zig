const ziglet = @import("ziglet");
const CommandContext = ziglet.CommandContext;
const std = @import("std");
const printColored = ziglet.utils.terminal.printColored;

pub fn createCommand(ctx: CommandContext) !void {
    var cwd = std.Io.Dir.cwd();
    const io = ctx.init.io;

    const args = ctx.args;

    if (args.len == 0) {
        printColored(io, &.{.yellow}, "Usage: zio create <file_name>\n", .{});
    }

    for (args) |name| {
        var new_file = cwd.createFile(io, name, .{}) catch |err| {
            switch (err) {
                error.PathAlreadyExists => {
                    printColored(io, &.{.red}, "Error: File '{s}' already exists.\n", .{name});
                    return;
                },
                else => return err,
            }
        };
        defer new_file.close(io);
        printColored(io, &.{.green}, "Created file: '{s}'\n", .{name});
    }
}
