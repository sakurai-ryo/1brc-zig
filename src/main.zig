const std = @import("std");
const Io = std.Io;

const Stats = struct {
    min: f64,
    max: f64,
    sum: f64,
    count: u64,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    const path = if (args.len > 1) args[1] else "measurements.txt";

    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var read_buffer: [64 * 1024]u8 = undefined;
    var file_reader: Io.File.Reader = .init(file, io, &read_buffer);
    const reader = &file_reader.interface;

    var stations: std.StringHashMapUnmanaged(Stats) = .empty;

    while (try reader.takeDelimiter('\n')) |line| {
        const sep = std.mem.lastIndexOfScalar(u8, line, ';').?;
        const value = try std.fmt.parseFloat(f64, line[sep + 1 ..]);

        const entry = try stations.getOrPut(arena, line[0..sep]);
        if (entry.found_existing) {
            const s = entry.value_ptr;
            s.min = @min(s.min, value);
            s.max = @max(s.max, value);
            s.sum += value;
            s.count += 1;
        } else {
            // line は次の読み込みで上書きされるバッファを指しているので、キーを複製する
            entry.key_ptr.* = try arena.dupe(u8, line[0..sep]);
            entry.value_ptr.* = .{
                .min = value,
                .max = value,
                .sum = value,
                .count = 1,
            };
        }
    }

    const names = try arena.alloc([]const u8, stations.count());
    var it = stations.keyIterator();
    var i: usize = 0;
    while (it.next()) |key| : (i += 1) names[i] = key.*;
    std.mem.sort([]const u8, names, {}, lessThan);

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.writeAll("{");
    for (names, 0..) |name, n| {
        const s = stations.get(name).?;
        // baseline と同じく、合計を一度丸めてから件数で割る
        const mean = round(round(s.sum) / @as(f64, @floatFromInt(s.count)));
        if (n > 0) try out.writeAll(", ");
        try out.print("{s}={d:.1}/{d:.1}/{d:.1}", .{ name, round(s.min), mean, round(s.max) });
    }
    try out.writeAll("}\n");
    try out.flush();
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn round(x: f64) f64 {
    return @floor(x * 10.0 + 0.5) / 10.0;
}
