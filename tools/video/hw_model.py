#!/usr/bin/env python3
"""Bit-exact integer twin of the Assignment 2 video analysis RTL (rtl/video/*), so every number the hardware
produces can be predicted here first, and the thresholds chosen on all three pictures before synthesis.

Every function below is one block of the hardware:
    hdiff            the 1-D difference in a2/video_subsystem.sv   |p[x] - p[x-1]|, x = 1..W-1
    conv3            barcode_reuse/conv3x3.sv        interior centres only, integer weights
    gauss            conv3x3 with [1 2 1; 2 4 2; 1 2 1], then >> 4        (R-V4 smoothing)
    profile          barcode_reuse/col_profile.sv    sum over rows Y0..Y1 inclusive
    normalise        a2/profile_normalise.sv         n = floor(p * 256 / max), 0..256
    local_thr        a2/local_threshold.sv           (k_q * sum of n over x-12..x+12) >> 10
    hysteresis       a2/hysteresis_profile.sv        NMS + two thresholds + min_gap (R-V3, R-V4)
    peak_pick        barcode_reuse/peak_pick.sv      local maxima above thr + min_gap (R-V1 1-D, R-V2 Sobel)
    lattice / lanes  a2/key_mask_generator.sv        median spacing, off-lattice boundaries dropped, 4 lanes

    python3 tools/video/hw_model.py        prints every mode on every picture in memory/
"""
import os
import sys

import numpy as np

W, H = 320, 240
Y0, Y1 = 150, 176                    # below the black keys, above the white keys' bottom, in both supplied pictures
WIN_HALF = 12                        # local mean over 25 columns (video_model: win = 25)
HI_DEF, LO_DEF = 115, 64             # 0.45 and 0.25 of the maximum, in 1/256
K_Q_DEF = 102                        # k = 2.5 over 25 columns: round(2.5 * 1024 / 25)
FLOOR_DEF = 26                       # R-V4 noise floor: 0.10 of the maximum (see choose() below)
GAP_RV3, GAP_RV4 = 10, 8             # min_gap: the notebook's values
THR_ABS_DEF = 2048                   # R-V1/R-V2 absolute threshold in 1-D units; x4 for Sobel
LANE_FIRST = 15                      # 15: the four middle keys (key_mask_generator.sv)
SOBEL_X = np.array([[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]])
SOBEL_Y = SOBEL_X.T
GAUSS = np.array([[1, 2, 1], [2, 4, 2], [1, 2, 1]])


def load(n, d="memory"):
    img = np.array([int(v, 16) for v in open(f"{d}/piano{n}.hex").read().split()], dtype=np.int64).reshape(H, W)
    edges = [int(v) for v in open(f"{d}/piano{n}.txt").read().split("edges=")[1].split()]
    return img, edges


# ------------------------------------------------------------------ edge images (value, valid mask)
def conv3(img, k, valid):
    """conv3x3.sv: output only where the whole 3x3 window was valid input (interior of the valid region)."""
    h, w = img.shape
    out = np.zeros((h, w), dtype=np.int64)
    ok = np.zeros((h, w), dtype=bool)
    for y in range(1, h - 1):
        for x in range(1, w - 1):
            if valid[y - 1:y + 2, x - 1:x + 2].all():
                out[y, x] = int((k * img[y - 1:y + 2, x - 1:x + 2]).sum())
                ok[y, x] = True
    return out, ok


def conv3_fast(img, k, valid):
    h, w = img.shape
    out = np.zeros((h, w), dtype=np.int64)
    for dy in range(3):
        for dx in range(3):
            out[1:h - 1, 1:w - 1] += k[dy, dx] * img[dy:dy + h - 2, dx:dx + w - 2]
    ok = np.zeros((h, w), dtype=bool)
    v = valid.astype(np.int64)
    s = np.zeros((h, w), dtype=np.int64)
    for dy in range(3):
        for dx in range(3):
            s[1:h - 1, 1:w - 1] += v[dy:dy + h - 2, dx:dx + w - 2]
    ok[1:h - 1, 1:w - 1] = s[1:h - 1, 1:w - 1] == 9
    return np.where(ok, out, 0), ok


def edge_image(img, sobel=True, smooth=False):
    """(|Gx|-like value used for the profile, magnitude shown on the edge map, valid mask)."""
    valid = np.ones_like(img, dtype=bool)
    src = img
    if smooth:
        g, valid = conv3_fast(img, GAUSS, valid)
        src = g >> 4
    if sobel:
        gx, ok = conv3_fast(src, SOBEL_X, valid)
        gy, _ = conv3_fast(src, SOBEL_Y, valid)
        return np.abs(gx), np.abs(gx) + np.abs(gy), ok
    d = np.zeros_like(src)
    ok = np.zeros_like(valid)
    d[:, 1:] = np.abs(src[:, 1:] - src[:, :-1])
    ok[:, 1:] = valid[:, 1:] & valid[:, :-1]
    d = np.where(ok, d, 0)
    return d, d, ok


def profile(g, ok, y0=Y0, y1=Y1):
    return np.where(ok, g, 0)[y0:y1 + 1].sum(axis=0)


# ------------------------------------------------------------------ profile processing
def normalise(p):
    m = int(p.max())
    if m == 0:
        return np.zeros(W, dtype=np.int64), 0
    return np.array([(int(v) << 8) // m for v in p], dtype=np.int64), m


def local_thr(n, k_q=K_Q_DEF, half=WIN_HALF):
    pad = np.concatenate([np.zeros(half, dtype=np.int64), n, np.zeros(half, dtype=np.int64)])
    s = np.array([pad[x:x + 2 * half + 1].sum() for x in range(W)], dtype=np.int64)
    return (s * k_q) >> 10


def hysteresis(n, hi, lo, min_gap):
    """hysteresis_profile.sv. hi and lo are per-column arrays (constants for R-V3).
    Candidate: 1 <= x <= W-2, n[x] >= both neighbours, n[x] > lo[x]. Strong: n[x] > hi[x].
    Accepted: strong, or within min_gap (<=) of a strong candidate. Accepted peaks closer than min_gap to
    the last kept one merge into it, the larger winning (a tie keeps the first)."""
    cand = [x for x in range(1, W - 1) if n[x] >= n[x - 1] and n[x] >= n[x + 1] and n[x] > lo[x]]
    strong = [x for x in cand if n[x] > hi[x]]
    out = []
    for c in cand:
        if n[c] > hi[c] or any(abs(c - s) <= min_gap for s in strong):
            if out and c - out[-1] < min_gap:
                if n[c] > n[out[-1]]:
                    out[-1] = c
            else:
                out.append(c)
    return out


def peak_pick(p, thr, min_gap):
    """peak_pick.sv (3.2d): examines x = 1..W-2."""
    out, last_v = [], 0
    for x in range(1, W - 1):
        if p[x] > thr and p[x] >= p[x - 1] and p[x] >= p[x + 1]:
            if out and x - out[-1] < min_gap:
                if p[x] > last_v:
                    out[-1], last_v = x, p[x]
            else:
                out.append(x)
                last_v = p[x]
    return out


# ------------------------------------------------------------------ boundaries -> keys -> lanes
def median_spacing(b):
    """key_mask_generator.sv: the lower median of the spacings (the smallest d with count(<= d) >= ceil(m/2))."""
    d = sorted(b[i + 1] - b[i] for i in range(len(b) - 1))
    return d[(len(d) - 1) // 2] if d else 0


def lattice(b):
    """video_model.template_fit in integers: keep a boundary if it is s +- s/4 from the last kept one, or
    more than 1.5 s (a missed boundary). Returns (kept, spacing)."""
    if len(b) < 3:
        return list(b), 0
    s = median_spacing(b)
    keep = [b[0]]
    for x in b[1:]:
        d = x - keep[-1]
        if abs(d - s) < (s >> 2) or 2 * d > 3 * s:
            keep.append(x)
    return keep, s


def lanes(kept, first=LANE_FIRST):
    """Four consecutive keys starting at key `first` (key i spans kept[i]..kept[i+1]); first = 15 means
    the four middle keys: (len(kept) - 5) // 2."""
    if first == 15:
        first = (len(kept) - 5) // 2 if len(kept) >= 5 else 0
    if len(kept) < first + 5:
        return None
    return [(kept[first + i], kept[first + i + 1]) for i in range(4)]


# ------------------------------------------------------------------ the whole analysis
MODES = {0: "R-V4 smooth+adaptive", 1: "R-V3 norm+NMS+hyst", 2: "R-V1/R-V2 peak_pick"}      # SW7..6 (3 = 2)


def analyse(img, mode=0, sobel=True, hi=HI_DEF, lo=LO_DEF, floor=FLOOR_DEF, k_q=K_Q_DEF, thr_abs=THR_ABS_DEF):
    g, mag, ok = edge_image(img, sobel, smooth=(mode == 0))
    p = profile(g, ok)
    thr_abs = thr_abs * 4 if sobel else thr_abs
    n, m = normalise(p)
    t = local_thr(n, k_q)
    if mode == 0:
        hi_c = np.maximum(t, floor)
        lo_c = np.maximum(t - (t >> 2), floor)          # weak peaks: 3/4 of the local threshold
        found = hysteresis(n, hi_c, lo_c, GAP_RV4)
    elif mode == 1:
        found = hysteresis(n, np.full(W, hi), np.full(W, lo), GAP_RV3)
    else:                                               # R-V1 (1-D) / R-V2 (Sobel): one absolute threshold
        found = peak_pick(p, thr_abs, GAP_RV4)
    return dict(p=p, n=n, max=m, t=t, found=found, mag=mag, g=g, ok=ok)


def report(name, found, truth, tol=3):
    hits = sum(any(abs(f - t) <= tol for f in found) for t in truth)
    extra = sum(not any(abs(f - t) <= tol for t in truth) for f in found)
    print(f"{name:44s} found {len(found):2d}  true {len(truth):2d}  matched {hits:2d}  spurious {extra:2d}")
    return hits, extra


if __name__ == "__main__":
    d = sys.argv[1] if len(sys.argv) > 1 else "memory"
    for pic in range(3):
        if not os.path.exists(f"{d}/piano{pic}.hex"):
            continue
        img, truth = load(pic, d)
        for mode in range(3):
            for sob in (True, False):
                r = analyse(img, mode, sob)
                kept, s = lattice(r["found"])
                report(f"piano{pic} {MODES[mode]:22s} {'Sobel' if sob else '1-D  '}", r["found"], truth)
        r = analyse(img, 0, True)
        kept, s = lattice(r["found"])
        print(f"   R-V4 found {r['found']}\n   lattice kept {kept} (spacing {s}), lanes {lanes(kept)}")
