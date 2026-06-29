const ziglet = @import("ziglet");
const CommandContext = ziglet.CommandContext;
const std = @import("std");
const printColored = ziglet.utils.terminal.printColored;

pub fn moveCommand(ctx: CommandContext) !void {
    var cwd = std.Io.Dir.cwd();
    const io = ctx.init.io;

    const args = ctx.args;

    if (args.len == 0) {
        printColored(io, &.{.yellow}, "Usage: zio move <old_location>::<new_location>\n", .{});
    }

    for (args) |arg| {
        const parts = std.mem.indexOf(u8, arg, "::");

        if (parts == null) {
            printColored(io, &.{.red}, "Invalid argument format: {s}. Expected format: <old_location>::<new_location>\n", .{arg});
            return;
        }

        var parts_slice = std.mem.tokenizeAny(u8, arg, "::");

        const old_location = parts_slice.next().?;
        const new_location = parts_slice.next();

        if (new_location == null) {
            printColored(io, &.{.red}, "Missing new location in argument: {s}. Expected format: <old_location>::<new_location>\n", .{arg});
            return;
        }

        // Since this is a move operation ensure the filename are same, <e.g> users.json :: data/users.json
        const old_name = std.fs.path.basename(old_location);
        const new_name = std.fs.path.basename(new_location.?);
        const new_dir_path = std.fs.path.dirname(new_location.?) orelse ".";

        if (!std.mem.eql(u8, old_name, new_name)) {
            printColored(io, &.{.red}, "Error: Move operation requires the same filename. Example: 'data.txt::folder/data.txt'. Got '{s}'::'{s}'\n", .{ old_name, new_name });
            return;
        }

        const new_dir = try cwd.openDir(io, new_dir_path, .{});
        defer new_dir.close(io);

        cwd.rename(old_location, new_dir, new_location.?, io) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    printColored(io, &.{.red}, "Error: Source file '{s}' not found.\n", .{old_location});
                    return;
                },
                error.DirNotEmpty => {
                    printColored(io, &.{.red}, "Error: Destination '{s}' already exists.\n", .{new_location.?});
                    return;
                },
                else => {
                    printColored(io, &.{.red}, "Error: Could not rename file '{s}' to '{s}': {s}.\n", .{ old_location, new_location.?, @errorName(err) });
                    return;
                },
            }
        };
        printColored(io, &.{.green}, "Moved file: '{s}' to '{s}'\n", .{ old_location, new_location.? });
    }
}
