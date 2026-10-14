"""Repair pubspec.yaml after another PowerShell round trip.

Second time this has happened. `Get-Content -Raw` reads with the ANSI code page,
so the Chinese description came back as mojibake and was written out as UTF-8.
The encoding checker caught it immediately this time (private-use-area character
U+E57D), which is exactly why that check exists.

Python reads and writes UTF-8 correctly.

STOP USING POWERSHELL ON THIS FILE. Use the edit tool, which preserves encoding.
"""
import io
import sys

sys.stdout.reconfigure(encoding="utf-8")

PATH = "pubspec.yaml"
DESCRIPTION = "错题集：拍照 -> 切题 -> 还原干净题目 -> 挑题打印"

text = io.open(PATH, encoding="utf-8").read()
out = []
fixed = False
for line in text.splitlines(keepends=True):
    if line.startswith("description:"):
        out.append(f'description: "{DESCRIPTION}"\n')
        fixed = True
    else:
        out.append(line)

io.open(PATH, "w", encoding="utf-8", newline="\n").write("".join(out))

check = io.open(PATH, encoding="utf-8").read()
pua = sorted({c for c in check if 0xE000 <= ord(c) <= 0xF8FF})
print(f"  修复 description: {fixed}")
print(f"  description: {[l for l in check.splitlines() if l.startswith('description')]}")
print(f"  version    : {[l for l in check.splitlines() if l.startswith('version')]}")
print(f"  私用区字符 : {[hex(ord(c)) for c in pua] if pua else '无'}")
sys.exit(1 if pua or not fixed else 0)
