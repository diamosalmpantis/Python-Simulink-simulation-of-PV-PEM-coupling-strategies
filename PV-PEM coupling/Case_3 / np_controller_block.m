function Np_out = np_controller_block(G, T)
%NP_CONTROLLER_BLOCK  Real-time 2-objective Np selector for Simulink.
%
%  Place this code inside a MATLAB Function block in PV_PEM_reconfigurable.
%  Connect the live Irradiance (G) and Temperature (T) Simulink signals as
%  inputs.  The block outputs the optimal Np (5, 6, or 7) at every step.
%
%  HOW TO ADD TO SIMULINK
%  ----------------------
%  1. In PV_PEM_reconfigurable, open the Recon_sw subsystem.
%  2. Add a MATLAB Function block (from Simulink > User-Defined Functions).
%  3. Double-click → paste this entire file content.
%  4. Connect: G (irradiance signal) → input port 1
%              T (temperature signal) → input port 2
%  5. Connect: output port 1 → the Np selection logic (replaces the
%              threshold comparator blocks that read THR_97_up / THR_75_up).
%  6. Set block sample time to match Irr_stair_tsamp (= 60/scale_factor s).
%
%  TWO-OBJECTIVE FORMULATION
%  -------------------------
%  Objective 1  Maximise H2 rate:     score_H2  = I_op
%               (I_op ∝ mol H2/s via Faraday's law)
%               Prefers MORE strings.
%
%  Objective 2  Maximise PEM electro- score_eta = Vint_stack / V_op
%               chemical efficiency:  (= fraction of V_op used for water
%               splitting; 1-eta = ohmic heating fraction)
%               Prefers FEWER strings (less current → lower V_op → higher η).
%
%  ADJACENT-ONLY SWITCHING
%  -----------------------
%  The controller only considers one step at a time (7→6 or 6→5, never 7→5).
%  This is necessary because with two monotonic objectives the global winner
%  is always Np=7 (H2 objective) or Np=5 (eta objective) — Np=6 can only
%  win in a pairwise comparison against one neighbour at a time.
%
%  Crossover G values emerge from the physics (no hardcoded thresholds):
%    Np 7 → 6 : ≈ 450 W/m²
%    Np 6 → 5 : ≈ 600 W/m²
%  Both values shift ±20–40 W/m² with cell temperature (T-correction).

% -------------------------------------------------------------------------
%  PERSISTENT STATE  (survives across simulation timesteps)
% -------------------------------------------------------------------------
persistent Np_current;
if isempty(Np_current)
    Np_current = 7;   % start at maximum strings (safest at low G)
end

% -------------------------------------------------------------------------
%  SYSTEM CONSTANTS  (must match G_direct_recon__no_batt_run.m)
% -------------------------------------------------------------------------
NIGHT_THR = 70.0;    % [W/m²] below this → night, reset to 7 strings
W_H2      = 1.0/6.0; % H2 rate weight      (≈ 0.167)
W_eta     = 5.0/6.0; % PEM eta weight      (≈ 0.833)
HYST      = 0.005;   % 0.5% improvement needed to trigger a switch

% -------------------------------------------------------------------------
%  NIGHT RESET
% -------------------------------------------------------------------------
if G < NIGHT_THR
    Np_current = 7;
    Np_out = 7.0;
    return;
end

% -------------------------------------------------------------------------
%  ADJACENT-ONLY PAIRWISE SCORING
% -------------------------------------------------------------------------
% Try stepping DOWN (fewer strings: 7→6 or 6→5)
step_down = false;
if Np_current > 5
    Np_lo = Np_current - 1;
    [s_curr, s_lo] = score_pair(double(Np_current), double(Np_lo), G, T, W_H2, W_eta);
    if (s_lo - s_curr) > HYST * max(abs(s_curr), 1e-9)
        Np_current = Np_lo;
        step_down  = true;
    end
end

% Try stepping UP (more strings: 5→6 or 6→7) — only if not already stepping down
if ~step_down && Np_current < 7
    Np_hi = Np_current + 1;
    [s_curr, s_hi] = score_pair(double(Np_current), double(Np_hi), G, T, W_H2, W_eta);
    if (s_hi - s_curr) > HYST * max(abs(s_curr), 1e-9)
        Np_current = Np_hi;
    end
end

Np_out = double(Np_current);
end


% =========================================================================
%  LOCAL FUNCTION: score_pair
%  Score two adjacent Np candidates against each other.
%  Normalises only across the pair so neither magnitude dominates.
% =========================================================================
function [s_a, s_b] = score_pair(Np_a, Np_b, G, T, W_H2, W_eta)

[Va, Ia] = op_point(Np_a, G, T);
[Vb, Ib] = op_point(Np_b, G, T);

Vint = 1.475841 * 13;   % thermodynamic (reversible) stack voltage [V]

if Va > Vint + 1e-6
    eta_a = Vint / Va;
else
    eta_a = 0.0;
end
if Vb > Vint + 1e-6
    eta_b = Vint / Vb;
else
    eta_b = 0.0;
end

maxI   = max(Ia, Ib)      + 1e-9;
maxEta = max(eta_a, eta_b) + 1e-9;

s_a = W_H2 * (Ia   / maxI)   + W_eta * (eta_a / maxEta);
s_b = W_H2 * (Ib   / maxI)   + W_eta * (eta_b / maxEta);
end


% =========================================================================
%  LOCAL FUNCTION: op_point
%  Compute the PV–PEM operating point using bisection.
%  Finds voltage where PV I-V curve intersects the PEM ohmic load line.
% =========================================================================
function [V_op, I_op] = op_point(Np, G, T)

% Cell / array parameters
Ns       = 45;
Isc_c    = 10.14;  Voc_c  = 0.67;
Impp_c   =  9.59;  Vmpp_c = 0.56;
aIsc     =  5e-4;  bVoc   = -3e-3;  bVmpp = -3.5e-3;

% PEM stack parameters (N=13 cells)
N_pem    = 13;
Vint     = 1.475841 * N_pem;
R_stk    = (0.008673 + 0.00177 + 0.0005) * N_pem;
Vmax_pem = 2.0 * N_pem;

% Temperature-corrected single-diode parameters
dT       = T - 25.0;
g        = max(G / 1000.0, 1e-6);
Iph      = Np * Isc_c  * g * (1.0 + aIsc  * dT);
Impp_loc = Np * Impp_c * g * (1.0 + aIsc  * dT);
Voc_loc  = Ns * Voc_c  * (1.0 + bVoc  * dT);
Vmpp_loc = Ns * Vmpp_c * (1.0 + bVmpp * dT);

ratio = min(max(1.0 - Impp_loc / max(Iph, 1e-9), 1e-4), 1.0 - 1e-4);
Vt    = (Vmpp_loc - Voc_loc) / log(ratio);
I0    = Iph * exp(-Voc_loc / Vt);

% Search bounds
V_lo = Vint + 0.05;
V_hi = min(Voc_loc - 0.05, Vmax_pem);

% Default (no solution)
V_op = 0.0;
I_op = 0.0;

if V_lo >= V_hi
    return;
end

% Residual: f(V) = I_pv(V) - I_pem(V) = 0 at operating point
fa = (Iph - I0 * exp(V_lo / Vt)) - (V_lo - Vint) / R_stk;
fb = (Iph - I0 * exp(V_hi / Vt)) - (V_hi - Vint) / R_stk;  %#ok<NASGU>

if fa * ((Iph - I0 * exp(V_hi / Vt)) - (V_hi - Vint) / R_stk) > 0
    return;   % no sign change → no intersection in range
end

% Bisection (60 iterations → accuracy < 1e-5 V over a 7 V range)
for k = 1:60  %#ok<FORFLG>
    Vm = (V_lo + V_hi) * 0.5;
    fm = (Iph - I0 * exp(Vm / Vt)) - (Vm - Vint) / R_stk;
    if abs(fm) < 1e-5 || (V_hi - V_lo) < 1e-5
        break;
    end
    if fa * fm <= 0
        V_hi = Vm;
    else
        V_lo = Vm;
        fa   = fm;
    end
end

V_op = (V_lo + V_hi) * 0.5;
I_op = max((V_op - Vint) / R_stk, 0.0);
end
