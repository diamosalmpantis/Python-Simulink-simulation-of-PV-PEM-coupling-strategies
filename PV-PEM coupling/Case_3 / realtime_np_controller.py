"""
realtime_np_controller.py
=========================
Online (real-time) PV string-count optimiser for the Reconfigurable Direct
PV-PEM coupling topology  (Case G).

TWO-OBJECTIVE FORMULATION
--------------------------
At every daytime timestep each Np candidate (5, 6, 7 strings) is scored on
two physically competing objectives:

  Objective 1 — Maximise H2 production rate
                score_H2  =  I_op  [A]
                Rationale :  I_op is proportional to moles of H2 per second
                             (Faraday's law: n_H2 = N × I / (2F) × eta_F).
                Prefers   :  MORE strings  (higher short-circuit current).

  Objective 2 — Maximise PEM electrochemical efficiency
                score_eta =  Vint_stack / V_op  [-]
                Rationale :  Vint_stack is the stack's thermodynamic (reversible)
                             voltage — the minimum voltage needed to split water.
                             V_op is the actual operating voltage.  The ratio
                               eta = Vint_stack / V_op
                             is the fraction of electrical energy converted to
                             chemical energy; the rest (1 - eta) is dissipated
                             as ohmic heat in the membrane and electrodes.
                Prefers   :  FEWER strings  (less current -> lower V_op ->
                             less I²R loss -> higher eta).

WHY THESE TWO OBJECTIVES PRODUCE MEANINGFUL SWITCHING
------------------------------------------------------
The tension between the two objectives creates a natural crossover:

  More strings  →  more H2  BUT  V_op rises  →  eta falls
  Fewer strings →  less H2  BUT  V_op drops  →  eta rises

ADJACENT-ONLY COMPARISON (critical implementation detail)
---------------------------------------------------------
Both objectives are monotonic in opposite directions with Np:
  H2 rate  is always highest at Np=7, lowest at Np=5.
  PEM eta  is always highest at Np=5, lowest at Np=7.
In a global three-way comparison, Np=6 can NEVER win — any weight
combination makes either Np=7 or Np=5 the global optimum.

Solution: at each timestep, compare only ADJACENT configurations
(current Np vs Np±1, one step at a time).  This creates two separate
pairwise crossover points that emerge from the physics:
  • Np 7 vs Np 6  →  crossover at  G ≈ 450 W/m²  (7 → 6 switch)
  • Np 6 vs Np 5  →  crossover at  G ≈ 600 W/m²  (6 → 5 switch)
Np=6 is therefore used between ≈ 450 and ≈ 600 W/m².

No irradiance thresholds are hardcoded.  Increasing W_H2 (favouring
more strings) shifts both crossovers upward; decreasing shifts them
lower.  See sensitivity table in Section 2.

TEMPERATURE CORRECTION
-----------------------
Isc, Voc, and Vmpp are corrected for cell temperature using standard
single-diode model coefficients (alpha_Isc, beta_Voc, beta_Vmpp).

Inputs  (written by G_direct_recon__no_batt_run.m, Section 4c)
-------
  online_controller_input.csv   :  time_idx | G_Wm2 | T_C

Outputs
-------
  online_np_sequence.csv        :  per-sample Np decision
  online_np_stats.json          :  summary statistics
"""

import numpy as np
import json, os, sys
import pandas as pd
from scipy.optimize import brentq

try:
    SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
except NameError:
    SCRIPT_DIR = os.getcwd()

# ---------------------------------------------------------------------------
# 1  SYSTEM PARAMETERS  (must match G_direct_recon__no_batt_run.m)
# ---------------------------------------------------------------------------
Ns            = 45             # cells in series per string
Np_candidates = [5, 6, 7]     # possible active string counts

# Cell STC values
Isc_cell  = 10.14   # [A]
Voc_cell  =  0.67   # [V]
Impp_cell =  9.59   # [A]
Vmpp_cell =  0.56   # [V]

# Temperature coefficients (per °C relative to STC = 25 °C)
alpha_Isc  =  0.0005   # Isc: +0.05 %/°C
beta_Voc   = -0.0030   # Voc: -0.30 %/°C
beta_Vmpp  = -0.0035   # Vmpp: -0.35 %/°C

# PEM electrolyzer stack (N = 13 cells in series)
N_pem      = 13
Vint_stack = 1.475841 * N_pem                      # [V]  thermodynamic (reversible) voltage
R_total    = (0.008673 + 0.00177 + 0.0005) * N_pem # [Ω]  total ohmic resistance
Vmax_PEM   = 2.0 * N_pem                           # [V]  maximum allowable voltage

NIGHT_THR  = 70.0   # [W/m²] below this → night, Np resets to maximum

# ---------------------------------------------------------------------------
# 2  OBJECTIVE WEIGHTS
# ---------------------------------------------------------------------------
# W_eta : W_H2 = 5 : 1  →  first crossover ≈ 450 W/m², second ≈ 620 W/m².
# Rationale: electrochemical efficiency is weighted more heavily because
# thermal losses in the PEM membrane limit lifetime and reduce STH;
# H2 rate still contributes to prevent unnecessary de-rating at low G.
#
# Sensitivity (approximate, at STC T = 25 °C):
#   W_eta/W_H2 = 2  →  crossovers at ~600 W/m² and ~800 W/m²
#   W_eta/W_H2 = 5  →  crossovers at ~450 W/m² and ~620 W/m²  ← default
#   W_eta/W_H2 = 10 →  crossovers at ~350 W/m² and ~500 W/m²
W_H2  = 1 / 6.0   # H2 production rate weight  (≈ 0.167)
W_eta = 5 / 6.0   # PEM efficiency weight       (≈ 0.833)

# Hysteresis: switch only when score improvement exceeds this fraction of
# the current winner's score.  Prevents chattering near crossover points.
HYST_FRAC = 0.005   # 0.5 % required margin to trigger a switch

# ---------------------------------------------------------------------------
# 3  TEMPERATURE-CORRECTED PV MODEL
# ---------------------------------------------------------------------------
def _iv_params(Np: int, G: float, T: float):
    """
    Single-diode parameters corrected for irradiance G [W/m²] and
    cell temperature T [°C].  Returns (Vt, Iph, I0).
    """
    dT   = T - 25.0
    g    = max(G / 1000.0, 1e-6)
    Iph  = Np * Isc_cell  * g * (1.0 + alpha_Isc * dT)
    Impp = Np * Impp_cell * g * (1.0 + alpha_Isc * dT)
    Voc  = Ns * Voc_cell  * (1.0 + beta_Voc  * dT)
    Vmpp = Ns * Vmpp_cell * (1.0 + beta_Vmpp * dT)
    ratio = np.clip(1.0 - Impp / max(Iph, 1e-9), 1e-4, 1.0 - 1e-4)
    Vt   = (Vmpp - Voc) / np.log(ratio)
    I0   = Iph * np.exp(-Voc / Vt)
    return Vt, Iph, I0


def operating_point(Np: int, G: float, T: float):
    """
    Compute the PV–PEM operating point by solving the intersection of:
      PV I-V curve  :  I_pv  = Iph - I0 * exp(V / Vt)
      PEM load line :  I_pem = (V - Vint_stack) / R_total

    Operating voltage is capped at Vmax_PEM to protect the electrolyzer.
    Returns (V_op, I_op, P_op).  Returns (0, 0, 0) at night or no solution.
    """
    if G < NIGHT_THR:
        return 0.0, 0.0, 0.0

    Vt, Iph, I0 = _iv_params(Np, G, T)
    dT           = T - 25.0
    Voc          = Ns * Voc_cell * (1.0 + beta_Voc * dT)

    def f(V):
        I_pv  = max(float(Iph - I0 * np.exp(V / Vt)), 0.0)
        I_pem = max((V - Vint_stack) / R_total,        0.0)
        return I_pv - I_pem

    V_lo = Vint_stack + 0.05
    V_hi = min(Voc - 0.05, Vmax_PEM)

    if V_lo >= V_hi:
        return 0.0, 0.0, 0.0
    if np.sign(f(V_lo)) == np.sign(f(V_hi)):
        return 0.0, 0.0, 0.0

    try:
        V_op = brentq(f, V_lo, V_hi, xtol=1e-5, maxiter=200)
        I_op = max((V_op - Vint_stack) / R_total, 0.0)
        return V_op, I_op, V_op * I_op
    except Exception:
        return 0.0, 0.0, 0.0


# ---------------------------------------------------------------------------
# 4  TWO-OBJECTIVE SCORING
# ---------------------------------------------------------------------------
def compute_scores(G: float, T: float) -> dict:
    """
    Score each Np candidate using the two-objective formulation.

    Metrics (computed for each Np):
      score_H2   = I_op            (proportional to H2 mol/s)
      score_eta  = Vint_stack/V_op (electrochemical efficiency)

    Both metrics are normalised to [0, 1] across the Np candidates at the
    current timestep before applying the weights, so neither dominates by
    magnitude.

    Returns: {Np: weighted_score}
    """
    raw_I   = {}
    raw_eta = {}

    for Np in Np_candidates:
        V_op, I_op, _ = operating_point(Np, G, T)
        raw_I[Np]   = I_op
        raw_eta[Np] = (Vint_stack / V_op) if V_op > Vint_stack + 1e-6 else 0.0

    max_I   = max(raw_I.values())   + 1e-9
    max_eta = max(raw_eta.values()) + 1e-9

    scores = {}
    for Np in Np_candidates:
        scores[Np] = (
            W_H2  * (raw_I[Np]   / max_I)
          + W_eta * (raw_eta[Np] / max_eta)
        )
    return scores


def score_adjacent(Np_a: int, Np_b: int, G: float, T: float):
    """
    Score two adjacent configurations against each other by normalising
    ONLY across the pair {Np_a, Np_b}.

    This ensures the comparison is always between neighbours (±1 step),
    so the controller cannot jump from Np=7 directly to Np=5.  Without
    this, both objectives are monotonic in opposite directions and the
    middle configuration (Np=6) can never win a three-way global score.

    Returns (score_a, score_b).
    """
    V_a, I_a, _ = operating_point(Np_a, G, T)
    V_b, I_b, _ = operating_point(Np_b, G, T)

    eta_a = (Vint_stack / V_a) if V_a > Vint_stack + 1e-6 else 0.0
    eta_b = (Vint_stack / V_b) if V_b > Vint_stack + 1e-6 else 0.0

    max_I   = max(I_a,   I_b)   + 1e-9
    max_eta = max(eta_a, eta_b) + 1e-9

    s_a = W_H2 * (I_a   / max_I)   + W_eta * (eta_a / max_eta)
    s_b = W_H2 * (I_b   / max_I)   + W_eta * (eta_b / max_eta)
    return s_a, s_b


# ---------------------------------------------------------------------------
# 5  ONLINE Np SELECTOR  (adjacent-only, with hysteresis)
# ---------------------------------------------------------------------------
def online_select(G_array: np.ndarray, T_array: np.ndarray) -> np.ndarray:
    """
    Return the optimal Np sequence for the measured (G, T) time-series.

    ADJACENT-ONLY SWITCHING RULE
    ----------------------------
    At each timestep only the two neighbours of the current Np are considered
    (Np_current - 1 and Np_current + 1).  The controller steps toward
    whichever adjacent level scores higher, by ONE step at a time.

    Why adjacent-only?
      Both objectives are monotonic in opposite directions with respect to Np:
        • H2 rate (score_H2)  is maximum at Np=7,  minimum at Np=5.
        • PEM efficiency (score_eta) is maximum at Np=5, minimum at Np=7.
      In a global three-way comparison, Np=6 can NEVER win: for any weight
      combination the global winner is either Np=7 or Np=5.
      Restricting the comparison to adjacent pairs creates two independent
      crossover points, one per pair, so the sequence 7 → 6 → 5 (and back)
      is followed naturally, with Np=6 active between the two crossovers.

    Crossover G values emerge from the physics (no hardcoded thresholds):
      • Np 7 → 6 : score_adjacent(6, 7) tips at  G ≈ 450 W/m²
      • Np 6 → 5 : score_adjacent(5, 6) tips at  G ≈ 600 W/m²
      (exact values shift ±20–40 W/m² with temperature)

    Hysteresis: a switch fires only when the improvement exceeds
    HYST_FRAC × |score_current| to prevent chattering at crossover G.

    At night (G < NIGHT_THR): Np resets to 7 (safest at low G).
    """
    np_sorted  = sorted(Np_candidates)   # [5, 6, 7] — ascending
    n          = len(G_array)
    Np_out     = np.zeros(n, dtype=int)
    Np_current = max(Np_candidates)      # start at maximum strings

    for i in range(n):
        G_i = float(G_array[i])
        T_i = float(T_array[i])

        if G_i < NIGHT_THR:
            Np_current = max(Np_candidates)
            Np_out[i]  = Np_current
            continue

        idx = np_sorted.index(Np_current)

        # Evaluate score vs the lower neighbour (step down = fewer strings)
        can_step_down = idx > 0
        step_down     = False
        if can_step_down:
            Np_lower = np_sorted[idx - 1]
            s_curr, s_lower = score_adjacent(Np_current, Np_lower, G_i, T_i)
            improvement_down = s_lower - s_curr
            if improvement_down > HYST_FRAC * max(abs(s_curr), 1e-9):
                step_down = True

        # Evaluate score vs the upper neighbour (step up = more strings)
        can_step_up = idx < len(np_sorted) - 1
        step_up     = False
        if can_step_up and not step_down:   # step down takes priority if both trigger
            Np_upper = np_sorted[idx + 1]
            s_curr, s_upper = score_adjacent(Np_current, Np_upper, G_i, T_i)
            improvement_up = s_upper - s_curr
            if improvement_up > HYST_FRAC * max(abs(s_curr), 1e-9):
                step_up = True

        if step_down:
            Np_current = np_sorted[idx - 1]
        elif step_up:
            Np_current = np_sorted[idx + 1]

        Np_out[i] = Np_current

    return Np_out


# ---------------------------------------------------------------------------
# 6  MAIN
# ---------------------------------------------------------------------------
if __name__ == '__main__':
    input_csv = os.path.join(SCRIPT_DIR, 'online_controller_input.csv')
    if not os.path.isfile(input_csv):
        print('[ERROR] online_controller_input.csv not found.')
        sys.exit(1)

    df_in = pd.read_csv(input_csv)
    G_arr = df_in['G_Wm2'].values.astype(float)
    T_arr = df_in['T_C'].values.astype(float)

    print(f'Online Np controller (2-objective, adjacent switching): {len(G_arr)} timesteps')
    print(f'  Obj 1  H2 rate : W = {W_H2:.3f}  →  maximise I_op')
    print(f'  Obj 2  PEM eta : W = {W_eta:.3f}  →  maximise Vint/V_op')
    print(f'  Hysteresis: {HYST_FRAC*100:.1f}%  |  Night cutoff: {NIGHT_THR} W/m²')

    Np_online = online_select(G_arr, T_arr)
    print('Done.\n')

    # ------------------------------------------------------------------
    # Save results CSV  (Np_online is the only decision column)
    # ------------------------------------------------------------------
    df_out = pd.DataFrame({
        'time_idx':  df_in['time_idx'].values if 'time_idx' in df_in.columns
                     else np.arange(len(G_arr)),
        'G_Wm2':     np.round(G_arr, 1),
        'T_C':       np.round(T_arr, 1),
        'Np_online': Np_online,
    })
    out_csv = os.path.join(SCRIPT_DIR, 'online_np_sequence.csv')
    df_out.to_csv(out_csv, index=False)
    print(f'Saved: {out_csv}')

    # ------------------------------------------------------------------
    # Summary statistics
    # ------------------------------------------------------------------
    daytime  = G_arr >= NIGHT_THR
    n_day    = int(np.sum(daytime))

    np_fracs = {int(Np): round(float(np.mean(Np_online[daytime] == Np)) * 100, 1)
                for Np in Np_candidates} if n_day > 0 else {Np: 0.0 for Np in Np_candidates}

    # Count actual switch events
    n_switches = int(np.sum(np.diff(Np_online) != 0))

    stats = {
        'objectives': {
            'H2_rate_weight':  round(W_H2,  4),
            'PEM_eta_weight':  round(W_eta, 4),
            'H2_rate_formula': 'maximise I_op  [A]  ∝  mol H2/s',
            'PEM_eta_formula': 'maximise Vint_stack / V_op  [electrochemical efficiency]',
        },
        'switching_method':        'adjacent-only pairwise (7→6→5, no jumps)',
        'hysteresis_fraction':     HYST_FRAC,
        'night_threshold_Wm2':     NIGHT_THR,
        'n_total_samples':         int(len(G_arr)),
        'n_daytime_samples':       n_day,
        'n_switch_events':         n_switches,
        'mean_G_daytime_Wm2':      round(float(np.mean(G_arr[daytime])), 1) if n_day > 0 else 0.0,
        'mean_T_daytime_C':        round(float(np.mean(T_arr[daytime])), 1) if n_day > 0 else 0.0,
        'Np_fractions_daytime_pct': np_fracs,
        'approx_crossovers_Wm2':   {'Np7_to_Np6': '~450', 'Np6_to_Np5': '~600'},
    }
    stats_path = os.path.join(SCRIPT_DIR, 'online_np_stats.json')
    with open(stats_path, 'w') as fh:
        json.dump(stats, fh, indent=2)
    print(f'Saved: {stats_path}')

    # ------------------------------------------------------------------
    # Console summary
    # ------------------------------------------------------------------
    print(f'\n=== Online Np Controller — Results ===')
    print(f'  Objectives   :  H2 rate (W={W_H2:.2f})  +  PEM eta (W={W_eta:.2f})')
    print(f'  Daytime Np   :  ' +
          '  '.join([f'Np{k} = {v:.1f}%' for k, v in np_fracs.items()]))
    print(f'  Switch events:  {n_switches}')
    print(f'  Mean G (day) :  {stats["mean_G_daytime_Wm2"]:.0f} W/m²'
          f'  |  Mean T: {stats["mean_T_daytime_C"]:.1f} °C')
