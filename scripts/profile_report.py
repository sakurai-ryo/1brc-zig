"""samply のプロファイルを関数別・行別のテキスト表にする。

usage: profile_report.py <profile.json.gz> <binary>

samply の --unstable-presymbolicate はインライン展開を関数ごとに 1 か所分しか
出さないので、アドレスごとの解決は atos -i に任せる。
"""

import gzip
import json
import subprocess
import sys
from collections import Counter

# Zig の Mach-O リンカが置く __TEXT の先頭アドレス
TEXT_BASE = 0x100000000
TOP = 20

prof_path, binary = sys.argv[1], sys.argv[2]
exe = binary.rsplit("/", 1)[-1]
p = json.load(gzip.open(prof_path))
libs = [lib["name"] for lib in p["libs"]]

# サンプルごとに、葉から根へのフレーム列 [(lib, address), ...] を作る
samples = []
for t in p["threads"]:
    st, ft, fn, rt = t["stackTable"], t["frameTable"], t["funcTable"], t["resourceTable"]
    for s in t["samples"]["stack"]:
        chain = []
        while s is not None:
            f = st["frame"][s]
            res = fn["resource"][ft["func"][f]]
            lib = libs[rt["lib"][res]] if res is not None else "?"
            chain.append((lib, ft["address"][f]))
            s = st["prefix"][s]
        samples.append(chain)

addrs = sorted({a for chain in samples for lib, a in chain if lib == exe})
out = subprocess.run(
    ["atos", "-o", binary, "-l", hex(TEXT_BASE), "-i", *[hex(TEXT_BASE + a) for a in addrs]],
    capture_output=True, text=True, check=True,
).stdout

# atos -i は 1 アドレスにつきインライン展開の内側から順に複数行を出し、空行で区切る
resolved = {}
for addr, block in zip(addrs, out.strip("\n").split("\n\n")):
    frames = []
    for line in block.splitlines():
        func, _, rest = line.partition(" (in ")
        loc = rest.rsplit("(", 1)[-1].rstrip(")") if "(" in rest else "?"
        frames.append((func, loc))
    resolved[addr] = frames


def expand(chain):
    """葉から根への (関数名, 位置) 列にインライン展開を含めて変換する。"""
    for lib, a in chain:
        if lib == exe and a in resolved:
            yield from resolved[a]
        else:
            yield (lib, "?")


self_func, self_line, total_func = Counter(), Counter(), Counter()
for chain in samples:
    frames = list(expand(chain))
    if not frames:
        continue
    self_func[frames[0][0]] += 1
    self_line[f"{frames[0][1]}  {frames[0][0]}"] += 1
    for name in {f for f, _ in frames}:
        total_func[name] += 1

n = len(samples)
for title, c in [("self time by function", self_func),
                 ("self time by line", self_line),
                 ("total time by function", total_func)]:
    print(f"## {title} ({n} samples)")
    for key, v in c.most_common(TOP):
        print(f"{100 * v / n:6.1f}%  {key}")
    print()
