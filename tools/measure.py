exec(open(r"C:\Users\User\Desktop\cc ce\tools\decode_font.py").read().split("# occupancy analysis")[0])

def used(ch, x0, y0, x1, y1):
    cx, cy = ch % 16, ch // 16
    ox, oy = cx*8, cy*11
    return any(grid[oy+r][ox+c] for r in range(y0, y1) for c in range(x0, x1))

cols = [0]*8
rows = [0]*11
outside = []
for ch in range(32, 127):
    for c in range(8):
        if used(ch, c, 0, c+1, 11): cols[c] += 1
    for r in range(11):
        if used(ch, 0, r, 8, r+1): rows[r] += 1
    if used(ch, 0, 0, 1, 11) or used(ch, 7, 0, 8, 11) or used(ch,0,0,8,1) or used(ch,0,9,8,11):
        outside.append(ch)
print("printable chars (32-126) using col:", cols)
print("printable chars (32-126) using row:", rows)
print("chars touching border col0/col7/row0/row9/10:", [(c, chr(c)) for c in outside])

# same for all chars
colsA = [0]*8; rowsA=[0]*11
for ch in range(0, 256):
    for c in range(8):
        if used(ch, c, 0, c+1, 11): colsA[c] += 1
    for r in range(11):
        if used(ch, 0, r, 8, r+1): rowsA[r] += 1
print("all chars using col:", colsA)
print("all chars using row:", rowsA)
