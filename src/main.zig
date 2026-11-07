const std = @import("std");
const Io = std.Io;

const Stats = struct {
    min: f64 = std.math.inf(f64),
    max: f64 = -std.math.inf(f64),
    sum: f64 = 0,
    count: u64 = 0,
};

// 通常の hash map だと tombstone やリサイズの処理がボトルネックになる
// 今回はキーを削除しないので、tombstone もリサイズもない線形探索のリストにする
const Table = struct {
    // リサイズしないので、観測所の最大数 10,000 より十分大きく取る（負荷率 1/3 未満）
    const capacity = 1 << 15;
    const Entry = struct { name: []const u8, stats: Stats };

    entries: []Entry,

    fn init(gpa: std.mem.Allocator) !Table {
        const entries = try gpa.alloc(Entry, capacity);
        // 観測所名は 1 文字以上なので、空の名前を未使用の印にできる
        @memset(entries, .{ .name = "", .stats = .{} });
        return .{ .entries = entries };
    }

    fn get(self: *Table, gpa: std.mem.Allocator, name: []const u8) !*Stats {
        var i: usize = @truncate(std.hash.Wyhash.hash(0, name));
        while (true) : (i +%= 1) {
            // 下位 15 ビットだけを使ってインデックスを計算する
            const e = &self.entries[i & (capacity - 1)];
            if (e.name.len == 0) {
                // name は次の読み込みで上書きされるバッファを指しているので複製する
                e.name = try gpa.dupe(u8, name);
                return &e.stats;
            }
            if (std.mem.eql(u8, e.name, name)) return &e.stats;
        }
    }
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

    var table: Table = try .init(arena);

    while (try reader.takeDelimiter('\n')) |line| {
        const sep = std.mem.lastIndexOfScalar(u8, line, ';').?;
        const value = try std.fmt.parseFloat(f64, line[sep + 1 ..]);

        const s = try table.get(arena, line[0..sep]);
        s.min = @min(s.min, value);
        s.max = @max(s.max, value);
        s.sum += value;
        s.count += 1;
    }

    var used: std.ArrayList(*const Table.Entry) = .empty;
    for (table.entries) |*e| {
        if (e.name.len > 0) try used.append(arena, e);
    }
    std.mem.sort(*const Table.Entry, used.items, {}, lessThan);

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.writeAll("{");
    for (used.items, 0..) |e, n| {
        const s = e.stats;
        // baseline と同じく、合計を一度丸めてから件数で割る
        const mean = round(round(s.sum) / @as(f64, @floatFromInt(s.count)));
        if (n > 0) try out.writeAll(", ");
        try out.print("{s}={d:.1}/{d:.1}/{d:.1}", .{ e.name, round(s.min), mean, round(s.max) });
    }
    try out.writeAll("}\n");
    try out.flush();
}

fn lessThan(_: void, a: *const Table.Entry, b: *const Table.Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn round(x: f64) f64 {
    return @floor(x * 10.0 + 0.5) / 10.0;
}
