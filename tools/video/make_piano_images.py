#!/usr/bin/env python3
"""Make the three pictures the video subsystem reads (SW4..3 = 0, 1, 2), from the two piano pictures
supplied on the assignment page, with the course's converter (Mini-Project 2's image_to_mif.py, here
tools/video/image_conversion_script.py -- the tutor's answer on Ed: "save those images and convert them
with the script in the barcode mini project's tools folder").

    python3 tools/video/make_piano_images.py            (from the repository root)

writes memory/piano{0,1,2}.{mif,hex,png,txt}:
    piano0   supplied picture 1 (memory/originals/supplied_piano_1.png), letterboxed to 300x240
    piano1   supplied picture 2 (memory/originals/supplied_piano_2.png), letterboxed to 320x160
    piano2   the photo-like test picture: piano0 with the notebook's photo_like() -- a strong lighting
             gradient (left side at 20 %), sensor noise and a dark shadow band across one key.
             A stand-in for the tutor's photograph until it is available: then run
             python3 tools/video/image_conversion_script.py tutor_photo.jpg memory/piano2

The .txt holds the TRUE key boundaries the tests check the hardware against. They were measured on the
converted pictures independently of the key finder: the mean grey level of each column over rows
150..176 (white keys only) is ~220-240 on a key and drops to 20..110 in the one or two dark columns
between two keys -- the boundary is the darkest column -- and the keyboard's outer edges are where the
grey border / dark frame meets the first and last white key.
"""
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import video_model                                       # noqa: E402
from img_io import W, H, write_all                       # noqa: E402

TRUTH = {
    0: ("supplied picture 1 (memory/originals/supplied_piano_1.png)",
        [10, 34, 66, 99, 132, 164, 196, 228, 260, 292, 310]),
    1: ("supplied picture 2 (memory/originals/supplied_piano_2.png)",
        [19, 60, 98, 136, 172, 210, 249, 300]),
}


def convert(src):
    """image_conversion_script.py's conversion: greyscale, fit inside 320x240, grey (128) letterbox."""
    im = Image.open(src).convert("L")
    im.thumbnail((W, H))
    canvas = Image.new("L", (W, H), 128)
    canvas.paste(im, ((W - im.width) // 2, (H - im.height) // 2))
    return np.asarray(canvas, dtype=np.uint8)


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "memory"
    orig = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "memory", "originals")
    os.makedirs(out_dir, exist_ok=True)
    pics = [convert(os.path.join(orig, "supplied_piano_1.png")), convert(os.path.join(orig, "supplied_piano_2.png"))]
    video_model.rng = np.random.default_rng(37)          # the notebook's seed: same picture every run
    # the shadow sits across the middle of the key 66..99 (a cable / a stand over one key)
    pics.append(video_model.photo_like(pics[0].astype(float), gradient=0.8, noise=7, shadow=(79, 4)))
    truth = dict(TRUTH)
    truth[2] = ("photo-like: picture 0 + lighting gradient, noise, shadow at x ~ 78..86", TRUTH[0][1])
    for n, img in enumerate(pics):
        what, edges = truth[n]
        stem = os.path.join(out_dir, f"piano{n}")
        write_all(stem, img)
        open(stem + ".txt", "w").write(f"what={what}\nedges={' '.join(map(str, edges))}\n")
        print(f"wrote {stem}.mif/.hex/.png/.txt  ({what}; {len(edges)} boundaries)")


if __name__ == "__main__":
    main()
