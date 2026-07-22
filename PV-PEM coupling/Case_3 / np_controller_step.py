"""
np_controller_step.py
=====================
Python side of the Python-Simulink co-simulation for real-time Np selection.

Called by sfunc_np_controller.m at every Simulink sample step via the
MATLAB py.* interface.  Because MATLAB's Python engine keeps module state
alive for the entire simulation, the global _Np_current variable acts as
persistent memory across timesteps — exactly like a Simulink Unit Delay.

TWO-OBJECTIVE FORMULATION
--------------------------
  Objective 1  Maximise H2 rate    : score_H2  = I_op          (W_H2  = 1/6)
               Prefers MORE strings (higher current).

  Objective 2  Maximise PEM η      : score_eta = Vint / V_op   (W_eta = 5/6)
               Prefers FEWER strings (lower current → lower V_op → higher η).

ADJACENT-ONLY SWITCHING
------------------------
  The controller only considers ±1 step from the current Np.
  This prevents the Pareto monotonicity problem that causes Np=6 to never
  be selected when all three configs are compared globally.

  Crossover G values emerge from physics (no hardcoded thresholds):
    Np 7 → 6 : ≈ 450 W/m²  (shifts ±20–40 W/m² with temperature)
    Np 6 → 5 : ≈ 600 W/m²
"""

import math

# ── module-level state (survives across MATLAB py.* calls) ───────────────────
_Np_current = 7   # start at maximum strings (safest at low irradiance)

# ── tuning constants ──────────────────────────────────────────────────────────
NIGHT_THR  = 70.0       # [W/m²]  below this → night; reset to Np=7
W_H2       = 1.0 / 6.0  # H2-rate weight   ≈ 0.167
W_eta      = 5.0 / 6.0  # PEM-η weight     ≈ 0.833
HYST_FRAC  = 0.005       # 0.5% margin required to trigger a switch

# ── PV array parameters (must match Simulink Solar Cell blocks) ───────────────
Ns_cell  = 45
Isc_c    = 10.14;  Voc_c  = 0.67
Impp_c   =  9.59;  Vmpp_c = 0.56
aIsc     =  5e-4;  bVoc   = -3e-3;  bVmpp = -3.5e-3

# ── PEM stack parameters (N=13 cells) ─────────────────────────────────────────
N_pem    = 13
Vint_stack = 1.475841 * N_pem          # thermodynamic stack voltage [V]
R_stack    = (0.008673 + 0.00177 + 0.0005) * N_pem   # total ohmic resistance [Ω]
Vmax_pem   = 2.0 * N_pem


# ─────────────────────────────────────────────────────────────────────────────
#  PUBLIC API
# ─────────────────────────────────────────────────────────────────────────────

def reset():
    """
    Called once by sfunc_np_controller.m in its Start method.
    Resets the controller to the initial state (Np = 7 strings).
    """
    global _Np_current
    _Np_current = 7


def step(G, T):
    """
    Called by sfunc_np_controller.m at every Simulink sample instant.

    Parameters
    ----------
    G : float  Irradiance [W/m²]
    T : float  Cell temperature [°C]

    Returns
    -------
    int  Active parallel strings: 5, 6, or 7
    """
    global _Np_current

    G = float(G)
    T = float(T)

    # ── Night reset ───────────────────────────────────────────────────────────
    if G < NIGHT_THR:
        _Np_current = 7
        return _Np_current

    # ── Try stepping DOWN (fewer strings: 7→6 or 6→5) ────────────────────────
    step_down = False
    if _Np_current > 5:
        Np_lo = _Np_current - 1
        s_curr, s_lo = _score_pair(_Np_current, Np_lo, G, T)
        if (s_lo - s_curr) > HYST_FRAC * max(abs(s_curr), 1e-9):
            _Np_current = Np_lo
            step_down   = True

    # ── Try stepping UP (more strings: 5→6 or 6→7) — only if not going down ──
    if not step_down and _Np_current < 7:
        Np_hi = _Np_current + 1
        s_curr, s_hi = _score_pair(_Np_current, Np_hi, G, T)
        if (s_hi - s_curr) > HYST_FRAC * max(abs(s_curr), 1e-9):
            _Np_current = Np_hi

    return _Np_current


def get_current_np():
    """Return the controller's current Np (useful for logging from MATLAB)."""
    return _Np_current


# ─────────────────────────────────────────────────────────────────────────────
#  PRIVATE HELPERS
# ─────────────────────────────────────────────────────────────────────────────

def _score_pair(Np_a, Np_b, G, T):
    """
    Compute weighted scores for two adjacent Np candidates.
    Normalises ONLY across the pair so neither objective magnitude dominates.

    Returns
    -------
    (s_a, s_b) : float, float   Scores for Np_a and Np_b
    """
    V_a, I_a = _op_point(Np_a, G, T)
    V_b, I_b = _op_point(Np_b, G, T)

    eta_a = Vint_stack / V_a if V_a > Vint_stack + 1e-6 else 0.0
    eta_b = Vint_stack / V_b if V_b > Vint_stack + 1e-6 else 0.0

    max_I   = max(I_a,   I_b)   + 1e-9
    max_eta = max(eta_a, eta_b) + 1e-9

    s_a = W_H2 * (I_a   / max_I)   + W_eta * (eta_a / max_eta)
    s_b = W_H2 * (I_b   / max_I)   + W_eta * (eta_b / max_eta)
    return s_a, s_b


def _op_point(Np, G, T):
    """
    Find the PV-PEM operating point (V_op, I_op) using the bisection method.

    The operating point is the voltage where the PV I-V curve intersects the
    PEM ohmic load line:  I_pem(V) = (V - Vint_stack) / R_stack

    Returns
    -------
    (V_op, I_op) : float, float   [V] and [A]
                   Both are 0.0 if no valid intersection is found.
    """
    dT  = T - 25.0
    g   = max(G / 1000.0, 1e-6)

    # Temperature-corrected single-diode parameters
    Iph      = Np * Isc_c  * g * (1.0 + aIsc  * dT)
    Impp_loc = Np * Impp_c * g * (1.0 + aIsc  * dT)
    Voc_loc  = Ns_cell * Voc_c  * (1.0 + bVoc  * dT)
    Vmpp_loc = Ns_cell * Vmpp_c * (1.0 + bVmpp * dT)

    ratio = min(max(1.0 - Impp_loc / max(Iph, 1e-9), 1e-4), 1.0 - 1e-4)
    Vt    = (Vmpp_loc - Voc_loc) / math.log(ratio)
    I0    = Iph * math.exp(-Voc_loc / Vt)

    # Search bounds: PEM must operate above Vint_stack
    V_lo = Vint_stack + 0.05
    V_hi = min(Voc_loc - 0.05, Vmax_pem)

    if V_lo >= V_hi:
        return 0.0, 0.0

    def residual(V):
        try:
            I_pv  = Iph - I0 * math.exp(V / Vt)
            I_pem = (V - Vint_stack) / R_stack
            return I_pv - I_pem
        except OverflowError:
            return -1e9

    fa = residual(V_lo)
    fb = residual(V_hi)

    if fa * fb > 0:
        return 0.0, 0.0   # no sign change → no intersection in range

    # Bisection — 60 iterations gives < 1e-5 V accuracy over a 7 V range
    for _ in range(60):
        Vm = (V_lo + V_hi) * 0.5
        fm = residual(Vm)
        if abs(fm) < 1e-5 or (V_hi - V_lo) < 1e-5:
            break
        if fa * fm <= 0:
            V_hi = Vm
        else:
            V_lo = Vm
            fa   = fm

    V_op = (V_lo + V_hi) * 0.5
    I_op = max((V_op - Vint_stack) / R_stack, 0.0)
    return V_op, I_op
