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

    fn init(gpa: std.mem.Allocator) !Table {
        const entries = try gpa.alloc(Entry, capacity);
        // 観測所名は 1 文字以上なので、空の名前を未使用の印にできる
        @memset(entries, .{ .name = "", .prefix = @splat(0), .stats = .{} });
        return .{ .entries = entries };
    }

    fn get(self: *Table, gpa: std.mem.Allocator, name: []const u8, prefix: Prefix) !*Stats {
        const words: [2]u64 = @bitCast(prefix);
        const h = (words[0] ^ (words[1] *% 0x9E3779B97F4A7C15) ^ name.len) *% 0xBF58476D1CE4E5B9;
        // 掛け算の結果は上位ビットほどよく混ざるので、上位 15 ビットを使う
        var i: usize = @intCast(h >> (64 - 15));
        while (true) : (i +%= 1) {
            const e = &self.entries[i & (capacity - 1)];
            if (e.name.len == 0) {
                // name は次の読み込みで上書きされるバッファを指しているので複製する
                e.* = .{ .name = try gpa.dupe(u8, name), .prefix = prefix, .stats = .{} };
                return &e.stats;
            }
            if (e.name.len == name.len and @reduce(.And, e.prefix == prefix) and
                (name.len <= 16 or std.mem.eql(u8, e.name[16..], name[16..]))) return &e.stats;
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

    var table: Table = try .init(arena);

    // ファイル全体を mmap すると、ページキャッシュに収まらないときに 16KB ごとの同期読み込みになって遅い
    // なので、read() で大きめに読めばカーネルの先読みが効く
    const buf = try arena.alloc(u8, 1 << 20);
    var carry: usize = 0;
    while (true) {
        const n = file.readStreaming(io, &.{buf[carry..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const filled = carry + n;
        // 最後の改行までを処理し、途中で切れた行は次の読み込みの先頭に繰り越す
        const end = if (std.mem.lastIndexOfScalar(u8, buf[0..filled], '\n')) |i| i + 1 else 0;
        try process(&table, arena, buf[0..end]);
        std.mem.copyForwards(u8, buf, buf[end..filled]);
        carry = filled - end;
    }
    // 末尾に改行のないファイルの最終行
    try process(&table, arena, buf[0..carry]);

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
        // baseline は f64 の合計を一度丸めてから 10 で割り、件数で割って丸める。
        // 丸めた合計は整数の合計と一致するので、それ以降を同じ順序で f64 で計算する
        const mean = round(tenths(s.sum) / @as(f64, @floatFromInt(s.count)));
        if (n > 0) try out.writeAll(", ");
        try out.print("{s}={d:.1}/{d:.1}/{d:.1}", .{ e.name, tenths(s.min), mean, tenths(s.max) });
    }
    try out.writeAll("}\n");
    try out.flush();
}

fn process(table: *Table, gpa: std.mem.Allocator, data: []const u8) !void {
    var pos: usize = 0;
    while (pos < data.len) {
        const start = pos;
        const prefix = scanName(data, &pos);
        const name = data[start..pos];
        pos += 1;
        const value = parseTemp(data, &pos);

        const s = try table.get(gpa, name, prefix);
        s.min = @min(s.min, value);
        s.max = @max(s.max, value);
        s.sum += value;
        s.count += 1;
    }
}

// 観測所名の先頭 16 バイト（Apple Silicon の SIMD レジスタサイズに合わせる）
// 名前より後ろは 0 で埋める
// ';' を探すときに読んだバイト列を、ハッシュと比較にそのまま使い回すために持つ
const Prefix = @Vector(16, u8);

// data[pos..] の観測所名を読み、pos を ';' の位置に進めて、名前の先頭 16 バイトを返す
fn scanName(data: []const u8, pos: *usize) Prefix {
    const start = pos.*;
    if (start + 16 <= data.len) {
        const chunk: Prefix = data[start..][0..16].*;
        const mask: u16 = @bitCast(chunk == @as(Prefix, @splat(';')));
        if (mask != 0) {
            const len: u8 = @ctz(mask);
            pos.* = start + len;
            // chunk には ';' 以降（気温や次の行）も入っているので、名前の部分だけ残して 0 で埋める
            // 同じ観測所でも後ろに続く内容は行ごとに違い、そのままではハッシュと比較が一致しない
            // iota は { 0, 1, ..., 15 } で、len 未満のレーンだけ keep が true になる
            // 例: "Hamburg;12.0\nBul" (len = 7) -> "Hamburg" + 0 x 9
            const keep = std.simd.iota(u8, 16) < @as(Prefix, @splat(len));
            return @select(u8, keep, chunk, @as(Prefix, @splat(0)));
        }
        pos.* = findSemicolon(data, start + 16);
        return chunk;
    }

    // バッファ末尾の 16 バイト未満は 1 バイトずつ読む
    pos.* = findSemicolon(data, start);
    var prefix: [16]u8 = @splat(0);
    const n = @min(pos.* - start, 16);
    @memcpy(prefix[0..n], data[start..][0..n]);
    return prefix;
}

// 16 バイトずつまとめて ';' と比べ、最初に一致した位置を返す
fn findSemicolon(data: []const u8, start: usize) usize {
    var i = start;
    while (i + 16 <= data.len) : (i += 16) {
        const chunk: Prefix = data[i..][0..16].*;
        // @splat(';') は 0x3B を 16 レーンに並べたベクトル
        // レーンごとに比べた結果を u16 にすると ';' の位置のビットが立つ（レーン 0 が最下位ビット）
        // `==` はレーンごとの比較
        // 例: "Hamburg;12.0\nBul" -> 0x0080
        //     @ctz で最初の ';' の位置 7 が分かる
        const mask: u16 = @bitCast(chunk == @as(Prefix, @splat(';')));
        if (mask != 0) return i + @ctz(mask);
    }
    // ファイル末尾の 16 バイト未満は 1 バイトずつ探す
    while (data[i] != ';') i += 1;
    return i;
}

fn lessThan(_: void, a: *const Table.Entry, b: *const Table.Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

// data[pos..] の "-12.3\n" を -123 として読み、pos を次の行の先頭に進める
// 整数部が 1〜2 桁、小数部が 1 桁という形式を前提に、改行を探さずに読み進める
fn parseTemp(data: []const u8, pos: *usize) i32 {
    var i = pos.*;
    const neg = data[i] == '-';
    if (neg) i += 1;
    // 1 桁目
    var v: i32 = asciiToDigit(data[i]);
    i += 1;

    // 2 桁目（存在すれば）
    if (data[i] != '.') {
        v = v * 10 + asciiToDigit(data[i]);
        i += 1;
    }

    // 小数部の 1 桁目
    v = v * 10 + asciiToDigit(data[i + 1]);

    // '.'、小数部、'\n' の 3 バイトを飛ばす
    pos.* = i + 3;
    return if (neg) -v else v;
}

fn asciiToDigit(c: u8) u8 {
    return c - '0';
}

test "asciiToDigit" {
    const expect = std.testing.expect;
    try expect(asciiToDigit('0') == 0);
    try expect(asciiToDigit('1') == 1);
    try expect(asciiToDigit('9') == 9);
}

fn tenths(v: anytype) f64 {
    return @as(f64, @floatFromInt(v)) / 10.0;
}

fn round(x: f64) f64 {
    return @floor(x * 10.0 + 0.5) / 10.0;
}
