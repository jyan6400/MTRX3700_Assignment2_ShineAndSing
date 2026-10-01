#!/usr/bin/env python3
"""Convert Quartus .mif memory-initialisation files into .hex files for $readmemh.

Usage:  python3 mif_to_hex.py happy.mif neutral.mif angry.mif      (writes happy.hex, ...)

Quartus initialises the image ROMs from the .mif files (the `ram_init_file`
attribute in vga_face.sv). A simulator does not read .mif, but $readmemh reads
a plain list of hex values, one per address: that is all a .hex file is. Running
this before every simulation keeps the two in step: one source image, two formats.
"""
import re
import sys


def parse_mif(path):
    depth = width = None
    addr_radix = data_radix = "HEX"
    values = {}
    in_content = False
    text = open(path).read()
    text = re.sub(r"--[^\n]*", "", text)        # -- comments
    text = re.sub(r"%[^%]*%", "", text)          # % comments %
    for stmt in text.split(";"):
        s = stmt.strip()
        if not s:
            continue
        m = re.match(r"(DEPTH|WIDTH|ADDRESS_RADIX|DATA_RADIX)\s*=\s*(\w+)", s, re.I)
        if m:
            key, val = m.group(1).upper(), m.group(2).upper()
            if key == "DEPTH": depth = int(val)
            elif key == "WIDTH": width = int(val)
            elif key == "ADDRESS_RADIX": addr_radix = val
            else: data_radix = val
            continue
        if re.match(r"CONTENT\s*BEGIN", s, re.I):
            in_content = True
            s = re.sub(r"CONTENT\s*BEGIN", "", s, flags=re.I).strip()
            if not s:
                continue
        if s.upper() == "END":
            break
        if in_content:
            m = re.match(r"\[?\s*(\w+)\s*(?:\.\.\s*(\w+))?\s*\]?\s*:\s*([\w\s]+)$", s)
            if not m:
                raise SystemExit(f"{path}: cannot parse '{s}'")
            base = {"HEX": 16, "BIN": 2, "DEC": 10, "UNS": 10, "OCT": 8}
            a0 = int(m.group(1), base[addr_radix])
            a1 = int(m.group(2), base[addr_radix]) if m.group(2) else a0
            vals = [int(v, base[data_radix]) for v in m.group(3).split()]
            a = a0
            while a <= a1:
                for v in vals:
                    values[a] = v
                    a += 1
    if depth is None or width is None:
        raise SystemExit(f"{path}: DEPTH/WIDTH missing")
    return depth, width, values


def main(files):
    for path in files:
        depth, width, values = parse_mif(path)
        digits = (width + 3) // 4
        out = path[:-4] + ".hex" if path.lower().endswith(".mif") else path + ".hex"
        with open(out, "w") as fh:
            for a in range(depth):
                fh.write(f"{values.get(a, 0):0{digits}x}\n")
        print(f"{path} -> {out} ({depth} words of {width} bits)")


if __name__ == "__main__":
    main(sys.argv[1:] or ["happy.mif", "neutral.mif", "angry.mif"])
