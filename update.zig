// const ziglet = @import("ziglet");
// const CommandContext = ziglet.CommandContext;
// const Atomic = std.atomic.Value;
// const Thread = std.Thread;
// const std = @import("std");
// const terminal = ziglet.utils.terminal;
// const Color = terminal.Color;
// const printColored = terminal.printColored;

// const InstallationInfo = struct {
//     installing: bool,
//     version: []const u8,
// };

// const TuiEvent = union(enum) {
//     Checking,
//     FoundUpdate,
//     Installing,
//     Installed,
//     UpToDate,
//     Done,
// };

// const InstallEvent = enum {
//     Start,
//     Done,
// };

// fn EventChannel(comptime Event: type) type {
//     return struct {
//         mutex: Thread.Mutex = .{},
//         cond: Thread.Condition = .{},
//         queue: std.ArrayList(Event),
//         allocator: std.mem.Allocator,

//         const Self = @This();

//         pub fn init(allocator: std.mem.Allocator) Self {
//             return .{
//                 .queue = .empty,
//                 .allocator = allocator,
//             };
//         }

//         pub fn deinit(self: *Self) void {
//             self.queue.deinit(self.allocator);
//         }

//         pub fn send(self: *Self, event: Event) void {
//             self.mutex.lock();
//             defer self.mutex.unlock();

//             self.queue.append(self.allocator, event) catch unreachable;
//             self.cond.signal();
//         }

//         pub fn recv(self: *Self) Event {
//             self.mutex.lock();
//             defer self.mutex.unlock();

//             while (self.queue.items.len == 0) {
//                 self.cond.wait(&self.mutex);
//             }

//             return self.queue.orderedRemove(0);
//         }

//         pub fn tryRecv(self: *Self) ?Event {
//             self.mutex.lock();
//             defer self.mutex.unlock();

//             if (self.queue.items.len == 0) return null;
//             return self.queue.orderedRemove(0);
//         }
//     };
// }

// pub fn updateCommand(ctx: CommandContext) !void {
//     const allocator = ctx.allocator;
//     // var checking = Atomic(bool).init(true);

//     var tui = EventChannel(TuiEvent).init(allocator);
//     var install_channel = EventChannel(InstallEvent).init(allocator);

//     defer tui.deinit();
//     defer install_channel.deinit();

//     const animator = try std.Thread.spawn(.{}, animate, .{&tui});
//     const checker = try std.Thread.spawn(.{}, checkUpdate, .{ allocator, &tui, &install_channel });
//     const installer = try std.Thread.spawn(.{}, install, .{ allocator, &tui, &install_channel });

//     checker.join();
//     installer.join();

//     tui.send(.Done);
//     animator.join();
// }

// fn animate(channel: *EventChannel(TuiEvent)) void {
//     const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
//     var frame_index: usize = 0;

//     var text: []const u8 = "Checking for updates...";
//     var text_color: []const u8 = Color.ansiCode(.white);
//     var running = true;

//     while (running) {
//         while (channel.tryRecv()) |event| {
//             switch (event) {
//                 .Checking => {
//                     text = "Checking for updates...";
//                     text_color = Color.ansiCode(.white);
//                 },
//                 .Installing => {
//                     text = "Installing update...";
//                     text_color = Color.ansiCode(.white);
//                 },
//                 .Installed => {
//                     text = "✓ Update installed";
//                     text_color = Color.ansiCode(.green);
//                 },
//                 .UpToDate => {
//                     text = "🤗 zio is up to date!";
//                     text_color = Color.ansiCode(.green);
//                 },
//                 .FoundUpdate => {
//                     text = "New update available!";
//                     text_color = Color.ansiCode(.yellow);
//                 },
//                 .Done => running = false,
//                 // else => {},
//             }
//         }

//         std.debug.print("\r{s}{s} {s}{s}", .{
//             text_color,
//             frames[frame_index % frames.len],
//             text,
//             Color.ansiCode(.reset),
//         });

//         frame_index += 1;
//         std.Thread.sleep(100 * std.time.ns_per_ms);
//     }
//     std.debug.print("\n", .{});
// }

// fn checkUpdate(
//     allocator: std.mem.Allocator,
//     tui: *EventChannel(TuiEvent),
//     install_channel: *EventChannel(InstallEvent),
// ) void {
//     tui.send(.Checking);

//     const values_to_strip = std.ascii.whitespace ++ "\x1b[0m" ++ "\x1b[37m";

//     var child_process = std.process.Child.init(&.{ "curl", "-sL", "https://raw.githubusercontent.com/iamraphealc/zio/main/version" }, allocator);
//     child_process.stdout_behavior = .Pipe;

//     child_process.spawn() catch |err| {
//         printColored(.red, "Unable to spawn child process:{s}\n", .{@errorName(err)});
//         return;
//     };

//     var buffer: [50]u8 = undefined;

//     var first_byte_read: usize = 0;

//     if (child_process.stdout) |out| {
//         const len = out.readAll(&buffer) catch |err| {
//             printColored(.red, "Unable to read child process output:{s}\n", .{@errorName(err)});
//             return;
//         };
//         first_byte_read = len;
//     }

//     _ = child_process.wait() catch {
//         printColored(.red, "Unable to wait for child process\n", .{});
//         return;
//     };

//     const remote_version = std.mem.trim(u8, buffer[0..first_byte_read], &std.ascii.whitespace);

//     var child = std.process.Child.init(&.{ "zio", "-V" }, allocator);
//     child.stdout_behavior = .Pipe;

//     child.spawn() catch |err| {
//         printColored(.red, "Unable to spawn child process:{s}\n", .{@errorName(err)});
//         return;
//     };

//     var current_buffer: [50]u8 = undefined;

//     var byte_read: usize = 0;

//     if (child.stdout) |out| {
//         const len = out.readAll(&current_buffer) catch |err| {
//             printColored(.red, "Unable to read child process output:{s}\n", .{@errorName(err)});
//             return;
//         };
//         byte_read = len;
//     }

//     _ = child.wait() catch {
//         printColored(.red, "Unable to wait for child process\n", .{});
//         return;
//     };

//     const current_version = std.mem.trim(u8, current_buffer[0..byte_read], values_to_strip);

//     const is_updated = std.mem.eql(u8, remote_version, current_version);

//     if (is_updated) {
//         tui.send(.UpToDate);
//         return;
//     }

//     tui.send(.FoundUpdate);
//     tui.send(.Installing);

//     install_channel.send(.Start);
// }

// fn install(allocator: std.mem.Allocator, tui: *EventChannel(TuiEvent), install_channel: *EventChannel(InstallEvent)) void {
//     _ = allocator;
//     while (true) {
//         switch (install_channel.recv()) {
//             .Start => {},
//             .Done => return,
//         }
//     }

//     // simulate install work
//     var i: usize = 0;
//     while (i < 600_000_000) : (i += 1) {}

//     tui.send(.Installed);
// }
