const ziglet = @import("ziglet");
const CommandContext = ziglet.CommandContext;
const std = @import("std");
const printColored = ziglet.utils.terminal.printColored;

pub fn renameDirCommand(ctx: CommandContext) !void {
    var cwd = std.Io.Dir.cwd();
    const args = ctx.args;
    const io = ctx.init.io;

    if (args.len == 0) {
        printColored(io, &.{.yellow}, "Usage: zio rndir <old_name>-><new_name>\n\n", .{});
    }

    for (args) |value| {
        const parts = std.mem.indexOf(u8, value, "->");

        if (parts == null) {
            printColored(io, &.{.yellow}, "Usage: zio rndir <old_name>-><new_name>\n", .{});
            return;
        }

        var parts_slice = std.mem.tokenizeAny(u8, value, "->");

        const old_name = parts_slice.next().?;
        const new_name = parts_slice.next();

        if (new_name == null) {
            printColored(io, &.{.yellow}, "Missing new name in argument: {s}. Expected format: <old_name>-><new_name>\n", .{value});
            return;
        }

        const new_dir_path = std.fs.path.dirname(new_name.?) orelse ".";

        const new_dir = try cwd.openDir(io, new_dir_path, .{});
        defer new_dir.close(io);

        cwd.rename(old_name, new_dir, new_name.?, io) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    printColored(io, &.{.red}, "Error: Directory '{s}' not found.\n", .{old_name});
                    return;
                },
                error.DirNotEmpty => {
                    printColored(io, &.{.red}, "Error: Directory '{s}' already exists.\n", .{new_name.?});
                    return;
                },
                else => {
                    printColored(io, &.{.red}, "Error: Could not rename directory '{s}' to '{s}': {s}.\n", .{ old_name, new_name.?, @errorName(err) });
                    return;
                },
            }
        };
        printColored(io, &.{.green}, "Renamed directory: '{s}' to '{s}'\n", .{ old_name, new_name.? });
    }
}
