const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Mutex = std.Io.Mutex;
const Condition = std.Io.Condition;

/// Generic typed channel supporting buffered and unbuffered modes
pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        buffer: ?[]T,
        head: usize,
        tail: usize,
        count: usize,
        capacity: usize,
        mutex: Mutex,
        send_cond: Condition,
        recv_cond: Condition,
        closed: bool,
        io: std.Io,

        /// Initialize a new channel with the specified capacity
        /// capacity = 0 creates an unbuffered (synchronous) channel
        /// capacity > 0 creates a buffered channel
        pub fn init(allocator: Allocator, capacity: usize, io: std.Io) !*Self {
            const channel = try allocator.create(Self);
            errdefer allocator.destroy(channel);

            const buffer = if (capacity > 0) try allocator.alloc(T, capacity) else null;

            channel.* = Self{
                .allocator = allocator,
                .buffer = buffer,
                .head = 0,
                .tail = 0,
                .count = 0,
                .capacity = capacity,
                .mutex = Mutex{
                    .state = .init(.unlocked),
                },
                .send_cond = Condition{
                    .state = .init(.{ .waiters = 0, .signals = 0 }),
                    .epoch = .init(0),
                },
                .recv_cond = Condition{
                    .state = .init(.{ .waiters = 0, .signals = 0 }),
                    .epoch = .init(0),
                },
                .closed = false,
                .io = io,
            };
            return channel;
        }

        /// Deinitialize the channel and free all resources
        pub fn deinit(self: *Self) void {
            // Ensure channel is closed before deinit
            self.close();

            // Free buffer if it exists
            if (self.buffer) |buf| {
                self.allocator.free(buf);
            }
            self.allocator.destroy(self);
        }

        /// Send a value to the channel
        /// Blocks if channel is full (buffered) or no receiver ready (unbuffered)
        pub fn send(self: *Self, value: T) !void {
            self.mutex.lock(self.io) catch unreachable;
            defer self.mutex.unlock(self.io);

            // Check if channel is closed
            if (self.closed) {
                return error.ChannelClosed;
            }

            // For unbuffered channels, wait for a receiver
            if (self.capacity == 0) {
                // In a real implementation, we'd need to handle direct transfer
                // For now, we'll use a simplified approach
                while (self.count > 0) {
                    try self.send_cond.wait(self.io, &self.mutex);
                    if (self.closed) return error.ChannelClosed;
                }
            } else {
                // For buffered channels, wait if buffer is full
                while (self.count >= self.capacity) {
                    try self.send_cond.wait(self.io, &self.mutex);
                    if (self.closed) return error.ChannelClosed;
                }
            }

            // Store the value
            if (self.capacity > 0) {
                // Buffered mode
                self.buffer.?[self.tail] = value;
                self.tail = (self.tail + 1) % self.capacity;
                self.count += 1;
            } else {
                // Unbuffered mode - just signal that we have a value
                self.count = 1;
            }

            // Signal waiting receivers
            self.recv_cond.signal(self.io);
        }

        /// Receive a value from the channel
        /// Blocks until a value is available or channel is closed
        pub fn recv(self: *Self) !T {
            self.mutex.lock(self.io) catch unreachable;
            defer self.mutex.unlock(self.io);

            // Wait for data
            while (self.count == 0) {
                if (self.closed) {
                    return error.ChannelClosed;
                }
                self.recv_cond.wait(self.io, &self.mutex);
            }

            // Get the value
            const value = if (self.capacity > 0) blk: {
                const val = self.buffer.?[self.head];
                self.head = (self.head + 1) % self.capacity;
                self.count -= 1;
                break :blk val;
            } else {
                // For unbuffered, we don't actually store
                self.count = 0;
                // In a real implementation, the value would come directly from sender
                // This is a placeholder
                @panic("Unbuffered receive needs proper implementation");
            };

            // Signal waiting senders
            self.send_cond.signal(self.io);

            return value;
        }

        /// Non-blocking receive
        pub fn tryRecv(self: *Self) !?T {
            self.mutex.lock(self.io) catch unreachable;
            defer self.mutex.unlock(self.io);

            if (self.closed) {
                return error.ChannelClosed;
            }

            if (self.count == 0) {
                return null;
            }

            const value = self.buffer.?[self.head];
            self.head = (self.head + 1) % self.capacity;
            self.count -= 1;

            // Signal waiting senders
            self.send_cond.signal(self.io);

            return value;
        }

        /// Non-blocking send
        pub fn trySend(self: *Self, value: T) !bool {
            self.mutex.lock(self.io) catch unreachable;
            defer self.mutex.unlock(self.io);

            if (self.closed) {
                return error.ChannelClosed;
            }

            if (self.count >= self.capacity) {
                return false;
            }

            self.buffer.?[self.tail] = value;
            self.tail = (self.tail + 1) % self.capacity;
            self.count += 1;

            // Signal waiting receivers
            self.recv_cond.signal(self.io);

            return true;
        }

        /// Close the channel
        /// No more sends allowed, but receivers can still drain
        pub fn close(self: *Self) void {
            self.mutex.lock(self.io) catch unreachable;
            defer self.mutex.unlock(self.io);

            if (!self.closed) {
                self.closed = true;
                // Wake up all waiting threads
                self.send_cond.broadcast(self.io);
                self.recv_cond.broadcast(self.io);
            }
        }

        /// Get the number of items currently in the channel
        pub fn len(self: *Self) usize {
            self.mutex.lock(self.io) catch unreachable;
            defer self.mutex.unlock(self.io);
            return self.count;
        }

        /// Check if channel is closed
        pub fn isClosed(self: *Self) bool {
            self.mutex.lock(self.io) catch unreachable;
            defer self.mutex.unlock(self.io);
            return self.closed;
        }
    };
}
