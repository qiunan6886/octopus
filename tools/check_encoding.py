"""Detect PowerShell re-encoding corruption properly.

The old check looked for a blacklist of characters (euro sign, degree sign, ...).
That misses the common case: UTF-8 Chinese read as GBK and written back as UTF-8
produces *valid* CJK characters, just the wrong ones. `图片在控件里` becomes
`鍥剧墖鍦ㄦ帶浠堕噷`, which the blacklist happily accepts.

The reliable test is a round trip: mojibake is text whose GBK bytes happen to be
valid UTF-8 that decodes back to real Chinese. Genuine Chinese does not survive
that path, so a successful round trip is strong evidence of corruption.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEXT_EXT = {".md", ".html", ".py", ".txt", ".yaml", ".yml", ".json", ".xml", ".dart", ".kt"}
SKIP_DIRS = {"build", ".dart_tool", ".git", ".gradle", "ephemeral"}

# Flipping these characters produces text that still looks like Chinese.
GARBAGE = set("鍥剧墖鍦ㄦ帶浠堕噷瀹為檯鍗犳嵁鐨勭煩褰紙浼氱暀杈癸級锛屾垜浣犱粬鐨勪簡鏄湪鍜屼笉浜嗘湁涓婁笅澶т腑灏忚繖閭ｄ釜")


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
    if recovered == text:
        return None
    return recovered


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
        problems.append((path, f"INVALID UTF-8: {exc}"))
        continue

    checked += 1
    hits = []

    # 1. 逐行做往返检测，能定位到行
    for lineno, line in enumerate(text.splitlines(), 1):
        if cjk_ratio(line) < 0.15:
            continue
        recovered = round_trip_recoverable(line)
        if recovered and cjk_ratio(recovered) > 0.5:
            hits.append((lineno, line.strip()[:60], recovered.strip()[:60]))
            if len(hits) >= 3:
                break

    # 2. 老的黑名单仍然保留，抓另一类损坏
    bad = sorted({ord(c) for c in text} & {0x20AC, 0x2103, 0x2122, 0x2039, 0x203A, 0x201A})
    if bad:
        hits.append((-1, f"字符 {[hex(b) for b in bad]}", ""))

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
