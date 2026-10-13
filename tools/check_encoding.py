"""Scan the project for the PowerShell re-encoding signature.

`Get-Content` under Windows PowerShell reads with the ANSI code page, and writing
the result back as UTF-8 turns every Chinese character into mojibake. The tell is
characters that cannot appear in these files: U+20AC (euro), U+2103 (degree C),
and the halfwidth-katakana block.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEXT_EXT = {".md", ".html", ".py", ".txt", ".yaml", ".yml", ".json", ".xml"}
SUSPECT = {0x20AC, 0x2103, 0x2122, 0x2039, 0x203A, 0x201A, 0x201E}

problems = []
checked = 0
for path in sorted(ROOT.rglob("*")):
    if not path.is_file() or ".git" in path.parts:
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
    hits = sorted({ord(c) for c in text} & SUSPECT)
    # Halfwidth katakana is never legitimate here.
    katakana = sorted({ord(c) for c in text if 0xFF61 <= ord(c) <= 0xFF9F})
    if hits or katakana:
        problems.append((path, f"suspect chars: {[hex(h) for h in hits + katakana][:8]}"))

print(f"  scanned {checked} text files")
if problems:
    print("  PROBLEMS:")
    for path, why in problems:
        print(f"    {path.relative_to(ROOT)}  ->  {why}")
else:
    print("  no re-encoding signature found")
    sys.exit(0)
sys.exit(1)
