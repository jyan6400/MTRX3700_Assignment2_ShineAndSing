#!/usr/bin/env python3
"""Train the classifier's template ROM from SignalTap captures (PROVIDED for A2).

    python3 train_templates.py templates.hex ee.csv ah.csv oo.csv aw.csv [--nt 4] [--rho 0.9] [--holdout 0.3]

One SignalTap export per vowel (File > Export, Comma Separated Values, radix Hexadecimal), in lane order:
class 0 first. Each capture holds the classifier's input, one row per stored sample:

    feature        the bus at the classifier's input: D words of FW bits. Quartus exports a grouped bus as one
                   fixed-width column in the chosen radix (`...|feature[0][0..15]` at D = 1) followed by one
                   column per bit; all of that is understood, as is a flat `feature[127..0]` or bits alone
    feature_valid  optional: rows where it is 0 are skipped
    enable         optional (the gate): rows where it is 0 are skipped

so a capture with a storage qualifier (only frames with the gate open are stored) and a plain capture (every
clock, mostly idle) both work; the first is the one to use. One capture for all four vowels also works, with
the vowel on two switches while you speak: --label-col "SW[7..6]" (the column name as exported).

Writes templates.hex (one packed word per template, class 0's NT templates first) and templates.svh (the
localparam that classifier.sv includes), NT templates per class from k-means on the sum of absolute
differences. Then a held-out fraction of each class's frames is scored against the templates with the same
rule the hardware uses, and the confusion matrix and reject rate are printed: your first look at how the rung
you are on is doing."""
import argparse, sys, csv, re, collections
import numpy as np

# ----------------------------------------------------------------------------- reading a SignalTap export
# The layout Quartus 18.1 writes (File > Export > .csv), from a real capture of the classifier's input:
#
#   Groups:
#   classifier:u_clf|feature[0][0..15] =, classifier:u_clf|feature[0][15], ..., classifier:u_clf|feature[0][0],  hex
#
#   Data:
#   time unit: s, classifier:u_clf|feature[0][0..15], classifier:u_clf|feature[0][15], ..., classifier:u_clf|feature_valid, classifier:u_clf|enable,
#   0, XXXX, X, X, ..., X, X,
#   17, 0019, 0, 0, ..., 1, 1,
#
# so: a grouped bus is one fixed-width column in the chosen radix followed by one column per bit; buffer positions
# never filled (the acquisition stopped early) are X in every column; fields are separated by ", ".
# At D = 24 the bus is `feature[23..0][15..0]` and the bits `feature[0][0]`, `feature[0][1]`, ... `feature[23][15]`.
# The group's hex column follows the ORDER THE BITS WERE LISTED IN when the group was made, which the GUI may make
# ascending (then every 16-bit chunk comes out bit-reversed). The per-bit columns are unambiguous, so they are read
# whenever they are present, and the group's hex only when they are not.
def _tail(name):
    """'classifier:u_clf|feature[0][0..15]' -> 'feature[0][0..15]' (the node's own name, hierarchy stripped)"""
    return name.strip().strip('"').split("|")[-1].split(":")[-1].strip()

def _parse_name(tail, feature):
    """feature column? -> (kind, element, width_or_bit): kind 'bus' (a multi-bit column) or 'bit'.
    feature[23..0][15..0] is a bus of 24 x 16 bits (element None); feature[0][0..15] a bus of 16 bits, element 0;
    feature[5][3] the bit 3 of element 5; feature[83] the bit 83 of a flat bus."""
    m = re.fullmatch(re.escape(feature) + r"((?:\[[^\]]+\])*)", tail)
    if not m: return None
    groups = re.findall(r"\[([^\]]+)\]", m.group(1))
    if not groups: return ("bus", None, None)
    ranges = [g for g in groups if ".." in g]; ints = [g for g in groups if re.fullmatch(r"\d+", g)]
    if len(ranges) + len(ints) != len(groups): return None
    if ranges:
        width = 1
        for g in ranges: lo, hi = (int(v) for v in g.split("..")); width *= abs(hi - lo) + 1
        element = int(ints[0]) if (ints and groups[0] == ints[0] and len(ranges) == 1) else None
        return ("bus", element, width)
    if len(ints) == 2: return ("bit", int(ints[0]), int(ints[1]))
    if len(ints) == 1: return ("bit", None, int(ints[0]))
    return None

def _value(v, radix):
    """one field -> int, or None for X/Z (an unfilled buffer position)"""
    v = v.strip().strip('"').replace("_", "").replace(" ", "")
    for pre in ("0x", "0X"):
        if v.startswith(pre): v = v[len(pre):]
    if v == "" or re.search(r"[xXzZ]", v): return None
    try:
        return int(v, 16 if radix == "hex" else 2 if radix == "bin" else 10)
    except ValueError:                                           # a repeated header line (captures appended by a bench): no data
        return None

def _radix_of(vals, width, radix, path, name):
    if radix != "auto": return radix
    vals = [v for v in vals if not re.search(r"[xXzZ]", v) and v]
    junk = [v for v in vals if not re.fullmatch(r"(0[xX])?[0-9a-fA-F_ ]+", v)]
    if junk and len(junk) < len(vals): vals = [v for v in vals if v not in junk]   # repeated header lines, not values
    if not vals: return "hex"
    if all(re.fullmatch(r"[01]+", v) for v in vals) and width and all(len(v) == width for v in vals): return "bin"
    if all(re.fullmatch(r"[0-9a-fA-F]+", v) for v in vals):
        if any(re.search(r"[a-fA-F]", v) for v in vals) or (width and all(len(v) == (width + 3) // 4 for v in vals)): return "hex"
        if len(set(len(v) for v in vals)) > 1: return "dec"
        return "hex"
    sys.exit(f"{path}: cannot tell the radix of column '{name}' (values like {vals[:3]}): export with the bus shown in "
             f"Hexadecimal, or pass --radix hex|dec|bin")

def read_capture(path, feature="feature", fw=16, radix="auto", label_col=None):
    """-> (list of int arrays of D features, list of labels or None, D). A SignalTap export, or any CSV with a header
    naming the columns (what a bench $fwrites: "feature, feature_valid, enable" then one hex word per frame)."""
    rows = [r for r in csv.reader(open(path, newline="", encoding="utf-8", errors="replace"))]
    start = next((i + 1 for i, r in enumerate(rows) if r and r[0].strip().lower().startswith("data:")), 0)
    hdr = next((i for i in range(start, len(rows)) if any(_parse_name(_tail(c), feature) for c in rows[i])), None)
    if hdr is None:
        sys.exit(f"{path}: no column named '{feature}' (or '{feature}[...]') in any row. Add the classifier's feature bus to the "
                 f"SignalTap node list (or pass --feature with the name you used).")
    names = [_tail(c) for c in rows[hdr]]
    data = [r for r in rows[hdr + 1:] if len(r) >= len(names) - 1 and any(c.strip() for c in r)]
    data = [r + [""] * (len(names) - len(r)) for r in data]
    parsed = {i: _parse_name(n, feature) for i, n in enumerate(names)}
    buses = {i: p for i, p in parsed.items() if p and p[0] == "bus"}
    bits = {i: p for i, p in parsed.items() if p and p[0] == "bit"}
    def col(name):
        cands = [i for i, n in enumerate(names) if n == name]
        return cands[0] if cands else None
    keep = [c for c in (col("feature_valid"), col("enable"), col("voice_active")) if c is not None]
    words = []                                                  # one int per row: the packed bus, or None
    if bits:                                                    # the per-bit columns: unambiguous, preferred
        pos = {}                                                # column -> bit position in the packed bus
        for i, (_, elem, b) in bits.items(): pos[i] = b + (fw * elem if elem is not None else 0)
        D = max(1, (max(pos.values()) + 1 + fw - 1) // fw)
        for r in data:
            w, ok = 0, True
            for i, b in pos.items():
                v = r[i].strip()
                if v not in ("0", "1"): ok = False; break
                w |= int(v) << b
            words.append(w if ok else None)
    elif buses:
        by_elem = {}
        for i, (_, elem, width) in buses.items(): by_elem.setdefault(elem, (i, width))
        if None in by_elem and len(by_elem) == 1:               # the whole packed bus as one column
            ci, width = by_elem[None]; vals = [r[ci].strip() for r in data]
            rdx = _radix_of(vals, width, radix, path, names[ci])
            if width is None:
                good = [v for v in vals if v and not re.search(r"[xXzZ]", v)]
                width = max(len(v) for v in good) * (4 if rdx == "hex" else 1) if good else fw
                if rdx == "dec": width = max(int(v).bit_length() for v in good)
            D = max(1, round(width / fw)); words = [_value(r[ci], rdx) for r in data]
        else:                                                   # one column per element: feature[i][0..15]
            elems = sorted(e for e in by_elem if e is not None); D = max(elems) + 1
            cols = {e: by_elem[e] for e in elems}
            rdx = {e: _radix_of([r[ci].strip() for r in data], w, radix, path, names[ci]) for e, (ci, w) in cols.items()}
            for r in data:
                w, ok = 0, True
                for e, (ci, _) in cols.items():
                    v = _value(r[ci], rdx[e])
                    if v is None: ok = False; break
                    w |= v << (fw * e)
                words.append(w if ok else None)
    else:
        sys.exit("unreachable")
    labels = None
    if label_col is not None:
        li = col(_tail(label_col))
        if li is None: sys.exit(f"{path}: no column '{label_col}' (columns: {', '.join(n for n in names if n)})")
        labels = [_value(r[li], "hex") for r in data]
    feats, labs = [], []; n_data = sum(w is not None for w in words)
    for k, (r, w) in enumerate(zip(data, words)):
        if w is None or any(r[c].strip() != "1" for c in keep): continue
        if labels is not None and labels[k] is None: continue
        feats.append(np.array([(w >> (fw * i)) & ((1 << fw) - 1) for i in range(D)], dtype=float))
        if labels is not None: labs.append(labels[k])
    gates = " and ".join(names[c] for c in keep) or "(no feature_valid/enable columns: every row kept)"
    print(f"{path}: {len(data)} rows, {n_data} with data, {len(feats)} kept where {gates} = 1, D = {D}")
    if n_data and not feats:
        print(f"   none of the rows with data has {gates} = 1: the storage qualifier was probably not set to feature_valid = 1 and\n"
              f"   enable = 1 (the rows are then consecutive clocks, on which the frame pulse is almost never high). Set it, or if\n"
              f"   you meant to keep every row, leave those two nodes out of the capture.")
    return feats, (labs if labels is not None else None), D

# ----------------------------------------------------------------------------- the trainer
def kmeans_sad(F, nt, seed=0, iters=15):
    rng = np.random.default_rng(seed)
    if len(F) <= nt: return F.copy()
    cen = F[rng.choice(len(F), nt, replace=False)]
    for _ in range(iters):
        a = np.abs(F[:, None, :] - cen[None, :, :]).sum(axis=2).argmin(axis=1)
        for t in range(nt):
            if np.any(a == t): cen[t] = np.median(F[a == t], axis=0)   # the median minimises the SAD
    return cen

def write_svh(path, rows, D, fw=16):
    """templates.svh: a localparam array for classifier.sv (row 0 = class 0 template 0, ...)."""
    hexw = (fw + 3) // 4
    lines = ["// generated by train_templates.py: %d templates, D=%d, FW=%d. Rows: class 0's NT templates, then class 1's, ..." % (len(rows), D, fw),
             "localparam logic [%d:0][%d:0] TEMPLATES [0:%d] = '{" % (D - 1, fw - 1, len(rows) - 1)]
    for i, row in enumerate(rows):
        words = ", ".join("%d'h%0*x" % (fw, hexw, int(round(v))) for v in list(row)[::-1])   # element [D-1] first
        lines.append("    '{" + words + "}" + ("," if i < len(rows) - 1 else ""))
    lines.append("};")
    open(path, "w").write("\n".join(lines) + "\n")

def classify(f, T, rho):
    """the hardware's rule: nearest template by SAD; reject when the runner-up class is almost as near"""
    d = {c: np.abs(T[c] - f).sum(axis=1).min() for c in T}
    best = min(d, key=d.get); d1 = d[best]; d2 = min([v for c, v in d.items() if c != best] or [np.inf])
    return (None if (d2 > 0 and d1 / d2 > rho) else best), d1, d2

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("out", help="templates.hex to write (templates.svh is written beside it)")
    ap.add_argument("captures", nargs="+", help="SignalTap .csv exports, one per class in lane order (or one with --label-col)")
    ap.add_argument("--nt", type=int, default=4, help="templates per class (classifier NT)")
    ap.add_argument("--rho", type=float, default=0.9, help="reject when d1/d2 > rho (classifier RHO_NUM/RHO_DEN)")
    ap.add_argument("--holdout", type=float, default=0.3, help="fraction of each class's frames kept back for the score")
    ap.add_argument("--fw", type=int, default=16, help="bits per feature (classifier FW)")
    ap.add_argument("--feature", default="feature", help="the bus's name in the export")
    ap.add_argument("--radix", default="auto", choices=["auto", "hex", "dec"], help="radix the bus was exported in")
    ap.add_argument("--label-col", default=None, help="one capture for all classes: the column holding the class (e.g. \"SW[7..6]\")")
    a = ap.parse_args()
    by = collections.defaultdict(list); D = None
    for k, path in enumerate(a.captures):
        feats, labs, d = read_capture(path, a.feature, a.fw, a.radix, a.label_col)
        if D is not None and d != D: sys.exit(f"{path}: D = {d} but the first capture had D = {D}: were they taken from the same build?")
        D = d
        for i, f in enumerate(feats): by[labs[i] if labs is not None else k].append(f)
        if labs is not None: print(f"   labels {sorted(set(labs))}")
    classes = sorted(by)
    if not classes: sys.exit("no frames at all: nothing to train on")
    if len(classes) < 2: print("warning: only one class: the templates are written, but the score below means nothing until there are two")
    for c in classes:
        if len(by[c]) < 3 * a.nt: print(f"warning: class {c} has only {len(by[c])} frames; hold the vowel until the buffer fills")
    rng = np.random.default_rng(1); train = {}; test = []
    for c in classes:
        F = np.array(by[c]); idx = rng.permutation(len(F)); nh = int(len(F) * a.holdout)
        test += [(c, F[i]) for i in idx[:nh]]; train[c] = F[idx[nh:]] if nh < len(F) else F
    T = {c: kmeans_sad(train[c], a.nt) for c in classes}
    all_rows = []
    with open(a.out, "w") as f:
        for c in classes:
            rows = T[c]
            if len(rows) < a.nt: rows = np.vstack([rows] + [rows[-1:]] * (a.nt - len(rows)))
            for row in rows: f.write("".join(f"{int(round(v)):0{(a.fw + 3) // 4}x}" for v in row[::-1]) + "\n"); all_rows.append(row)
    svh = a.out.rsplit(".", 1)[0] + ".svh"
    write_svh(svh, all_rows, D, a.fw)
    print(f"wrote {a.out} and {svh}: {len(classes)} classes x {a.nt} templates x D={D}")
    M = np.zeros((len(classes), len(classes) + 1), int)
    for c, x in test:
        p, _, _ = classify(x, T, a.rho); M[classes.index(c), classes.index(p) if p is not None else -1] += 1
    print("held-out confusion (rows: the vowel said; columns: the vowel named, then rejected):")
    for c, row in zip(classes, M): print(f"  class {c}: " + " ".join(f"{v:4d}" for v in row))
    acc = np.trace(M[:, :-1]) / max(M[:, :-1].sum(), 1); rej = M[:, -1].sum() / max(M.sum(), 1)
    print(f"accuracy on accepted frames {acc*100:.1f}%, rejected {rej*100:.1f}%  (chance is {100/len(classes):.0f}%)")

if __name__ == "__main__":
    main()

