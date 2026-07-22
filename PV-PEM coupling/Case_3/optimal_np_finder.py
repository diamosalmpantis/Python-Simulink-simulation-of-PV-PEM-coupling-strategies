"""
optimal_np_finder.py
====================
Offline sweep of the multi-objective Np optimisation over the full
(G, T) operating space for Case G – Reconfigurable Direct PV-PEM.

MULTI-OBJECTIVE FORMULATION
----------------------------
For every (Np, G, T) the score combines four objectives:

  Maximise H2_rate  –  I_op [A]            ∝ molar H2 production rate
  Maximise STH_rel  –  I_op / Np           ∝ Solar-to-H2 efficiency
                        (penalises using extra PV area for marginal current)
  Maximise C        –  P_op / P_mpp        coupling / load-matching factor
  Minimise mismatch –  1 - C               fraction of MPP wasted

Each positive metric is normalised within the candidate set at each G-point
before weighting, so no single metric dominates due to scale differences.

HOW THIS DIFFERS FROM THE OLD C × Np SCORE
-------------------------------------------
C × Np ∝ absolute power and always picks the most strings.  Adding STH
(I/Np) as a significant term shifts crossover thresholds to LOWER irradiance
because once the PEM starts saturating near its rated voltage, extra strings
increase PV area without proportional current gain — lowering STH.

Outputs
-------
  optimal_np_lookup.csv         G | optimal_Np | per-Np score/C/V/P  (at 25 °C)
  optimal_thresholds.json       STC thresholds  (backward-compatible)
  optimal_thresholds_2d.json    T-indexed threshold arrays for MATLAB interp
  C_vs_G_Np_comparison.png      publication-quality figure

Usage
-----
  python optimal_np_finder.py

MATLAB reads optimal_thresholds_2d.json and interpolates at the dataset's
mean daytime temperature before calling sim().
"""

import numpy as np
import json
import pandas as pd
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from scipy.optimize import brentq
import os

try:
    SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
except NameError:
    SCRIPT_DIR = os.getcwd()

# -----------------------------------------------------------------------
# 1 – SYSTEM PARAMETERS  (keep in sync with G_direct_recon__no_batt_run.m)
# -----------------------------------------------------------------------
Ns            = 45
Np_candidates = [5, 6, 7]

Isc_cell  = 10.14
Voc_cell  =  0.67
Impp_cell =  9.59
Vmpp_cell =  0.56

alpha_Isc  =  0.0005
beta_Voc   = -0.0030
beta_Vmpp  = -0.0035

N_pem      = 13
Vint_stack = 1.475841 * N_pem
R_total    = (0.008673 + 0.00177 + 0.0005) * N_pem
Vmax_PEM   = 2.0 * N_pem

NIGHT_THR  = 70
HYSTERESIS = 15   # [W/m²] half-band around each crossover

T_sweep = np.arange(10, 55, 5, dtype=float)   # 10 … 50 °C

# -----------------------------------------------------------------------
# 2 – MULTI-OBJECTIVE WEIGHTS  (identical to realtime_np_controller.py)
# -----------------------------------------------------------------------
W_H2  = 0.25   # H2 production rate   (maximise)
W_STH = 0.25   # Solar-to-H2 eff.    (maximise) — key driver for switching diversity
W_C   = 0.25   # Coupling factor      (maximise)
W_MM  = 0.25   # Mismatch fraction    (minimise)

# -----------------------------------------------------------------------
# 3 – TEMPERATURE-CORRECTED PV / PEM MODEL
# -----------------------------------------------------------------------
def _iv_params_T(Np, G, T):
    dT   = T - 25.0
    g    = max(G / 1000.0, 1e-5)
    Iph  = Np * Isc_cell  * g * (1.0 + alpha_Isc * dT)
    Impp = Np * Impp_cell * g * (1.0 + alpha_Isc * dT)
    Voc  = Ns * Voc_cell  * (1.0 + beta_Voc  * dT)
    Vmpp = Ns * Vmpp_cell * (1.0 + beta_Vmpp * dT)
    ratio = np.clip(1.0 - Impp / max(Iph, 1e-9), 1e-4, 1.0 - 1e-4)
    Vt   = (Vmpp - Voc) / np.log(ratio)
    I0   = Iph * np.exp(-Voc / Vt)
    return Vt, Iph, I0, Voc, Vmpp


def operating_point_T(Np, G, T):
    if G < NIGHT_THR:
        return 0.0, 0.0, 0.0
    Vt, Iph, I0, Voc, _ = _iv_params_T(Np, G, T)

    def f(V):
        return max(float(Iph - I0 * np.exp(V / Vt)), 0.0) \
             - max((V - Vint_stack) / R_total, 0.0)

    V_lo, V_hi = Vint_stack + 0.05, min(Voc - 0.05, Vmax_PEM)
    if V_lo >= V_hi:
        return 0.0, 0.0, 0.0
    try:
        if np.sign(f(V_lo)) == np.sign(f(V_hi)):
            return 0.0, 0.0, 0.0
        V_op = brentq(f, V_lo, V_hi, xtol=1e-5, maxiter=200)
        I_op = max((V_op - Vint_stack) / R_total, 0.0)
        return V_op, I_op, V_op * I_op
    except Exception:
        return 0.0, 0.0, 0.0


def mpp_power_T(Np, G, T):
    dT   = T - 25.0
    g    = max(G / 1000.0, 1e-5)
    return max(0.0, Np * Impp_cell * g * (1.0 + alpha_Isc * dT)
                  * Ns * Vmpp_cell * (1.0 + beta_Vmpp * dT))


# -----------------------------------------------------------------------
# 4 – MULTI-OBJECTIVE SCORE  (same formulation as realtime controller)
# -----------------------------------------------------------------------
def scores_at(G_arr, T, Np_list):
    """
    Returns score array shape (len(Np_list), len(G_arr)) for fixed T.
    Normalisation is across Np candidates at each G independently.
    """
    n_G  = len(G_arr)
    n_Np = len(Np_list)
    raw_H2  = np.zeros((n_Np, n_G))
    raw_STH = np.zeros((n_Np, n_G))
    raw_C   = np.zeros((n_Np, n_G))
    raw_mm  = np.zeros((n_Np, n_G))
    raw_P   = np.zeros((n_Np, n_G))
    raw_V   = np.zeros((n_Np, n_G))
    raw_I   = np.zeros((n_Np, n_G))

    for ni, Np in enumerate(Np_list):
        for gi, G in enumerate(G_arr):
            V_op, I_op, P_op   = operating_point_T(Np, G, T)
            P_mpp               = mpp_power_T(Np, G, T)
            C                   = P_op / P_mpp if P_mpp > 1e-6 else 0.0
            raw_H2[ni, gi]      = I_op
            raw_STH[ni, gi]     = I_op / float(Np)
            raw_C[ni, gi]       = C
            raw_mm[ni, gi]      = max(0.0, 1.0 - C)
            raw_P[ni, gi]       = P_op
            raw_V[ni, gi]       = V_op
            raw_I[ni, gi]       = I_op

    eps = 1e-9
    # Normalise each metric across Np candidates per G column
    max_H2  = raw_H2.max(axis=0, keepdims=True)  + eps
    max_STH = raw_STH.max(axis=0, keepdims=True) + eps
    max_C   = raw_C.max(axis=0,  keepdims=True)  + eps

    score = (W_H2  * (raw_H2  / max_H2)
           + W_STH * (raw_STH / max_STH)
           + W_C   * (raw_C   / max_C)
           - W_MM  *  raw_mm)

    return score, raw_C, raw_P, raw_V, raw_I


# -----------------------------------------------------------------------
# 5 – SWEEP G AND T
# -----------------------------------------------------------------------
G_sweep = np.arange(NIGHT_THR, 1201, 1, dtype=float)
n_G     = len(G_sweep)
n_T     = len(T_sweep)
n_Np    = len(Np_candidates)

score_2d = np.zeros((n_T, n_Np, n_G))   # [T, Np, G]
C_2d     = np.zeros((n_T, n_Np, n_G))
P_2d     = np.zeros((n_T, n_Np, n_G))
V_2d     = np.zeros((n_T, n_Np, n_G))
I_2d     = np.zeros((n_T, n_Np, n_G))

print('Computing multi-objective scores over G × T grid …')
for ti, T in enumerate(T_sweep):
    print(f'  T = {T:.0f} °C', flush=True)
    sc, rc, rp, rv, ri = scores_at(G_sweep, T, Np_candidates)
    score_2d[ti] = sc
    C_2d[ti]     = rc
    P_2d[ti]     = rp
    V_2d[ti]     = rv
    I_2d[ti]     = ri

# -----------------------------------------------------------------------
# 6 – CROSSOVER THRESHOLDS AT EACH TEMPERATURE
# -----------------------------------------------------------------------
sorted_Np   = sorted(Np_candidates, reverse=True)   # [7, 6, 5]
np_pairs    = [(sorted_Np[k], sorted_Np[k+1]) for k in range(len(sorted_Np)-1)]
pair_labels = ['THR_97', 'THR_75']

def find_crossover(score_hi, score_lo, G_arr):
    """G where score_lo first exceeds score_hi (rising G direction)."""
    diff = score_lo - score_hi
    sign_changes = np.where(np.diff(np.sign(diff)) > 0)[0]
    if len(sign_changes) == 0:
        # No clean crossover: return end of range as safe fallback
        return float(G_arr[-1])
    i0      = sign_changes[0]
    d0, d1  = diff[i0], diff[i0+1]
    return float(G_arr[i0] + (G_arr[i0+1]-G_arr[i0]) * (-d0)/(d1-d0))

all_crossovers = []
print('\n=== Switching Thresholds vs Temperature (multi-objective) ===')
print(f"  {'T':>5}  {'7→6 cross':>10}  {'thr_up':>7}  {'thr_dn':>7}  "
      f"{'6→5 cross':>10}  {'thr_up':>7}  {'thr_dn':>7}")
for ti, T in enumerate(T_sweep):
    co = {}
    for (Np_hi, Np_lo) in np_pairs:
        ni_hi = Np_candidates.index(Np_hi)
        ni_lo = Np_candidates.index(Np_lo)
        G_cross = find_crossover(score_2d[ti, ni_hi, :],
                                 score_2d[ti, ni_lo, :], G_sweep)
        co[(Np_hi, Np_lo)] = {
            'G_cross': G_cross,
            'thr_up':  G_cross + HYSTERESIS,
            'thr_dn':  G_cross - HYSTERESIS,
        }
    all_crossovers.append(co)
    c97, c75 = co[(7,6)], co[(6,5)]
    print(f"  {T:5.0f}  {c97['G_cross']:10.1f}  {c97['thr_up']:7.1f}  "
          f"{c97['thr_dn']:7.1f}  {c75['G_cross']:10.1f}  {c75['thr_up']:7.1f}  "
          f"{c75['thr_dn']:7.1f}")

# -----------------------------------------------------------------------
# 7 – SAVE OUTPUTS
# -----------------------------------------------------------------------
idx_STC = int(np.argmin(np.abs(T_sweep - 25.0)))
co_STC  = all_crossovers[idx_STC]

# 7a – CSV lookup (T=25 °C, backward-compatible)
optimal_Np_STC = np.array(
    [Np_candidates[int(np.argmax(score_2d[idx_STC, :, i]))] for i in range(n_G)],
    dtype=int)
df = pd.DataFrame({'G_Wm2': G_sweep, 'optimal_Np': optimal_Np_STC})
for ni, Np in enumerate(Np_candidates):
    df[f'score_Np{Np}'] = np.round(score_2d[idx_STC, ni, :], 5)
    df[f'C_Np{Np}']     = np.round(C_2d[idx_STC,     ni, :], 5)
    df[f'Vop_Np{Np}']   = np.round(V_2d[idx_STC,     ni, :], 4)
    df[f'Pwp_Np{Np}']   = np.round(P_2d[idx_STC,     ni, :], 3)
csv_path = os.path.join(SCRIPT_DIR, 'optimal_np_lookup.csv')
df.to_csv(csv_path, index=False)
print(f'\nSaved: {csv_path}')

# 7b – STC JSON (backward-compatible)
thr_STC = {'NIGHT_THR': int(NIGHT_THR), 'HYSTERESIS': float(HYSTERESIS),
           'weights': {'W_H2': W_H2, 'W_STH': W_STH, 'W_C': W_C, 'W_MM': W_MM}}
for (Np_hi, Np_lo), lbl in zip(np_pairs, pair_labels):
    co = co_STC[(Np_hi, Np_lo)]
    thr_STC[f'{lbl}_up']    = round(co['thr_up'],   1)
    thr_STC[f'{lbl}_dn']    = round(co['thr_dn'],   1)
    thr_STC[f'{lbl}_cross'] = round(co['G_cross'],  1)
    thr_STC[f'{lbl}_pair']  = f'Np{Np_hi}->Np{Np_lo}'
with open(os.path.join(SCRIPT_DIR, 'optimal_thresholds.json'), 'w') as fh:
    json.dump(thr_STC, fh, indent=2)
print(f"Saved: optimal_thresholds.json  (STC / 25 °C)")

# 7c – 2-D JSON
thr_2d = {'description': 'Multi-objective switching thresholds vs G and T.',
          'T_bins': T_sweep.tolist(),
          'NIGHT_THR': int(NIGHT_THR), 'HYSTERESIS': float(HYSTERESIS),
          'weights': {'W_H2': W_H2, 'W_STH': W_STH, 'W_C': W_C, 'W_MM': W_MM}}
for (Np_hi, Np_lo), lbl in zip(np_pairs, pair_labels):
    thr_2d[f'{lbl}_cross'] = [round(all_crossovers[ti][(Np_hi,Np_lo)]['G_cross'],1)
                               for ti in range(n_T)]
    thr_2d[f'{lbl}_up']    = [round(all_crossovers[ti][(Np_hi,Np_lo)]['thr_up'],1)
                               for ti in range(n_T)]
    thr_2d[f'{lbl}_dn']    = [round(all_crossovers[ti][(Np_hi,Np_lo)]['thr_dn'],1)
                               for ti in range(n_T)]
    thr_2d[f'{lbl}_pair']  = f'Np{Np_hi}->Np{Np_lo}'
with open(os.path.join(SCRIPT_DIR, 'optimal_thresholds_2d.json'), 'w') as fh:
    json.dump(thr_2d, fh, indent=2)
print(f"Saved: optimal_thresholds_2d.json  ({n_T} T-bins)")

# -----------------------------------------------------------------------
# 8 – FIGURE
# -----------------------------------------------------------------------
wong = {5: [0.85,0.33,0.10], 6: [0.90,0.62,0.00], 7: [0.00,0.45,0.70]}
T_show   = [10.0, 25.0, 40.0]
T_ls     = [':', '-', '--']
T_labels = ['T = 10 °C  (cool)', 'T = 25 °C  (STC)', 'T = 40 °C  (hot)']

fig, axes = plt.subplots(3, 1, figsize=(11, 12), sharex=True)
fig.suptitle(
    'Optimal PV String Configuration — Direct-Coupled PV-PEM\n'
    rf'Multi-objective score: $w_{{H_2}}$={W_H2}  '
    rf'$w_{{STH}}$={W_STH}  $w_C$={W_C}  $w_{{mm}}$={W_MM}',
    fontsize=12, fontweight='bold')

# ---- Panel 1: multi-objective score curves at 3 temperatures ----
ax1 = axes[0]
for T_ref, ls in zip(T_show, T_ls):
    ti_ref = int(np.argmin(np.abs(T_sweep - T_ref)))
    for Np in sorted(Np_candidates):
        ni = Np_candidates.index(Np)
        lbl = (f'T={T_ref:.0f}°C' if Np == Np_candidates[0] else '_')
        ax1.plot(G_sweep, score_2d[ti_ref, ni, :],
                 color=wong[Np], linestyle=ls, linewidth=1.8, label=lbl)

# Shaded optimal background at STC
for i in range(n_G - 1):
    best_ni = int(np.argmax(score_2d[idx_STC, :, i]))
    ax1.axvspan(G_sweep[i], G_sweep[i+1], alpha=0.07,
                color=wong[Np_candidates[best_ni]], linewidth=0)

for (Np_hi, Np_lo), lbl_str in zip(np_pairs, pair_labels):
    co = co_STC[(Np_hi, Np_lo)]
    ax1.axvline(co['G_cross'], color='k', linestyle='--', linewidth=1.0, alpha=0.6)
    ax1.axvspan(co['thr_dn'], co['thr_up'], alpha=0.15, color='grey',
                label=f'Hysteresis ±{HYSTERESIS} ({lbl_str}, STC)')
    ax1.text(co['G_cross'], ax1.get_ylim()[0] if ax1.get_ylim()[0] > 0 else 0.55,
             f"{co['G_cross']:.0f}", ha='center', va='bottom', fontsize=8, color='0.3')

legend_T    = [Line2D([0],[0],color='0.3',     ls=ls, lw=1.8) for ls in T_ls]
legend_Np   = [Line2D([0],[0],color=wong[Np],  ls='-', lw=2.2) for Np in sorted(Np_candidates)]
legend_labs = T_labels + [f'Np={Np}' + (' (High-G)' if Np==5 else ' (Mid-G)' if Np==6 else ' (Low-G)')
                          for Np in sorted(Np_candidates)]
ax1.legend(legend_T + legend_Np, legend_labs, fontsize=8, loc='lower right', ncol=2)
ax1.set_ylabel('Multi-objective score', fontsize=11)
ax1.grid(True, alpha=0.3)
ax1.set_title('(a) Multi-objective score vs G — shaded = optimal (STC)', fontsize=10)

# ---- Panel 2: coupling factor C (for comparison with old approach) ----
ax2 = axes[1]
for T_ref, ls in zip(T_show, T_ls):
    ti_ref = int(np.argmin(np.abs(T_sweep - T_ref)))
    for Np in sorted(Np_candidates):
        ni = Np_candidates.index(Np)
        ax2.plot(G_sweep, C_2d[ti_ref, ni, :],
                 color=wong[Np], linestyle=ls, linewidth=1.8)

for (Np_hi, Np_lo) in np_pairs:
    co = co_STC[(Np_hi, Np_lo)]
    ax2.axvline(co['G_cross'], color='k', linestyle='--', linewidth=1.0, alpha=0.6)
ax2.set_ylabel('Coupling factor  C = P_op / P_mpp', fontsize=11)
ax2.set_ylim([0, 1.05])
ax2.grid(True, alpha=0.3)
ax2.set_title('(b) Coupling factor C vs G — same colour/style coding', fontsize=10)

# ---- Panel 3: crossover G vs T (threshold sensitivity) ----
ax3 = axes[2]
colors_pair = ['#0072B2', '#D55E00']
for (Np_hi, Np_lo), lbl_str, clr in zip(np_pairs, pair_labels, colors_pair):
    G_cross_arr = np.array([all_crossovers[ti][(Np_hi,Np_lo)]['G_cross'] for ti in range(n_T)])
    thr_up_arr  = np.array([all_crossovers[ti][(Np_hi,Np_lo)]['thr_up']  for ti in range(n_T)])
    thr_dn_arr  = np.array([all_crossovers[ti][(Np_hi,Np_lo)]['thr_dn']  for ti in range(n_T)])
    ax3.plot(T_sweep, G_cross_arr, color=clr, linewidth=2.2,
             label=f'Crossover Np{Np_hi}→Np{Np_lo}  ({lbl_str})')
    ax3.fill_between(T_sweep, thr_dn_arr, thr_up_arr, alpha=0.18, color=clr,
                     label=f'Hysteresis band  (±{HYSTERESIS} W/m²)')

ax3.axvline(25, color='k', linestyle='--', linewidth=0.9, alpha=0.6, label='STC (25 °C)')
ax3.set_xlabel('Cell Temperature  T  (°C)', fontsize=11)
ax3.set_ylabel('Crossover Irradiance  (W m⁻²)', fontsize=11)
ax3.legend(fontsize=9, loc='upper right')
ax3.grid(True, alpha=0.3)
ax3.set_title('(c) Switching threshold G vs T — higher T shifts crossover downward', fontsize=10)

axes[1].set_xlabel('')
axes[0].set_xlabel('')
axes[2].set_xlabel('Cell Temperature  T  (°C)', fontsize=11)
axes[1].set_xlabel('')

plt.tight_layout()
fig_path = os.path.join(SCRIPT_DIR, 'C_vs_G_Np_comparison.png')
plt.savefig(fig_path, dpi=300, bbox_inches='tight')
print(f'Saved: {fig_path}')

# -----------------------------------------------------------------------
# 9 – SUMMARY
# -----------------------------------------------------------------------
print(f'\n=== Summary ===')
print(f'  Objective weights: W_H2={W_H2}  W_STH={W_STH}  W_C={W_C}  W_MM={W_MM}')
print(f'  Temperature bins : {T_sweep.tolist()} °C')
print(f'  Hysteresis       : ±{HYSTERESIS} W/m²')
print(f'\n  STC thresholds (T=25 °C, multi-objective):')
for (Np_hi, Np_lo) in np_pairs:
    co = co_STC[(Np_hi, Np_lo)]
    print(f'    Np{Np_hi}→Np{Np_lo}: crossover {co["G_cross"]:.1f} W/m²  '
          f'(up={co["thr_up"]:.1f}  dn={co["thr_dn"]:.1f})')
print(f'\n  Run G_direct_recon__no_batt_run.m — it loads optimal_thresholds_2d.json')
print(f'  and interpolates at the dataset mean daytime T.')
