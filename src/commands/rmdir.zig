const ziglet = @import("ziglet");
const CommandContext = ziglet.CommandContext;
const std = @import("std");
const terminal = ziglet.utils.terminal;
const printColored = terminal.printColored;

const Status = enum { success, _error, dir_not_empty };

const Stream = @import("../stream/mod.zig").Stream;
const Channel = @import("../stream/mod.zig").Channel;

pub fn removeDirCommand(ctx: CommandContext) !void {
    const allocator = ctx.allocator;
    const io = ctx.init.io;

    const force = ctx.options.get("force");

    const args = ctx.args;

    if (args.len == 0) {
        printColored(io, &.{.yellow}, "Usage: zio rmdir <dir_name>\n", .{});
    }

    for (args) |name| {
        if (force) |f| {
            const should_force = try ziglet.CLIUtils.takeBool(f);

            if (should_force) {
                try forceRemoveDir(name, io);
            } else {
                try removeDir(name, allocator, io);
            }
        }
    }
}

fn forceRemoveDir(name: []const u8, io: std.Io) !void {
    var cwd = std.Io.Dir.cwd();

    cwd.deleteTree(io, name) catch |err| {
        printColored(io, &.{.red}, "Failed to remove directory '{s}': {s}\n", .{ name, @errorName(err) });
        return;
    };
    printColored(io, &.{.green}, "Removed directory: '{s}'\n", .{name});
}

fn removeDir(name: []const u8, allocator: std.mem.Allocator, io: std.Io) !void {
    var cwd = std.Io.Dir.cwd();

    // First, check if directory exists
    cwd.access(io, name, .{}) catch |err| {
        if (err == error.FileNotFound) {
            printColored(io, &.{.red}, "Error: Directory '{s}' not found.\n", .{name});
            return;
        }
        return err;
    };

    // Create a channel for communication between the removal thread and spinner
    var status_ch = try Channel(Status).init(allocator, 1, io);
    defer status_ch.deinit();

    // Create error message channel for passing error details
    var error_ch = try Channel([]u8).init(allocator, 1, io);
    defer error_ch.deinit();

    // Initialize stream manager
    var stream = Stream.init(allocator);

    // Spawn the directory removal stream
    const removal_stream = try stream.spawn(struct {
        fn run(
            dir_name: []const u8,
            status_chan: *Channel(Status),
            error_chan: *Channel([]u8),
            io_inner: std.Io,
        ) !void {
            // Try to remove the directory
            var dir_cwd = std.Io.Dir.cwd();
            dir_cwd.deleteDir(io_inner, dir_name) catch |err| {
                switch (err) {
                    error.DirNotEmpty => {
                        status_chan.send(.dir_not_empty) catch {};
                        return;
                    },
                    else => {
                        // Send error details
                        const err_msg = try std.fmt.allocPrint(std.heap.page_allocator, "Failed to remove directory: {s}", .{@errorName(err)});
                        error_chan.send(err_msg) catch {
                            std.heap.page_allocator.free(err_msg);
                        };
                        status_chan.send(._error) catch {};
                        return;
                    },
                }
            };

            // If we get here, removal was successful
            status_chan.send(.success) catch {};
        }
    }.run, .{ name, status_ch, error_ch, io });
    defer {
        removal_stream.join();
        removal_stream.deinit();
    }

    // Spinner animation frames
    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    var frame_index: usize = 0;

    // Hide cursor while animating
    terminal.hideCursor(io);

    // Main loop - wait for removal to complete while showing spinner
    var removal_complete = false;
    while (!removal_complete) {
        // Try to receive status without blocking
        if (try status_ch.tryRecv()) |status| {
            removal_complete = true;

            // Clear the spinner line
            terminal.clearLine(io);

            switch (status) {
                .success => {
                    printColored(io, &.{.green}, "✓ Removed directory: '{s}'\n", .{name});
                },
                ._error => {
                    if (try error_ch.tryRecv()) |err_msg| {
                        defer allocator.free(err_msg);
                        printColored(io, &.{.red}, "✗ {s}\n", .{err_msg});
                    } else {
                        printColored(io, &.{.red}, "✗ Failed to remove directory '{s}'\n", .{name});
                    }
                },
                .dir_not_empty => {
                    // Handle non-empty directory
                    terminal.clearLine(io);
                    printColored(io, &.{.yellow}, "! Directory '{s}' is not empty.\n", .{name});

                    // Ask user if they want to force remove
                    const message = try std.fmt.allocPrint(allocator, "Do you want to force remove it?", .{});
                    defer allocator.free(message);

                    const should_force = terminal.confirm(allocator, io, message) catch {
                        printColored(io, &.{.red}, "Error: Failed to get confirmation input.\n", .{});
                        return;
                    };

                    if (should_force) {
                        // Spawn another stream for force removal
                        const force_stream = try stream.spawn(struct {
                            fn run(dir: []const u8, s: *Channel(Status), inner_io: std.Io) !void {
                                var fs_cwd = std.Io.Dir.cwd();
                                fs_cwd.deleteTree(inner_io, dir) catch {
                                    // _ = er;
                                    s.send(._error) catch {};
                                    return;
                                };
                                s.send(.success) catch {};
                            }
                        }.run, .{ name, status_ch, io });

                        // Show spinner again for force removal
                        removal_complete = false;
                        while (!removal_complete) {
                            if (try status_ch.tryRecv()) |new_status| {
                                removal_complete = true;
                                terminal.clearLine(io);
                                switch (new_status) {
                                    .success => {
                                        printColored(io, &.{.green}, "✓ Force removed directory: '{s}'\n", .{name});
                                    },
                                    ._error => {
                                        printColored(io, &.{.red}, "✗ Failed to force remove directory '{s}'\n", .{name});
                                    },
                                    else => {},
                                }
                            } else {
                                // Show spinner
                                terminal.clearLine(io);
                                printColored(io, &.{.cyan}, "{s} Force removing '{s}'...", .{ frames[frame_index % frames.len], name });
                                frame_index += 1;
                                try io.sleep(.fromMilliseconds(100 * std.time.ns_per_ms), .awake);
                            }
                        }
                        force_stream.join();
                        force_stream.deinit();
                    } else {
                        printColored(io, &.{.yellow}, "Skipped removing directory '{s}'.\n", .{name});
                    }
                },
            }
        } else {
            // Show spinner animation
            terminal.clearLine(io);
            printColored(io, &.{.cyan}, "{s} Removing directory '{s}'...", .{ frames[frame_index % frames.len], name });
            frame_index += 1;
            try io.sleep(.fromMilliseconds(100 * std.time.ns_per_ms), .awake);
        }
    }

    // Show cursor again
    terminal.showCursor(io);
}
