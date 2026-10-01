#!/usr/bin/env python3
"""The Assignment 2 audio pipeline, step by step, on real vowels (Hillenbrand et al. 1995).

Models exactly what the hardware does at each rung (the gate, then the feature vector: peak bin, 8 band
energies, the same divided by their total, log-Mel; MFCC as the Extra), then trains the same
nearest-template classifier the FPGA runs (sum of absolute differences, NT templates per class, a vote,
a reject rule) and reports confusion matrices for the situations the demo probes create:

  same voice        enrol on the first half of a speaker's frames, test on the second half
  other voice/sex   templates from one speaker (or a group), tested on others
  "twice as loud"   the test recordings scaled by a constant (probe 5, and "from twice the distance", probe 6)
  "sing it higher"  templates from men, tested on women and children (higher pitch)

Run:  python3 audio_model.py            (writes results/*.png, results/summary.md)
Data: the recordings are read where they lie, never unzipped: $H95_DATA, then /course/h95_data (Ed mounts
      the dataset there, read-only), then /course, then data/ beside this file, each holding h95_wav/*.wav or
      h95.zip, and timedata.dat (the vowel times) beside them. See source().
Reuse: from audio_model import *        (the notebook imports these functions)
"""
import io, os, sys, zipfile, wave, collections, json
import numpy as np
from scipy.signal import resample_poly

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data"); WAV = os.path.join(DATA, "h95_wav"); RES = os.path.join(HERE, "results")
FS_IN, FS = 16000, 12000                 # the recordings are 16 kHz; the board works at 12 kHz
N, HOP = 1024, 128                       # FFT length; the hop used for MODELLING (many frames per 0.4 s recording).
                                         # The hardware hops N, or N/2 when frames overlap; overlap only changes how often a frame arrives.
VOWELS = {"ee": "iy", "ah": "ah", "oo": "uw", "aw": "aw"}      # our four, in Hillenbrand's names
CLASSES = list(VOWELS)

# --------------------------------------------------------------------------- data
H95_URL = os.environ.get("H95_URL", "")     # a direct link to h95.zip, if the course gives you one: download() uses it
ROOTS = (os.environ.get("H95_DATA"), "/course/h95_data", "/course", DATA)   # Ed mounts /course read-only

def download(url=None):
    """Fetch h95.zip (22 MB) into data/ beside this file from `url` (or $H95_URL). Not called automatically: on Ed the
    dataset is mounted, and on your own machine the Canvas link is the reliable source (the public mirrors of the
    Hillenbrand data have 404ed before now). Usage:  python3 -c "import audio_model; audio_model.download('https://...')" """
    path = os.path.join(DATA, "h95.zip")
    if os.path.exists(path): return path
    url = url or H95_URL
    if not url: raise ValueError("download() needs the link to h95.zip (the Canvas page has it): download(url) or $H95_URL")
    os.makedirs(DATA, exist_ok=True)
    import urllib.request
    print(f"downloading the Hillenbrand vowel recordings (22 MB) from {url} ...")
    urllib.request.urlretrieve(url, path)
    return path

_SRC = None
def source():
    """(kind, path, root) for the recordings: a folder of .wav files ("dir") or the dataset zip ("zip"),
    whichever this machine has. Searched in $H95_DATA, then /course/h95_data (Ed's read-only mount),
    then /course itself, then data/ beside this file. Nothing is ever unzipped: a student workspace holds
    20 MB and the mount is read only, so the zip is read in place (see index())."""
    global _SRC
    if _SRC is None:
        for root in filter(None, ROOTS):
            for d in (os.path.join(root, "h95_wav"), root):
                if os.path.isdir(d) and sum(f.endswith(".wav") for f in os.listdir(d)) > 1000:
                    _SRC = ("dir", d, root); return _SRC
            if os.path.exists(os.path.join(root, "h95.zip")):
                _SRC = ("zip", os.path.join(root, "h95.zip"), root); return _SRC
        raise FileNotFoundError(
            "\n\nThe vowel recordings (Hillenbrand 1995) are not on this machine. Looked for h95_wav/*.wav or h95.zip in:\n    "
            + "\n    ".join(filter(None, ROOTS)) + "\n"
            "On Ed they are mounted at /course/h95_data and this does not happen. Elsewhere: download h95.zip (22 MB) from the\n"
            "Canvas page next to the assignment and put it in " + DATA + " (or set $H95_DATA to the folder that holds it).\n")
    return _SRC

_INDEX = None
def index():
    """{name: bytes-reader} for all 1668 recordings. A folder is listed; a zip is opened once and its
    three nested zips (men, women, kids) are held in memory, about 21 MB, and read from in place."""
    global _INDEX
    if _INDEX is None:
        kind, path, _ = source()
        if kind == "dir":
            _INDEX = {f[:-4].lower(): (lambda f=f: open(os.path.join(path, f), "rb").read())
                      for f in os.listdir(path) if f.endswith(".wav")}
        else:
            _INDEX, z = {}, zipfile.ZipFile(path)
            for name in z.namelist():
                if name.endswith(".zip"):
                    inner = zipfile.ZipFile(io.BytesIO(z.read(name)))
                    for f in inner.namelist():
                        if f.lower().endswith(".wav"):
                            _INDEX[os.path.basename(f).lower()[:-4]] = (lambda i=inner, f=f: i.read(f))
    return _INDEX

def unpack():
    """Kept because the notebooks open with it. Nothing is unpacked any more: this only finds the
    recordings and the vowel times, so that a missing dataset is reported here and not five cells later."""
    index(); nucleus_times()
    return source()[1]

def timedata_text():
    """The dataset's timedata.dat, from beside the recordings or from inside the zip. Never written
    anywhere: on Ed the data sits on a read-only mount."""
    kind, path, root = source()
    for cand in (os.path.join(root, "timedata.dat"), os.path.join(path if kind == "dir" else root, "timedata.dat")):
        if os.path.exists(cand): return open(cand, "rb").read().decode("latin-1")
    for cand in ([path] if kind == "zip" else []) + [os.path.join(root, "h95.zip"), os.path.join(DATA, "h95.zip")]:
        if os.path.exists(cand): return zipfile.ZipFile(cand).read("timedata.dat").decode("latin-1")
    raise FileNotFoundError(f"timedata.dat (the vowel nucleus times) is not in {root}, and nor is h95.zip")

_NUCLEUS = None
def nucleus_times():
    """{name: (start_ms, end_ms)} of the vowel nucleus, from the dataset's timedata.dat (the recordings
    are whole words, h-V-d; only the vowel in the middle is what a singer holds)."""
    global _NUCLEUS
    if _NUCLEUS is None:
        times = {}                                        # filled first, cached last: a failure here must not
        for line in timedata_text().splitlines():         # leave an empty dict behind, which would silently
            parts = line.split()                          # stop every recording being trimmed
            if len(parts) >= 3 and parts[0][0] in "mwbg" and parts[0][1:3].isdigit():
                try: times[parts[0].lower()] = (float(parts[1]), float(parts[2]))
                except ValueError: pass
        _NUCLEUS = times
    return _NUCLEUS

def load(name, trim=True):
    """name like 'm01iy' -> float samples at 12 kHz in [-1, 1], trimmed to the vowel nucleus"""
    w = wave.open(io.BytesIO(index()[name]()))
    x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(float) / 32768.0
    if trim and name in nucleus_times():
        a, b = nucleus_times()[name]; x = x[int(a * FS_IN / 1000): int(b * FS_IN / 1000)]
    return resample_poly(x, 3, 4)        # 16 kHz -> 12 kHz: the decimation the Lesson 4 FIR does

def speakers(group=None):
    names = sorted(set(n[:3] for n in index()))
    return [s for s in names if group is None or s[0] in group]

def recording_ok(spk, vowel):
    return f"{spk}{VOWELS[vowel]}" in index()

# --------------------------------------------------------------------------- the processing steps
def frames(x, hop=N):
    """cut into N-sample frames (rectangular: the handout). hop=N/2 overlaps them by half."""
    if len(x) < N: x = np.pad(x, (0, N - len(x)))
    starts = range(0, len(x) - N + 1, hop)
    return np.stack([x[s:s + N] for s in starts])

def level_db_hw(sv):
    """20*log10(s) re 1 LSB as the hardware shows it: the leading-one position of s is log2 to the integer, the
    three bits below it are the fraction (eighths), and 6.02 dB per bit is taken as 3/4 dB per eighth. 0..99."""
    if sv < 1: return 0
    e = int(np.floor(np.log2(sv))); frac3 = int(sv * 8 / 2 ** e) - 8          # 0..7
    return min(99, ((e * 8 + frac3) * 3) >> 2)

def gate(x, K=4.0, alpha_sh=8, beta_sh=15, fall_sh=11, hold_sh=4, db_hold_sh=13, init_frac=1 / 8):
    """The gate as the RTL does it, on 16-bit samples at 48 kHz (x in [-1, 1] is scaled to LSBs).
      s   the level: a fast leaky average of |x|, 2^-alpha_sh per sample (~5 ms at 48 kHz)
      nf  the noise floor, a MINIMUM tracker: follows s down quickly (2^-fall_sh, ~40 ms), up slowly
          (2^-beta_sh, ~0.7 s), and 2^hold_sh times slower still while the gate is open, so that a held note
          cannot lift the floor and close the gate on itself. Starts at init_frac of full scale: closed until
          the room has been heard.
      open  s > K * nf (K = 4 is 12 dB: the margin)
      level_db  what HEX1..0 show (level_db_hw), updated every 2^db_hold_sh samples (0.17 s) so it can be read.
    Every step is a subtract, a shift and an add: no multiplier, no divider, no logarithm."""
    a = np.abs(np.asarray(x, dtype=float)) * 32768.0
    n = len(a); s = np.zeros(n); nf = np.zeros(n); opn = np.zeros(n, bool); db = np.zeros(n, int)
    sv = 0.0; nv = 32768.0 * init_frac; shown = 0
    for i in range(n):
        o = sv > K * nv; opn[i] = o                                       # from the registers as they stand
        s_new = sv + (a[i] - sv) * 2.0 ** -alpha_sh
        if sv < nv: nv += (sv - nv) * 2.0 ** -fall_sh                     # quieter: drop quickly
        elif o:     nv += (sv - nv) * 2.0 ** -(beta_sh + hold_sh)          # voice: barely move
        else:       nv += (sv - nv) * 2.0 ** -beta_sh                      # louder room: learn slowly
        sv = s_new; s[i] = sv; nf[i] = nv
        if i % 2 ** db_hold_sh == 0: shown = level_db_hw(sv)
        db[i] = shown
    return s, nf, db, opn

def hamming(n=N): return 0.54 - 0.46 * np.cos(2 * np.pi * np.arange(n) / (n - 1))

def power_spectrum(fr, window=True):
    w = hamming() if window else 1.0
    X = np.fft.rfft(fr * w, axis=-1)
    return np.abs(X) ** 2                              # |X_k|^2, k = 0..512

def peak_bin(P):                      # D = 1
    return np.argmax(P[:, :N // 2], axis=1)[:, None].astype(float)

def band_energies(P, nb=8, normalise=None):
    """D = nb: the energy in nb equal bands of 64 bins (Credit). normalise="total" divides each frame's bands by their
    sum (Distinction); "pow2" divides by the largest power of two below the sum instead, which is a shift by the
    total's leading-one position in hardware (no divider), exact to within a factor of two."""
    edges = np.linspace(0, N // 2, nb + 1).astype(int)
    E = np.stack([P[:, edges[i]:edges[i + 1]].sum(axis=1) for i in range(nb)], axis=1)
    tot = np.maximum(E.sum(axis=1, keepdims=True), 1e-12)
    if normalise == "total": return E / tot
    if normalise == "pow2":  return E / 2.0 ** np.floor(np.log2(tot))
    return E

def hz2mel(f): return 2595 * np.log10(1 + f / 700.0)
def mel2hz(m): return 700 * (10 ** (m / 2595.0) - 1)
def mel_bank(nf=24, fmin=100, fmax=6000):
    m = np.linspace(hz2mel(fmin), hz2mel(fmax), nf + 2); k = np.round(mel2hz(m) * N / FS).astype(int)
    W = np.zeros((nf, N // 2 + 1))
    for j in range(nf):
        lo, c, hi = k[j], k[j + 1], k[j + 2]
        W[j, lo:c] = (np.arange(lo, c) - lo) / max(c - lo, 1); W[j, c:hi] = (hi - np.arange(c, hi)) / max(hi - c, 1)
    return W

def log_mel(P, W=None):               # D = 24, log2, minus the mean
    W = mel_bank() if W is None else W
    L = np.log2(P @ W.T + 1e-9)
    return L - L.mean(axis=1, keepdims=True)

def dct_matrix(nf=24, nc=13):
    return np.array([[np.cos(np.pi * q * (j + 0.5) / nf) for j in range(nf)] for q in range(nc)])

def mfcc(P, W=None, C=None):          # D = 12, c1..c12 (c0 is the mean, already zero)
    L = log_mel(P, W); C = dct_matrix() if C is None else C
    return (L @ C.T)[:, 1:13]

FEATURES = {                                   # the rungs, in order (the notebook's tables use these names)
    "peak bin":      lambda P: peak_bin(P),                          # R-A1 Pass B
    "8 bands":       lambda P: band_energies(P),                     # R-A2 Credit
    "8 bands/total": lambda P: band_energies(P, normalise="total"),  # R-A3 Distinction
    "log-Mel":       lambda P: log_mel(P),                           # R-A4 High Distinction
    "MFCC":          lambda P: mfcc(P),                              # Extras
}
RUNG = {"peak bin": "Pass B", "8 bands": "Credit", "8 bands/total": "Distinction", "log-Mel": "HD", "MFCC": "Extras"}
EXTRA_FEATURES = {                             # variants to try in the model before building them
    "8 bands/pow2":  lambda P: band_energies(P, normalise="pow2"),
}
def feature_fn(name):
    return FEATURES[name] if name in FEATURES else EXTRA_FEATURES[name]

# --------------------------------------------------------------------------- the classifier (as the RTL does it)
def make_templates(feat_by_class, nt=4, seed=0):
    """NT templates per class: k-means with a few iterations (the trainer notebook does the same)."""
    rng = np.random.default_rng(seed); T = {}
    for c, F in feat_by_class.items():
        F = np.asarray(F)
        if len(F) <= nt: T[c] = F.copy(); continue
        cen = F[rng.choice(len(F), nt, replace=False)]
        for _ in range(10):
            d = np.abs(F[:, None, :] - cen[None, :, :]).sum(axis=2); a = d.argmin(axis=1)
            for t in range(nt):
                if np.any(a == t): cen[t] = F[a == t].mean(axis=0)
        T[c] = cen
    return T

def classify(F, T, dmax=np.inf, rho=0.7, M=5):
    """per-frame nearest template with reject, then a majority vote over the last M accepted frames"""
    classes = list(T); raw = []; conf = []
    for f in F:
        d = {c: np.abs(T[c] - f).sum(axis=1).min() for c in classes}
        best = min(d, key=d.get); d1 = d[best]; d2 = min(v for c, v in d.items() if c != best)
        rej = (d1 > dmax) or (d2 > 0 and d1 / d2 > rho)
        raw.append(None if rej else best); conf.append(0.0 if rej else 1 - d1 / max(d2, 1e-9))
    voted = []; recent = collections.deque(maxlen=M)
    for r in raw:
        if r is not None: recent.append(r)
        voted.append(collections.Counter(recent).most_common(1)[0][0] if recent else None)
    return raw, voted, conf

def confusion(y_true, y_pred, classes=CLASSES):
    M = np.zeros((len(classes), len(classes) + 1), dtype=int)   # last column: rejected / undecided
    for t, p in zip(y_true, y_pred):
        M[classes.index(t), classes.index(p) if p in classes else -1] += 1
    return M

def accuracy(M): return np.trace(M[:, :-1]) / max(M.sum(), 1)

# --------------------------------------------------------------------------- experiments
def features_for(spk, vowel, feature, hop=HOP, window=True, gain=1.0):
    """the feature vectors of one recording; gain scales the samples first (x2 = 6 dB louder)"""
    P = power_spectrum(frames(load(f"{spk}{VOWELS[vowel]}") * gain, hop), window)
    return feature_fn(feature)(P)

def experiment(train_spk, test_spk, feature, nt=4, rho=0.7, hop=HOP, split_same=False, window=True, M=5, gain=1.0):
    """Train templates on train_spk's recordings, test on test_spk's, one recording at a time (the
    vote restarts for every recording, as it would for every utterance at the demo).
    split_same: enrol on the first 60 % of each recording's frames and test on the last 40 % (same voice).
    gain: the TEST recordings are scaled by this (2.0 = the same vowel twice as loud; 0.5 = from further away).
    Returns per-frame confusion (rejects in the last column), the per-recording voted confusion
    (the vote at the end of the utterance), and the reject rate."""
    tr = {c: [] for c in CLASSES}
    for c in CLASSES:
        for s in train_spk:
            if not recording_ok(s, c): continue
            F = features_for(s, c, feature, hop, window)
            tr[c].extend(F[: int(len(F) * 0.6)] if split_same else F)
    T = make_templates(tr, nt)
    Mf = np.zeros((4, 5), int); Mv = np.zeros((4, 5), int); nrej = 0; nfr = 0
    for c in CLASSES:
        for s in test_spk:
            if not recording_ok(s, c): continue
            F = features_for(s, c, feature, hop, window, gain)
            F = F[int(len(F) * 0.6):] if split_same else F
            raw, voted, _ = classify(F, T, rho=rho, M=M)
            Mf += confusion([c] * len(raw), raw); nrej += sum(r is None for r in raw); nfr += len(raw)
            Mv += confusion([c], [voted[-1]])
    return Mf, Mv, nrej / max(nfr, 1)

def acc_accepted(M):
    """accuracy among the frames the classifier accepted (did not reject)"""
    return np.trace(M[:, :-1]) / max(M[:, :-1].sum(), 1)

def run_all(n_speakers=20, seed=1, rho=0.7):
    unpack(); os.makedirs(RES, exist_ok=True)
    rng = np.random.default_rng(seed)
    men = [s for s in speakers("m") if all(recording_ok(s, c) for c in CLASSES)]
    women = [s for s in speakers("w") if all(recording_ok(s, c) for c in CLASSES)]
    kids = [s for s in speakers("bg") if all(recording_ok(s, c) for c in CLASSES)]
    men_s = list(rng.choice(men, n_speakers, replace=False)); women_s = list(rng.choice(women, n_speakers, replace=False))
    kids_s = list(rng.choice(kids, n_speakers, replace=False))
    scenarios = {
        "same voice": [("same", [s], [s], 1.0) for s in men_s[:10] + women_s[:10]],
        "same voice, twice as loud": [("same", [s], [s], 2.0) for s in men_s[:10] + women_s[:10]],
        "another man": [("cross", [a], [b], 1.0) for a, b in zip(men_s[:10], men_s[10:20])],
        "a woman (man's templates)": [("cross", [a], [b], 1.0) for a, b in zip(men_s[:10], women_s[:10])],
        "a child (man's templates)": [("cross", [a], [b], 1.0) for a, b in zip(men_s[:10], kids_s[:10])],
        "20 voices enrolled, 20 new": [("cross", men_s[:10] + women_s[:10], men_s[10:20] + women_s[10:20], 1.0)],
    }
    summary = {}
    for feature in FEATURES:
        summary[feature] = {}
        for name, runs in scenarios.items():
            Mf = np.zeros((4, 5), int); Mv = np.zeros((4, 5), int); rej = []
            for kind, tr, te, g in runs:
                f, v, r = experiment(tr, te, feature, split_same=(kind == "same"), rho=rho, gain=g)
                Mf += f; Mv += v; rej.append(r)
            summary[feature][name] = {"frame_all": accuracy(Mf), "frame_accepted": acc_accepted(Mf), "reject": float(np.mean(rej)),
                                   "utterance_voted": accuracy(Mv), "frame_cm": Mf.tolist(), "voted_cm": Mv.tolist()}
            d = summary[feature][name]
            print(f"{feature:22s} | {name:28s} | accepted frames {d['frame_accepted']*100:5.1f}%  rejected {d['reject']*100:4.1f}%  utterance (voted) {d['utterance_voted']*100:5.1f}%")
    json.dump(summary, open(os.path.join(RES, "summary.json"), "w"), indent=1)
    write_summary_md(summary)
    return summary

def write_summary_md(summary):
    lines = ["# Audio features on real vowels (Hillenbrand 1995)", "",
             "Each cell: accuracy on accepted frames % / reject rate % / utterance accuracy after the vote %.", "",
             "| Feature | " + " | ".join(next(iter(summary.values())).keys()) + " |", "|---|" + "---|" * len(next(iter(summary.values())))]
    for feature, d in summary.items():
        lines.append(f"| {RUNG.get(feature, '')}: {feature} | " + " | ".join(f"{v['frame_accepted']*100:.0f} / {v['reject']*100:.0f} / {v['utterance_voted']*100:.0f}" for v in d.values()) + " |")
    lines += ["", "Chance is 25 %. Four vowels: ee, ah, oo, aw. Same voice = first half of each recording enrolled, second half tested.",
              "Templates: 4 per class (k-means), sum-of-absolute-differences, reject if d1/d2 > rho, vote over 5 frames.",
              "Frames of 1024 samples at 12 kHz (85 ms); Hamming window on all but the peak bin; 'twice as loud' scales the test recordings by 2."]
    open(os.path.join(RES, "summary.md"), "w").write("\n".join(lines) + "\n")

# --------------------------------------------------------------------------- figures and the rho sweep
def rho_sweep(rhos=(0.6, 0.7, 0.8, 0.9, 0.95, 1.0), n_speakers=20, seed=1):
    """accuracy on accepted frames and reject rate against rho, per feature, same voice and new voices"""
    unpack(); rng = np.random.default_rng(seed)
    men = [s for s in speakers("m") if all(recording_ok(s, c) for c in CLASSES)]
    women = [s for s in speakers("w") if all(recording_ok(s, c) for c in CLASSES)]
    men_s = list(rng.choice(men, n_speakers, replace=False)); women_s = list(rng.choice(women, n_speakers, replace=False))
    out = {}
    for feature in FEATURES:
        out[feature] = {"same voice": [], "20 voices enrolled, 20 new": []}
        for rho in rhos:
            Mf = np.zeros((4, 5), int); Mv = np.zeros((4, 5), int); rej = []
            for sp in men_s[:10] + women_s[:10]:
                f, v, r = experiment([sp], [sp], feature, split_same=True, rho=rho); Mf += f; Mv += v; rej.append(r)
            out[feature]["same voice"].append((rho, acc_accepted(Mf), float(np.mean(rej)), accuracy(Mv)))
            f, v, r = experiment(men_s[:10] + women_s[:10], men_s[10:20] + women_s[10:20], feature, rho=rho)
            out[feature]["20 voices enrolled, 20 new"].append((rho, acc_accepted(f), r, accuracy(v)))
    return out

def figures(rho=0.9):
    import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
    plt.rcParams.update({"font.size": 8, "svg.fonttype": "none"})
    unpack(); os.makedirs(RES, exist_ok=True)
    def save(fig, name):
        for ext in ("png", "svg", "pdf"): fig.savefig(os.path.join(RES, f"{name}.{ext}"), dpi=200, bbox_inches="tight")
        plt.close(fig)
    # 1. one speaker, four vowels, with each feature
    spk = "m01"; W = mel_bank(); C = dct_matrix()
    fig, axs = plt.subplots(4, 5, figsize=(12, 7))
    for r, c in enumerate(CLASSES):
        P = power_spectrum(frames(load(f"{spk}{VOWELS[c]}"), HOP)); Pm = P.mean(axis=0)
        f = np.arange(N // 2 + 1) * FS / N
        axs[r, 0].plot(f[:300], 10 * np.log10(Pm[:300] / Pm.max() + 1e-9), lw=0.7); axs[r, 0].set_ylim(-60, 2); axs[r, 0].set_ylabel(f'"{c}"')
        axs[r, 0].axvline(f[int(peak_bin(Pm[None, :])[0, 0])], color="r", lw=0.8)
        axs[r, 1].bar(range(8), band_energies(Pm[None, :])[0], color="C1")
        axs[r, 2].bar(range(8), band_energies(Pm[None, :], normalise="total")[0], color="C1")
        axs[r, 3].plot(log_mel(Pm[None, :], W)[0], color="C2", lw=1)
        axs[r, 4].bar(range(1, 13), mfcc(Pm[None, :], W, C)[0], color="C3")
    for a, t in zip(axs[0], ["power spectrum, peak bin in red", "8 band energies", "8 bands / total", "24 log-Mel, mean removed", "MFCC c1..c12 (Extra)"]): a.set_title(t, fontsize=8)
    for a, t in zip(axs[-1], ["Hz", "band", "band", "Mel filter", "coefficient"]): a.set_xlabel(t)
    fig.suptitle(f"Speaker {spk} (a man), four vowels, each feature (frame average)", fontsize=9)
    save(fig, "features_one_speaker")
    # 2. the pitch probe: the same vowel from a man, a woman and a child
    fig, axs = plt.subplots(1, 3, figsize=(10, 2.6))
    for spk2, col in (("m01", "C0"), ("w01", "C3"), ("b01", "C2")):
        P = power_spectrum(frames(load(f"{spk2}iy"), HOP)).mean(axis=0)[None, :]
        f = np.arange(N // 2 + 1) * FS / N
        axs[0].plot(f[:300], 10 * np.log10(P[0, :300] / P.max() + 1e-9), lw=0.7, color=col, label=spk2)
        axs[1].plot(log_mel(P, W)[0], lw=1, color=col); axs[2].plot(range(1, 13), mfcc(P, W, C)[0], lw=1, color=col, marker=".")
    axs[0].set_ylim(-60, 2); axs[0].legend(fontsize=7, frameon=False); axs[0].set_title('"ee" from a man, a woman, a boy: the spectra', fontsize=8)
    axs[1].set_title("log-Mel: the humps agree, the ripple moves", fontsize=8); axs[2].set_title("MFCC: closer, not identical", fontsize=8)
    save(fig, "pitch_probe")
    # 3. confusion matrices per feature x scenario, at the chosen rho
    summary = run_all(rho=rho)
    scen = list(next(iter(summary.values())).keys())
    fig, axs = plt.subplots(len(FEATURES), len(scen), figsize=(2.2 * len(scen), 2.0 * len(FEATURES)))
    for i, feature in enumerate(FEATURES):
        for j, sc in enumerate(scen):
            Mv = np.array(summary[feature][sc]["voted_cm"]); a = axs[i, j]
            a.imshow(Mv[:, :4] / np.maximum(Mv.sum(axis=1, keepdims=True), 1), cmap="Blues", vmin=0, vmax=1)
            for r in range(4):
                for c in range(4): a.text(c, r, Mv[r, c], ha="center", va="center", fontsize=6, color="white" if Mv[r, c] > 0.55 * Mv[r].sum() else "black")
            a.set_xticks(range(4)); a.set_xticklabels(CLASSES, fontsize=6); a.set_yticks(range(4)); a.set_yticklabels(CLASSES, fontsize=6)
            if i == 0: a.set_title(sc, fontsize=7)
            if j == 0: a.set_ylabel(feature, fontsize=7)
    fig.suptitle(f"Utterance-level confusion after the vote (rows: sung; columns: shown), rho = {rho}", fontsize=9)
    save(fig, "confusion_grid")
    # 4. the rho sweep
    sw = rho_sweep()
    fig, axs = plt.subplots(1, 2, figsize=(9, 3))
    for a, sc in zip(axs, ["same voice", "20 voices enrolled, 20 new"]):
        for feature in FEATURES:
            rows = np.array(sw[feature][sc]); a.plot(rows[:, 2] * 100, rows[:, 1] * 100, marker="o", ms=3, label=feature)
            for r in rows: a.annotate(f"{r[0]:.2g}", (r[2] * 100, r[1] * 100), fontsize=5, xytext=(2, 2), textcoords="offset points")
        a.set_xlabel("frames rejected (%)"); a.set_ylabel("accuracy on accepted frames (%)"); a.set_title(sc, fontsize=8); a.set_ylim(20, 100)
    axs[0].legend(fontsize=6, frameon=False)
    fig.suptitle("The reject rule: accuracy against how much is rejected, as rho goes from 0.6 to 1.0", fontsize=9)
    save(fig, "rho_sweep")
    json.dump({r: {s: v for s, v in d.items()} for r, d in sw.items()}, open(os.path.join(RES, "rho_sweep.json"), "w"), indent=1)
    return summary, sw

# --------------------------------------------------------------------------- the "sing it higher" experiment (synthetic)
def synth_vowel(f0, formants, dur=0.5, fs=FS, seed=0):
    """harmonics of f0 under a fixed formant envelope: the same mouth, a different note"""
    rng = np.random.default_rng(seed); t = np.arange(int(dur * fs)) / fs; x = np.zeros_like(t)
    for h in range(1, int(fs / 2 / f0)):
        f = h * f0; amp = sum(np.exp(-((f - fc) / bw) ** 2) for fc, bw in formants)
        x += amp * np.sin(2 * np.pi * f * t + rng.uniform(0, 2 * np.pi))
    return x / (np.abs(x).max() + 1e-9)

SYNTH_VOWELS = {"ee": [(280, 90), (2300, 250), (3000, 300)], "ah": [(700, 130), (1100, 150), (2600, 250)],
                "oo": [(300, 90), (870, 120), (2300, 250)], "aw": [(590, 120), (880, 130), (2500, 250)]}

def pitch_experiment(f0_enrol=150, f0_test=(110, 130, 150, 175, 200, 250, 300), rho=0.9):
    """enrol each synthetic vowel at f0_enrol; test the same vowels sung at other notes; per feature accuracy"""
    out = {}
    for feature in FEATURES:
        tr = {c: FEATURES[feature](power_spectrum(frames(synth_vowel(f0_enrol, fm), HOP))) for c, fm in SYNTH_VOWELS.items()}
        T = make_templates(tr, nt=4); accs = []
        for f0 in f0_test:
            Mv = np.zeros((4, 5), int)
            for c, fm in SYNTH_VOWELS.items():
                F = FEATURES[feature](power_spectrum(frames(synth_vowel(f0, fm, seed=3), HOP)))
                raw, voted, _ = classify(F, T, rho=rho); Mv += confusion([c], [voted[-1]])
            accs.append(accuracy(Mv))
        out[feature] = list(zip(f0_test, accs))
    return out

def figure_pitch(rho=0.9):
    import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
    pe = pitch_experiment(rho=rho)
    fig, a = plt.subplots(figsize=(6, 3))
    for feature, rows in pe.items():
        r = np.array(rows); a.plot(r[:, 0], r[:, 1] * 100, marker="o", ms=3, label=feature)
    a.axvline(150, color="0.6", ls="--", lw=0.8); a.text(152, 30, "enrolled at 150 Hz", fontsize=7)
    a.set_xlabel("note sung (Hz)"); a.set_ylabel("vowels named correctly (%)"); a.set_ylim(0, 105); a.legend(fontsize=6, frameon=False)
    a.set_title("Synthetic vowels: same mouth, different note. Which feature keeps recognising the vowel?", fontsize=8)
    for ext in ("png", "svg", "pdf"): fig.savefig(os.path.join(RES, f"pitch_experiment.{ext}"), dpi=200, bbox_inches="tight")
    plt.close(fig); json.dump(pe, open(os.path.join(RES, "pitch_experiment.json"), "w"), indent=1)
    for feature, rows in pe.items(): print(f"{feature:22s} " + " ".join(f"{f0}Hz:{acc*100:3.0f}%" for f0, acc in rows))
    return pe

# --------------------------------------------------------------------------- ADAPTED (Luke Mouawad, A2)
# The only change to the provided model: rtl_tables() prints the constants the RTL uses, computed by
# the model's own functions, so the hardware and the model cannot drift apart. Paste the printed
# literals over the parameter defaults in rtl/audio/a2/band_energy_8.sv (BAND_EDGES) and
# rtl/audio/a2/mel_filterbank_24.sv (MEL_PTS). Live-change cards ("a band edge", "the number of Mel
# bands") are a re-run:   python3 -c "import audio_model as a; a.rtl_tables(nmel=20)"
def rtl_tables(nb=8, nmel=24, fmin=100, fmax=6000):
    def packed(vals, name):
        return "parameter logic [%d:0][9:0] %s =\n    {%s}" % (
            len(vals) - 1, name, ", ".join("10'd%d" % v for v in reversed(vals)))
    edges = [int(e) for e in np.linspace(0, N // 2, nb + 1).astype(int)]          # as band_energies()
    m = np.linspace(hz2mel(fmin), hz2mel(fmax), nmel + 2)                             # as mel_bank()
    pts = [int(k) for k in np.round(mel2hz(m) * N / FS).astype(int)]
    assert all(b > a for a, b in zip(pts, pts[1:])), f"Mel points collide (zero-width triangle): {pts}"
    print(f"// band_energy_8.sv: {nb} equal bands of {N // 2 // nb} bins, band b owns [edge[b], edge[b+1])")
    print(packed(edges, "BAND_EDGES"))
    print(f"// mel_filterbank_24.sv: NM = {nmel}, {fmin}-{fmax} Hz (mel_bank)")
    print(packed(pts, "MEL_PTS"))
    return edges, pts

if __name__ == "__main__":
    figure_pitch(rho=0.9)
    figures(rho=0.9)