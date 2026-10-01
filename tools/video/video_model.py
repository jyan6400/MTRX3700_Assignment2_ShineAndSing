#!/usr/bin/env python3
"""The Assignment 2 video pipeline, step by step, on synthetic piano pictures (320x240 8-bit grey, as the
board stores them). Every function is the float twin of a hardware block in the barcode mini-project or a
step of the spec:

  conv3 / sobel_mag       conv3x3.sv with the Sobel (and smoothing) tables
  profile                 col_profile.sv (rows Y0..Y1 only)
  pick_fixed              the simplest picker: every column above a fixed threshold
  pick_spaced             normalised profile, local maxima, min_gap merge (peak_pick.sv)
  adaptive_threshold      a threshold that follows the picture: k x the local mean
  template_fit            keep only the boundaries that sit on the key lattice

Reuse: from video_model import *        (the notebook imports these)
"""
import numpy as np

W, H = 320, 240
rng = np.random.default_rng(37)

# ------------------------------------------------------------------ synthetic pianos
def piano(n_white=10, key_w=None, gap=3, white=225, black=25, bg=170, gapc=45, top=40, bottom=210, black_h=0.6,
          start_note=0, jitter=0.0):
    """A keyboard: n_white white keys separated by dark gaps, black keys between them in the 2-3 pattern."""
    img = np.full((H, W), bg, dtype=float)
    key_w = key_w or (W - 20) // n_white
    x0 = (W - n_white * key_w) // 2
    edges = [x0 + i * key_w + int(rng.uniform(-jitter, jitter) * key_w) for i in range(n_white + 1)]
    img[top:bottom, edges[0]:edges[-1]] = gapc            # the dark gaps between white keys
    for i in range(n_white):
        img[top:bottom, edges[i] + (gap + 1) // 2: edges[i + 1] - gap // 2] = white
    # black keys: pattern over C D E F G A B -> black after C, D, F, G, A (not E, B)
    has_black = [True, True, False, True, True, True, False]
    bw = int(key_w * 0.55); bh = int((bottom - top) * black_h)
    blacks = []
    for i in range(n_white - 1):
        if has_black[(i + start_note) % 7]:
            cx = edges[i + 1]
            img[top:top + bh, cx - bw // 2: cx + bw // 2] = black; blacks.append(cx)
    return img, edges, blacks

def photo_like(img, gradient=0.5, noise=6, shadow=None):
    """Lighting gradient across the width, sensor noise, optional dark diagonal band (a cable/shadow)."""
    x = np.linspace(1 - gradient, 1, W)[None, :]
    out = img * x + rng.normal(0, noise, img.shape)
    if shadow is not None:
        xs, wd = shadow
        for y in range(H):
            cx = xs + int(0.02 * y)                      # a nearly vertical shadow: a cable, a stand
            out[y, max(0, cx - wd):cx + wd] *= 0.5
    return np.clip(out, 0, 255)


# ------------------------------------------------------------------ the processing steps
SOBEL_X = np.array([[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]], dtype=float)
SOBEL_Y = SOBEL_X.T
GAUSS = np.array([[1, 2, 1], [2, 4, 2], [1, 2, 1]], dtype=float) / 16

def grad1d(img):
    """The 1-D difference |p[x] - p[x-1]| along each row (hdiff.sv). No vertical averaging."""
    g = np.zeros_like(img); g[:, 1:] = np.abs(img[:, 1:] - img[:, :-1]); return g

def pick_runs(prof, thr, min_gap=8):
    """Every run of consecutive columns above thr is one boundary (its centre); runs closer than min_gap merge (pick_runs.sv)."""
    above = prof > thr; out = []; i = 0
    while i < W:
        if above[i]:
            j = i
            while j < W and above[j]: j += 1
            c = (i + j - 1) // 2
            if not (out and c - out[-1] < min_gap): out.append(c)
            i = j
        else: i += 1
    return out

def pick_nms_hyst(prof_n, hi=0.5, lo=0.25, min_gap=8):
    """On the normalised profile, keep local maxima (non-maximum suppression) above lo, accept a peak
    if it is above hi or within min_gap of one that is (hysteresis); merge peaks closer than min_gap."""
    peaks = [c for c in range(1, W - 1) if prof_n[c] >= prof_n[c - 1] and prof_n[c] >= prof_n[c + 1] and prof_n[c] > lo]
    strong = [c for c in peaks if prof_n[c] > hi]
    out = []
    for c in peaks:
        if prof_n[c] > hi or any(abs(c - s) <= min_gap for s in strong):
            if out and c - out[-1] < min_gap:
                if prof_n[c] > prof_n[out[-1]]: out[-1] = c
            else: out.append(c)
    return out

def conv3(img, k):
    p = np.pad(img, 1, mode="edge"); out = np.zeros_like(img)
    for dy in range(3):
        for dx in range(3):
            out += k[dy, dx] * p[dy:dy + H, dx:dx + W]
    return out

def sobel_mag(img, smooth=False):
    src = conv3(img, GAUSS) if smooth else img
    gx, gy = conv3(src, SOBEL_X), conv3(src, SOBEL_Y)
    return np.abs(gx), np.abs(gy), np.sqrt(gx ** 2 + gy ** 2)

def profile(gx, y0=0, y1=H):
    return gx[y0:y1].sum(axis=0)

def pick_fixed(prof, thr):
    """Every column above a fixed threshold is a boundary (runs merged to their centre)."""
    above = prof > thr; cols = []; i = 0
    while i < W:
        if above[i]:
            j = i
            while j < W and above[j]: j += 1
            cols.append((i + j - 1) // 2); i = j
        else: i += 1
    return cols

def pick_spaced(prof_n, thr, min_gap):
    """A normalised profile, a threshold, then peaks at least min_gap apart (hysteresis: keep the larger)."""
    cand = [c for c in range(1, W - 1) if prof_n[c] > thr and prof_n[c] >= prof_n[c - 1] and prof_n[c] >= prof_n[c + 1]]
    out = []
    for c in cand:
        if out and c - out[-1] < min_gap:
            if prof_n[c] > prof_n[out[-1]]: out[-1] = c
        else: out.append(c)
    return out

def adaptive_threshold(prof_n, win=25, k=2.5):
    """A threshold that follows the picture: k x the local mean (a moving average), like the gate's noise floor."""
    kernel = np.ones(win) / win
    local = np.convolve(prof_n, kernel, mode="same")
    return k * local

def template_fit(bounds, n_white_expected=None):
    """Find the dominant spacing, keep the boundaries that sit on the lattice, drop the rest."""
    b = np.array(bounds)
    if len(b) < 3: return list(b), None
    d = np.diff(b); s = np.median(d)
    keep = [b[0]]
    for x in b[1:]:
        if abs((x - keep[-1]) - s) < 0.25 * s: keep.append(x)
        elif (x - keep[-1]) > 1.5 * s:            # a missing boundary: accept and note the gap
            keep.append(x)
    return keep, s

Y0, Y1 = 40 + int(170 * 0.6) + 6, 205     # rows below the black keys: white keys only
def run(img, smooth=False, adaptive=False, min_gap=10, thr_fixed=None, thr_norm=0.35):
    gx, gy, mag = sobel_mag(img, smooth)
    prof = profile(gx, Y0, Y1)
    prof_n = prof / prof.max()
    if thr_fixed is not None:
        return prof, prof_n, pick_fixed(prof, thr_fixed), None
    if adaptive:
        thr = adaptive_threshold(prof_n)
        cand = [c for c in range(1, W - 1) if prof_n[c] > thr[c] and prof_n[c] >= prof_n[c - 1] and prof_n[c] >= prof_n[c + 1]]
        out = []
        for c in cand:
            if out and c - out[-1] < min_gap:
                if prof_n[c] > prof_n[out[-1]]: out[-1] = c
            else: out.append(c)
        return prof, prof_n, out, thr
    return prof, prof_n, pick_spaced(prof_n, thr_norm, min_gap), None


def report(name, found, truth, tol=3):
    """How many true boundaries were found (within tol px) and how many spurious ones were added."""
    hits = sum(any(abs(f - t) <= tol for f in found) for t in truth)
    extra = sum(not any(abs(f - t) <= tol for t in truth) for f in found)
    print(f"{name:42s} found {len(found):2d}  true {len(truth):2d}  matched {hits:2d}  spurious {extra:2d}")
    return hits, extra

def demo_images(noise2=45):
    """The three pictures the notebook uses: the supplied piano, a second (grainy) piano, and a photo-like one."""
    img1, e1, b1 = piano(n_white=10, key_w=30, white=230)
    img2, e2, b2 = piano(n_white=13, key_w=22, white=185, bg=120, gapc=90, start_note=3)
    img2 = np.clip(img2 + np.random.default_rng(3).normal(0, noise2, img2.shape), 0, 255)
    img3 = photo_like(img1, gradient=0.8, noise=7, shadow=(75, 4))
    return (img1, e1, b1), (img2, e2, b2), (img3, e1, b1)
