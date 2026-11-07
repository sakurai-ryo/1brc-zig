# 1BRC 1 位の実装の解説

対象は [CalculateAverage_thomaswue.java](https://github.com/gunnarmorling/1brc/blob/main/src/main/java/dev/morling/onebrc/CalculateAverage_thomaswue.java)（`1brc/src/main/java/dev/morling/onebrc/` にもある）である。

この実装は、評価環境（AMD EPYC 7502P の 8 コア）で 10 億行を 1.535 秒で処理し、本家のランキングで 1 位になった。

Thomas Wuerthinger が書き、Quan Anh Mai、Alfonso² Peterssen らの工夫を取り込んでいる。

Java で書かれているが、GraalVM の native image としてビルドし、`sun.misc.Unsafe` でメモリを直接読む。

境界チェックのない生のメモリアクセスを使うので、書き方は C に近い。

## 全体の流れ

1. 親プロセスが自分自身を子プロセスとして起動し、子の標準出力を中継する。
2. 子プロセスがファイル全体を mmap し、コア数だけスレッドを立てる。
3. 各スレッドは、2MB の塊（segment）をアトミックなカウンタで取り合う。
4. 各スレッドは 1 つの塊を 3 つに分け、3 つのカーソルを 1 つのループで交互に進める。
5. 1 行ごとに、観測所名でハッシュ表を引き、気温をパースして集計値を更新する。
6. 全スレッドの結果を `TreeMap` にまとめ、名前順に出力する。

## 子プロセスと計測の範囲

`main` は、引数に `--worker` がなければ `spawnWorker` を呼び、同じコマンドに `--worker` を付けて子プロセスを起動する。

親は、子の標準出力を自分の標準出力に流すだけである。

子は結果を出力すると、`System.out.close()` で出力を閉じる。

親はそこで終了するので、計測もそこで止まる。

子はその後で、約 14GB の mmap の解除やプロセスの後片付けをするが、その時間は計測に入らない。

## ファイル全体の mmap

```java
final long fileStart = fileChannel.map(FileChannel.MapMode.READ_ONLY, 0, fileSize, java.lang.foreign.Arena.global()).address();
```

子プロセスはファイル全体を 1 つの領域として mmap し、その先頭アドレスを `long` で持つ。

以降は、すべて `UNSAFE.getLong(address)` で 8 バイトずつ読む。

名前を表に登録するときも、文字列を複製せず、mmap した領域内のアドレス（`nameAddress`）だけを保存する。

ファイル全体が最後までマップされているので、このアドレスは処理の途中で無効にならない。

評価環境ではファイルを RAM ディスクに置くので、mmap した領域を読んでもディスクの読み込みを待つことはない。

## 2MB の塊の取り合い

```java
long current = counter.addAndGet(SEGMENT_SIZE) - SEGMENT_SIZE;
if (current >= fileEnd) {
    return;
}
```

各スレッドは、共有の `AtomicLong` を 2MB（`SEGMENT_SIZE = 1 << 21`）進め、進める前の値を自分の塊の先頭にする。

塊の終わりは、`nextNewLine` で次の改行に合わせる。

塊の先頭も、ファイルの先頭でなければ次の改行の直後に合わせる。

ファイルをスレッド数で均等に分けるより、小さな塊を取り合うほうが速い。

均等に分けると、いちばん遅いスレッドが終わるまで、ほかのスレッドは待つしかない。

小さな塊を取り合えば、速いスレッドがそのぶん多くの塊を処理するので、全スレッドがほぼ同時に終わる。

コメントによれば、この効果は Artsiom Korzun が示した。

## 1 スレッドでの 3 行の同時処理

`parseLoop` は塊を 3 つに分け、それぞれにカーソル（`Scanner`）を置く。

```java
long word1 = scanner1.getLong();
long word2 = scanner2.getLong();
long word3 = scanner3.getLong();
long delimiterMask1 = findDelimiter(word1);
long delimiterMask2 = findDelimiter(word2);
long delimiterMask3 = findDelimiter(word3);
...
Result existingResult1 = findResult(word1, delimiterMask1, ...);
Result existingResult2 = findResult(word2, delimiterMask2, ...);
Result existingResult3 = findResult(word3, delimiterMask3, ...);
long number1 = scanNumber(scanner1);
long number2 = scanNumber(scanner2);
long number3 = scanNumber(scanner3);
record(existingResult1, number1);
record(existingResult2, number2);
record(existingResult3, number3);
```

1 行の処理は、名前の読み込み、`;` の探索、ハッシュ計算、表の参照、気温のパース、集計値の更新が、前の結果に依存して順につながっている。

1 行ずつ処理すると、メモリの読み込みや掛け算の結果が出るまで、次の命令を実行できない時間ができる。

現代の CPU は、互いに依存しない命令を同時に実行できる（命令レベル並列性）。

互いに無関係な 3 行の命令を交互に並べると、ある行の結果を待つあいだに、CPU は別の行の命令を実行できる。

3 つのカーソルのどれかが範囲の終わりに達したら、交互のループを抜け、残りの行をカーソルごとに 1 行ずつ処理する。

## SWAR による `;` と改行の探索

`findDelimiter` は、8 バイトを 1 つの `long` として扱い、ビット演算だけで `;` の位置を求める。

このように、SIMD 命令を使わずに汎用レジスタの中で複数バイトを同時に処理する手法を、SWAR（SIMD Within A Register）と呼ぶ。

```java
private static long findDelimiter(long word) {
    long input = word ^ 0x3B3B3B3B3B3B3B3BL;
    return (input - 0x0101010101010101L) & ~input & 0x8080808080808080L;
}
```

1. `word ^ 0x3B3B...` で、`;`（`0x3B`）のバイトだけが `0x00` になる。
2. `(input - 0x0101...) & ~input & 0x8080...` で、`0x00` のバイトの最上位ビットだけを立てる。
   これは、0 のバイトを探すときによく使われる技法である。
3. 結果の末尾の 0 の数（`numberOfTrailingZeros`）を 8 で割ると、`;` が何バイト目にあるかが分かる。

`nextNewLine` も、同じ技法で `0x0A`（改行）を探す。

## 観測所名の検索（`findResult`）

### 15 バイト以下の名前

名前の先頭から 2 ワード（16 バイト）を読み、両方で `;` を探す。

名前の長さにかかわらず、常に 2 ワードを読む。

```java
int letterCount1 = Long.numberOfTrailingZeros(delimiterMask) >>> 3;  // 1〜8
int letterCount2 = Long.numberOfTrailingZeros(delimiterMask2) >>> 3; // 0〜8
long mask = MASK2[letterCount1];
word = word & MASK1[letterCount1];
word2 = mask & word2 & MASK1[letterCount2];
hash = word ^ word2;
```

- `MASK1[n]` は下位 n バイトを残すマスクで、名前より後ろ（`;` 以降）を 0 にする。
- `MASK2[n]` は、`;` が 1 ワード目に見つからなかったとき（n = 8）だけ全ビットが 1 になる。
  名前が 8 バイト以下なら、このマスクで 2 ワード目を丸ごと 0 にする。

この実装は、シフトの代わりにルックアップ表のマスクを使い、名前の長さによる分岐をなくしている。

名前が 8 バイト以下か 9 バイト以上かは行ごとにばらばらなので、分岐にすると予測が外れやすい。

コメントによれば、仕事が少し増えても分岐予測の失敗を避けるほうが速いことを、Jaromir Hamala が示した。

ハッシュは、2 ワードの XOR だけで作る。

表の該当位置にあるエントリの 2 ワード（`firstNameWord`、`secondNameWord`）が一致すれば、その時点で目的のエントリが見つかる。

名前の比較は、整数の比較 2 回で済む。

### 16 バイト以上の名前とハッシュの衝突

16 バイト以内に `;` がなければ、8 バイトずつ読み進め、各ワードをハッシュに XOR していく。

表の探索では、名前を 8 バイトずつ比べる。

比べる長さは名前の長さ + 1 で、`;` まで含める。

こうすると、ある名前が別の名前の先頭部分と同じ場合（`Ab` と `Abc` など）も区別できる。

一致しなければ、31 個先のエントリへ進む。

### ハッシュ表

```java
private static int hashToIndex(long hash, Result[] results) {
    long hashAsInt = hash ^ (hash >>> 33) ^ (hash >>> 15);
    return (int) (hashAsInt & (results.length - 1));
}
```

表の大きさは 131,072（`1 << 17`）である。

観測所は最大 10,000 個なので、表が埋まる割合は 8% 未満にとどまる。

エントリ（`Result`）は次の値だけを持つ。

| フィールド | 型 | 内容 |
|---|---|---|
| `firstNameWord`、`secondNameWord` | `long` | 名前の先頭 16 バイト（15 バイト以下の名前の比較に使う） |
| `min`、`max` | `short` | 0.1 度単位の最低・最高気温 |
| `count` | `int` | 件数 |
| `sum` | `long` | 0.1 度単位の合計 |
| `nameAddress` | `long` | mmap した領域での名前の位置 |

## 分岐のない気温のパース

`scanNumber` は `;` の直後から 8 バイトを読み、`convertIntoNumber`（Quan Anh Mai による）で 0.1 度単位の整数にする。

```java
long numberWord = scanPtr.getLongAt(scanPtr.pos() + 1);
int decimalSepPos = Long.numberOfTrailingZeros(~numberWord & 0x10101000L);
```

気温は行ごとにランダムなので、「負かどうか」「整数部が 1 桁か 2 桁か」で分岐すると、予測が頻繁に外れる。

この方法は、小数点の位置、符号、桁の合成をすべてビット演算と掛け算で処理し、分岐を 1 つも使わない。

### 小数点の位置

`'0'`〜`'9'`（`0x30`〜`0x39`）はビット 4（`0x10`）が 1 で、`'.'`（`0x2E`）と `'-'`（`0x2D`）は 0 である。

`.` は 1〜3 バイト目のどこかにあるので、各バイトのビット 4 を反転して `0x10101000` で取り出すと、`.` のバイトだけが 1 になる。

その末尾の 0 の数が、`.` の位置を表す（1 バイト目なら 12、2 バイト目なら 20、3 バイト目なら 28）。

### 符号と桁の合成

```java
int shift = 28 - decimalSepPos;
long signed = (~numberWord << 59) >> 63;         // 負なら -1、正なら 0
long designMask = ~(signed & 0xFF);              // 負なら先頭の '-' を消す
long digits = ((numberWord & designMask) << shift) & 0x0F000F0F00L;
long absValue = ((digits * 0x640a0001) >>> 32) & 0x3FF;
return (absValue ^ signed) - signed;
```

- **符号**: 先頭バイトのビット 4 を反転して最上位まで移し、算術シフトで戻す。
  `-` はビット 4 が 0 なので `-1` になり、数字なら `0` になる。
- **桁の整列**: `.` の位置に合わせてシフトし、百の位、十の位、一の位を、それぞれ決まったバイトに置く。
  `& 0x0F000F0F00` で各バイトの下位 4 ビットだけを残すと、ASCII の文字が数値に変わる。
- **合成**: `0x640a0001` は `100 × 2^24 + 10 × 2^16 + 1` である。
  1 回の掛け算で、百の位 × 100 + 十の位 × 10 + 一の位が、ビット 32 から始まる位置に集まる。
- **符号の適用**: `signed` が `-1` なら、`(x ^ -1) - (-1)` は `-x` になる。

`"12.3"` では、`.` が 2 バイト目にあるので、`decimalSepPos` は 20、`shift` は 8 になる。

シフト後の桁は百の位が 1、十の位が 2、一の位が 3 で、掛け算の結果は `123` になる。

`"-1.2"` では、`designMask` で `-` を消すと百の位が 0 になり、`12` に符号を付けた `-12` になる。

### 改行を探さない次の行への移動

```java
scanPtr.add((decimalSepPos >>> 3) + 4);
```

`.` の位置が分かれば、気温の残りは小数部 1 桁と改行だけである。

そこで、`;`、`.` の手前までの文字、`.`、小数部、改行の分だけカーソルを進め、次の行の先頭に移る。

改行を探す処理は要らない。

## 集計と出力

`record` は、`min`、`max`、`sum`、`count` を更新するだけである。

各スレッドは、表に新しく登録したエントリを `List` にも入れておく。

全スレッドが終わったら、各 `List` のエントリから名前を UTF-8 の文字列に戻し、`TreeMap` で名前ごとにまとめて出力する。

文字列を作るのは、この最後の段階だけである。

## 3 つの設計方針

ここまでの工夫は、次の 3 つの方針に分けられる。

- **分岐をなくす**: 名前の長さと、気温の符号と桁数を、マスクと算術で処理する。
  入力がランダムなので、分岐予測が外れるたびに失う時間を避けられる。
- **待ち時間を別の行で埋める**: 1 スレッドで 3 行を交互に処理し、1 行の依存の連鎖で生じる待ちのあいだに、別の行の命令を実行する。
- **同じバイトを何度も読まない**: `;` を探すために読んだ 2 ワードを、そのままハッシュと名前の比較に使う。
  気温も 1 回の 8 バイトの読み込みで処理し、改行は探さない。
