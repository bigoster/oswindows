exec(open(r"C:\Users\User\Desktop\cc ce\tools\decode_font.py").read().split("# occupancy analysis")[0])
for y in range(0, 176):
    print("%3d|" % y + "".join("#" if grid[y][x] else "." for x in range(0, 128)))
