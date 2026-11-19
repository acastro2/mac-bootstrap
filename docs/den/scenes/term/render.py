"""Render saved den output as a terminal window (HTML), for README screenshots.

    python3 docs/den/scenes/term/render.py docs/den/scenes/term/den-up.txt "den up" /tmp/den-up.html

The .txt files next to this script are real output, copied from a run. Only
colour is added here: status words and [ok]/[skip]/[err] markers, the way gum
paints them in a terminal. Capture the HTML with the anatomy skill:

    node ~/.agents/skills/anatomy/scripts/capture.mjs /tmp/den-up.html \
      --select .win --out docs/den/img/den-up.png
"""
import html
import re
import sys

src, title, out = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src, encoding="utf-8").read().rstrip("\n")

RULES = [
    (r"\b(done)\b", "ok"),
    (r"\b(skip)\b", "skip"),
    (r"\b(fail)\b", "err"),
    (r"\b(dry)\b", "dim"),
    (r"(\[ok\])", "ok"),
    (r"(\[skip\])", "skip"),
    (r"(\[err\]|\[warn\])", "err"),
    (r"(\[info\])", "dim"),
    (r"^(== .* ==)$", "head"),
    (r"^(\s*phase\s+status.*|PHASE\s+TOGGLE.*)$", "head"),
    (r"^(\$ .*)$", "cmd"),
]


def paint(line):
    line = html.escape(line)
    for pattern, cls in RULES:
        line = re.sub(pattern, rf'<span class="{cls}">\1</span>', line, flags=re.M)
    return line


body = "\n".join(paint(line) for line in text.split("\n"))
page = f"""<!doctype html><html><head><meta charset="utf-8"><style>
body{{margin:0;padding:32px;background:#0b0d10;}}
.win{{display:inline-block;background:#14171c;border:1px solid #2a2f37;border-radius:10px;
  box-shadow:0 18px 50px rgba(0,0,0,.55);overflow:hidden;min-width:760px}}
.bar{{height:34px;display:flex;align-items:center;gap:8px;padding:0 14px;background:#1b1f25;
  border-bottom:1px solid #2a2f37;font:12px -apple-system,system-ui,sans-serif;color:#8b93a1}}
.dot{{width:12px;height:12px;border-radius:50%}} .r{{background:#ff5f57}} .y{{background:#febc2e}} .g{{background:#28c840}}
.t{{margin-left:10px}}
pre{{margin:0;padding:18px 22px 22px;font:13px/1.55 "SF Mono",Menlo,monospace;color:#d6dbe3;white-space:pre}}
.ok{{color:#4ade80}} .skip{{color:#facc15}} .err{{color:#f87171}} .dim{{color:#7d8695}}
.head{{color:#93c5fd;font-weight:600}} .cmd{{color:#f5f5f5;font-weight:600}}
</style></head><body><div class="win"><div class="bar"><span class="dot r"></span><span class="dot y"></span>
<span class="dot g"></span><span class="t">{html.escape(title)}</span></div><pre>{body}</pre></div></body></html>"""
open(out, "w", encoding="utf-8").write(page)
print("wrote", out)
