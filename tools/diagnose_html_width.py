"""Find what makes the generated HTML wider than the viewport.

Injects a script that measures every element and writes the offenders into the
DOM, then reads them back with Edge --dump-dom. Guessing at CSS is slower and
less reliable than asking the renderer.
"""
import re
import subprocess
import sys
from pathlib import Path

EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
src = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()

doc = src.read_text(encoding="utf-8")

probe = """
<script>
window.addEventListener('load', function () {
  var vw = document.documentElement.clientWidth;
  var rows = ['viewport=' + vw,
              'docScrollWidth=' + document.documentElement.scrollWidth,
              'bodyScrollWidth=' + document.body.scrollWidth];
  var all = document.querySelectorAll('*');
  for (var i = 0; i < all.length; i++) {
    var el = all[i];
    var r = el.getBoundingClientRect();
    if (r.right > vw + 0.5 || r.width > vw + 0.5) {
      var id = el.tagName.toLowerCase()
        + (el.className && typeof el.className === 'string' ? '.' + el.className.split(' ').join('.') : '');
      rows.push('OVERFLOW ' + id + ' width=' + Math.round(r.width)
                + ' right=' + Math.round(r.right)
                + ' text=' + (el.textContent || '').trim().slice(0, 24));
    }
  }
  var pre = document.createElement('pre');
  pre.id = 'DIAG';
  pre.textContent = rows.join('\\n');
  document.body.appendChild(pre);
});
</script>
"""

doc = doc.replace("</body>", probe + "</body>")
out.write_text(doc, encoding="utf-8")

res = subprocess.run(
    [EDGE, "--headless=new", "--disable-gpu", "--no-sandbox",
     "--force-device-scale-factor=1", "--hide-scrollbars",
     f"--window-size={sys.argv[3] if len(sys.argv) > 3 else 430},1400",
     "--virtual-time-budget=4000", "--dump-dom", out.as_uri()],
    capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180,
)
dom = res.stdout or ""
m = re.search(r'<pre id="DIAG">(.*?)</pre>', dom, re.S)
if m:
    import html as _h
    lines = _h.unescape(m.group(1)).splitlines()
    print(f"  diagnostic lines: {len(lines)}")
    for line in lines[:24]:
        print("   ", line)
else:
    print("  no DIAG block found; dom length =", len(dom))
    print("  stderr tail:", (res.stderr or "")[-300:])
