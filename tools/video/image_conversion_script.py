#!/usr/bin/env python3
"""Any picture -> 320x240 8-bit grey .mif + .hex + .png, ready for image_rom.sv.
(Mini-Project 2's tools/image_to_mif.py, made self-contained: it imported its writers from make_barcode.py.)

    python3 tools/video/image_conversion_script.py tutor_photo.jpg memory/piano2

Resizes to fit 320x240 (letterboxed with grey borders) and converts to greyscale. For the demo, run this on
the tutor's photograph and recompile: piano2.mif is the ROM behind SW4..3 = 2.
"""
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from img_io import W, H, write_all                      # noqa: E402

if len(sys.argv) != 3:
    sys.exit(__doc__)
src, out = sys.argv[1], sys.argv[2]
im = Image.open(src).convert("L")
im.thumbnail((W, H))
canvas = Image.new("L", (W, H), 128)
canvas.paste(im, ((W - im.width) // 2, (H - im.height) // 2))
write_all(out, np.asarray(canvas, dtype=np.uint8))
print(f"wrote {out}.mif/.hex/.png from {src} ({im.width}x{im.height} inside {W}x{H})")
