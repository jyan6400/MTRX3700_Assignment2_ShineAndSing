#!/usr/bin/env python3
"""frame_<n>.ppm (from vga_monitor_model) -> frame_<n>.png. Pillow if present, else a tiny PNG writer."""
import glob, struct, sys, zlib
def read_ppm(p):
    d = open(p, "rb").read(); parts = d.split(b"\n", 3); w, h = (int(v) for v in parts[1].split()); return w, h, parts[3][:w*h*3]
def write_png(p, w, h, rgb):
    raw = b"".join(b"\x00" + rgb[y*w*3:(y+1)*w*3] for y in range(h))
    def chunk(t, b): return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)
    open(p, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
for f in sorted(glob.glob("frame_*.ppm")):
    w, h, rgb = read_ppm(f); write_png(f[:-4] + ".png", w, h, rgb); print("wrote", f[:-4] + ".png")
