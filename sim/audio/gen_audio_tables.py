#!/usr/bin/env python3
"""
gen_audio_tables.py  --  Luke Mouawad, MTRX3700 A2 audio subsystem

Generates the constant tables that are pasted into the audio RTL, so every
number in the hardware can be traced back to a formula:

  1. LOG2_LUT   : 65-entry table of round(log2(1 + i/64) * 2^12), i = 0..64
                  -> rtl/audio/a2/log2_energy.sv   (function log2_lut)
  2. BAND_EDGES : 9 FFT-bin edges for the R-A2 8-band accumulator
                  -> rtl/audio/a2/band_energy_8.sv (parameter BAND_EDGES)
  3. MEL_PTS    : NMEL+2 FFT-bin points of the triangular Mel filterbank
                  -> rtl/audio/a2/mel_filterbank_24.sv (parameter MEL_PTS)

Live-change cards ("change a band edge", "change the number of Mel bands"):
edit the arguments below, re-run, paste the printed SystemVerilog literal
over the parameter default (or override the parameter where the module is
instantiated in audio_features.sv).

Usage:
    python3 gen_audio_tables.py                    # defaults
    python3 gen_audio_tables.py --nmel 20 --fmax 4000
"""
import argparse
import math

FS_FFT = 12000   # AUDIO_FS_FFT after 48k -> 12k decimation
N_FFT = 1024     # FFT_N


def hz_to_bin(f_hz: float) -> int:
    """Nearest FFT bin for frequency f: k = round(f N / fs)."""
    return int(math.floor(f_hz * N_FFT / FS_FFT + 0.5))


def hz_to_mel(f: float) -> float:
    return 2595.0 * math.log10(1.0 + f / 700.0)


def mel_to_hz(m: float) -> float:
    return 700.0 * (10.0 ** (m / 2595.0) - 1.0)


def log2_lut():
    return [int(round(math.log2(1.0 + i / 64.0) * 4096)) for i in range(65)]


def band_edges(fmin_hz: float, fmax_hz: float, nb: int):
    """Equal-width bands in Hz; band b owns bins [edge[b], edge[b+1])."""
    edges = [hz_to_bin(fmin_hz + (fmax_hz - fmin_hz) * b / nb) for b in range(nb + 1)]
    assert all(b > a for a, b in zip(edges, edges[1:])), "band edges must be strictly increasing"
    return edges


def mel_points(fmin_hz: float, fmax_hz: float, nmel: int):
    """NMEL+2 points equally spaced in Mel; filter m rises on
    [pt[m], pt[m+1]) and falls on [pt[m+1], pt[m+2])."""
    mlo, mhi = hz_to_mel(fmin_hz), hz_to_mel(fmax_hz)
    pts = [hz_to_bin(mel_to_hz(mlo + (mhi - mlo) * j / (nmel + 1))) for j in range(nmel + 2)]
    assert all(b > a for a, b in zip(pts, pts[1:])), (
        "Mel points collide at this resolution; raise fmin or lower nmel: %s" % pts)
    return pts


def sv_packed(values, width, name):
    """Packed-array literal, element [0] is the right-most (LSB) entry."""
    body = ", ".join("%d'd%d" % (width, v) for v in reversed(values))
    return "parameter logic [%d:0][%d:0] %s = {%s}" % (len(values) - 1, width - 1, name, body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--band-fmin", type=float, default=0.0)
    ap.add_argument("--band-fmax", type=float, default=4000.0)
    ap.add_argument("--nmel", type=int, default=24)
    ap.add_argument("--fmin", type=float, default=100.0)
    ap.add_argument("--fmax", type=float, default=5000.0)
    ap.add_argument("--n", type=int, default=1024, help="FFT length (live-change: N = 512)")
    a = ap.parse_args()
    global N_FFT
    N_FFT = a.n

    lut = log2_lut()
    print("// LOG2_LUT[i] = round(log2(1+i/64) * 4096), i = 0..64")
    for i, v in enumerate(lut):
        print("      7'd%d: log2_lut = 13'd%d;" % (i, v))

    be = band_edges(a.band_fmin, a.band_fmax, 8)
    # bin 0 (DC) and bin 1 (DC leakage through the window) are excluded
    be[0] = max(be[0], 2)
    print("\n// 8 equal-width bands %.0f-%.0f Hz (DC bins 0,1 excluded)" % (a.band_fmin, a.band_fmax))
    print(sv_packed(be, 10, "BAND_EDGES"))
    print("//   Hz:", [round(k * FS_FFT / N_FFT, 1) for k in be])

    mp = mel_points(a.fmin, a.fmax, a.nmel)
    print("\n// %d Mel filters %.0f-%.0f Hz" % (a.nmel, a.fmin, a.fmax))
    print(sv_packed(mp, 10, "MEL_PTS"))
    print("//   Hz:", [round(k * FS_FFT / N_FFT, 1) for k in mp])
    print("//   segment widths (bins):", [b - a_ for a_, b in zip(mp, mp[1:])])


if __name__ == "__main__":
    main()
