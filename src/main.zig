const std = @import("std");
const Io = std.Io;

// 気温は小数部が必ず 1 桁なので、0.1 度単位の整数で正確に持てる
const Stats = struct {
    min: i32 = std.math.maxInt(i32),
    max: i32 = std.math.minInt(i32),
    sum: i64 = 0,
    count: u64 = 0,
};

// 通常の hash map だと tombstone やリサイズの処理がボトルネックになる
// 今回はキーを削除しないので、tombstone もリサイズもない線形探索のリストにする
const Table = struct {
    // リサイズしないので、観測所の最大数 10,000 より十分大きく取る（負荷率 1/3 未満）
    const capacity = 1 << 15;
    const Entry = struct { name: []const u8, prefix: Prefix, stats: Stats };

    entries: []Entry,

    fn init(allocator: std.mem.Allocator) !Table {
        const entries = try allocator.alloc(Entry, capacity);
        // 観測所名は 1 文字以上なので、空の名前を未使用の印にできる
        @memset(entries, .{ .name = "", .prefix = @splat(0), .stats = .{} });
        return .{ .entries = entries };
    }

    // name は mmap した領域内を指し、その領域は main の最後まで有効なので、複製せずにキーにする
    fn get(self: *Table, name: []const u8, prefix: Prefix) *Stats {
        const prefix_words: [2]u64 = @bitCast(prefix);
        const hash = (prefix_words[0] ^ (prefix_words[1] *% 0x9E3779B97F4A7C15) ^ name.len) *% 0xBF58476D1CE4E5B9;
        // 掛け算の結果は上位ビットほどよく混ざるので、上位 15 ビットを使う
        var slot_index: usize = @intCast(hash >> (64 - 15));
        while (true) : (slot_index +%= 1) {
            const entry = &self.entries[slot_index & (capacity - 1)];
            if (entry.name.len == 0) {
                entry.* = .{ .name = name, .prefix = prefix, .stats = .{} };
                return &entry.stats;
            }
            if (entry.name.len == name.len and @reduce(.And, entry.prefix == prefix) and
                (name.len <= 16 or std.mem.eql(u8, entry.name[16..], name[16..]))) return &entry.stats;
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

    const file_size = try file.length(io);
    // 長さ 0 の mmap は失敗するので、空ファイルは読まずに済ませる
    var memory_map: ?Io.File.MemoryMap = if (file_size == 0) null else try file.createMemoryMap(io, .{
        .len = file_size,
        .protection = .{ .read = true },
        .populate = false,
    });
    defer if (memory_map) |*map| map.destroy(io);
    const file_contents: []const u8 = if (memory_map) |map| map.memory else "";

    var next_chunk_index: std.atomic.Value(usize) = .init(0);
    const thread_count = try std.Thread.getCpuCount();
    const workers = try arena.alloc(Worker, thread_count);
    const threads = try arena.alloc(std.Thread, thread_count);
    for (workers, threads) |*worker, *thread| {
        worker.* = .{ .file_contents = file_contents, .next_chunk_index = &next_chunk_index };
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
    }
    for (threads) |thread| thread.join();

    var merged_table: Table = try .init(arena);
    for (workers) |*worker| {
        if (worker.err) |err| return err;
        for (worker.table.entries) |*worker_entry| {
            if (worker_entry.name.len == 0) continue;
            const merged_stats = merged_table.get(worker_entry.name, worker_entry.prefix);
            merged_stats.min = @min(merged_stats.min, worker_entry.stats.min);
            merged_stats.max = @max(merged_stats.max, worker_entry.stats.max);
            merged_stats.sum += worker_entry.stats.sum;
            merged_stats.count += worker_entry.stats.count;
        }
    }

    var sorted_entries: std.ArrayList(*const Table.Entry) = .empty;
    for (merged_table.entries) |*entry| {
        if (entry.name.len > 0) try sorted_entries.append(arena, entry);
    }
    std.mem.sort(*const Table.Entry, sorted_entries.items, {}, nameLessThan);

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("{");
    for (sorted_entries.items, 0..) |entry, entry_index| {
        const stats = entry.stats;
        // baseline は f64 の合計を一度丸めてから 10 で割り、件数で割って丸める。
        // 丸めた合計は整数の合計と一致するので、それ以降を同じ順序で f64 で計算する
        const mean = roundToTenth(tenthsToFloat(stats.sum) / @as(f64, @floatFromInt(stats.count)));
        if (entry_index > 0) try stdout.writeAll(", ");
        try stdout.print("{s}={d:.1}/{d:.1}/{d:.1}", .{ entry.name, tenthsToFloat(stats.min), mean, tenthsToFloat(stats.max) });
    }
    try stdout.writeAll("}\n");
    try stdout.flush();
}

// offset 以降で最初の行頭の位置を返す
// offset がすでに行頭ならそのまま返す
fn nextLineStart(file_contents: []const u8, offset: usize) usize {
    if (offset == 0) return 0;
    const newline_index = std.mem.indexOfScalarPos(u8, file_contents, offset - 1, '\n') orelse return file_contents.len;
    return newline_index + 1;
}

// ファイルを chunk_size ごとの塊に分け、各スレッドが空き次第つぎの塊を取って処理する
// 均等に分けると、Apple Silicon では高性能コアのスレッドが先に終わって高効率コアを待つことになる
// 表とメモリはスレッドごとに持つので、塊の取得以外にスレッド間の同期は要らない
const Worker = struct {
    // 16 MiB
    const chunk_size = 16 << 20;

    file_contents: []const u8,
    next_chunk_index: *std.atomic.Value(usize),
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    table: Table = undefined,
    err: ?anyerror = null,

    fn run(worker: *Worker) void {
        worker.runInner() catch |err| {
            worker.err = err;
        };
    }

    fn runInner(worker: *Worker) !void {
        worker.table = try .init(worker.arena.allocator());
        const file_contents = worker.file_contents;
        while (true) {
            const chunk_index = worker.next_chunk_index.fetchAdd(1, .monotonic);
            if (chunk_index * chunk_size >= file_contents.len) break;
            // 塊の境界を次の行頭に合わせ、行頭が [chunk_begin, chunk_end) にある行を担当する
            const chunk_begin = nextLineStart(file_contents, chunk_index * chunk_size);
            const chunk_end = nextLineStart(file_contents, @min((chunk_index + 1) * chunk_size, file_contents.len));
            processLines(&worker.table, file_contents[chunk_begin..@max(chunk_begin, chunk_end)]);
        }
    }
};

fn processLines(table: *Table, lines: []const u8) void {
    var cursor: usize = 0;
    while (cursor < lines.len) {
        const name_start = cursor;
        const prefix = scanName(lines, &cursor);
        const name = lines[name_start..cursor];
        // ';' を飛ばす
        cursor += 1;
        const temperature = parseTemperature(lines, &cursor);

        const stats = table.get(name, prefix);
        stats.min = @min(stats.min, temperature);
        stats.max = @max(stats.max, temperature);
        stats.sum += temperature;
        stats.count += 1;
    }
}

// 観測所名の先頭 16 バイト（Apple Silicon の SIMD レジスタサイズに合わせる）
// 名前より後ろは 0 で埋める
// ';' を探すときに読んだバイト列を、ハッシュと比較にそのまま使い回すために持つ
const Prefix = @Vector(16, u8);

// lines[cursor..] の観測所名を読み、cursor を ';' の位置に進めて、名前の先頭 16 バイトを返す
fn scanName(lines: []const u8, cursor: *usize) Prefix {
    const name_start = cursor.*;
    if (name_start + 16 <= lines.len) {
        const window: Prefix = lines[name_start..][0..16].*;
        const semicolon_bits: u16 = @bitCast(window == @as(Prefix, @splat(';')));
        if (semicolon_bits != 0) {
            const name_len: u8 = @ctz(semicolon_bits);
            cursor.* = name_start + name_len;
            // window には ';' 以降（気温や次の行）も入っているので、名前の部分だけ残して 0 で埋める
            // 同じ観測所でも後ろに続く内容は行ごとに違い、そのままではハッシュと比較が一致しない
            // iota は { 0, 1, ..., 15 } で、name_len 未満のレーンだけ is_name_byte が true になる
            // 例: "Hamburg;12.0\nBul" (name_len = 7) -> "Hamburg" + 0 x 9
            const is_name_byte = std.simd.iota(u8, 16) < @as(Prefix, @splat(name_len));
            return @select(u8, is_name_byte, window, @as(Prefix, @splat(0)));
        }
        cursor.* = findSemicolon(lines, name_start + 16);
        return window;
    }

    // 担当範囲の末尾の 16 バイト未満は 1 バイトずつ読む
    cursor.* = findSemicolon(lines, name_start);
    var prefix: [16]u8 = @splat(0);
    const copy_len = @min(cursor.* - name_start, 16);
    @memcpy(prefix[0..copy_len], lines[name_start..][0..copy_len]);
    return prefix;
}

// 16 バイトずつまとめて ';' と比べ、最初に一致した位置を返す
fn findSemicolon(lines: []const u8, search_start: usize) usize {
    var window_start = search_start;
    while (window_start + 16 <= lines.len) : (window_start += 16) {
        const window: Prefix = lines[window_start..][0..16].*;
        // @splat(';') は 0x3B を 16 レーンに並べたベクトル
        // レーンごとに比べた結果を u16 にすると ';' の位置のビットが立つ（レーン 0 が最下位ビット）
        // `==` はレーンごとの比較
        // 例: "Hamburg;12.0\nBul" -> 0x0080
        //     @ctz で最初の ';' の位置 7 が分かる
        const semicolon_bits: u16 = @bitCast(window == @as(Prefix, @splat(';')));
        if (semicolon_bits != 0) return window_start + @ctz(semicolon_bits);
    }
    // ファイル末尾の 16 バイト未満は 1 バイトずつ探す
    var index = window_start;
    while (lines[index] != ';') index += 1;
    return index;
}

fn nameLessThan(_: void, lhs: *const Table.Entry, rhs: *const Table.Entry) bool {
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

// lines[cursor..] の "-12.3\n" を -123 として読み、cursor を次の行の先頭に進める
// 整数部が 1〜2 桁、小数部が 1 桁という形式を前提に、改行を探さずに読み進める
fn parseTemperature(lines: []const u8, cursor: *usize) i32 {
    var index = cursor.*;
    const is_negative = lines[index] == '-';
    if (is_negative) index += 1;
    // 1 桁目
    var tenths: i32 = asciiToDigit(lines[index]);
    index += 1;

    // 2 桁目（存在すれば）
    if (lines[index] != '.') {
        tenths = tenths * 10 + asciiToDigit(lines[index]);
        index += 1;
    }

    // 小数部の 1 桁目
    tenths = tenths * 10 + asciiToDigit(lines[index + 1]);

    // '.'、小数部、'\n' の 3 バイトを飛ばす
    cursor.* = index + 3;
    return if (is_negative) -tenths else tenths;
}

fn asciiToDigit(char: u8) u8 {
    return char - '0';
}

test "asciiToDigit" {
    const expect = std.testing.expect;
    try expect(asciiToDigit('0') == 0);
    try expect(asciiToDigit('1') == 1);
    try expect(asciiToDigit('9') == 9);
}

// 0.1 度単位の整数を、度単位の f64 に変換する
fn tenthsToFloat(tenths: anytype) f64 {
    return @as(f64, @floatFromInt(tenths)) / 10.0;
}

// Java の Math.round(value * 10.0) / 10.0 と同じ丸め
fn roundToTenth(value: f64) f64 {
    return @floor(value * 10.0 + 0.5) / 10.0;
}
