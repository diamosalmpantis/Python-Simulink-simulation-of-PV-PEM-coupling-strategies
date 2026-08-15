%% =========================================================================
%  Case 4: Indirect_EMS_batt.m  –  Case 1b
%  Real Indirect PV → EMS → Battery + PEM  (no grid)
%
%  Topology:
%    PV ──► MPPT Conv (η=97%) ──► DC Bus (stable, ~48 V in real hw)
%                                       │
%                      ┌────────────────┼────────────────┐
%                      ▼                                 ▼
%              PEM conv (η=97%)                BiDi conv (η=97%)
%                      │                                 │
%                  PEM STACK                         Battery 12 V
%                 (PRIORITY)                          (BUFFER)
%
%  EMS Priority Dispatch (explicit control – NOT voltage-driven):
%    DAY  (Irr > NIGHT_THR = 70 W/m²):
%      1. PEM gets ALL available PV power  (up to Pmax_PEM = 1245 W)
%      2. Excess PV  (PV > Pmax_PEM) → charge battery  [if SOC < SOC_max]
%      3. Very low PV (< Pmin_PEM ≈ 42 W) → PEM OFF  (too inefficient)
%    NIGHT (Irr ≤ NIGHT_THR):
%      4. Battery discharges → PEM at rated power (Pmax_PEM)
%      5. SOC ≤ SOC_min → PEM OFF
%
%  KEY DIFFERENCE vs Case 1 (Indirect_batt.m, voltage-sharing bus):
%    Case 1   : PEM only gets ~540 W (midpoint V_bus), 68 % of PV → battery
%    Case 1b  : PEM gets up to 1245 W (rated), only ~417 W excess → battery
%    Trade-off: more daytime H₂, but battery drains faster at night (1.6 h vs 3.5 h)
%
%  SIMULATION: power-flow at 1-min resolution – NO Simulink required.
%  All PEM, PV, weather, battery parameters identical to Cases 1–4.
%  Simulink build guide: Section 10 at the bottom of this file.
% =========================================================================
clear; clc; close all;
warning('off','all');
fprintf('=== Case 1b – Real Indirect PV-EMS-Batt-PEM  (8-day power-flow) ===\n\n');

% =========================================================================
%  SECTION 1 – PEM ELECTROLYZER  (identical to Indirect_batt.m)
% =========================================================================
N           = 16;
Vint        = 1.475841;   Rint  = 0.008673;
Ra          = 0.00177;    Rc    = 0.0005;
Vint_stack  = Vint * N;                            % 23.613 V  (N=16)
Rint_stack  = Rint * N;
Ra_stack    = Ra   * N;
Rc_stack    = Rc   * N;
R_total     = Rint_stack + Ra_stack + Rc_stack;    % 0.1423 Ω

Vmin_PEM    = Vint_stack;                          % 19.19 V onset
Vmax_PEM    = 2.0 * N;                             % 26.00 V rated
Imin_PEM    = 2.2;                                 % [A] hardware minimum
Imax_PEM    = 80;                                  % [A] hardware maximum

I_rated_PEM = (Vmax_PEM - Vint_stack) / R_total;  % ≈ 47.9 A
P_rated_PEM = Vmax_PEM * I_rated_PEM;              % ≈ 1245 W
Pmax_PEM    = P_rated_PEM;
Pmin_PEM    = Vmin_PEM * Imin_PEM;                 % ≈  42 W  (hardware minimum)

fprintf('  PEM : %d cells | Vint=%.2f V | Vmin=%.1f V | Vmax=%.1f V\n', ...
        N, Vint_stack, Vmin_PEM, Vmax_PEM);
fprintf('        I_rated=%.1f A | Pmax=%.0f W | Pmin=%.1f W\n\n', ...
        I_rated_PEM, Pmax_PEM, Pmin_PEM);

% =========================================================================
%  SECTION 2 – PV ARRAY  (identical to Indirect_batt.m)
% =========================================================================
Im_PV       = 9.59;   Vm_PV    = 0.55;
Np_cell     = 7;      Ns_cell  = 60;
Isc_cell    = 10.14;  Voc_cell = 0.67;
alpha_Isc   = 0.0005;            % Isc temp coefficient [1/°C]
beta_Vmpp   = -0.0035;           % Vmpp temp coefficient [1/°C]

Vmpp        = Vm_PV  * Ns_cell;  % 33.0 V  (Ns=60)
Impp        = Im_PV  * Np_cell;  % 67.13 A
Pmpp        = Vmpp   * Impp;     % 2219  W  (STC)
cell_area   = 1.689 / 60;       % 0.02815 m² per cell  (panel area 1.689 m²)
PV_area     = Np_cell * Ns_cell * cell_area;  % 7×60×0.02815 = 11.823 m²

fprintf('  PV  : Ns=%d, Np=%d | Vmpp=%.2f V | Impp=%.2f A | Pmpp=%.0f W | Area=%.2f m²\n\n', ...
        Ns_cell, Np_cell, Vmpp, Impp, Pmpp, PV_area);

% =========================================================================
%  SECTION 3 – WEATHER DATA  (identical loading to Indirect_batt.m)
% =========================================================================
WEATHER_FILE = 'weather_profile_week.xlsx';
scale_factor = 36000;   % kept for reference / compare_batt_cases.m compatibility

if isfile(WEATHER_FILE)
    weather       = readtable(WEATHER_FILE);
    real_time_sec = weather.Time_min * 60;
    Irr_val       = weather.Irradiance;
    Temp_val      = weather.Temperature;
    NUM_DAYS      = round(max(real_time_sec) / 86400);
    fprintf('  Weather : %s | %d days | %d samples\n', ...
            WEATHER_FILE, NUM_DAYS, height(weather));
else
    error('[ERROR] %s not found in %s', WEATHER_FILE, pwd);
end

% Same 3-sample smoothing as Cases 1–4
Irr_val  = movmean(max(Irr_val,  0), 3);
Temp_val = movmean(max(Temp_val, -50), 3);

% Power-flow simulation runs at REAL time (1-min steps, no sim-time scaling)
t_real  = real_time_sec;     % [s] real-time axis
dt      = 60;                % [s] sample interval
Irr     = Irr_val;           % [W/m²]
Temp    = Temp_val;          % [°C]
N_t     = length(t_real);

NIGHT_THR = 70;    % W/m² — consistent with Cases 1–4

fprintf('  NIGHT_THR = %d W/m² | dt = %d s | N_t = %d points\n\n', ...
        NIGHT_THR, dt, N_t);

% =========================================================================
%  SECTION 4 – BATTERY PARAMETERS  (same as Cases 1–4)
% =========================================================================
% V_ref_battery: PEM bus midpoint for N=16 — equal-energy basis for all cases
V_ref_battery = (Vint_stack + Vmax_PEM) / 2;  % (23.613 + 32.0)/2 ≈ 27.81 V
% V_batt_nom = V_ref_battery → 27.81×250×0.70 = 4867 Wh (all cases equal)
V_batt_nom   = 12;          % [V]
Q_thesis     = 580;                    % [Ah]  real-world capacity
E_batt_max   = Q_thesis * V_batt_nom;  % [Wh]  total capacity
SOC_init_per = 25;                     % [%]
SOC_max_per  = 90;                     % [%]  hard charge limit
SOC_min_per  = 20;                     % [%]  hard discharge limit
SOC_max_hys  = 85;                     % [%]  re-enable charging below this
SOC_min_hys  = 25;                     % [%]  re-enable discharging above this

fprintf('  Batt: %.0f V | Q=%.0f Ah | E_max=%.0f Wh | SOC₀=%.0f%%\n', ...
        V_batt_nom, Q_thesis, E_batt_max, SOC_init_per);
fprintf('        SOC range: %.0f–%.0f %%  (usable %.0f Wh)\n\n', ...
        SOC_min_per, SOC_max_per, E_batt_max*(SOC_max_per-SOC_min_per)/100);

% =========================================================================
%  SECTION 5 – EMS & CONVERTER EFFICIENCY PARAMETERS
% =========================================================================
eta_mppt     = 0.97;    % PV → DC bus  (MPPT boost converter)
eta_pem_conv = 0.97;    % DC bus → PEM terminals  (buck converter)
eta_biDi     = 0.97;    % Bidirectional battery converter (each direction)
%  Effective round-trip storage efficiency = eta_biDi² = 0.94

%  gamma_P: PV power temperature coefficient  ≈ alpha_Isc + beta_Vmpp
gamma_P      = alpha_Isc + beta_Vmpp;        % −0.0030 /°C

%  H₂ constants (identical to Indirect_batt.m)
F_const      = 96485;        % [C/mol]
eta_F        = 0.99;         % Faraday efficiency
M_H2         = 2.016e-3;     % [kg/mol]
LHV_H2       = 119.96e6;     % [J/kg]

%  ── UNIFIED PEM POWER CAP (day AND night) ────────────────────────────────
%  This single parameter controls:
%    DAY : PEM gets min(P_pv_bus, P_PEM_MAX) → excess above P_PEM_MAX → battery
%    NIGHT: battery discharges to run PEM at P_PEM_MAX
%
%  KEY TRADE-OFF vs setting P_PEM_MAX = Pmax_PEM (1245 W):
%    Pmax (1245 W): max daytime H₂, but excess threshold = 772 W/m² → little charging
%                   night runtime = 2100/1283 = 1.6 h → battery barely contributes
%    800 W:         less daytime H₂, excess threshold = 495 W/m² → much more charging
%                   night runtime = 2100/824 = 2.55 h → meaningful battery cycling
%    600 W:         even more charging (threshold 372 W/m²), runtime 3.8 h
%
%  Rule of thumb: P_PEM_MAX ≈ P_pv_bus at median irradiance for balanced cycling.
P_PEM_MAX    = 800;     % [W]  unified day/night PEM cap — change here to explore trade-off
P_PEM_night  = P_PEM_MAX;   % night = same cap (consistent 24h operation)

%  Irradiance threshold above which excess PV goes to battery:
Irr_charge_thr = P_PEM_MAX / (eta_mppt * Pmpp / 1000);   % [W/m²]

fprintf('  EMS : eta_mppt=%.2f | eta_pem=%.2f | eta_biDi=%.2f\n', ...
        eta_mppt, eta_pem_conv, eta_biDi);
fprintf('  P_PEM_MAX = %.0f W | Excess→Batt when Irr > %.0f W/m²\n', ...
        P_PEM_MAX, Irr_charge_thr);
fprintf('  Night runtime (full batt): %.1f h | Battery drain: %.0f W\n\n', ...
        E_batt_max*(SOC_max_per-SOC_min_per)/100 / (P_PEM_night/eta_biDi), ...
        P_PEM_night/eta_biDi);

% =========================================================================
%  SECTION 6 – PV POWER MODEL  (temperature + irradiance corrected MPP)
% =========================================================================
%  Vmpp(T)    = Vmpp_STC × (1 + beta_Vmpp × (T−25))
%  Impp(T,G)  = Impp_STC × (1 + alpha_Isc × (T−25)) × (G/1000)
%  P_mpp(T,G) = Vmpp(T) × Impp(T,G)
Vmpp_T   = Vmpp .* (1 + beta_Vmpp .* (Temp - 25));
Impp_TG  = Impp .* (1 + alpha_Isc .* (Temp - 25)) .* (Irr / 1000);
P_mpp    = max(0, Vmpp_T .* Impp_TG);      % [W] at MPP (irradiance + temp corrected)

%  Effective MPP voltage (used for PEM operating point reference in plots)
Vmpp_eff = Vmpp_T;

%  Power reaching the DC bus after MPPT converter losses
P_pv_bus = P_mpp .* eta_mppt;              % [W]

fprintf('  PV model: STC Pmpp=%.0f W | peak P_pv_bus=%.0f W (η_mppt=%.0f%%)\n\n', ...
        Pmpp, max(P_pv_bus), eta_mppt*100);

% =========================================================================
%  SECTION 6b – MPPT TRACKING UNCERTAINTY
%
%  A real P&O MPPT oscillates around MPP by ±ΔP every perturbation period
%  (typically 5–30 s). At 1-min resolution this averages out, but the
%  residual tracking error still causes ≈2–3 % power spread around the
%  ideal P_mpp curve. Additional sources: sensor noise, sub-minute cloud
%  transients not captured in 1-min weather data, and converter ripple.
%
%  Model: zero-mean AR(1) multiplicative noise
%    σ   = 2.8 %   (P&O ripple + sensor noise, consistent with literature)
%    τ   = 5 min   (perturbation + averaging correlation time)
%  Applied only during daytime (night: battery dispatch is well-controlled,
%  no MPPT active → no tracking noise).
%  Fixed seed → reproducible results; does not shift mean KPIs significantly.
% =========================================================================
rng(2024);
sigma_track = 0.13;                             % tracking uncertainty [fraction]
tau_track   = 5 * 60;                            % correlation time [s]
alpha_track = exp(-dt / tau_track);              % AR(1) decay per 1-min step
eta_noise   = zeros(N_t, 1);
for ki = 2:N_t
    eta_noise(ki) = alpha_track * eta_noise(ki-1) + ...
                    sigma_track * sqrt(1 - alpha_track^2) * randn();
end
eta_noise(Irr <= NIGHT_THR) = 0;                % no MPPT noise at night

P_pv_bus_eff = max(0, P_pv_bus .* (1 + eta_noise));   % effective bus power

dm_init = Irr > NIGHT_THR;
fprintf('  MPPT tracking noise: sigma=%.1f%%  tau=%.0f min\n', sigma_track*100, tau_track/60);
fprintf('  Day mean offset: %.2f %%  (should be ~0)\n\n', ...
    (mean(P_pv_bus_eff(dm_init)) - mean(P_pv_bus(dm_init))) / mean(P_pv_bus(dm_init)) * 100);

% =========================================================================
%  SECTION 7 – EMS TIME-DOMAIN SIMULATION
%  Runs through every 1-minute real-time sample.
%  SOC is state-dependent → must be sequential.
% =========================================================================
fprintf('  Running EMS simulation (%d steps)...\n', N_t);

% Pre-allocate
P_PEM_cmd  = zeros(N_t, 1);   % [W] EMS power command to PEM
P_batt_net = zeros(N_t, 1);   % [W] net battery power  (+ charge, − discharge)
P_curtail  = zeros(N_t, 1);   % [W] PV curtailed (SOC full, no load available)
SOC_arr    = zeros(N_t, 1);   % [%]
EMS_mode   = zeros(N_t, 1);   % 0=off, 1=day/PV, 2=day/PV+charge, 3=night/batt

SOC         = SOC_init_per;
chg_inhibit = false;     % hysteresis: inhibit charging above SOC_max_hys
dis_inhibit = false;     % hysteresis: inhibit discharging below SOC_min_hys

for k = 1:N_t
    Gk = Irr(k);
    Pk = P_pv_bus_eff(k);   % PV power at bus [W] — includes MPPT tracking noise

    % ─── DAYTIME ─────────────────────────────────────────────────────────
    if Gk > NIGHT_THR

        if Pk >= Pmin_PEM
            % Step 1: PEM gets all PV (first priority), capped at P_PEM_MAX
            P_PEM_cmd(k) = min(Pk, P_PEM_MAX);
            EMS_mode(k)  = 1;   % day, PV → PEM

            % Step 2: PV above P_PEM_MAX → charge battery
            P_excess = Pk - P_PEM_MAX;    % [W]  positive when PV > cap
            if P_excess > 1
                if SOC < SOC_max_per && ~chg_inhibit
                    P_batt_net(k) = P_excess * eta_biDi;   % into battery
                    EMS_mode(k)   = 2;   % day, PV → PEM + charging
                else
                    P_curtail(k) = P_excess;   % SOC full → curtail
                end
            end
        else
            % Very low PV (< Pmin_PEM ≈ 42 W): PEM off
            P_PEM_cmd(k) = 0;
            EMS_mode(k)  = 0;
        end

    % ─── NIGHT (Irr ≤ NIGHT_THR) ─────────────────────────────────────────
    %  At dawn/dusk some PV may still be available (e.g. Irr=30-70 W/m²).
    %  Use it first → battery only covers the shortfall.
    %  This prevents wasting PV AND reduces battery depth-of-discharge.
    else
        if SOC > SOC_min_per && ~dis_inhibit
            P_pv_avail    = Pk;                                   % PV at bus [W]
            P_pv_use      = min(P_pv_avail, P_PEM_night);         % use PV first
            P_batt_needed = max(0, P_PEM_night - P_pv_use);       % battery covers rest
            P_PEM_cmd(k)  = P_PEM_night;                          % target power
            P_batt_net(k) = -(P_batt_needed / eta_biDi);          % discharge only shortfall
            EMS_mode(k)   = 3;   % night, battery (+ any PV) → PEM
        else
            % Battery empty or inhibited → PEM off
            P_PEM_cmd(k) = 0;
            EMS_mode(k)  = 0;
        end
    end

    % ─── HYSTERESIS FLAGS ────────────────────────────────────────────────
    if SOC >= SOC_max_per,  chg_inhibit = true;  end
    if SOC <= SOC_max_hys,  chg_inhibit = false; end
    if SOC <= SOC_min_per,  dis_inhibit = true;  end
    if SOC >= SOC_min_hys,  dis_inhibit = false; end

    % ─── SOC UPDATE ──────────────────────────────────────────────────────
    delta_E   = P_batt_net(k) * dt / 3600;           % [Wh]  + = store
    delta_SOC = delta_E / E_batt_max * 100;           % [%]
    SOC       = SOC + delta_SOC;
    SOC       = max(SOC_min_per, min(SOC_max_per, SOC));
    SOC_arr(k) = SOC;
end

fprintf('  EMS done. Final SOC=%.1f%%  |  Min SOC=%.1f%%\n\n', ...
        SOC_arr(end), min(SOC_arr));

% =========================================================================
%  SECTION 8 – H₂ PRODUCTION & EFFICIENCY METRICS
% =========================================================================
% Solve I_PEM from P_PEM_cmd using Randles quadratic:
%   R_total × I² + Vint_stack × I − P_at_stack = 0
%   I = (−Vint + sqrt(Vint² + 4·R·P)) / (2·R)
P_at_stack = P_PEM_cmd ./ eta_pem_conv;         % [W] power at PEM terminals
disc       = Vint_stack^2 + 4 .* R_total .* P_at_stack;
I_PEM      = (-Vint_stack + sqrt(max(0, disc))) ./ (2 .* R_total);
I_PEM      = max(0, min(I_PEM, Imax_PEM));

V_PEM      = Vint_stack + I_PEM .* R_total;     % [V] PEM operating voltage
P_PEM      = V_PEM .* I_PEM;                    % [W] actual PEM power

% Battery current (derived from power, for plotting)
Batt_I     = -P_batt_net ./ V_batt_nom;         % [A]  + = discharge current out

% H₂ production — Faraday law (same formula as Indirect_batt.m)
n_H2      = (N .* I_PEM) ./ (2 .* F_const) .* eta_F;  % [mol/s]
H2_inst   = n_H2 .* M_H2 .* 1e3;                       % [g/s]
H2_rate   = H2_inst .* 3600;                            % [g/h]
H2_cumul  = cumtrapz(t_real, H2_inst);                  % [g]

% Source attribution (use P_pv_bus_eff so attribution is consistent with EMS decisions)
P_pv_to_PEM   = min(P_PEM_cmd, P_pv_bus_eff);
P_batt_to_PEM = max(0, P_PEM_cmd - P_pv_to_PEM);
safe_src       = max(P_pv_to_PEM + P_batt_to_PEM, 1e-6);
H2_cumul_PV   = cumtrapz(t_real, H2_inst .* P_pv_to_PEM   ./ safe_src);
H2_cumul_Batt = cumtrapz(t_real, H2_inst .* P_batt_to_PEM ./ safe_src);

% Battery energy
E_chg_Wh = sum(max(0,  P_batt_net)) * dt / 3600;   % energy stored in battery
E_dis_Wh = sum(max(0, -P_batt_net)) * dt / 3600;   % energy drawn from battery
%  η_RT fix: E_dis > E_chg when initial SOC is consumed (not a real cycle).
%  Remove the initial SOC contribution before computing round-trip efficiency.
E_initial_net = (SOC_init_per - SOC_arr(end)) / 100 * E_batt_max;  % Wh from initial SOC
E_dis_cycle   = max(0, E_dis_Wh - max(0, E_initial_net));           % cycling discharge only
if E_chg_Wh > 1
    %  Both charge AND discharge pass through the BiDi converter (each at η_biDi),
    %  so round-trip efficiency = η_biDi² × (E_dis_cycle / E_chg_Wh).
    %  Without the η_biDi² factor the formula gives >100 % and is wrong.
    eta_batt_RT = E_dis_cycle * eta_biDi^2 / E_chg_Wh * 100;   % true round-trip η
else
    eta_batt_RT = eta_biDi^2 * 100;   % theoretical = 0.97² ≈ 94%
end

% Nighttime H₂
nm_mask      = Irr <= NIGHT_THR;
dm_mask      = ~nm_mask;
%  FIX: do NOT use trapz(t(mask), y(mask)) — it connects non-consecutive
%  nighttime samples across daytime gaps and inflates the integral ~5×.
%  Correct approach: zero out daytime values, integrate the full vector.
H2_inst_night            = H2_inst;
H2_inst_night(dm_mask)   = 0;          % zero daytime; leave nighttime intact
H2_night     = trapz(t_real, H2_inst_night);
H2_night_pct = H2_night / max(H2_cumul(end), 1e-6) * 100;
H2_PV_pct    = H2_cumul_PV(end)   / max(H2_cumul(end), 1e-6) * 100;
H2_Batt_pct  = H2_cumul_Batt(end) / max(H2_cumul(end), 1e-6) * 100;

% PV coupling efficiency
G_safe     = max(Irr, 10);
P_mpp_ref  = P_mpp;
Coupling_C = P_pv_to_PEM ./ max(P_mpp_ref, 1e-3);
Coupling_C = max(0, min(1.0, Coupling_C));
Coupling_C(nm_mask) = NaN;

% PV efficiency (eta_mppt already baked into P_pv_bus)
eta_PV     = P_pv_bus ./ (PV_area .* G_safe) * 100;
eta_PV(nm_mask) = NaN;
eta_PV     = max(0, min(100, eta_PV));

% PEM electrochemical efficiency
eta_PEM    = NaN(size(V_PEM));
valid_pem  = V_PEM > (Vint_stack + 0.1);
eta_PEM(valid_pem) = (Vint_stack ./ V_PEM(valid_pem)) * 100;
eta_PEM    = max(0, min(100, eta_PEM));

% PEM capacity factor
CF_PEM     = sum(P_at_stack > 0.10 * Pmax_PEM) / N_t * 100;

% C_sys
C_sys      = P_PEM ./ max(P_mpp_ref, 1e-3);
C_sys(nm_mask) = NaN;
C_sys      = min(C_sys, 2.0);

% STH & TTH
pv_frac         = P_pv_to_PEM ./ safe_src;
H2_power_solar  = H2_inst .* pv_frac * 1e-3 * LHV_H2;
STH             = H2_power_solar ./ (PV_area .* G_safe) * 100;
STH(nm_mask)    = NaN;
STH             = max(0, STH);

H2_power_total  = H2_inst * 1e-3 * LHV_H2;
TTH             = H2_power_total ./ (PV_area .* G_safe) * 100;
TTH(nm_mask)    = NaN;
TTH             = max(0, TTH);
TTH_8day        = (H2_cumul(end)*1e-3*LHV_H2) / trapz(t_real, Irr .* PV_area) * 100;

% SOC final
SOC_final     = SOC_arr(end);
E_initial_Wh  = max(0, (SOC_init_per - SOC_final)/100 * E_batt_max);
E_dis_cycle   = max(0, E_dis_Wh - E_initial_Wh);

% ── Console KPI summary ──────────────────────────────────────────────────
fprintf('  ════════════════════════════════════════════════════\n');
fprintf('  H₂ TOTAL (8-day)       : %.3f g\n',  H2_cumul(end));
fprintf('     from PV             : %.3f g  (%.1f%%)\n', H2_cumul_PV(end),   H2_PV_pct);
fprintf('     from Battery        : %.3f g  (%.1f%%)\n', H2_cumul_Batt(end), H2_Batt_pct);
fprintf('     at night (Irr<%d)  : %.3f g  (%.1f%%)\n', NIGHT_THR, H2_night, H2_night_pct);
fprintf('  PEM capacity factor    : %.2f %%\n',  CF_PEM);
fprintf('  C_PV  (daytime mean)   : %.3f\n',     mean(Coupling_C(dm_mask),'omitnan'));
fprintf('  C_sys (daytime mean)   : %.3f\n',     mean(C_sys,'omitnan'));
fprintf('  Mean eta_PV (daytime)  : %.2f %%\n',  mean(eta_PV(dm_mask),'omitnan'));
fprintf('  Mean eta_PEM (active)  : %.2f %%\n',  mean(eta_PEM(valid_pem),'omitnan'));
fprintf('  Mean STH (daytime)     : %.3f %%\n',  mean(STH(dm_mask),'omitnan'));
fprintf('  Mean TTH (daytime)     : %.3f %%\n',  mean(TTH(dm_mask),'omitnan'));
fprintf('  Total TTH (8-day)      : %.3f %%\n',  TTH_8day);
fprintf('  Battery E_chg          : %.1f Wh\n',  E_chg_Wh);
fprintf('  Battery E_dis          : %.1f Wh\n',  E_dis_Wh);
fprintf('  Battery η_RT           : %.1f %%\n',  eta_batt_RT);
fprintf('  PV curtailed           : %.1f Wh\n',  sum(P_curtail)*dt/3600);
fprintf('  SOC final              : %.1f %%\n',  SOC_final);
fprintf('  ════════════════════════════════════════════════════\n\n');

% =========================================================================
%  SECTION 9 – PLOTS  (same style as Cases 1–4)
% =========================================================================
t_day  = t_real / 86400;    % convert seconds → days for x-axis
clr_pv   = [0.93 0.69 0.13];
clr_pem  = [0.20 0.63 0.17];
clr_batt = [0.12 0.47 0.71];
clr_irr  = [0.85 0.33 0.10];
clr_h2   = [0.49 0.18 0.56];
clr_mode = [0.64 0.08 0.18];

% ── Figure 1: System Power Overview ──────────────────────────────────────
fig1 = figure('Name','Case1b System Overview','Position',[50 50 1200 800]);
tl1  = tiledlayout(3,1,'TileSpacing','compact','Padding','compact');

nexttile
  yyaxis left
  plot(t_day, Irr, 'Color', clr_irr, 'LineWidth', 0.8);
  ylabel('Irradiance (W/m²)'); ylim([0 1100]);
  yyaxis right
  plot(t_day, P_mpp, '--', 'Color', clr_pv, 'LineWidth', 1.2);
  hold on;
  plot(t_day, P_pv_bus_eff, 'Color', clr_pv, 'LineWidth', 1.5);
  ylabel('PV Power (W)'); ylim([0 2000]);
  legend({'Irr','P_{mpp} STC','P_{pv,bus} (w/ tracking)'},'Location','northeast','FontSize',8);
  title('PV Irradiance & Available Bus Power');
  grid on; xlim([0 max(t_day)]);

nexttile
  plot(t_day, P_PEM_cmd/1e3, 'Color', clr_pem, 'LineWidth', 1.5); hold on;
  plot(t_day, P_PEM/1e3,     ':', 'Color', clr_pem*0.7, 'LineWidth', 1.0);
  yline(Pmax_PEM/1e3,  '--r', sprintf('P_{max}=%.0f W', Pmax_PEM), 'FontSize', 8);
  yline(Pmin_PEM/1e3,  ':k',  sprintf('P_{min}=%.0f W', Pmin_PEM), 'FontSize', 8);
  ylabel('Power (kW)'); ylim([-0.1 1.6]);
  legend({'P_{PEM,cmd}','P_{PEM,actual}'},'Location','northeast','FontSize',8);
  title('PEM Power (EMS Commanded vs Actual)');
  grid on; xlim([0 max(t_day)]);

nexttile
  % Battery power: positive = charging, negative = discharging
  area(t_day,  max(0, P_batt_net)/1e3, 'FaceColor', [0.8 0.9 1.0], ...
       'EdgeColor', clr_batt, 'DisplayName', 'Charging');
  hold on;
  area(t_day, -max(0,-P_batt_net)/1e3, 'FaceColor', [1.0 0.8 0.8], ...
       'EdgeColor', [0.8 0.2 0.2], 'DisplayName', 'Discharging');
  ylabel('Battery Power (kW)'); grid on;
  legend('Location','northeast','FontSize',8);
  title('Battery Power (EMS Commanded)');
  xlim([0 max(t_day)]); xlabel('Time (days)');

title(tl1, sprintf('Case 1b – Real Indirect EMS  |  N=%d cells | Q=%.0f Ah | Pmax_{PEM}=%.0f W', ...
      N, Q_thesis, Pmax_PEM), 'FontSize', 12, 'FontWeight', 'bold');

% ── Figure 2: Battery EMS & SOC ──────────────────────────────────────────
fig2 = figure('Name','Case1b Battery EMS','Position',[100 50 1200 700]);
tl2  = tiledlayout(3,1,'TileSpacing','compact','Padding','compact');

nexttile
  plot(t_day, SOC_arr, 'Color', clr_batt, 'LineWidth', 2); hold on;
  yline(SOC_max_per, '--r', sprintf('SOC_{max}=%.0f%%', SOC_max_per), 'FontSize', 8);
  yline(SOC_min_per, '--m', sprintf('SOC_{min}=%.0f%%', SOC_min_per), 'FontSize', 8);
  yline(SOC_init_per, ':k', sprintf('SOC_{0}=%.0f%%',   SOC_init_per), 'FontSize', 8);
  ylabel('SOC (%)'); ylim([0 105]);
  title(sprintf('Battery SOC  |  Q=%.0f Ah, V=%.0f V, E_{max}=%.0f Wh', ...
        Q_thesis, V_batt_nom, E_batt_max));
  grid on; xlim([0 max(t_day)]);

nexttile
  % EMS mode colour bands
  mode_colours = [0.85 0.85 0.85;  % 0 = OFF
                  0.99 0.99 0.70;  % 1 = day PV
                  0.70 0.99 0.70;  % 2 = day PV + charge
                  0.70 0.80 0.99]; % 3 = night batt
  mode_labels  = {'PEM OFF','Day / PV','Day / PV + Chg','Night / Batt'};
  for m = 0:3
    mask_m = EMS_mode == m;
    if any(mask_m)
      area(t_day, double(mask_m)*(m+1), 'FaceColor', mode_colours(m+1,:), ...
           'EdgeColor', 'none', 'DisplayName', mode_labels{m+1});
      hold on;
    end
  end
  yticks(0.5:3.5); yticklabels({}); ylim([0 4]);
  legend('Location','northeast','FontSize',8);
  title('EMS Operating Mode'); ylabel('Mode'); grid on;
  xlim([0 max(t_day)]);

nexttile
  plot(t_day, Batt_I, 'Color', clr_batt, 'LineWidth', 1.2); hold on;
  yline(0, 'k:', 'LineWidth', 0.8);
  ylabel('Battery Current (A)'); grid on;
  title('Battery Current  (positive = discharge out of battery)');
  xlim([0 max(t_day)]); xlabel('Time (days)');

title(tl2, sprintf('Battery EMS  |  V_{nom}=%.0f V, Q=%.0f Ah, SOC_0=%.0f%% (real EMS)', ...
      V_batt_nom, Q_thesis, SOC_init_per), 'FontSize', 11, 'FontWeight', 'bold');

% ── Figure 3: H₂ Production ──────────────────────────────────────────────
fig3 = figure('Name','Case1b H2 Production','Position',[150 50 1200 700]);
tl3  = tiledlayout(3,1,'TileSpacing','compact','Padding','compact');

nexttile
  plot(t_day, H2_cumul, 'Color', clr_h2, 'LineWidth', 2); hold on;
  plot(t_day, H2_cumul_PV,   '--', 'Color', clr_pv,   'LineWidth', 1.2);
  plot(t_day, H2_cumul_Batt, '--', 'Color', clr_batt,  'LineWidth', 1.2);
  ylabel('H₂ (g)');
  legend({'Total','From PV','From Battery'},'Location','northwest','FontSize',8);
  title(sprintf('Cumulative H₂  |  Total=%.1f g  (PV=%.0f%%  Batt=%.0f%%)', ...
        H2_cumul(end), H2_PV_pct, H2_Batt_pct));
  grid on; xlim([0 max(t_day)]);

nexttile
  plot(t_day, H2_rate, 'Color', clr_h2, 'LineWidth', 1.2); hold on;
  % Night shading
  night_mask_t = Irr <= NIGHT_THR;
  y_lim_h2     = [0 max(H2_rate)*1.15 + 0.01];
  for k2 = find(diff([0; night_mask_t; 0]) == 1)'
    k_end = find(diff([0; night_mask_t; 0]) == -1, 1, 'first') + k2 - 1;
    if k_end > N_t, k_end = N_t; end
    patch([t_day(k2) t_day(min(k_end,N_t)) t_day(min(k_end,N_t)) t_day(k2)], ...
          [y_lim_h2(1) y_lim_h2(1) y_lim_h2(2) y_lim_h2(2)], ...
          [0.9 0.9 0.9], 'EdgeColor', 'none', 'FaceAlpha', 0.4, 'HandleVisibility','off');
  end
  ylabel('H₂ rate (g/h)'); ylim(y_lim_h2);
  title(sprintf('H₂ Rate  |  Night=%.1f g (%.0f%%)', H2_night, H2_night_pct));
  grid on; xlim([0 max(t_day)]);

nexttile
  plot(t_day, SOC_arr, 'Color', clr_batt, 'LineWidth', 1.5); hold on;
  yyaxis right;
  plot(t_day, H2_cumul, 'Color', clr_h2, 'LineWidth', 1.5);
  ylabel('Cumulative H₂ (g)');
  yyaxis left;
  ylabel('SOC (%)'); ylim([0 105]);
  legend({'SOC','Cumul. H₂'},'Location','northwest','FontSize',8);
  title('SOC vs Cumulative H₂'); grid on;
  xlim([0 max(t_day)]); xlabel('Time (days)');

title(tl3, sprintf('H₂ Production  |  Case 1b Real Indirect EMS  |  Q=%.0f Ah', ...
      Q_thesis), 'FontSize', 11, 'FontWeight', 'bold');

% ── Figure 4: Efficiency Overview ────────────────────────────────────────
fig4 = figure('Name','Case1b Efficiency','Position',[200 50 1200 700]);
tl4  = tiledlayout(3,1,'TileSpacing','compact','Padding','compact');

nexttile
  plot(t_day, eta_PV, 'Color', clr_pv, 'LineWidth', 1.2);
  yline(mean(eta_PV(dm_mask),'omitnan'), '--', 'Color', clr_pv, 'LineWidth', 1.0, ...
        'Label', sprintf('μ=%.1f%%', mean(eta_PV(dm_mask),'omitnan')));
  ylabel('η_{PV} (%)'); ylim([0 25]);
  title('PV Efficiency  (η = P_{pv,bus} / (A × G), daytime only)');
  grid on; xlim([0 max(t_day)]);

nexttile
  plot(t_day, Coupling_C, 'Color', clr_pv, 'LineWidth', 1.0); hold on;
  yline(mean(Coupling_C(dm_mask),'omitnan'), '--', 'Color', clr_pv*0.7, 'LineWidth', 1.0);
  plot(t_day, C_sys, 'Color', clr_pem, 'LineWidth', 1.2);
  yline(mean(C_sys,'omitnan'), '--', 'Color', clr_pem*0.7, 'LineWidth', 1.0);
  ylabel('Coupling (-)'); ylim([0 1.15]);
  legend({'C_{PV}  = P_{PV→PEM}/P_{mpp}', ...
          sprintf('μ C_{PV}=%.3f', mean(Coupling_C(dm_mask),'omitnan')), ...
          'C_{sys} = P_{PEM}/P_{mpp}', ...
          sprintf('μ C_{sys}=%.3f', mean(C_sys,'omitnan'))}, ...
          'Location','northeast','FontSize',8);
  title('PV–PEM Coupling Efficiency (daytime)');
  grid on; xlim([0 max(t_day)]);

nexttile
  plot(t_day, STH, 'Color', clr_h2,   'LineWidth', 1.2); hold on;
  plot(t_day, TTH, 'Color', clr_mode, 'LineWidth', 1.0, 'LineStyle','--');
  yline(mean(STH,'omitnan'), '-.',  'Color', clr_h2*0.7, 'LineWidth', 1.0);
  yline(mean(TTH,'omitnan'), '--',  'Color', clr_mode*0.7, 'LineWidth', 1.0);
  ylabel('Efficiency (%)');
  legend({sprintf('STH  μ=%.2f%%', mean(STH,'omitnan')), ...
          sprintf('TTH  μ=%.2f%%', mean(TTH,'omitnan'))}, ...
          'Location','northeast','FontSize',8);
  title(sprintf('STH & TTH  |  8-day TTH=%.3f%%', TTH_8day));
  grid on; xlim([0 max(t_day)]); xlabel('Time (days)');

title(tl4, sprintf('Efficiency – Case 1b  |  η_{biDi}=%.0f%%  |  η_{PEM-conv}=%.0f%%', ...
      eta_biDi*100, eta_pem_conv*100), 'FontSize', 11, 'FontWeight', 'bold');

% =========================================================================
%  SECTION 10 – EXCEL EXPORT
%  Column names EXACTLY match Cases 1–4 so compare_batt_cases.m can load
%  Case 1b (EMS) with the identical col_safe() calls as the Simulink cases.
% =========================================================================
OUT_FILE = 'Indirect_EMS_batt_results.xlsx';
try
    if isfile(OUT_FILE), delete(OUT_FILE); end

    % ── Bus-side battery power columns ───────────────────────────────────────
    %  The EMS stores power at the BATTERY TERMINAL (P_batt_net).
    %  compare_batt_cases.m computes η_RT = ∫P_dis / ∫P_chg from these columns.
    %  For consistency we export the BUS-SIDE powers so that E_dis/E_chg gives
    %  the true round-trip efficiency (~η_biDi² ≈ 94 %).
    %    Charge:   bus provides P_excess → BiDi (η_biDi) → battery stores P_excess·η
    %              bus-side chg power = P_excess = P_batt_net(+) / η_biDi
    %    Discharge: battery supplies Y → BiDi (η_biDi) → bus gets Y·η
    %              bus-side dis power = Y·η = (-P_batt_net) · η_biDi
    Batt_P_chg_bus = max(0,  P_batt_net) / eta_biDi;   % [W]  bus → battery
    Batt_P_dis_bus = max(0, -P_batt_net) * eta_biDi;   % [W]  battery → bus

    % ── TimeSeries sheet (same column names as Cases 1–4) ────────────────────
    T_out = table( ...
        t_real / 3600,  t_real, Irr, P_mpp, P_pv_bus_eff, P_PEM, ...
        P_batt_net, Batt_P_chg_bus, Batt_P_dis_bus, SOC_arr, ...
        H2_rate, H2_cumul, H2_cumul_PV, H2_cumul_Batt, ...
        Coupling_C, C_sys, eta_PV, eta_PEM, STH, TTH, ...
        I_PEM, V_PEM, ...
        'VariableNames', { ...
            't_plot_[h]','t_real_[s]','Irr_[W/m2]','P_mpp_[W]','PV_P_[W]','PEM_P_[W]', ...
            'Batt_P_[W]','Batt_P_chg_[W]','Batt_P_dis_[W]','Batt_SOC_[%]', ...
            'H2_rate_[g_h]','H2_cumul_[g]','H2_cumul_PV_[g]','H2_cumul_Batt_[g]', ...
            'Coupling_C','C_sys','eta_PV_[pct]','eta_PEM_[pct]','STH_[pct]','TTH_[pct]', ...
            'I_PEM_[A]','V_PEM_[V]'});
    writetable(T_out, OUT_FILE, 'Sheet','TimeSeries','WriteMode','overwritesheet');

    % ── Parameters sheet (same structure/keys as Cases 1–4) ──────────────────
    %  compare_batt_cases.m reads 'NUM_DAYS' and 'Pmax_PEM_[W]' from this sheet.
    paramNames = {'Case'; 'N_cells_PEM'; 'Np_cell'; 'Ns_cell'; 'PV_area_[m2]'; ...
                  'Vmax_PEM_[V]'; 'Imax_PEM_[A]'; 'Pmax_PEM_[W]'; 'P_PEM_MAX_[W]'; ...
                  'V_batt_nom_[V]'; 'Q_thesis_[Ah]'; 'SOC_init_[%]'; ...
                  'NIGHT_THR_[W/m2]'; 'NUM_DAYS'; 'eta_mppt'; 'eta_pem_conv'; 'eta_biDi'; ...
                  'H2_total_[g]'; 'H2_PV_[g]'; 'H2_Batt_[g]'; 'H2_night_[g]'; ...
                  'H2_PV_[%]'; 'H2_Batt_[%]'; 'H2_night_[%]'; ...
                  'E_chg_[Wh]'; 'E_dis_[Wh]'; 'eta_batt_RT_[%]'; ...
                  'eta_PV_mean_[%]'; 'eta_PEM_mean_[%]'; ...
                  'STH_mean_[%]'; 'TTH_mean_[%]'; 'TTH_8day_[%]'; ...
                  'CF_PEM_[%]'; 'PV_curtailed_[Wh]'};
    paramValues = [1.5; N; Np_cell; Ns_cell; PV_area; ...
                   Vmax_PEM; Imax_PEM; Pmax_PEM; P_PEM_MAX; ...
                   V_batt_nom; Q_thesis; SOC_init_per; ...
                   NIGHT_THR; NUM_DAYS; eta_mppt; eta_pem_conv; eta_biDi; ...
                   H2_cumul(end); H2_cumul_PV(end); H2_cumul_Batt(end); H2_night; ...
                   H2_PV_pct; H2_Batt_pct; H2_night_pct; ...
                   E_chg_Wh; E_dis_Wh; eta_batt_RT; ...
                   mean(eta_PV(dm_mask),'omitnan'); mean(eta_PEM(valid_pem),'omitnan'); ...
                   mean(STH(dm_mask),'omitnan'); mean(TTH(dm_mask),'omitnan'); TTH_8day; ...
                   CF_PEM; sum(P_curtail)*dt/3600];
    PARAM = table(paramNames, paramValues, 'VariableNames',{'Parameter','Value'});
    writetable(PARAM, OUT_FILE, 'Sheet','Parameters','WriteMode','overwritesheet');

    fprintf('  Results saved → %s\n\n', OUT_FILE);
catch eX
    fprintf('  [WARN] Excel write failed: %s\n\n', eX.message);
end

% =========================================================================
%  SECTION 11 – SIMULINK BUILD GUIDE
%  (this section is COMMENTS ONLY — no MATLAB code)
%
%  To build the matching Simulink model (PV_PEM_real_indirect.slx):
%
%  ┌─────────────────────────────────────────────────────────────────────┐
%  │  BLOCK 1 – PV SOURCE                                                │
%  │   • Use the same Solar Cell Array block as in Case 1                │
%  │   • Parameters: Np_cell=7, Ns_cell=45  (same as Case 1)            │
%  │   • Drive with Irr_stair_ts and Temp_stair_ts from workspace        │
%  └─────────────────────────────────────────────────────────────────────┘
%
%  ┌─────────────────────────────────────────────────────────────────────┐
%  │  BLOCK 2 – MPPT BOOST CONVERTER  (PV-side MPPT — KEY DIFFERENCE)  │
%  │   • Input: PV terminals                                             │
%  │   • Output: DC bus (48 V reference — set large bus capacitor)      │
%  │   • MPPT algorithm: P&O on V_PV (not V_bus as in Case 1)           │
%  │     → Measure V_PV and I_PV on the PV side                         │
%  │     → RefGen adjusts duty D to keep V_PV = Vmpp = 24.75 V          │
%  │   • In Case 1 the RefGen varied Vref (V_bus); here it must          │
%  │     vary D directly to regulate V_PV. Change the RefGen script:     │
%  │       old: Vrefinit = 23.5; Vrefmax = 24; Vrefmini = 22;           │
%  │       new: Vrefinit = Vmpp; target V_PV, not V_bus                 │
%  └─────────────────────────────────────────────────────────────────────┘
%
%  ┌─────────────────────────────────────────────────────────────────────┐
%  │  BLOCK 3 – PEM BUCK CONVERTER  (new block, not in Case 1)          │
%  │   • Input: DC bus (48 V)                                            │
%  │   • Output: PEM terminals (19–26 V)                                 │
%  │   • Control: CURRENT reference from EMS block                       │
%  │     I_PEM_ref = solve_I_from_P(EMS.P_PEM_cmd, Vint_stack, R_total)│
%  │   • Use PI current controller: error = I_PEM_ref − I_PEM_meas      │
%  └─────────────────────────────────────────────────────────────────────┘
%
%  ┌─────────────────────────────────────────────────────────────────────┐
%  │  BLOCK 4 – BIDIRECTIONAL CONVERTER  (modified from Case 1)         │
%  │   • Input/Output: DC bus ↔ Battery (12 V)                          │
%  │   • Control: POWER reference from EMS block                         │
%  │     P_batt_ref: + = charge, − = discharge                          │
%  │   • Replace the Day_mode V_ref switching (Case 1) with             │
%  │     a power-loop PI: error = P_batt_ref − P_batt_meas              │
%  └─────────────────────────────────────────────────────────────────────┘
%
%  ┌─────────────────────────────────────────────────────────────────────┐
%  │  BLOCK 5 – EMS STATEFLOW / MATLAB FUNCTION BLOCK  (NEW)           │
%  │   Inputs:  P_pv_bus, P_PEM_meas, SOC, Irr                          │
%  │   Outputs: I_PEM_ref (to PEM buck conv), P_batt_ref (to BiDi)      │
%  │   States: DAY_PV / DAY_PV_CHARGE / NIGHT_BATT / OFF               │
%  │                                                                     │
%  │   Pseudocode (implement in MATLAB Function block):                  │
%  │     if Irr > NIGHT_THR                                              │
%  │       if P_pv_bus >= Pmin_PEM                                       │
%  │         P_pem_ref = min(P_pv_bus, Pmax_PEM)                        │
%  │         P_batt_ref = (P_pv_bus - Pmax_PEM) * (P_pv_bus>Pmax_PEM)  │
%  │       else                                                          │
%  │         P_pem_ref = 0; P_batt_ref = 0                              │
%  │       end                                                           │
%  │     else  % night                                                   │
%  │       if SOC > SOC_min                                              │
%  │         P_pem_ref = Pmax_PEM; P_batt_ref = -Pmax_PEM/eta_biDi     │
%  │       else                                                          │
%  │         P_pem_ref = 0; P_batt_ref = 0                              │
%  │       end                                                           │
%  │     end                                                             │
%  │     I_PEM_ref = solve_quadratic(P_pem_ref)                         │
%  └─────────────────────────────────────────────────────────────────────┘
%
%  SUMMARY OF CHANGES vs Case 1 (Indirect_batt.m) Simulink model:
%  ┌──────────────────────┬───────────────────────┬─────────────────────┐
%  │ Component            │ Case 1                │ Case 1b (Real EMS)  │
%  ├──────────────────────┼───────────────────────┼─────────────────────┤
%  │ PV MPPT              │ Vref of V_bus varies  │ V_PV held at Vmpp   │
%  │ DC bus voltage       │ ~22–24 V (floating)   │ 48 V (regulated)    │
%  │ PEM connection       │ Direct to bus         │ Via buck converter  │
%  │ PEM control          │ Voltage-driven (load) │ Current-controlled  │
%  │ Battery control      │ Day/night V_ref switch│ EMS power command   │
%  │ Priority             │ None (passive share)  │ PEM FIRST (EMS)     │
%  └──────────────────────┴───────────────────────┴─────────────────────┘
% =========================================================================

fprintf('=== Case 1b simulation complete ===\n');
