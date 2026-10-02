#!/usr/bin/env python3
"""Any picture -> 320x240 8-bit grey .mif + .hex + .png, ready for image_rom.sv.
(Mini-Project 2's tools/image_to_mif.py with the writers it imported from make_barcode.py in the same
file, so this one script is everything the pictures need.)

    python3 tools/video/image_conversion_script.py tutor_photo.jpg memory/piano2

Resizes to fit 320x240 (letterboxed with grey borders) and converts to greyscale. For the demo, run this on
the tutor's photograph and recompile: piano2.mif is the ROM behind SW4..3 = 2.

    .mif  Quartus initialises the image ROM from it (runs of equal pixels are written as address ranges,
          so the file stays small) -- make_barcode.py's writer, unchanged
    .hex  the same pixels for $readmemh in simulation
    .png  to look at

Other scripts import convert() and write_all() from here (make_piano_images.py).
"""
import sys

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


def write_all(stem, img):
    """stem.mif, stem.hex and stem.png from a W x H array (rounded and clipped to 0..255)."""
    img = np.clip(np.round(img), 0, 255).astype(np.uint8)
    write_mif(stem + ".mif", img)
    write_hex(stem + ".hex", img)
    write_png(stem + ".png", img)
    return img


def convert(src):
    """A picture file -> W x H uint8 array: greyscale, fitted inside W x H, grey (128) letterbox."""
    from PIL import Image
    im = Image.open(src).convert("L")
    im.thumbnail((W, H))
    canvas = Image.new("L", (W, H), 128)
    canvas.paste(im, ((W - im.width) // 2, (H - im.height) // 2))
    return np.asarray(canvas, dtype=np.uint8), (im.width, im.height)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, out = sys.argv[1], sys.argv[2]
    img, (w, h) = convert(src)
    write_all(out, img)
    print(f"wrote {out}.mif/.hex/.png from {src} ({w}x{h} inside {W}x{H})")
