const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Channel = @import("channel.zig").Channel;

/// Stream - lightweight abstraction over Thread + Channel
pub const Stream = struct {
    const Self = @This();

    /// Stream handle for managing a spawned stream
    pub const Handle = struct {
        thread: Thread, // Store by value, not pointer
        allocator: Allocator,

        pub fn join(self: *Handle) void {
            self.thread.join();
        }

        pub fn deinit(self: *Handle) void {
            self.allocator.destroy(self);
        }
    };

    allocator: Allocator,

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    /// Spawn a new stream that runs the given function
    /// Returns a Handle that can be used to join the stream
    pub fn spawn(self: *Self, comptime func: anytype, args: anytype) !*Handle {
        const Wrapper = struct {
            fn run(fn_ptr: @TypeOf(func), args_ptr: @TypeOf(args)) void {
                @call(.auto, fn_ptr, args_ptr) catch |err| {
                    std.debug.print("Stream error: {s}\n", .{@errorName(err)});
                };
            }
        };

        const handle = try self.allocator.create(Handle);
        errdefer self.allocator.destroy(handle);

        const thread = try Thread.spawn(.{}, Wrapper.run, .{ func, args });

        handle.* = Handle{
            .thread = thread,
            .allocator = self.allocator,
        };

        return handle;
    }

    /// Fan-out: distribute values from input channel to multiple output channels
    pub fn fanOut(self: *Self, comptime T: type, input: *Channel(T), outputs: []*Channel(T)) !void {
        _ = self;
        while (true) {
            const value = input.recv() catch |err| {
                if (err == error.ChannelClosed) {
                    // Close all output channels when input is closed
                    for (outputs) |out| {
                        out.close();
                    }
                    return;
                }
                return err;
            };

            // Distribute to all outputs
            for (outputs) |out| {
                out.send(value) catch |err| {
                    if (err == error.ChannelClosed) {
                        // Skip closed channels
                        continue;
                    }
                    return err;
                };
            }
        }
    }

    /// Fan-in: merge multiple input channels into a single output channel
    pub fn fanIn(self: *Self, comptime T: type, inputs: []*Channel(T), output: *Channel(T)) !void {
        _ = self;
        var active_inputs = inputs.len;

        while (active_inputs > 0) {
            for (inputs) |input| {
                if (input.isClosed()) {
                    continue;
                }

                const value = input.tryRecv() catch |err| {
                    if (err == error.ChannelClosed) {
                        active_inputs -= 1;
                        continue;
                    }
                    return err;
                };

                if (value) |v| {
                    output.send(v) catch |err| {
                        if (err == error.ChannelClosed) {
                            return;
                        }
                        return err;
                    };
                }
            }
        }

        // Close output when all inputs are done
        output.close();
    }
};
