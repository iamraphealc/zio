const std = @import("std");
const builtin = @import("builtin");
const ziglet = @import("ziglet");
const CLIUtils = ziglet.CLIUtils;
const CommandContext = ziglet.CommandContext;
const terminal = ziglet.utils.terminal;
const Color = terminal.Color;
const ColorV1 = @import("../utils.zig").ColorV1;
const print = terminal.print;
const printColored = terminal.printColored;

const FileStats = struct {
    name: []const u8,
    lines: usize,
    size: usize,
};

pub fn shouldIgnore(path: []const u8, patterns: [][]u8) bool {
    for (patterns) |p| {
        // Exact file match
        if (std.mem.eql(u8, path, p)) return true;

        // Prefix directory ignore
        if (std.mem.startsWith(u8, path, p)) return true;

        // Simple wildcard suffix matching
        if (std.mem.startsWith(u8, p, "*")) {
            const suffix = p[1..];
            if (std.mem.endsWith(u8, path, suffix)) return true;
        }
    }
    return false;
}

fn buildIgnoreList(allocator: std.mem.Allocator, args: [][]u8) [][]u8 {
    const default_ignore_lists = [_][]const u8{ "node_modules", "*.jpg", "*.png", "*.mp4", "*.svg", "*.ttf", ".git", ".zig-cache", "zig-pkg", "*.zir", "*.dia", "zig-out", "*.o", "*.obj", "*.so", "*.tgz", "*.tar", "*.zip", ".next", ".expo", "bin", "*.exe", "package-lock.json", "pnpm-lock.yaml", "*.tsbuildinfo", "*.lock", ".vscode", "*-cache", "*.cache" };

    var ignore_list: std.ArrayList([]u8) = .empty;

    // Add args first
    for (args) |arg| {
        ignore_list.append(allocator, arg) catch std.debug.panic("OOM", .{});
    }

    // Add default lists
    for (default_ignore_lists) |list| {
        ignore_list.append(allocator, @constCast(list)) catch std.debug.panic("OOM", .{});
    }

    return ignore_list.toOwnedSlice(allocator) catch std.debug.panic("OOM", .{});
}

const FILE_COL_WIDTH: usize = 45;
const LINES_COL_WIDTH: usize = 9;
const SIZE_COL_WIDTH: usize = 11;

pub fn statsCommand(ctx: CommandContext) !void {
    const allocator = ctx.allocator;
    const args = buildIgnoreList(allocator, ctx.args);
    defer allocator.free(args);
    const io = ctx.init.io;

    var dir: std.Io.Dir = undefined;

    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        dir = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    } else {
        dir = try std.Io.Dir.cwd().openDir(io, "", .{ .iterate = true });
    }
    defer dir.close(io);

    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |value| {
            allocator.free(value);
        }
        files.deinit(allocator);
    }

    var timer = std.Io.Timestamp.now(io, .awake);

    var scan_timer = std.Io.Timestamp.now(io, .awake);

    try walkFiles(allocator, &dir, "", &files, args, io);

    const scan_time = scan_timer.untilNow(io, .awake);

    var file_stats: std.ArrayList(FileStats) = .empty;
    defer file_stats.deinit(allocator);

    const CHUNK_SIZE: usize = 10000;

    var compute_timer = std.Io.Timestamp.now(io, .awake);

    for (files.items) |path| {
        var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch continue;
        defer file.close(io);

        const file_size = try file.length(io);

        var buffer: [CHUNK_SIZE]u8 = undefined;

        var line_count: usize = 0;

        // 2. Initialize the Streaming Reader with the required 'io' context and buffer
        var streaming_reader = file.readerStreaming(io, &buffer);
        const reader = &streaming_reader.interface;

        // 3. Proper chunk-reading loop in 0.16.0
        while (true) {
            // Use 'take' or 'read' equivalents depending on whether you want a full slice
            // readSliceAll populates the array or throws EndOfStream if it can't fill it entirely.
            // Instead, we use 'take' to read up to CHUNK_SIZE bytes smoothly.
            const bytes_read = reader.take(CHUNK_SIZE) catch |err| switch (err) {
                error.EndOfStream => {
                    // Handle the final remainder trailing in the internal buffer if any
                    const buffered = reader.buffered();
                    if (buffered.len > 0) {
                        line_count += std.mem.count(u8, buffered, "\n");
                    }
                    break;
                },
                else => return err,
            };

            if (bytes_read.len == 0) break;

            // Count newlines on exactly what was retrieved
            line_count += std.mem.count(u8, bytes_read, "\n");
        }

        // 4. Corrected last byte check using direct positional pread to avoid messing with stream states
        if (file_size > 0) {
            var last_byte_storage: [1]u8 = undefined;
            // pread reads from a specific absolute offset without modifying file seek pointers
            const bytes_read = try file.readPositionalAll(io, last_byte_storage[0..], file_size - 1);

            if (bytes_read == 1 and last_byte_storage[0] != '\n') {
                line_count += 1;
            }
        }

        try file_stats.append(allocator, .{ .name = path, .lines = line_count, .size = @intCast(file_size) });
    }

    // Print header
    printColored(io, &.{.gray}, "{s}", .{"File"});
    for ("File".len..FILE_COL_WIDTH) |_| printColored(io, &.{.gray}, " ", .{});
    printColored(io, &.{.gray}, " | ", .{});
    printColored(io, &.{.gray}, "{s}", .{"Line"});
    for ("Line".len..SIZE_COL_WIDTH) |_| printColored(io, &.{.gray}, " ", .{});
    printColored(io, &.{.gray}, " | ", .{});
    printColored(io, &.{.gray}, "{s}\n", .{"Size"});

    // Print separator
    for (0..FILE_COL_WIDTH + 5 + LINES_COL_WIDTH + 5 + SIZE_COL_WIDTH) |_| printColored(io, &.{.gray}, "-", .{});
    printColored(io, &.{.gray}, "\n", .{});

    // Print each row
    var total_lines: usize = 0;
    var total_size: usize = 0;
    for (file_stats.items) |fs| {
        var file_display = truncateName(fs.name);

        // Add "..." if truncated
        if (fs.name.len > FILE_COL_WIDTH) {
            // allocate temp buffer for truncated + "..."
            var tmp: [FILE_COL_WIDTH]u8 = undefined;
            @memcpy(tmp[0 .. FILE_COL_WIDTH - 3], file_display);
            tmp[FILE_COL_WIDTH - 3] = '.';
            tmp[FILE_COL_WIDTH - 2] = '.';
            tmp[FILE_COL_WIDTH - 1] = '.';
            file_display = tmp[0..FILE_COL_WIDTH];
        }

        // File column
        printColored(io, &.{.cyan}, "{s}", .{file_display});
        for (file_display.len..FILE_COL_WIDTH) |_| printColored(io, &.{.cyan}, " ", .{});

        printColored(io, &.{.green}, " | ", .{});

        const formatted_line_str = try formatNumber(allocator, fs.lines);
        defer allocator.free(formatted_line_str);

        // Right-align lines
        for (formatted_line_str.len..SIZE_COL_WIDTH) |_| printColored(io, &.{.green}, " ", .{});
        printColored(io, &.{.green}, "{s}", .{formatted_line_str});

        const size_str = try ziglet.utils.format.formatBytes(allocator, @intCast(fs.size));
        defer allocator.free(size_str);

        // Size column
        printColored(io, &.{.green}, " | ", .{});
        for (size_str.len..SIZE_COL_WIDTH) |_| printColored(io, &.{.green}, " ", .{});
        printColored(io, &.{.green}, "{s}\n", .{size_str});

        total_lines += fs.lines;
        total_size += fs.size;
    }

    // Print footer
    for (0..FILE_COL_WIDTH + 5 + LINES_COL_WIDTH + 5 + SIZE_COL_WIDTH) |_| printColored(io, &.{.gray}, "-", .{});
    printColored(io, &.{.gray}, "\n", .{});

    const total_lines_str = try formatNumber(allocator, total_lines);
    defer allocator.free(total_lines_str);

    const total_files_str = try formatNumber(allocator, file_stats.items.len);
    defer allocator.free(total_files_str);

    const total_size_str = try ziglet.utils.format.formatBytes(allocator, @intCast(total_size));
    defer allocator.free(total_size_str);

    print(io, "{s}Total files:{s} {s}\n", .{ ColorV1.ansiCode(.gray), ColorV1.ansiCode(.reset), total_files_str });
    print(io, "{s}Total lines:{s} {s}\n", .{ ColorV1.ansiCode(.gray), ColorV1.ansiCode(.reset), total_lines_str });
    print(io, "{s}Total Size:{s} {s}\n", .{ ColorV1.ansiCode(.gray), ColorV1.ansiCode(.reset), total_size_str });

    for (0..FILE_COL_WIDTH + 5 + LINES_COL_WIDTH + 5 + SIZE_COL_WIDTH) |_| printColored(io, &.{.gray}, "-", .{});

    printLanguageStats(allocator, &file_stats, io);

    print(io, "\n", .{});

    const dir_scan_time = ziglet.utils.format.convertNanosecondsToTime(@intCast(scan_time.toNanoseconds()));
    const compute_time = ziglet.utils.format.convertNanosecondsToTime(@intCast(compute_timer.untilNow(io, .awake).toNanoseconds()));
    const total_time = ziglet.utils.format.convertNanosecondsToTime(@intCast(timer.untilNow(io, .awake).toNanoseconds()));

    printColored(io, &.{.gray}, "\nDirectory scan completed in {d:.2}ms.\n", .{dir_scan_time.milliseconds});
    printColored(io, &.{.gray}, "Computation completed in {d:.2}ms.\n", .{compute_time.milliseconds});
    printColored(io, &.{.gray}, "Total time: {d:.2}ms.\n", .{total_time.milliseconds});
}

pub fn walkFiles(
    allocator: std.mem.Allocator,
    dir: *std.Io.Dir,
    base_path: []const u8,
    files: *std.ArrayList([]const u8),
    ignore_paths: [][]u8,
    io: std.Io,
) !void {
    var it = dir.iterate();

    while (try it.next(io)) |entry| {
        const name = entry.name;

        const full_path = try std.fs.path.join(allocator, &.{ base_path, name });

        // Check ignore
        if (shouldIgnore(full_path, ignore_paths)) {
            allocator.free(full_path); // Free ignored memory
            continue;
        }

        switch (entry.kind) {
            .file => {
                try files.append(allocator, full_path);
                // Caller frees later
            },
            .directory => {
                var sub_dir = dir.openDir(io, name, .{ .iterate = true }) catch {
                    allocator.free(full_path);
                    continue;
                };
                defer sub_dir.close(io);

                // Recurse
                walkFiles(allocator, &sub_dir, full_path, files, ignore_paths, io) catch {
                    allocator.free(full_path);
                    return;
                };

                allocator.free(full_path); // Always free after recursion
            },
            else => {
                allocator.free(full_path); // Avoid forgetting weird entries
            },
        }
    }
}

fn repeatChar(allocator: std.mem.Allocator, c: u8, count: usize) ![]u8 {
    const buf = try allocator.alloc(u8, count);
    for (buf) |*b| b.* = c;
    return buf;
}

fn padFixed(s: []const u8, width: usize) []const u8 {
    if (s.len >= width) return s[0..width]; // truncate if too long
    return s;
}

// Helper: truncate filenames if too long
fn truncateName(name: []const u8) []const u8 {
    if (name.len > FILE_COL_WIDTH) return name[0 .. FILE_COL_WIDTH - 3];
    return name;
}

pub fn formatNumber(allocator: std.mem.Allocator, n: usize) ![]const u8 {
    if (n >= 1_000_000_000) {
        const value = n / 1_000_000_000;
        const rem = (n % 1_000_000_000) / 100_000_000; // get 1 decimal
        return try std.fmt.allocPrint(allocator, "{d}.{d}B", .{ value, rem });
    } else if (n >= 1_000_000) {
        const value = n / 1_000_000;
        const rem = (n % 1_000_000) / 100_000; // 1 decimal
        return try std.fmt.allocPrint(allocator, "{d}.{d}M", .{ value, rem });
    } else if (n >= 1_000) {
        const value = n / 1_000;
        const rem = (n % 1_000) / 100; // 1 decimal
        return try std.fmt.allocPrint(allocator, "{d}.{d}K", .{ value, rem });
    } else {
        return try std.fmt.allocPrint(allocator, "{}", .{n});
    }
}

const Lang = struct {
    name: []const u8,
    color: []const u8, // ascii color
};

const language_map = std.StaticStringMap(Lang).initComptime(.{
    .{ ".zig", Lang{ .name = "Zig", .color = "\x1b[38;2;236;145;92m" } }, // #EC915C
    .{ ".zon", Lang{ .name = "Zig", .color = "\x1b[38;2;236;145;92m" } }, // #EC915C
    .{ ".ts", Lang{ .name = "TypeScript", .color = "\x1b[38;2;49;120;198m" } }, // #3178C6
    .{ ".js", Lang{ .name = "JavaScript", .color = "\x1b[38;2;241;224;90m" } }, // #F1E05A
    .{ ".rs", Lang{ .name = "Rust", .color = "\x1b[38;2;206;116;89m" } }, // #CE7459
    .{ ".py", Lang{ .name = "Python", .color = "\x1b[38;2;53;114;165m" } }, // #3572A5
    .{ ".java", Lang{ .name = "Java", .color = "\x1b[38;2;176;114;25m" } }, // #B07219
    .{ ".go", Lang{ .name = "Go", .color = "\x1b[38;2;0;173;216m" } }, // #00ADD8
    .{ ".c", Lang{ .name = "C", .color = "\x1b[38;2;85;85;85m" } }, // #555555
    .{ ".cpp", Lang{ .name = "C++", .color = "\x1b[38;2;243;75;125m" } }, // #F34B7D
    .{ ".h", Lang{ .name = "Header", .color = "\x1b[38;2;243;75;125m" } }, // #F34B7D
    .{ ".hpp", Lang{ .name = "C++ Header", .color = "\x1b[38;2;243;75;125m" } }, // #F34B7D
    .{ ".md", Lang{ .name = "Markdown", .color = "\x1b[38;2;8;63;161m" } }, // #083FA1
    .{ ".json", Lang{ .name = "JSON", .color = "\x1b[38;2;41;41;41m" } }, // #292929
    .{ ".qv", Lang{ .name = "Qorvak", .color = "\x1b[38;2;245;128;21m" } }, // #F58015
    .{ ".qvc", Lang{ .name = "Qorvak Bytecode", .color = "\x1b[38;2;79;118;133m" } }, // #4F7685
    .{ ".ush", Lang{ .name = "U-shell", .color = "\x1b[38;2;212;215;224m" } }, // #D4D7E0
    // Web languages
    .{ ".html", Lang{ .name = "HTML", .color = "\x1b[38;2;227;76;38m" } }, // #E34C26
    .{ ".htm", Lang{ .name = "HTML", .color = "\x1b[38;2;227;76;38m" } }, // #E34C26
    .{ ".css", Lang{ .name = "CSS", .color = "\x1b[38;2;102;51;153m" } }, // #663399
    .{ ".scss", Lang{ .name = "SCSS", .color = "\x1b[38;2;198;83;140m" } }, // #C6538C
    .{ ".sass", Lang{ .name = "Sass", .color = "\x1b[38;2;166;107;133m" } }, // #A69285
    .{ ".less", Lang{ .name = "Less", .color = "\x1b[38;2;29;54;93m" } }, // #1D365D
    .{ ".jsx", Lang{ .name = "React", .color = "\x1b[38;2;241;224;90m" } }, // #F1E05A (JavaScript)
    .{ ".tsx", Lang{ .name = "React TS", .color = "\x1b[38;2;49;120;198m" } }, // #3178C6 (TypeScript)
    .{ ".vue", Lang{ .name = "Vue", .color = "\x1b[38;2;65;184;131m" } }, // #41B883
    .{ ".svelte", Lang{ .name = "Svelte", .color = "\x1b[38;2;255;62;0m" } }, // #FF3E00
    // Shell/Scripting
    .{ ".sh", Lang{ .name = "Shell", .color = "\x1b[38;2;137;224;81m" } }, // #89E051
    .{ ".bash", Lang{ .name = "Bash", .color = "\x1b[38;2;137;224;81m" } }, // #89E051
    .{ ".zsh", Lang{ .name = "Zsh", .color = "\x1b[38;2;137;224;81m" } }, // #89E051
    .{ ".fish", Lang{ .name = "Fish", .color = "\x1b[38;2;74;110;87m" } }, // #4A6E57
    .{ ".ps1", Lang{ .name = "PowerShell", .color = "\x1b[38;2;1;36;86m" } }, // #012456
    .{ ".bat", Lang{ .name = "Batch", .color = "\x1b[38;2;193;241;46m" } }, // #C1F12E
    .{ ".cmd", Lang{ .name = "Batch", .color = "\x1b[38;2;193;241;46m" } }, // #C1F12E

    // Other popular languages
    .{ ".rb", Lang{ .name = "Ruby", .color = "\x1b[38;2;112;21;22m" } }, // #701516
    .{ ".php", Lang{ .name = "PHP", .color = "\x1b[38;2;79;93;149m" } }, // #4F5D95
    .{ ".swift", Lang{ .name = "Swift", .color = "\x1b[38;2;240;81;56m" } }, // #F05138
    .{ ".kt", Lang{ .name = "Kotlin", .color = "\x1b[38;2;169;123;255m" } }, // #A97BFF
    .{ ".cs", Lang{ .name = "C#", .color = "\x1b[38;2;23;134;0m" } }, // #178600
    .{ ".lua", Lang{ .name = "Lua", .color = "\x1b[38;2;0;0;128m" } }, // #000080
    .{ ".r", Lang{ .name = "R", .color = "\x1b[38;2;25;140;231m" } }, // #198CE7
    .{ ".scala", Lang{ .name = "Scala", .color = "\x1b[38;2;194;45;64m" } }, // #C22D40
    .{ ".dart", Lang{ .name = "Dart", .color = "\x1b[38;2;0;180;171m" } }, // #00B4AB
    .{ ".elm", Lang{ .name = "Elm", .color = "\x1b[38;2;96;181;204m" } }, // #60B5CC

    // Markup/Data
    .{ ".xml", Lang{ .name = "XML", .color = "\x1b[38;2;13;103;76m" } }, // #0D674C
    .{ ".yml", Lang{ .name = "YAML", .color = "\x1b[38;2;203;56;55m" } }, // #CB3837
    .{ ".yaml", Lang{ .name = "YAML", .color = "\x1b[38;2;203;56;55m" } }, // #CB3837
    .{ ".toml", Lang{ .name = "TOML", .color = "\x1b[38;2;156;66;33m" } }, // #9C4221
    .{ ".ini", Lang{ .name = "INI", .color = "\x1b[38;2;209;219;224m" } }, // #D1DBE0
    .{ ".sql", Lang{ .name = "SQL", .color = "\x1b[38;2;224;148;0m" } }, // #E09400
    .{ ".graphql", Lang{ .name = "GraphQL", .color = "\x1b[38;2;225;0;152m" } }, // #E10098

    // Config/Build
    .{ ".dockerfile", Lang{ .name = "Dockerfile", .color = "\x1b[38;2;56;77;84m" } }, // #384D54
    .{ ".makefile", Lang{ .name = "Makefile", .color = "\x1b[38;2;66;120;25m" } }, // #427819
    .{ ".cmake", Lang{ .name = "CMake", .color = "\x1b[38;2;218;52;52m" } }, // #DA3434
    .{ ".gradle", Lang{ .name = "Gradle", .color = "\x1b[38;2;2;48;58m" } }, // #02303A
});

const LangCount = struct {
    count: usize = 0,
    color: []const u8,
};

fn printLanguageStats(allocator: std.mem.Allocator, file_stats: *std.ArrayList(FileStats), io: std.Io) void {
    var lang_counts = std.StringHashMap(LangCount).init(allocator);
    defer lang_counts.deinit();

    for (file_stats.items) |fs| {
        const ext = std.fs.path.extension(fs.name);
        if (language_map.get(ext)) |lang| {
            if (lang_counts.getPtr(lang.name)) |lg| {
                lg.count += 1;
            } else {
                lang_counts.put(lang.name, .{ .color = lang.color, .count = 1 }) catch std.debug.panic("OOM", .{});
            }
        } else {
            if (lang_counts.getPtr("Others")) |lg| {
                lg.count += 1;
            } else {
                lang_counts.put("Others", .{ .color = ColorV1.ansiCode(.gray), .count = 1 }) catch std.debug.panic("OOM", .{});
            }
        }
    }

    // print result
    var it = lang_counts.iterator();

    const total_file_count = file_stats.items.len;

    print(io, "\n", .{});

    printColored(io, &.{.bold}, "Languages\n\n", .{});

    // print line block
    while (it.next()) |entry| {
        print(io, "{s}", .{entry.value_ptr.color});
        for (0..(entry.value_ptr.count * 100) / total_file_count) |_| {
            print(io, "█", .{});
        }
        print(io, "{s}", .{ColorV1.ansiCode(.reset)});
    }

    print(io, "\n", .{});

    it = lang_counts.iterator();
    // display language statistics
    while (it.next()) |entry| {
        const count_float: f64 = @floatFromInt(entry.value_ptr.count);
        const total_float: f64 = @floatFromInt(total_file_count);
        const percentage = (count_float * 100) / total_float;

        print(io, "{s}{s}{s} {s}{d:.2}%{s}   ", .{
            entry.value_ptr.color,
            entry.key_ptr.*,
            ColorV1.ansiCode(.reset),
            //
            ColorV1.ansiCode(.gray),
            percentage,
            ColorV1.ansiCode(.reset),
        });
    }
}
