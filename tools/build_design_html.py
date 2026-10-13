"""Render DESIGN.md to a single self-contained HTML file.

No external CSS, fonts or scripts: the file has to open correctly from a phone
with no network. Written by hand rather than with a markdown library because the
runtime ships none, and because the styling is the point here.
"""
import html
import re
import sys
from pathlib import Path

SRC = Path(sys.argv[1])
OUT = Path(sys.argv[2])

CSS = """
:root {
  --bg: #f6f7f9;
  --card: #ffffff;
  --ink: #1c1f23;
  --ink-soft: #5a636e;
  --line: #e3e6ea;
  --accent: #2f6fed;
  --accent-soft: #eef3fe;
  --warn: #b45309;
  --warn-soft: #fff7ed;
  --code-bg: #f2f4f7;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #16181c; --card: #1e2126; --ink: #e8eaed; --ink-soft: #a5adb8;
    --line: #2e333a; --accent: #7aa7ff; --accent-soft: #1d2735;
    --warn: #fbbf24; --warn-soft: #2a2317; --code-bg: #262a30;
  }
}
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body {
  margin: 0; padding: 0 14px 64px;
  background: var(--bg); color: var(--ink);
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC",
               "Hiragino Sans GB", "Microsoft YaHei", "Source Han Sans SC",
               "Noto Sans CJK SC", sans-serif;
  font-size: 16px; line-height: 1.8;
}
.wrap { max-width: 780px; margin: 0 auto; }
.card {
  background: var(--card); border: 1px solid var(--line); border-radius: 14px;
  padding: 20px 18px; margin: 16px 0;
}
h1 { font-size: 1.4em; line-height: 1.4; margin: .3em 0 .5em; letter-spacing: -.01em; }
h2 {
  font-size: 1.22em; margin: 2em 0 .6em; padding-bottom: .35em;
  border-bottom: 2px solid var(--accent); color: var(--accent);
}
h3 { font-size: 1.06em; margin: 1.6em 0 .5em; }
h4 { font-size: 1em; margin: 1.3em 0 .4em; color: var(--ink-soft); }
p { margin: .7em 0; }
strong { font-weight: 650; }
a { color: var(--accent); }
hr { border: 0; border-top: 1px solid var(--line); margin: 2em 0; }
ul, ol { padding-left: 1.35em; margin: .6em 0; }
li { margin: .28em 0; }
code {
  background: var(--code-bg); border-radius: 5px; padding: .12em .38em;
  font-family: ui-monospace, "SFMono-Regular", Consolas, monospace;
  font-size: .88em; word-break: break-word;
}
pre {
  background: var(--code-bg); border: 1px solid var(--line); border-radius: 10px;
  padding: 12px 14px; overflow-x: auto; line-height: 1.5;
}
pre code { background: none; padding: 0; font-size: .84em; }
blockquote {
  margin: .9em 0; padding: .7em 1em; background: var(--accent-soft);
  border-left: 4px solid var(--accent); border-radius: 0 8px 8px 0;
  color: var(--ink); font-size: .96em;
}
blockquote p { margin: .3em 0; }
blockquote.warn { background: var(--warn-soft); border-left-color: var(--warn); }
.tablewrap { overflow-x: auto; margin: 1em 0; -webkit-overflow-scrolling: touch; }
table { border-collapse: collapse; width: 100%; font-size: .9em; min-width: 380px; }
th, td { border: 1px solid var(--line); padding: 8px 10px; text-align: left; vertical-align: top; }
th { background: var(--accent-soft); font-weight: 650; }
tbody tr:nth-child(even) { background: color-mix(in srgb, var(--line) 34%, transparent); }
.toc { font-size: .94em; }
.toc ol { padding-left: 1.2em; }
.toc a { text-decoration: none; }
.toc a:hover { text-decoration: underline; }
.meta { color: var(--ink-soft); font-size: .9em; }
"""


def esc(text):
    return html.escape(text, quote=False)


def inline(text):
    """**bold**, `code` -> html. Bold first so `**a**` wins over `*`."""
    out = esc(text)
    out = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", out)
    out = re.sub(r"`(.+?)`", r"<code>\1</code>", out)
    return out


def slug(text):
    return "h-" + re.sub(r"[^0-9A-Za-z\u4e00-\u9fff]+", "-", text).strip("-")


def render(md_lines):
    body = []
    toc = []
    i = 0
    n = len(md_lines)

    while i < n:
        line = md_lines[i]
        stripped = line.strip()

        # fenced code
        if stripped.startswith("```"):
            buf = []
            i += 1
            while i < n and not md_lines[i].strip().startswith("```"):
                buf.append(md_lines[i])
                i += 1
            i += 1
            body.append("<pre><code>" + esc("\n".join(buf)) + "</code></pre>")
            continue

        # table
        if stripped.startswith("|") and stripped.endswith("|"):
            rows = []
            while i < n and md_lines[i].strip().startswith("|"):
                cells = [c.strip() for c in md_lines[i].strip().strip("|").split("|")]
                if not all(re.fullmatch(r":?-{2,}:?", c) for c in cells):
                    rows.append(cells)
                i += 1
            if rows:
                head, rest = rows[0], rows[1:]
                parts = ["<div class='tablewrap'><table><thead><tr>"]
                parts += [f"<th>{inline(c)}</th>" for c in head]
                parts.append("</tr></thead><tbody>")
                for r in rest:
                    parts.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>")
                parts.append("</tbody></table></div>")
                body.append("".join(parts))
            continue

        # grouped blockquote
        if stripped.startswith(">"):
            buf = []
            while i < n and md_lines[i].strip().startswith(">"):
                buf.append(md_lines[i].strip().lstrip(">").strip())
                i += 1
            warn = any(("⚠" in b or "高风险" in b or "风险" in b) for b in buf)
            inner = "".join(f"<p>{inline(b)}</p>" for b in buf if b)
            body.append(f"<blockquote class='{'warn' if warn else ''}'>{inner}</blockquote>")
            continue

        # horizontal rule
        if stripped == "---":
            body.append("<hr>")
            i += 1
            continue

        # heading
        m = re.match(r"^(#{1,6})\s+(.*)$", stripped)
        if m:
            level = len(m.group(1))
            text = m.group(2)
            tag = f"h{min(level, 4)}"
            anchor = ""
            if level in (2, 3):
                anchor = f" id='{slug(text)}'"
                toc.append((level, text, slug(text)))
            body.append(f"<{tag}{anchor}>{inline(text)}</{tag}>")
            i += 1
            continue

        # list (group consecutive items, honour nesting)
        if re.match(r"^\s*([-*]|\d+\.)\s+", line):
            ordered = bool(re.match(r"^\s*\d+\.", line))
            items = []
            while i < n and re.match(r"^\s*([-*]|\d+\.)\s+", md_lines[i]):
                m = re.match(r"^(\s*)([-*]|\d+\.)\s+(.*)$", md_lines[i])
                depth = len(m.group(1)) // 2
                items.append((depth, m.group(3)))
                i += 1
            html_out = []
            level = -1
            for depth, text in items:
                if depth > level:
                    html_out.append("<ol>" if ordered else "<ul>")
                    level = depth
                elif depth < level:
                    html_out.append("</ol>" if ordered else "</ul>")
                    level = depth
                html_out.append(f"<li>{inline(text)}</li>")
            if level >= 0:
                html_out.append("</ol>" if ordered else "</ul>")
            body.append("".join(html_out))
            continue

        if not stripped:
            i += 1
            continue

        body.append(f"<p>{inline(stripped)}</p>")
        i += 1

    return "\n".join(body), toc


def main():
    md = SRC.read_text(encoding="utf-8").splitlines()
    content, toc = render(md)

    # The title and the leading summary stay above the table of contents; the
    # body starts at the first section heading.
    split = content.find("<h2")
    header_html = content[:split] if split != -1 else ""
    body_html = content[split:] if split != -1 else content
    header_html = header_html.replace("<hr>", "").strip()

    toc_html = ""
    if toc:
        rows = "".join(
            f"<li style='margin-left:{0 if lvl == 2 else 1.1}em'><a href='#{a}'>{inline(t)}</a></li>"
            for lvl, t, a in toc
        )
        toc_html = (
            "<div class='card toc'><h3 style='margin-top:0'>目录</h3>"
            f"<ol style='list-style:none;padding-left:0'>{rows}</ol></div>"
        )

    doc = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Octopus 错题集 · 设计文档 v0.1</title>
<style>{CSS}</style>
</head>
<body>
<div class="wrap">
<div class="card">
{header_html}
</div>
{toc_html}
<div class="card">
{body_html}
</div>
</div>
</body>
</html>
"""
    OUT.write_text(doc, encoding="utf-8")
    print(f"written: {OUT}  ({len(doc)} chars, {len(toc)} headings in TOC)")


main()
