import zlib, struct, sys

path = r"C:\Users\User\Desktop\cc ce\term_font.png"
data = open(path, "rb").read()

pos = 8
idat = b""
plte = None
trns = None
while pos < len(data):
    ln = struct.unpack(">I", data[pos:pos+4])[0]
    typ = data[pos+4:pos+8]
    chunk = data[pos+8:pos+8+ln]
    if typ == b"IHDR":
        w, h, bd, ct, comp, filt, inter = struct.unpack(">IIBBBBB", chunk)
        print("IHDR", w, h, bd, ct, inter)
    elif typ == b"PLTE":
        plte = chunk
    elif typ == b"tRNS":
        trns = chunk
    elif typ == b"IDAT":
        idat += chunk
    pos += 12 + ln

raw = zlib.decompress(idat)
assert bd == 1 and ct == 3
bpp = 1
stride = (w * bpp + 7) // 8
rows = []
prev = bytearray(stride)
i = 0
for y in range(h):
    f = raw[i]; i += 1
    line = bytearray(raw[i:i+stride]); i += stride
    if f == 1:
        for x in range(bpp, stride):
            line[x] = (line[x] + line[x-bpp]) & 0xFF
    elif f == 2:
        for x in range(stride):
            line[x] = (line[x] + prev[x]) & 0xFF
    elif f == 3:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            line[x] = (line[x] + ((a + prev[x]) >> 1)) & 0xFF
    elif f == 4:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x-bpp] if x >= bpp else 0
            p = a + b - c
            pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[x] = (line[x] + pr) & 0xFF
    rows.append(line)
    prev = line

# to boolean grid
grid = [[False]*w for _ in range(h)]
for y in range(h):
    line = rows[y]
    for x in range(w):
        byte = line[x >> 3]
        bit = (byte >> (7 - (x & 7))) & 1
        grid[y][x] = bool(bit)

# occupancy analysis per 16x16 cell
print("plte", plte, "trns", trns)
for cy in range(h // 16):
    line_out = ""
    for cx in range(w // 16):
        occ = sum(1 for y in range(cy*16, cy*16+16) for x in range(cx*16, cx*16+16) if grid[y][x])
        line_out += ("%3d" % occ)
    print(cy, line_out)

# bbox of first cell block rows 16..? print ascii art for a few chars
def art(ch):
    cx, cy = ch % 16, ch // 16
    print("char", ch, repr(chr(ch)))
    for y in range(cy*16, cy*16+16):
        print("".join("#" if grid[y][x] else "." for x in range(cx*16, cx*16+16)))

for c in (65, 97, 48, 32, 33):
    art(c)
