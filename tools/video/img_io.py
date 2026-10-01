#!/usr/bin/env python3
"""Shared picture writers for the video tools: 320x240 8-bit grey as .mif (Quartus), .hex (readmemh in
simulation) and .png (to look at). The .mif writer is make_barcode.py's (Mini-Project 2), unchanged: runs
of equal pixels are written as address ranges so the file stays small."""
import numpy as np

W, H = 320, 240


def write_mif(path, img):
    flat = np.asarray(img, dtype=np.uint8).flatten()
    lines = ["WIDTH=8;", f"DEPTH={flat.size};", "ADDRESS_RADIX=UNS;", "DATA_RADIX=HEX;", "CONTENT BEGIN"]
    i = 0
    while i < flat.size:
        j = i
        while j + 1 < flat.size and flat[j + 1] == flat[i]:
            j += 1
        lines.append(f"  [{i}..{j}] : {flat[i]:02X};" if j > i else f"  {i} : {flat[i]:02X};")
        i = j + 1
    lines.append("END;")
    open(path, "w").write("\n".join(lines) + "\n")


def write_hex(path, img):
    flat = np.asarray(img, dtype=np.uint8).flatten()
    open(path, "w").write("\n".join(f"{v:02X}" for v in flat) + "\n")


def write_png(path, img):
    try:
        from PIL import Image
        Image.fromarray(np.asarray(img, dtype=np.uint8), "L").save(path)
    except ImportError:
        pass


def read_hex(path, w=W, h=H):
    vals = [int(v, 16) for v in open(path).read().split()]
    return np.array(vals, dtype=float).reshape(h, w)


def write_all(stem, img):
    img = np.clip(np.round(img), 0, 255).astype(np.uint8)
    write_mif(stem + ".mif", img)
    write_hex(stem + ".hex", img)
    write_png(stem + ".png", img)
    return img
