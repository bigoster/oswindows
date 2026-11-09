exec(open(r"C:\Users\User\Desktop\cc ce\tools\decode_font.py").read().split("# occupancy analysis")[0])

def glyph(ch, x0=None, y0=None):
    cx, cy = ch % 16, ch // 16
    x0 = cx*8 if x0 is None else x0
    y0 = cy*11 if y0 is None else y0
    for y in range(y0, y0+11):
        print("".join("#" if grid[y][x] else "." for x in range(x0, x0+8)))

for c in "ABCabc0!? .gjpqy":
    print("=== %r (%d)" % (c, ord(c)))
    glyph(ord(c))
