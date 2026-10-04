#!/usr/bin/env python3
"""Synthetic templates for tb_classifier: 4 classes x 4 templates x D=8, well separated: class c has one big feature
(feature c, 20000 against 3000) and one small signature (feature 4 + c, 6000 against 3000), plus noise."""
import numpy as np, sys
rng = np.random.default_rng(0); D, NC, NT = 8, 4, 4
base = np.array([[20000, 3000, 3000, 3000, 3000, 3000, 3000, 3000], [3000, 20000, 3000, 3000, 3000, 3000, 3000, 3000],
                 [3000, 3000, 20000, 3000, 3000, 3000, 3000, 3000], [3000, 3000, 3000, 20000, 3000, 3000, 3000, 3000]])
out = sys.argv[1] if len(sys.argv) > 1 else "templates_test.hex"
from train_templates import write_svh          # beside this file
rows = []
with open(out, "w") as f:
    for c in range(NC):
        for t in range(NT):
            row = base[c] + rng.integers(-500, 500, D); row[4 + c] += 3000; f.write("".join(f"{int(v):04x}" for v in row[::-1]) + "\n"); rows.append(row)   # one packed word per template, f[D-1] first
write_svh(out.rsplit(".", 1)[0] + ".svh", rows, D)
print("wrote templates")
