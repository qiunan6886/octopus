"""Detect PowerShell re-encoding corruption properly.

The first version looked for a blacklist of characters (euro sign, degree sign).
That misses the common case: UTF-8 Chinese read as GBK and written back as UTF-8
produces *valid* CJK characters, just the wrong ones. `图片在控件里` becomes
`鍥剧墖鍦ㄦ帶浠堕噷`, which the blacklist happily accepts.

A second version added a GBK round trip. That catches the simple case but not
this one, which is what actually bit us twice: the same round trip applied to a
file whose bytes do not happen to survive re-encoding produces **private use
area** characters (U+E000..U+F8FF). `pubspec.yaml` ended up with U+E162 and
friends and the YAML parser rejected it. PUA characters never appear in source
that a person wrote, so their presence is conclusive on its own.

So both signals are checked: PUA characters, and the GBK round trip.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEXT_EXT = {
    ".md",
    ".html",
    ".py",
    ".txt",
    ".yaml",
    ".yml",
    ".json",
    ".xml",
    ".dart",
    ".kt",
    ".kts",
    ".gradle",
    ".pro",
}
SKIP_DIRS = {"build", ".dart_tool", ".git", ".gradle", "ephemeral"}


def cjk_ratio(text):
    if not text:
        return 0.0
    cjk = sum(1 for c in text if "\u4e00" <= c <= "\u9fff")
    return cjk / len(text)


def round_trip_recoverable(text):
    """Return the recovered text if `text` looks like GBK-mojibake, else None."""
    try:
        recovered = text.encode("gbk").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return None
    return None if recovered == text else recovered


problems = []
checked = 0

for path in sorted(ROOT.rglob("*")):
    if not path.is_file():
        continue
    if SKIP_DIRS & set(path.relative_to(ROOT).parts):
        continue
    if path.suffix.lower() not in TEXT_EXT:
        continue

    raw = path.read_bytes()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        problems.append((path, [(-1, f"不是合法 UTF-8: {exc}", "")]))
        continue

    checked += 1
    hits = []

    # 1. 私用区字符：人手写出来的源码里不会有，出现了就是损坏。
    pua = sorted({ord(c) for c in text if 0xE000 <= ord(c) <= 0xF8FF})
    if pua:
        lines = [
            i
            for i, line in enumerate(text.splitlines(), 1)
            if any(0xE000 <= ord(c) <= 0xF8FF for c in line)
        ]
        hits.append(
            (-1, f"私用区字符 {[hex(c) for c in pua][:6]}（第 {lines[:5]} 行）", "")
        )

    # 2. 黑名单：另一类损坏会留下这些符号。
    bad = sorted(
        {ord(c) for c in text} & {0x20AC, 0x2103, 0x2122, 0x2039, 0x203A, 0x201A}
    )
    if bad:
        hits.append((-1, f"可疑符号 {[hex(b) for b in bad]}", ""))

    # 3. GBK 往返：逐行做，能定位到行。
    for lineno, line in enumerate(text.splitlines(), 1):
        if cjk_ratio(line) < 0.15:
            continue
        recovered = round_trip_recoverable(line)
        if recovered and cjk_ratio(recovered) > 0.5:
            hits.append((lineno, line.strip()[:60], recovered.strip()[:60]))
            if len(hits) >= 4:
                break

    if hits:
        problems.append((path, hits))

print(f"  扫描 {checked} 个文本文件")
if not problems:
    print("  没有发现编码损坏")
    sys.exit(0)

print(f"  发现 {len(problems)} 个文件有问题：")
for path, hits in problems:
    print(f"    {path.relative_to(ROOT)}")
    for lineno, got, should_be in hits:
        if lineno == -1:
            print(f"        {got}")
        else:
            print(f"        第 {lineno} 行: {got}")
            print(f"            应为: {should_be}")
sys.exit(1)
