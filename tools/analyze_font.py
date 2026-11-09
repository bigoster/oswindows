exec(open(r"C:\Users\User\Desktop\cc ce\tools\decode_font.py").read().split("# occupancy analysis")[0])

# column occupancy in x 0..140, y 0..190
cols = [sum(1 for y in range(0, 192) if grid[y][x]) for x in range(w)]
rows_ = [sum(1 for x in range(0, 140) if grid[y][x]) for y in range(h)]
print("col occupancy x=0..140:")
print(" ".join("%d:%d" % (x, cols[x]) for x in range(140) if cols[x] == 0))
print("row occupancy y=0..200:")
print(" ".join("%d:%d" % (y, rows_[y]) for y in range(200)))

# guess: print art of x0..47, y0..48 to see first glyphs
for y in range(0, 34):
    print("%3d " % y + "".join("#" if grid[y][x] else "." for x in range(0, 56)))
