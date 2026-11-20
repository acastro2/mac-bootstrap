"""The bridges between the Mac and the agent VM, as one SVG per theme.

    python3 docs/den/scenes/bridges/build.py     # writes docs/den/img/bridges-{dark,light}.svg

The Mac is the top band, the VM the bottom band, the dashed line the boundary.
Every bridge is one numbered column. Blue: the Mac sends into the VM. Amber:
VM traffic that reaches the Mac, only through a door the Mac opened. Grey: no
direct link; each side talks to an internet service on its own. The README
table under the picture says what crosses each bridge and what guards it.
"""
import os
from html import escape

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "img")

W, H = 1262, 700
GUTTER = 150
X0, STEP, BOX_W = 222, 118, 106
MAC_Y, BOX_H = (96, 70)
VM_Y = 452
LINE = 315  # the boundary

THEMES = {
    "dark": dict(bg="#0d1117", band="#161b22", stroke="#30363d", box="#1c2128", text="#e6edf3",
                 muted="#8b949e", blue="#58a6ff", amber="#e3b341", grey="#8b949e", line="#6e7681"),
    "light": dict(bg="#ffffff", band="#f6f8fa", stroke="#d0d7de", box="#ffffff", text="#1f2328",
                  muted="#59636e", blue="#0969da", amber="#9a6700", grey="#6e7781", line="#8c959f"),
}

# number, Mac end, VM end, label on the line, kind: down (Mac -> VM),
# up (VM traffic reaching the Mac), pulled (the Mac fetches from the VM),
# or a service name for the two that go through the internet.
BRIDGES = [
    (1, ["Rex.app"], ["Rex server"], "SSH", "down"),
    (2, ["VS Code"], ["your code"], "Remote-SSH ⇄", "both"),
    (3, ["API keys", "relay token"], ["same files", "mode 600"], "copy", "down"),
    (4, ["browse relay", ":19988"], ["agents call", ":19988"], "tunnel", "up"),
    (5, ["VS Code", "window"], ["code .", "inbox"], "pulled", "pulled"),
    (6, ["vm-up", "den up"], ["start · heal", "den copy"], "control", "down"),
    (7, ["Mac browser"], ["dev servers", "1024-9999"], "port mirror", "down"),
    (8, ["git"], ["own gh login"], "GitHub", "net"),
    (9, ["Obsidian"], ["~/Developer/obsidian", "notes only"], "Obsidian Sync", "net"),
]


def text(x, y, s, size, fill, weight="normal", anchor="middle"):
    return (f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" fill="{fill}" '
            f'text-anchor="{anchor}">{escape(s)}</text>')


def box(cx, y, lines, t, h=BOX_H, w=BOX_W, fill=None, stroke=None):
    out = [f'<rect x="{cx - w / 2}" y="{y}" width="{w}" height="{h}" rx="9" '
           f'fill="{fill or t["box"]}" stroke="{stroke or t["stroke"]}" stroke-width="1.5"/>']
    top = y + h / 2 - (len(lines) - 1) * 9 + 5
    for i, line in enumerate(lines):
        out.append(text(cx, top + i * 18, line, 14.5, t["text"]))
    return "".join(out)


def build(theme):
    t = THEMES[theme]
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
         f'font-family="-apple-system, BlinkMacSystemFont, Segoe UI, Helvetica, Arial, sans-serif" '
         f'role="img" aria-label="The nine bridges between the Mac and the agent VM. The Mac opens every '
         f'connection; the VM cannot log in to the Mac or read its files.">',
         f'<rect width="{W}" height="{H}" fill="{t["bg"]}"/>',
         "<defs>"]
    for name in ("blue", "amber", "grey"):
        o.append(f'<marker id="a-{name}" viewBox="0 0 10 10" refX="8.5" refY="5" markerWidth="7" markerHeight="7" '
                 f'orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="{t[name]}"/></marker>')
    o.append("</defs>")

    # Bands and their labels in the gutter.
    right = X0 + STEP * (len(BRIDGES) - 1) + BOX_W / 2 + 22
    o.append(f'<rect x="16" y="64" width="{right - 16}" height="136" rx="14" fill="{t["band"]}" stroke="{t["stroke"]}"/>')
    o.append(f'<rect x="16" y="{VM_Y - 32}" width="{right - 16}" height="136" rx="14" fill="{t["band"]}" stroke="{t["stroke"]}"/>')
    o.append(text(36, 124, "Mac", 24, t["text"], "700", "start"))
    o.append(text(36, 148, "the window,", 13.5, t["muted"], anchor="start"))
    o.append(text(36, 166, "keys, browser", 13.5, t["muted"], anchor="start"))
    o.append(text(36, VM_Y + 28, "VM agent", 24, t["text"], "700", "start"))
    o.append(text(36, VM_Y + 52, "the dev box", 13.5, t["muted"], anchor="start"))

    # The boundary.
    o.append(f'<line x1="16" y1="{LINE}" x2="{right}" y2="{LINE}" stroke="{t["line"]}" stroke-width="1.5" stroke-dasharray="7 6"/>')
    o.append(text(36, LINE - 46, "boundary", 14, t["text"], "600", "start"))
    o.append(text(36, LINE - 28, "the Mac opens", 12.5, t["muted"], anchor="start"))
    o.append(text(36, LINE - 12, "every link", 12.5, t["muted"], anchor="start"))

    o.append(text(W / 2, 36, "Where the Mac and the agent VM touch", 20, t["text"], "700"))

    for i, (n, mac, vm, label, kind) in enumerate(BRIDGES):
        cx = X0 + STEP * i
        y1, y2 = MAC_Y + BOX_H, VM_Y
        if kind == "net":
            # Two separate links to an internet service in the middle: no direct line.
            mid_y, mid_h = LINE - 30, 60
            o.append(f'<line x1="{cx}" y1="{y1}" x2="{cx}" y2="{mid_y}" stroke="{t["grey"]}" stroke-width="2.2" '
                     f'marker-start="url(#a-grey)" marker-end="url(#a-grey)"/>')
            o.append(f'<line x1="{cx}" y1="{mid_y + mid_h}" x2="{cx}" y2="{y2}" stroke="{t["grey"]}" stroke-width="2.2" '
                     f'marker-start="url(#a-grey)" marker-end="url(#a-grey)"/>')
            o.append(box(cx, mid_y, label.split(" ", 1) if " " in label else [label], t, h=mid_h, fill=t["bg"],
                         stroke=t["grey"]))
            badge_y = mid_y - 2
        else:
            colour = "amber" if kind in ("up", "pulled", "both") else "blue"
            dash = ' stroke-dasharray="6 5"' if kind == "pulled" else ""
            if kind == "down":
                a, b = y1 + 2, y2 - 4
            else:
                a, b = y2 - 2, y1 + 4
            start = f' marker-start="url(#a-{colour})"' if kind == "both" else ""
            o.append(f'<line x1="{cx}" y1="{a}" x2="{cx}" y2="{b}" stroke="{t[colour]}" stroke-width="2.6"{dash}{start} '
                     f'marker-end="url(#a-{colour})"/>')
            # The label sits on a plate across the line, under the number.
            lw = 16 + 8.2 * len(label)
            o.append(f'<rect x="{cx - lw / 2}" y="{LINE + 22}" width="{lw}" height="22" rx="6" fill="{t["bg"]}" '
                     f'stroke="{t[colour]}" stroke-width="1"/>')
            o.append(text(cx, LINE + 37.5, label, 13, t[colour], "600"))
            badge_y = LINE
        colour = {"down": "blue", "up": "amber", "pulled": "amber", "both": "amber", "net": "grey"}[kind]
        o.append(f'<circle cx="{cx}" cy="{badge_y}" r="14" fill="{t[colour]}"/>')
        o.append(text(cx, badge_y + 5, str(n), 14.5, t["bg"], "700"))
        o.append(box(cx, MAC_Y, mac, t))
        o.append(box(cx, VM_Y, vm, t))

    # Legend.
    rows = [[("blue", "the Mac sends into the VM"),
             ("amber", "reaches the Mac, only through a door the Mac opened")],
            [("grey", "no direct link: each side uses the service on its own")]]
    for r, items in enumerate(rows):
        ly = H - 84 + r * 28
        x = 36
        for colour, words in items:
            o.append(f'<line x1="{x}" y1="{ly}" x2="{x + 34}" y2="{ly}" stroke="{t[colour]}" stroke-width="3" '
                     f'marker-end="url(#a-{colour})"/>')
            o.append(text(x + 44, ly + 5, words, 14, t["text"], anchor="start"))
            x += 44 + 7.4 * len(words) + 40
    o.append(text(36, H - 48, "Doors the VM can use: 2 a command through the open VS Code window · 4 the browser · "
                  "8 a push that lands at the Mac's next pull · 9 a note that lands at its next sync", 14, t["muted"], anchor="start"))
    o.append(text(36, H - 20, "Never crosses: your Mac's files (no shared folders) · your SSH agent (no forwarding) · "
                  "a login to the Mac (the VM has no account there)", 14, t["muted"], anchor="start"))
    o.append("</svg>")
    return "".join(o)


os.makedirs(OUT, exist_ok=True)
for theme in THEMES:
    path = os.path.join(OUT, f"bridges-{theme}.svg")
    with open(path, "w", encoding="utf-8") as f:
        f.write(build(theme))
    print("wrote", os.path.relpath(path))
