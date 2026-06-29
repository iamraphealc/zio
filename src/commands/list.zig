const ziglet = @import("ziglet");
const CommandContext = ziglet.CommandContext;
const std = @import("std");
const printColored = ziglet.utils.terminal.printColored;
const print = ziglet.utils.terminal.print;

pub fn listCommand(ctx: CommandContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.init.io;

    var cwd = std.Io.Dir.cwd();

    var dir = try cwd.openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();

    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(allocator);

    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(allocator);

    while (try it.next(io)) |entry| {
        const startsWithDot = entry.kind == .directory and std.mem.startsWith(u8, entry.name, ".");

        if (!startsWithDot and entry.kind == .directory) {
            try dirs.append(allocator, try allocator.dupe(u8, entry.name));
        } else if (!startsWithDot and entry.kind == .file) {
            try files.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }

    if (dirs.items.len > 0) {
        print(io, "Directories:\n", .{});
        for (dirs.items) |value| {
            printColored(io, &.{.green}, "  {s}\n", .{value});
            defer allocator.free(value);
        }
    }

    if (files.items.len > 0) {
        print(io, "\nFiles:\n", .{});
        for (files.items) |value| {
            printColored(io, &.{.blue}, "  {s}\n", .{value});
            defer allocator.free(value);
        }
    }
}
