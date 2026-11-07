# Zig の SIMD の基本

Zig 0.17.1 で SIMD を書くための基本をまとめる。

コード例は、すべて `zig test` で動作を確かめている。

## `@Vector` 型

SIMD で扱う値は `@Vector(長さ, 要素の型)` で表す。

長さはコンパイル時に決まる値でなければならない。

要素の型には、整数、浮動小数点数、`bool`、ポインタを使える。

```zig
const a: @Vector(4, i32) = .{ 1, 2, 3, 4 };
const b: @Vector(4, i32) = @splat(10); // { 10, 10, 10, 10 }
```

`@splat` は、1 つの値をすべてのレーン（ベクトルの各要素）にコピーしたベクトルを作る。

結果の型は代入先から決まるので、式の途中で使うときは `@as(@Vector(16, u8), @splat(';'))` のように型を指定する。

## 演算はレーンごとに行われる

算術演算子とビット演算子は、レーンごとに適用される。

```zig
a + b // { 11, 12, 13, 14 }
```

比較演算子もレーンごとに適用され、結果は `bool` のベクトルになる。

1 つの `bool` にはならないので、`if` の条件にそのまま書くことはできない。

```zig
const v: @Vector(16, u8) = "Hamburg;12.0\nBul".*;
const m = v == @as(@Vector(16, u8), @splat(';'));
// m は @Vector(16, bool) で、レーン 7 だけが true
```

## 配列とスライスとの変換

ベクトルと、同じ長さ・同じ要素型の配列は、互いに代入できる。

```zig
const arr: [4]i32 = a;              // ベクトル -> 配列
const v: @Vector(16, u8) = bytes[0..16].*; // 配列 -> ベクトル
```

スライスから読むときは、`slice[i..][0..16]` で長さ 16 の配列へのポインタを作り、`.*` で配列として取り出してから代入する。

スライスの長さが足りないと、Debug ビルドでは境界チェックで失敗し、ReleaseFast では未定義動作になる。

そのため、読む前に残りが 16 バイト以上あることを確かめる必要がある。

各レーンは `v[2]` のように添字で読める。

## 結果を 1 つの値にまとめる（`@reduce`）

`@reduce(演算, ベクトル)` は、全レーンを 1 つの値にまとめる。

```zig
const a: @Vector(4, i32) = .{ 3, -1, 7, 2 };
@reduce(.Add, a) // 11
@reduce(.Max, a) // 7
```

演算には `.And`、`.Or`、`.Xor`、`.Min`、`.Max`、`.Add`、`.Mul` がある。

`bool` のベクトルに `.And` を使うと「全レーンが true か」、`.Or` を使うと「どれかが true か」を判定できる。

2 つのベクトルが一致するかは、`@reduce(.And, x == y)` で判定する。

## ビットマスクへの変換（`@bitCast`）

`bool` のベクトルは、`@bitCast` で同じビット数の整数に変換できる。

レーン 0 が最下位ビットになる。

```zig
const bits: u16 = @bitCast(m); // 0x0080
@ctz(bits)                      // 7（最初の true のレーン）
```

`@ctz`（下位から数えた 0 の数）や `@popCount`（1 の数）と組み合わせると、一致したレーンの位置や数が分かる。

ただし、命令の数は CPU によって違う。

x86 にはこの変換に当たる命令（`pmovmskb`）があるが、Apple Silicon の NEON にはなく、複数の命令に展開される。

## レーンごとの選択（`@select`）

`@select(要素の型, 条件, a, b)` は、レーンごとに、条件が true なら `a`、false なら `b` の値を選ぶ。

分岐を使わずに、一部のレーンだけを別の値に置き換えられる。

```zig
const keep = std.simd.iota(u8, 4) < @as(@Vector(4, u8), @splat(2)); // { true, true, false, false }
@select(i32, keep, a, @as(@Vector(4, i32), @splat(0)))              // { 3, -1, 0, 0 }
```

`std.simd.iota(T, n)` は、`{ 0, 1, ..., n - 1 }` のベクトルを作る。

レーン番号と比べれば、「先頭から k レーンだけ」のような条件を作れる。

## レーンの並べ替え（`@shuffle`）

`@shuffle(要素の型, a, b, マスク)` は、マスクで指定した順にレーンを並べ替えた新しいベクトルを作る。

マスクの値が 0 以上なら `a` のレーン、負なら `b` のレーン（`-1` が `b[0]`、`-2` が `b[1]`）を取る。

マスクはコンパイル時に決まる値でなければならない。

```zig
const a: @Vector(4, u8) = .{ 'a', 'b', 'c', 'd' };
@shuffle(u8, a, undefined, @Vector(4, i32){ 3, 2, 1, 0 }) // { 'd', 'c', 'b', 'a' }
```

## `std.simd` の主な関数

| 関数 | 内容 |
|---|---|
| `iota(T, n)` | `{ 0, 1, ..., n - 1 }` を作る |
| `suggestVectorLength(T)` | 実行する CPU で、要素型 `T` に適したベクトルの長さを返す |
| `firstTrue(v)`、`lastTrue(v)` | 最初、最後に true のレーンの番号を返す。なければ `null` |
| `countTrues(v)` | true のレーンの数を返す |
| `firstIndexOfValue(v, x)` | 値 `x` が最初に現れるレーンの番号を返す |
| `reverseOrder(v)` | レーンの順序を逆にする |
| `join(a, b)` | 2 つのベクトルをつなげる |

## ベクトルの長さの選び方

ベクトルの長さは、CPU の SIMD レジスタに合わせると、1 回の演算が 1 命令で済む。

| CPU | 命令セット | レジスタの幅 | `u8` のレーン数 |
|---|---|---|---|
| Apple Silicon などの arm64 | NEON | 128 ビット | 16 |
| x86_64 | SSE2 | 128 ビット | 16 |
| x86_64 | AVX2 | 256 ビット | 32 |
| x86_64 | AVX-512 | 512 ビット | 64 |

このマシン（Apple Silicon）では、`std.simd.suggestVectorLength(u8)` が 16 を返す。

レジスタより長いベクトルも書けるが、コンパイラが複数のレジスタに分けるので、命令の数はそのぶん増える。

## このリポジトリでの使い方

`src/main.zig` では、観測所名の `;` を次のように探している。

```zig
const chunk: Prefix = data[i..][0..16].*;                          // 16 バイトを読む
const mask: u16 = @bitCast(chunk == @as(Prefix, @splat(';')));     // ';' のレーンのビットを立てる
if (mask != 0) return i + @ctz(mask);                              // 最初の ';' の位置
```

名前より後ろのレーンを 0 で埋めるところでは、`iota` と `@select` を使っている。

```zig
const keep = std.simd.iota(u8, 16) < @as(Prefix, @splat(len));
return @select(u8, keep, chunk, @as(Prefix, @splat(0)));
```

ハッシュ表での名前の比較は、`@reduce(.And, e.prefix == prefix)` の 1 回のベクトル比較で済ませている。
