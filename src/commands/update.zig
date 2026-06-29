const ziglet = @import("ziglet");
const CommandContext = ziglet.CommandContext;
const Atomic = std.atomic.Value;
const Thread = std.Thread;
const std = @import("std");
const terminal = ziglet.utils.terminal;
const Color = terminal.Color;
const ColorV1 = @import("../utils.zig").ColorV1;
const printColored = terminal.printColored;
const builtin = @import("builtin");

const InstallationInfo = struct {
    installing: bool,
    version: []const u8,
};

pub fn updateCommand(ctx: CommandContext) !void {
    const allocator = ctx.allocator;
    var checking = Atomic(bool).init(true);
    const io = ctx.init.io;

    const installation_info = allocator.create(InstallationInfo) catch unreachable;

    installation_info.* = .{
        .installing = false,
        .version = "",
    };

    var installing = Atomic(*InstallationInfo).init(installation_info);

    const animation_thread = try Thread.spawn(.{}, animate, .{ &checking, &installing, io });
    const check_thread = try Thread.spawn(.{}, checkUpdate, .{ &checking, allocator, &installing, io });

    check_thread.join();

    if (installing.load(.acquire).installing) {
        const install_thread = try Thread.spawn(.{}, install, .{ allocator, &installing, io });
        install_thread.join();
    }

    checking.store(false, .release);
    animation_thread.join();

    defer allocator.destroy(installation_info);
}

fn animate(is_checking: *Atomic(bool), is_installing: *Atomic(*InstallationInfo), io: std.Io) void {
    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    var frame_index: usize = 0;

    while (is_checking.load(.acquire) or is_installing.load(.acquire).installing) {
        std.debug.print("\r{s}{s} {s}{s}", .{
            ColorV1.ansiCode(.white),
            frames[frame_index % frames.len],
            if (is_installing.load(.acquire).installing) "Installing update..." else "Checking for updates...",
            ColorV1.ansiCode(.reset),
        });
        io.sleep(.fromMilliseconds(100 * std.time.ns_per_ms), .awake) catch unreachable;
        frame_index += 1;
    }
}

fn checkUpdate(is_checking: *Atomic(bool), allocator: std.mem.Allocator, is_installing: *Atomic(*InstallationInfo), io: std.Io) void {
    var child_process = std.process.spawn(io, .{
        .argv = &.{ "curl", "-sL", "https://raw.githubusercontent.com/Kingrashy12/zio/main/version" },
        .stdout = .pipe,
    }) catch |err| {
        printColored(io, &.{.red}, "Unable to spawn process: {s}\n", .{@errorName(err)});
        return;
    };

    var buffer: [50]u8 = undefined;

    var first_byte_read: usize = 0;

    if (child_process.stdout) |out| {
        var streaming_reader = out.readerStreaming(io, &buffer);
        const reader = &streaming_reader.interface;

        const bytes = reader.take(50) catch |err| {
            printColored(io, &.{.red}, "Unable to read child process output:{s}\n", .{@errorName(err)});
            return;
        };
        first_byte_read = bytes.len;
    }

    _ = child_process.wait(io) catch {
        printColored(io, &.{.red}, "Unable to wait for child process\n", .{});
        return;
    };

    const version = std.mem.trim(u8, buffer[0..first_byte_read], &std.ascii.whitespace);

    var child = std.process.spawn(io, .{ .argv = &.{ "zio", "-V" }, .stdout = .pipe }) catch |err| {
        printColored(io, &.{.red}, "Unable to spawn child process: {s}\n", .{@errorName(err)});
        return;
    };

    var current_buffer: [50]u8 = undefined;

    var byte_read: usize = 0;

    if (child.stdout) |out| {
        var streaming_reader = out.readerStreaming(io, &buffer);
        const reader = &streaming_reader.interface;

        const bytes = reader.take(50) catch |err| {
            printColored(io, &.{.red}, "Unable to read child process output:{s}\n", .{@errorName(err)});
            return;
        };
        byte_read = bytes.len;
    }

    _ = child.wait(io) catch {
        printColored(io, &.{.red}, "Unable to wait for child process\n", .{});
        return;
    };

    const raw = current_buffer[0..byte_read];
    const clean = stripAnsi(allocator, raw) catch unreachable;
    defer allocator.free(clean);

    const current_version = std.mem.trim(u8, clean, &std.ascii.whitespace);

    const is_updated = std.mem.eql(u8, version, current_version);

    if (is_updated) {
        printColored(io, &.{.magenta}, "\r🤗 zio is up to date!    \n", .{});
    } else {
        std.debug.print("\r{s}✨ New update available!   {s}\n", .{
            ColorV1.ansiCode(.yellow),
            ColorV1.ansiCode(.reset),
        });

        is_installing.load(.seq_cst).installing = true;
        is_installing.load(.seq_cst).version = allocator.dupe(u8, version) catch unreachable;
    }

    is_checking.store(false, .release);
}

fn install(allocator: std.mem.Allocator, installing: *Atomic(*InstallationInfo), io: std.Io) void {
    if (!installing.load(.acquire).installing) return;

    const cmd = if (builtin.os.tag == .windows)
        &.{ "powershell", "-ExecutionPolicy", "Bypass", "-Command", "iwr -useb https://raw.githubusercontent.com/Kingrashy12/zio/main/install.ps1 | iex" }
    else
        &.{ "sh", "-c", "curl -sL https://raw.githubusercontent.com/Kingrashy12/zio/main/install.bash | sudo bash" };

    var child = std.process.spawn(io, .{ .argv = cmd, .stdout = .pipe, .stderr = .pipe }) catch |err| {
        printColored(io, &.{.red}, "Unable to spawn child process:{s}\n", .{@errorName(err)});
        return;
    };

    _ = child.wait(io) catch {
        printColored(io, &.{.red}, "Unable to wait for child process\n", .{});
        return;
    };

    installing.load(.seq_cst).installing = false;

    printColored(io, &.{.green}, "\r✓ Update installed '{s}'\n", .{installing.load(.acquire).version});

    allocator.free(installing.load(.seq_cst).version);
}

fn stripAnsi(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;

    while (i < input.len) {
        if (input[i] == 0x1b and i + 1 < input.len and input[i + 1] == '[') {
            i += 2;
            while (i < input.len and input[i] != 'm') i += 1;
            i += 1;
        } else {
            try out.append(allocator, input[i]);
            i += 1;
        }
    }

    return try out.toOwnedSlice(allocator);
}
