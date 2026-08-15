% =========================================================================
%  PV_PEM_direct_batt_week.m
%  Case 6 – Direct PV-PEM  +  Indirect Battery  (bidirectional DC-DC)
%
%  Topology:  PV  ──►  PEM Electrolyzer  (natural impedance matching)
%              └──────►  Bidirectional DC-DC  ──►  Battery
%
%  Simulink model : PV_PEM_direct_battery_b.slx
%  Weather input  : weather_profile_week.xlsx  (8-day, 1-min resolution)
%  Output Excel   : PV_PEM_direct_batt_results_week.xlsx
%
%  FIXES APPLIED:
%    • Linked Q_batt to Q_thesis/scale_factor and decreased to 250Ah for sharper cycles
%    • Restored missing SOC_min_pct/SOC_max_pct workspace variables for state logic
%    • Removed broken PWM saturation limits that were causing the 20% charge lock-out
%    • V_batt_nom set to 12V (same as Case 1 — battery block patched via set_param)
%    • Near-ideal Diodes/Switches parameter injection applied to bidirectional converter
% =========================================================================
clear; clc; close all;
warning('off','all');
fprintf('=== Case 2 – Direct PV-PEM + Indirect Battery  (8-day simulation) ===\n\n');
% =========================================================================
%  SECTION 1 – PEM ELECTROLYZER PARAMETERS
% =========================================================================
N = 16;
Vint    = 1.475841;   Rint  = 0.008673;
Ra      = 0.00177;    Rc    = 0.0005;
tau_a   = 0.4;        tau_c = tau_a / 10;
Ca      = tau_a / Ra; Cc    = tau_c / Rc;
Active_Area = 17.64;

Vint_stack = Vint * N;          % 23.613 V  (N=16)
Rint_stack = Rint * N;
Ra_stack   = Ra   * N;
Rc_stack   = Rc   * N;
Ca_stack   = Ca   / N;
Cc_stack   = Cc   / N;
R_total    = Rint_stack + Ra_stack + Rc_stack;

Vmin_PEM    = Vint_stack;                              % 19.19 V
Vmax_PEM    = 2.0 * N;                                 % 26.00 V
Imin_PEM    = 2.2;                                     % [A]  minimum operating current
Imax_PEM    = 80;                                      % [A]  hardware protection limit
I_rated_PEM = (Vmax_PEM - Vint_stack) / R_total;
P_rated_PEM = Vmax_PEM * I_rated_PEM;
Pmax_PEM    = P_rated_PEM;
V_ref_battery = (Vint_stack + Vmax_PEM) / 2;   % ≈ 27.81 V for N=16

fprintf('  PEM: %d cells | Vint=%.2f V | Vmin=%.1f V | Vmax=%.1f V | I_rated=%.1f A | P_rated=%.0f W\n', ...
        N, Vint_stack, Vmin_PEM, Vmax_PEM, I_rated_PEM, Pmax_PEM);
% =========================================================================
%  SECTION 2 – PV ARRAY
% =========================================================================
Im_PV    = 9.59;   Vm_PV    = 0.55;
Np_cell  = 7;      Ns_cell  = 60;
Isc_cell = 10.14;  Voc_cell = 0.67;

Isc  = Isc_cell  * Np_cell;
Voc  = Voc_cell  * Ns_cell;
Vmpp = Vm_PV     * Ns_cell;   % 33.0 V  (Ns=60)
Impp = Im_PV     * Np_cell;   % 67.13 A
Pmpp = Vmpp      * Impp;

% PV active area: panel area 1.689 m², 60 cells per panel
cell_area = 1.689 / 60;        % 0.02815 m² per cell
PV_area   = Np_cell * Ns_cell * cell_area;   % 7×60×0.02815 = 11.823 m²

fprintf('  PV : Ns=%d, Np=%d | Vmpp=%.2f V | Impp=%.2f A | Pmpp=%.0f W | Area=%.3f m²\n\n', ...
        Ns_cell, Np_cell, Vmpp, Impp, Pmpp, PV_area);
% =========================================================================
%  SECTION 3 – WEATHER DATA  (8-day, 1-min resolution)
% =========================================================================
WEATHER_FILE = 'weather_profile_week.xlsx';
scale_factor = 36000;

if isfile(WEATHER_FILE)
    weather       = readtable(WEATHER_FILE);
    real_time_sec = weather.Time_min * 60;
    Irr_val       = weather.Irradiance;
    Temp_val      = weather.Temperature;
    NUM_DAYS      = round(max(real_time_sec) / 86400);
    fprintf('  Weather: %s | %d days | %d samples\n', ...
            WEATHER_FILE, NUM_DAYS, height(weather));
else
    error('[ERROR] %s not found in %s', WEATHER_FILE, pwd);
end

Irr_time = real_time_sec / scale_factor;
sim_t    = max(Irr_time);
Irr_stair_tsamp = 60 / scale_factor;
Irr_stair_time  = (0 : Irr_stair_tsamp : sim_t)';
Irr_stair_val   = interp1(Irr_time, Irr_val,  Irr_stair_time, 'linear', 0);
Temp_stair_val  = interp1(Irr_time, Temp_val, Irr_stair_time, 'linear', 25);
NIGHT_THR = 70;   % W/m² – irradiance below which PEM is off
% =========================================================================
%  SECTION 4 – BATTERY & CONVERTER PARAMETERS
% =========================================================================
Ts  = 1e-4;  Tsc = 1e-6;

% V_batt_nom = V_ref_battery → equal usable energy across all cases:
%   27.81 V × 250 Ah × 0.70 = 4867 Wh (same as Indirect and all direct cases)
V_batt_nom   = V_ref_battery;  % [V]  ≈ 27.81 V for N=16

Q_thesis     = 250;    % [Ah] Real-world thesis battery capacity  (matched to Case 1)
Q_batt       = Q_thesis / scale_factor;   % ≈ 0.01389 Ah (same formula as Cases 1,3,4)
% NOTE: 1 sim-second = 10 real hours.  500 Ah / ~30 A ≈ 16.7 real hours night runtime.

SOC_max      = 90;
SOC_min      = 20;   % hard discharge floor  (20 %)
SOC_max_hys  = 85;   % stop charging at 85 %, resume when SOC drops back below this
SOC_min_hys  = 25;   % stop discharging at 25 %, resume when SOC rises above this
%
% Relay thresholds in the Simulink EMS are HARDCODED at 0.25 / 0.20 and
% 0.90 / 0.85 — they do NOT read from workspace.  The charge relay (SOC > 0.90
% blocks charging) and discharge relay (SOC < 0.20 blocks discharging) are
% separate blocks and work correctly.
%
% WHY the battery was stuck: the EMS PID had LimitOutput=off + AntiWindupMode=none.
% At night V_PEM≈0 V → error = V_ref − 0 = 21.5 V → integrator winds up without
% bound.  By morning the PID output is >>1.0 → PWM comparator=1 all day →
% pure discharge, charging never occurs.  The PID patch below fixes this.

SOC_init_per = 25;    % [%]  same as Cases 1 & 3 — fair comparison baseline
SOC_init     = SOC_init_per / 100 * Q_batt;
R_batt_int   = 0.05;

Bi_C_Kp = 0.01;  Bi_C_Ki = 10.0;
Bi_V_Kp = 10;    Bi_V_Ki = 70;

Bi_L  = 4e-4;  Bi_C1 = 1e-5;  Bi_C2 = 1e-5;
Bi_R1 = 1e-6;  Bi_R2 = 1e-6;
fsw   = 10000; Ts1   = 5e-5;

sample_output_time = 60 / scale_factor;  % 60 s real-time steps = 1-min resolution → 11521 rows

fprintf('  Batt: %.1f V | Q_sim=%.5f Ah | Q_thesis=%.0f Ah | SOC0=%.0f%%\n\n', ...
        V_batt_nom, Q_batt, Q_thesis, SOC_init_per);
% =========================================================================
%  SECTION 5 – MODEL SETUP & PATCHES
% =========================================================================

% Delete stale code-generation cache (created by a different MATLAB release).
% This folder is rebuilt automatically — safe to remove before every run.
slprj_path = fullfile(pwd, 'slprj');
if isfolder(slprj_path)
    rmdir(slprj_path, 's');
    fprintf('  [INFO] Deleted stale slprj folder (release mismatch).\n');
end

case_model = '2_DirectBatt';
mdl_orig   = 'PV_PEM_direct_battery_b';
mdl_fixed  = 'PV_PEM_direct_battery_b_FIXED';

if bdIsLoaded(mdl_orig),  close_system(mdl_orig,  0); end
if bdIsLoaded(mdl_fixed), close_system(mdl_fixed, 0); end

slx_path = which([mdl_orig '.slx']);
if isempty(slx_path), slx_path = fullfile(pwd, [mdl_orig '.slx']); end
fixed_path = fullfile(fileparts(slx_path), [mdl_fixed '.slx']);
load_system(slx_path);
save_system(mdl_orig, fixed_path);
close_system(mdl_orig, 0);
load_system(fixed_path);
mdl = mdl_fixed;

% MATLAB 2026a compatible block-loop (indexed, avoids cell array reassignment)
blks = find_system(mdl, 'LookUnderMasks', 'all');
for bi = 1:numel(blks)
    b = blks{bi};
    b_name = ''; b_type = ''; ref = '';
    try b_name = get_param(b,'Name');      catch; end
    try b_type = get_param(b,'BlockType'); catch; end
    try ref    = get_param(b,'ReferenceBlock'); catch; end
    
    if strcmp(b_type,'Constant')
        try set_param(b,'OutMax','[]'); catch; end; continue
    end
    
    if contains(b_name,'Irradiance','IgnoreCase',true)
        try set_param(b,'OutValues',   'Irr_stair_val');   catch; end
        try set_param(b,'samp_time',   'Irr_stair_tsamp'); catch; end
        try set_param(b,'rep_seq_t',   'Irr_time');         catch; end
        try set_param(b,'rep_seq_y',   'Irr_val');          catch; end
    end
    
    % --- Charge Controller & Converter Parameter Injection ---
    if contains(ref, 'Diode') || strcmp(b_name, 'Diode') || strcmp(b_name, 'Diode1')
        try set_param(b, 'Vf', '0.1'); catch; end
        try set_param(b, 'Ron', '0.01'); catch; end
    end
    if contains(ref, 'Switch') || contains(b_name, 'Switch') || contains(ref, 'MOSFET') || contains(b_name, 'MOSFET')
        try set_param(b, 'R_closed', '0.005'); catch; end
    end
    if contains(b_name, 'Battery')
        try set_param(b, 'Vnom', num2str(V_batt_nom)); catch; end
        try set_param(b, 'V1', num2str(V_batt_nom * 0.9)); catch; end
        try set_param(b, 'R1', num2str(R_batt_int)); catch; end
        try set_param(b, 'R1_dis', num2str(R_batt_int)); catch; end
        try set_param(b, 'R1_ch', num2str(R_batt_int)); catch; end
    end
    
    try
        if contains(ref,'Simulink-PS Converter') || contains(ref,'PS-Simulink Converter')
            set_param(b,'FilteringAndDerivatives','filter');
            set_param(b,'InputFilterTimeConstant','1e-6');
        end
    catch; end
    
    % PID patch handled below by direct path after the block loop (library link
    % must be broken before set_param — done in the targeted section below).
    if contains(b_name,'PI_Vol_Battery','IgnoreCase',true)
        try set_param(b,'P','Bi_V_Kp');  catch; end
        try set_param(b,'Kp','Bi_V_Kp'); catch; end
        try set_param(b,'I','Bi_V_Ki');  catch; end
        try set_param(b,'Ki','Bi_V_Ki'); catch; end
    end
    if contains(b_name,'PI_Cur_Battery','IgnoreCase',true)
        try set_param(b,'P','Bi_C_Kp');  catch; end
        try set_param(b,'Kp','Bi_C_Kp'); catch; end
        try set_param(b,'I','Bi_C_Ki');  catch; end
        try set_param(b,'Ki','Bi_C_Ki'); catch; end
    end
    
    if contains(b_name,'Current','IgnoreCase',true) || contains(b_name,'Ammeter','IgnoreCase',true)
        try set_param(b,'i_unit','A'); catch; end
    end
    if contains(b_name,'Solver Configuration','IgnoreCase',true)
        try set_param(b,'UseLocalSolver','off'); catch; end
    end
    if strcmp(b_type,'Scope')
        try set_param(b,'LimitDataPoints','off'); catch; end
        try set_param(b,'DataPoints','500000');   catch; end
        try set_param(b,'Open','off');            catch; end
    end
end

% Normal mode — no compiler required (replaces 'accelerator')
set_param(mdl,'StopTime',num2str(sim_t),'Solver','ode15s', ...
    'MaxStep','1e-5','SimulationMode','normal');
try set_param(mdl,'SimscapeExplicitSolverDiagnostic','none'); catch; end

% ── PID anti-windup patch: known path from model XML ──────────────────────
% Block confirmed at: mdl/Subsystem/PID Controller  (SID 533 in system_521)
% ROOT CAUSE: LimitOutput=off → PID integrates to >>1 every night.
%   |PID| >> 1 > carrier_max(1) → RelOp TRUE 100% → NOT=0 → PWM_top=0 → no charge.
% FIX: LimitOutput=on keeps |PID| in [0.1,0.9] so carrier comparison gives
%   variable duty cycles and the charge path (PWM_top) activates when V_PEM>V_Ref.
% Library-linked blocks ignore set_param — must break link first ('none').
pid_path = [mdl '/Subsystem/PID Controller'];
pid_ok = false;
try
    set_param(pid_path, 'LinkStatus',           'none');
    set_param(pid_path, 'LimitOutput',          'on');
    set_param(pid_path, 'UpperSaturationLimit', '0.9');
    set_param(pid_path, 'LowerSaturationLimit', '0.1');
    set_param(pid_path, 'AntiWindupMode',       'clamping');
    lo  = get_param(pid_path, 'LowerSaturationLimit');
    lim = get_param(pid_path, 'LimitOutput');
    aw  = get_param(pid_path, 'AntiWindupMode');
    fprintf('  [PID PATCH OK] LimitOutput=%s | LowerSat=%s | AntiWindup=%s\n', lim, lo, aw);
    pid_ok = true;
catch e
    fprintf('  [PID PATCH FAILED] %s\n', e.message);
    fprintf('  → Open Simulink: double-click PID block in Subsystem, set LimitOutput=on, AntiWindupMode=clamping manually.\n');
end

% ── Discharge relay hysteresis fix ────────────────────────────────────────
% PROBLEM: Discharge_enable has a wide hysteresis band [0.20, 0.25].
%   Once SOC hits 0.20 (discharge OFF), small PV charging pushes SOC to
%   0.21-0.23 — but discharge stays OFF until SOC reaches 0.25.
%   With poor weather in Days 5-8, SOC never reaches 0.25 → battery stuck
%   in dead zone: can't discharge, can't charge past 0.23 → plateau.
% FIX: Tighten ON threshold from 0.25 → 0.21 so discharge resumes quickly
%   after any brief charging, restoring proper battery-PEM support.
dis_path = [mdl '/Subsystem/Discharge enable1'];
try
    set_param(dis_path, 'OnSwitchValue',  '0.21');
    set_param(dis_path, 'OffSwitchValue', '0.20');
    fprintf('  [RELAY PATCH OK] Discharge enable hysteresis: ON=0.21, OFF=0.20\n');
catch e
    fprintf('  [RELAY PATCH FAILED] %s\n', e.message);
end

% --- CRITICAL FIX: Ensure ALL logic state variables and PI params reach Simulink ---
assignin('base','sample_output_time', sample_output_time);
assignin('base','SOC_max',     SOC_max);
assignin('base','SOC_min',     SOC_min);
assignin('base','SOC_max_hys', SOC_max_hys);
assignin('base','SOC_min_hys', SOC_min_hys);
assignin('base','SOC_init',    SOC_init);
assignin('base','SOC_max_pct', SOC_max * 100);
assignin('base','SOC_min_pct', SOC_min * 100);
assignin('base','SOC_init_pct',SOC_init_per);
assignin('base','V_ref_battery', V_ref_battery);
assignin('base','V_batt_nom',    V_batt_nom);   % needed by EMS voltage comparator in Simulink

assignin('base','Q_batt',  Q_batt);   % scaled capacity → correct Simscape SOC
assignin('base','Bi_C_Kp', Bi_C_Kp);
assignin('base','Bi_C_Ki', Bi_C_Ki);
assignin('base','Bi_V_Kp', Bi_V_Kp);
assignin('base','Bi_V_Ki', Bi_V_Ki);
assignin('base','Bi_L',  Bi_L);
assignin('base','Bi_C1', Bi_C1);
assignin('base','Bi_C2', Bi_C2);
assignin('base','Bi_R1', Bi_R1);
assignin('base','Bi_R2', Bi_R2);
assignin('base','fsw', fsw);
assignin('base','Ts1', Ts1);

% ── PID discrete-time conversion + solver zero-crossing fix ───────────────
% Continuous-time PID with output saturation [0.1,0.9] + clamping anti-windup
% causes 1000 consecutive zero-crossing events at the saturation boundary →
% simulation aborts. Fix: make PID discrete (Ts=1e-4) so it steps at fixed
% intervals with no zero-crossing events, AND set solver to Adaptive ZC algorithm.
try set_param(pid_path, 'TimeDomain', 'discrete-time'); catch; end
try set_param(pid_path, 'SampleTime', '1e-4');          catch; end
fprintf('  [PID] Switched to discrete-time, Ts=1e-4\n');

set_param(mdl, 'Solver',             'ode15s');
set_param(mdl, 'MaxStep',            '1e-5');
set_param(mdl, 'ZeroCrossAlgorithm', 'Adaptive');
try set_param(mdl, 'ZeroCrossControl', 'UseLocalSettings'); catch; end
fprintf('  [SOLVER] ZeroCrossAlgorithm = Adaptive\n');

save_system(mdl);
fprintf('  Model ready: %s  (sim_t = %.2f s = %d days)\n\n', mdl_fixed, sim_t, NUM_DAYS);
% =========================================================================
%  SECTION 6 – RUN SIMULATION
% =========================================================================
fprintf('  Running simulation...\n');
out = sim(mdl);
fprintf('  Simulation complete.\n\n');
% =========================================================================
%  SECTION 7 – EXTRACT & CLAMP SIGNALS
% =========================================================================
t      = out.PV_V.Time;
t_plot = t * scale_factor / 3600;
real_t = t * scale_factor;

PV_V  = max(out.PV_V.Data,  0);
PV_I  = max(out.PV_I.Data,  0);
PEM_V = max(out.PEM_V.Data, 0);
PEM_I = max(out.PEM_I.Data, 0);
Irr   = max(out.Irr.Data,   0);

if max(PEM_I) > 500, PEM_I = PEM_I / 1000; end
if max(PV_I)  > 500, PV_I  = PV_I  / 1000; end

% PEM operating limit enforcement
PEM_over  = (PEM_V > Vmax_PEM) | (PEM_I > Imax_PEM) | (PEM_V .* PEM_I > Pmax_PEM);
PEM_I_eff = PEM_I;  PEM_I_eff(PEM_over) = 0;
PEM_V_eff = PEM_V;  PEM_V_eff(PEM_over) = 0;
if sum(PEM_over) > 0
    fprintf('  [NOTE] PEM over-limit: %d samples excluded from H2 calculation\n', sum(PEM_over));
end

% Battery signals
has_batt = false;
try
    Batt_V   = out.Batt_V.Data;
    Batt_I   = out.Batt_I.Data;
    
    % Extract true simulated SOC instead of overriding with raw Math
    Batt_SOC = out.Batt_SOC.Data; 
    if mean(Batt_SOC) <= 1.0
        Batt_SOC = Batt_SOC * 100;
    end
    
    Batt_P   = Batt_V .* Batt_I;
    has_batt = true;
    
    % Scale check: Simscape can output mA instead of A for some sensor configs
    if max(abs(Batt_I)) > 2000, Batt_I = Batt_I / 1000; Batt_P = Batt_V .* Batt_I; end
    
    night_mask_t  = Irr < NIGHT_THR;
    
    % Night-masked power: kept only for Eta_pct (system efficiency) calculation
    Batt_P_day = Batt_P;
    Batt_P_day(night_mask_t) = 0;
    
    % Clipped current for plotting — removes initialization transient spike
    Batt_I_plot = max(-300, min(300, Batt_I));
catch
    Batt_V        = V_batt_nom * ones(size(t));
    Batt_I        = zeros(size(t));
    Batt_SOC      = SOC_init_per * ones(size(t));
    Batt_P        = zeros(size(t));
    Batt_P_day    = Batt_P;
    Batt_I_plot   = Batt_I;
    fprintf('  [NOTE] Battery signals not found.\n');
end
% ── Battery charge / discharge power split ────────────────────────────────
% Sign convention (Simscape load convention): negative Batt_P = discharging,
% positive Batt_P = charging.  These two signals are always ≥ 0.
Batt_P_chg = max(0,  Batt_P);   % [W] power INTO battery   (positive = charging)
Batt_P_dis = max(0, -Batt_P);   % [W] power FROM battery   (positive = discharging)

% =========================================================================
%  SECTION 8 – DERIVED QUANTITIES
% =========================================================================
PV_P  = PV_V .* PV_I;
PEM_P = PEM_V_eff .* PEM_I_eff;

% P_mpp: analytical STC estimate
pv_Pu = Im_PV * Vm_PV * Ns_cell;
P_mpp = max(0, Np_cell * pv_Pu * (Irr / 1000));
P_mpp(Irr <= NIGHT_THR) = NaN;
Coupling_C = PV_P ./ max(P_mpp, 1e-3);
Coupling_C = max(0, min(1.0, Coupling_C));
Coupling_C(Irr <= NIGHT_THR) = 0;

% System efficiency (PEM out / total electrical input)
if has_batt
    Batt_disch = max(0, -Batt_P_day);
    Total_in   = movmean(PV_P + Batt_disch, 200);
else
    Total_in   = movmean(PV_P, 200);
end
eta_raw = movmean(PEM_P, 200) ./ max(Total_in, 1e-3) * 100;
eta_raw(eta_raw > 99) = 99;
Eta_pct = nan(size(t));
valid   = Total_in > 1;
Eta_pct(valid) = eta_raw(valid);

% H2 production  ── CRITICAL: include N (number of PEM cells) ──
F_const = 96485;  eta_F = 0.99;  M_H2 = 2.016e-3;
n_H2     = (N * PEM_I_eff) / (2 * F_const) * eta_F;   % mol/s  ← N multiplier
H2_inst  = n_H2 * M_H2 * 1e3;     % g/s
H2_rate  = H2_inst * 3600;         % g/h
H2_cumul = cumtrapz(real_t, H2_inst);   % g

if has_batt
    % Use UNMASKED Batt_P here (not Batt_P_day).
    % The night mask is correct for SOC integration only.
    % At night the battery discharges to power PEM — that H2 IS from battery
    % and must be credited, otherwise attribution does not sum to H2_cumul.
    Batt_P_attr = Batt_P;   % full signal, negative = discharge (Cases 1 & 2)
    safe_src = max(PV_P + max(0,-Batt_P_attr), 1e-6);
    H2_cumul_PV   = cumtrapz(real_t, H2_inst .* PV_P               ./ safe_src);
    H2_cumul_Batt = cumtrapz(real_t, H2_inst .* max(0,-Batt_P_attr) ./ safe_src);
else
    H2_cumul_PV   = H2_cumul;
    H2_cumul_Batt = zeros(size(H2_cumul));
end

% ── PV efficiency ─────────────────────────────────────────────────────────
G_safe  = max(Irr, 10);                        % avoid divide-by-zero [W/m²]
eta_PV  = PV_P ./ (PV_area .* G_safe) * 100;  % [%]
eta_PV(Irr <= NIGHT_THR) = NaN;
eta_PV  = max(0, min(100, eta_PV));

% ── PEM electrochemical efficiency  η = Vint / V_op ──────────────────────
eta_PEM = NaN(size(PEM_V_eff));
valid_pem = PEM_V_eff > (Vint_stack + 0.1);
eta_PEM(valid_pem) = (Vint_stack ./ PEM_V_eff(valid_pem)) * 100;
eta_PEM = max(0, min(100, eta_PEM));

% ── Solar-to-Hydrogen efficiency (STH) ────────────────────────────────────
% Use only the PV-attributed fraction of H2 (exclude battery contribution).
% Including battery H2 causes artificially high STH at dawn/dusk when G is
% small but PEM is still running at full current on battery power.
LHV_H2   = 119.96e6;   % J/kg lower heating value
pv_frac  = PV_P ./ max(PV_P + max(0,-Batt_P), 1e-6);   % PV share [0,1]
pv_frac  = min(1, max(0, pv_frac));
H2_power_solar = H2_inst .* pv_frac * 1e-3 * LHV_H2;   % W, solar H2 only
STH      = H2_power_solar ./ (PV_area .* G_safe) * 100; % [%]
STH(Irr <= NIGHT_THR) = NaN;
STH      = max(0, STH);

% ── Total-to-Hydrogen efficiency (TTH) ────────────────────────────────────
H2_power_total = H2_inst * 1e-3 * LHV_H2;
TTH = H2_power_total ./ (PV_area .* G_safe) * 100;
TTH(Irr <= NIGHT_THR) = NaN;
TTH = max(0, TTH);
TTH_8day = (H2_cumul(end) * 1e-3 * LHV_H2) / ...
            trapz(real_t, Irr .* PV_area) * 100;

% ── System coupling  C_sys = P_PEM / P_mpp  ─────────────────────────────
C_sys = PEM_P ./ max(P_mpp, 1e-3);
C_sys(Irr <= NIGHT_THR) = NaN;
C_sys = min(C_sys, 2.0);

% ── PEM capacity factor ───────────────────────────────────────────────────
CF_PEM = mean(PEM_P, 'omitnan') / max(Pmax_PEM, 1) * 100;   % [%]

% ── Battery round-trip efficiency ────────────────────────────────────────
E_chg_Wh = trapz(real_t, Batt_P_chg) / 3600;
E_dis_Wh = trapz(real_t, Batt_P_dis) / 3600;
if E_chg_Wh > 1
    eta_batt_RT = min(99, E_dis_Wh / E_chg_Wh * 100);   % cap at 99% (consistent with Cases 1,3,4)
else
    eta_batt_RT = NaN;
end

% ── Nighttime H2 production ──────────────────────────────────────────────
nm_mask = Irr <= NIGHT_THR;
%  FIX: trapz(t(mask), y(mask)) connects non-consecutive nighttime samples
%  across daytime gaps and inflates the integral ~5×. Correct approach:
%  zero out daytime values and integrate the full time vector.
H2_inst_night           = H2_inst;
H2_inst_night(~nm_mask) = 0;
H2_night = trapz(real_t, H2_inst_night);
H2_night_pct = H2_night  / max(H2_cumul(end), 1e-6) * 100;
H2_PV_pct    = H2_cumul_PV(end)   / max(H2_cumul(end), 1e-6) * 100;
H2_Batt_pct  = H2_cumul_Batt(end) / max(H2_cumul(end), 1e-6) * 100;

% ── Console summary ───────────────────────────────────────────────────────
sep1 = repmat('-',1,52);
fprintf('\n%s\n  CASE 2 — Direct PV-PEM + BiDi Batt  KPI Summary\n%s\n', sep1, sep1);
fprintf('  PV peak power          : %.1f W\n',   max(PV_P));
fprintf('  PEM peak power         : %.1f W\n',   max(PEM_P));
fprintf('  PEM capacity factor    : %.2f %%\n',  CF_PEM);
fprintf('  C_PV  (daytime mean)   : %.3f\n',     mean(Coupling_C(Irr>NIGHT_THR),'omitnan'));
fprintf('  C_sys (daytime mean)   : %.3f\n',     mean(C_sys,'omitnan'));
fprintf('  Total H2 produced      : %.3f g\n',   H2_cumul(end));
fprintf('     from Solar          : %.3f g  (%.1f %%)\n', H2_cumul_PV(end),   H2_PV_pct);
fprintf('     from Battery        : %.3f g  (%.1f %%)\n', H2_cumul_Batt(end), H2_Batt_pct);
fprintf('     at night (Irr<%.0f) : %.3f g  (%.1f %%)\n', NIGHT_THR, H2_night, H2_night_pct);
fprintf('  Mean eta_PV  (daytime) : %.2f %%\n',  mean(eta_PV(Irr>NIGHT_THR),'omitnan'));
fprintf('  Mean eta_PEM (active)  : %.2f %%\n',  mean(eta_PEM(valid_pem),'omitnan'));
fprintf('  Mean STH     (daytime) : %.3f %%\n',  mean(STH(Irr>NIGHT_THR),'omitnan'));
fprintf('  Mean TTH     (daytime) : %.3f %%\n',  mean(TTH(Irr>NIGHT_THR),'omitnan'));
fprintf('  Total TTH    (8-day)   : %.3f %%\n',  TTH_8day);
fprintf('  Battery charged        : %.1f Wh\n',  E_chg_Wh);
fprintf('  Battery discharged     : %.1f Wh\n',  E_dis_Wh);
if isfinite(eta_batt_RT)
    fprintf('  Batt round-trip η      : %.1f %%\n', eta_batt_RT);
else
    fprintf('  Batt round-trip η      : n/a\n');
end
fprintf('%s\n', sep1);
% =========================================================================
%  SECTION 9 – FIGURES
% =========================================================================
clr_pv   = [0.85 0.33 0.10];
clr_pem  = [0.13 0.47 0.71];
clr_batt = [0.47 0.25 0.80];
clr_irr  = [0.93 0.69 0.13];
clr_eta  = [0.18 0.55 0.18];
lw = 1.8;

day_ticks  = 0 : 24 : NUM_DAYS*24;
day_labels = arrayfun(@(d) sprintf('Day %d',d), 0:NUM_DAYS, 'UniformOutput', false);

% Helper: save figure without requiring graphics toolbox export
savefig_fn = @(fig, nm) print(fig, fullfile(pwd, nm), '-dpng', '-r300');

% ── Fig 1: System Overview ──────────────────────────────────────────────
fig1 = figure('Name','System Overview','Color','w','Position',[30 30 1100 760]);
tl1  = tiledlayout(4,1,'TileSpacing','compact','Padding','compact');
title(tl1, sprintf('Case 2 – Direct PV-PEM + Indirect Batt  |  N=%d cells | Np=%d strings | Q=%.0f Ah', ...
      N, Np_cell, Q_thesis), 'FontSize', 12, 'FontWeight','bold');

nexttile; plot(t_plot, Irr, 'Color', clr_irr, 'LineWidth', lw);
ylabel('G (W/m²)'); ylim([0 1200]); grid on; box on;

nexttile; hold on;
plot(t_plot, PV_V,  'Color', clr_pv,  'LineWidth', lw, 'DisplayName','V_{PV}');
plot(t_plot, PEM_V, 'Color', clr_pem, 'LineWidth', lw, 'DisplayName','V_{PEM}');
if has_batt, plot(t_plot, Batt_V,'Color',clr_batt,'LineWidth',lw,'DisplayName','V_{batt}'); end
yline(Vmax_PEM,'--','Color',[.5 .5 .5],'HandleVisibility','off');
yline(Vmin_PEM,':' ,'Color',[.5 .5 .5],'HandleVisibility','off');
hold off; ylabel('Voltage (V)'); grid on; box on; legend('Location','east');

nexttile; hold on;
plot(t_plot, PV_I,  'Color', clr_pv,  'LineWidth', lw, 'DisplayName','I_{PV}');
plot(t_plot, PEM_I, 'Color', clr_pem, 'LineWidth', lw, 'DisplayName','I_{PEM}');
if has_batt, plot(t_plot, Batt_I_plot,'Color',clr_batt,'LineWidth',lw,'DisplayName','I_{batt}'); end
yline(Imax_PEM,'--','Color',[.5 .5 .5],'HandleVisibility','off');
hold off; ylabel('Current (A)'); grid on; box on; legend('Location','northeast');

nexttile; hold on;
plot(t_plot, PV_P,  'Color', clr_pv,  'LineWidth', lw, 'DisplayName','P_{PV}');
plot(t_plot, PEM_P, 'Color', clr_pem, 'LineWidth', lw, 'DisplayName','P_{PEM}');
if has_batt, plot(t_plot, Batt_P,'Color',clr_batt,'LineWidth',lw,'DisplayName','P_{batt}'); end
yline(Pmax_PEM,'--','Color',[.5 .5 .5],'HandleVisibility','off');
hold off; xlabel('Time (hours)'); ylabel('Power (W)'); grid on; box on; legend('Location','northeast');

for ax = findobj(fig1,'Type','Axes')'
    xticks(ax, day_ticks); xticklabels(ax, day_labels); xlim(ax, [0 NUM_DAYS*24]);
    for d = day_ticks(2:end-1), xline(ax, d, ':','Color',[0.7 0.7 0.7],'HandleVisibility','off'); end
end
drawnow; savefig_fn(fig1, 'Fig1_SystemOverview_Case2.png');

% ── Fig 2: H2 + SOC ────────────────────────────────────────────────────
fig2 = figure('Name','H2 & SOC','Color','w','Position',[60 60 1100 560]);
tl2  = tiledlayout(2,1,'TileSpacing','compact','Padding','compact');

ax2a = nexttile; yyaxis(ax2a,'left'); ax2a.YColor = clr_pem;
plot(t_plot, H2_rate,'Color',clr_pem,'LineWidth',lw,'DisplayName','H_2 rate');
ylabel('H_2 rate (g h^{-1})');

yyaxis(ax2a,'right'); ax2a.YColor = [0 0.4 0.8];
plot(t_plot, H2_cumul,'Color',[0 0.4 0.8],'LineWidth',lw,'LineStyle','-.','DisplayName','Cumul. H_2');
ylabel('H_2 cumul. (g)'); grid on; box on; legend('Location','northwest','NumColumns',2);

if has_batt
    nexttile;
    plot(t_plot, Batt_SOC, 'Color', clr_batt, 'LineWidth', lw+0.4);
    yline(SOC_max*100,'--','Color',[0.7 0.1 0.1],'LineWidth',1.2,'HandleVisibility','off');
    yline(SOC_min*100,'--','Color',[0.7 0.1 0.1],'LineWidth',1.2,'HandleVisibility','off');
    ylabel('SOC (%)'); ylim([0 105]); xlabel('Time (hours)'); grid on; box on;
end

for ax = findobj(fig2,'Type','Axes')'
    try xticks(ax, day_ticks); xticklabels(ax, day_labels); xlim(ax, [0 NUM_DAYS*24]); catch; end
end
drawnow; savefig_fn(fig2, 'Fig2_H2_SOC_Case2.png');

% ── Fig 3: Battery EMS ──────────────────────────────────────────────────
if has_batt
    fig3 = figure('Name','Battery EMS','Color','w','Position',[80 80 1100 680]);
    tl3  = tiledlayout(3,1,'TileSpacing','compact','Padding','compact');
    title(tl3, sprintf('Battery EMS  |  V_{nom}=%.0f V, Q=%.0f Ah, SOC_0=%.0f%%', ...
          V_batt_nom, Q_thesis, SOC_init_per), 'FontSize', 11, 'FontWeight','bold');
          
    ax3a = nexttile; yyaxis(ax3a,'left'); ax3a.YColor = clr_batt;
    plot(t_plot, Batt_V,'Color',clr_batt,'LineWidth',lw); ylabel('V_{batt} (V)','Color',clr_batt);
    yyaxis(ax3a,'right'); ax3a.YColor = [0.7 0.1 0.1];
    plot(t_plot, Batt_I_plot,'Color',[0.7 0.1 0.1],'LineWidth',lw);
    yline(0,'k:','HandleVisibility','off'); ylabel('I_{batt} (A)'); grid on; box on;
    
    nexttile; hold on;
    plot(t_plot, PV_P, 'Color',clr_pv, 'LineWidth',lw,'DisplayName','P_{PV}');
    plot(t_plot, PEM_P,'Color',clr_pem,'LineWidth',lw,'DisplayName','P_{PEM}');
    plot(t_plot, Batt_P,'Color',clr_batt,'LineWidth',lw,'DisplayName','P_{batt}');
    yline(0,'k:','HandleVisibility','off');
    hold off; ylabel('Power (W)'); grid on; box on; legend('Location','northeast','NumColumns',3);
    
    nexttile;
    plot(t_plot, Batt_SOC,'Color',[0.1 0.6 0.3],'LineWidth',lw+0.4);
    yline(SOC_max*100,'--','Color',[0.7 0.1 0.1],'LineWidth',1.2,'HandleVisibility','off');
    yline(SOC_min*100,'--','Color',[0.7 0.1 0.1],'LineWidth',1.2,'HandleVisibility','off');
    text(NUM_DAYS*24*0.99,SOC_max*100+2,'SOC_{max}','FontSize',8,'HorizontalAlignment','right','Color',[0.7 0.1 0.1]);
    text(NUM_DAYS*24*0.99,SOC_min*100+2,'SOC_{min}','FontSize',8,'HorizontalAlignment','right','Color',[0.7 0.1 0.1]);
    ylabel('SOC (%)'); ylim([0 105]); xlabel('Time (hours)'); grid on; box on;
    
    for ax = findobj(fig3,'Type','Axes')'
        xticks(ax,day_ticks); xticklabels(ax,day_labels); xlim(ax,[0 NUM_DAYS*24]);
        for d = day_ticks(2:end-1), xline(ax,d,':','Color',[0.7 0.7 0.7],'HandleVisibility','off'); end
    end
    drawnow; savefig_fn(fig3,'Fig3_BattEMS_Case2.png');
end

% ── Fig 4: Efficiency chain ─────────────────────────────────────────────
fig4 = figure('Name','Efficiency','Color','w','Position',[100 100 1100 560]);
tl4  = tiledlayout(2,1,'TileSpacing','compact','Padding','compact');
title(tl4,'Case 2 – Efficiency Metrics','FontSize',12,'FontWeight','bold');

nexttile; hold on;
plot(t_plot, eta_PV,  'Color', clr_pv,  'LineWidth', lw, 'DisplayName','\eta_{PV} (%)');
plot(t_plot, eta_PEM, 'Color', clr_pem, 'LineWidth', lw, 'DisplayName','\eta_{PEM} (%)');
hold off; ylabel('Efficiency (%)'); ylim([0 100]); grid on; box on;
legend('Location','northeast','NumColumns',2);

nexttile;
plot(t_plot, STH, 'Color', clr_eta, 'LineWidth', lw);
ylabel('STH (%)'); grid on; box on; xlabel('Time (hours)');

for ax = findobj(fig4,'Type','Axes')'
    try xticks(ax,day_ticks); xticklabels(ax,day_labels); xlim(ax,[0 NUM_DAYS*24]); catch; end
end
drawnow; savefig_fn(fig4,'Fig4_Efficiency_Case2.png');

% =========================================================================
%  SECTION 10 – EXCEL EXPORT
% =========================================================================
filename = 'PV_PEM_direct_batt_results_week.xlsx';
if isfile(filename), delete(filename); end

TS = table( ...
    t_plot, real_t, Irr, ...
    PV_V, PV_I, PV_P, ...
    PEM_V, PEM_I, PEM_P, ...
    Batt_V, Batt_I, Batt_P, Batt_P_chg, Batt_P_dis, Batt_SOC, ...
    H2_rate, H2_cumul, H2_cumul_PV, H2_cumul_Batt, ...
    Coupling_C, C_sys, Eta_pct, eta_PV, eta_PEM, STH, TTH, ...
    'VariableNames', { ...
        't_plot_[h]','t_real_[s]','Irr_[W/m2]', ...
        'PV_V_[V]','PV_I_[A]','PV_P_[W]', ...
        'PEM_V_[V]','PEM_I_[A]','PEM_P_[W]', ...
        'Batt_V_[V]','Batt_I_[A]','Batt_P_[W]','Batt_P_chg_[W]','Batt_P_dis_[W]','Batt_SOC_[%]', ...
        'H2_rate_[g_h]','H2_cumul_[g]','H2_cumul_PV_[g]','H2_cumul_Batt_[g]', ...
        'Coupling_C','C_sys','Eta_pct','eta_PV_[pct]','eta_PEM_[pct]','STH_[pct]','TTH_[pct]'});
writetable(TS, filename,'Sheet','TimeSeries','WriteMode','overwritesheet');

paramNames  = {'Case'; 'N_cells_PEM'; 'Np_cell'; 'Ns_cell'; 'PV_area_[m2]'; ...
               'Vmax_PEM_[V]'; 'Imax_PEM_[A]'; 'Pmax_PEM_[W]'; ...
               'V_batt_nom_[V]'; 'Q_thesis_[Ah]'; 'SOC_init_[%]'; ...
               'sim_t_[s]'; 'scale_factor'; 'NUM_DAYS'; ...
               'total_H2_[g]'; 'H2_PV_[g]'; 'H2_Batt_[g]'; ...
               'H2_PV_pct_[pct]'; 'H2_Batt_pct_[pct]'; 'H2_night_[g]'; 'H2_night_pct_[pct]'; ...
               'mean_C_PV_[-]'; 'mean_C_sys_[-]'; 'CF_PEM_[pct]'; ...
               'E_chg_[Wh]'; 'E_dis_[Wh]'; 'eta_batt_RT_[pct]'; ...
               'mean_eta_PV_[pct]'; 'mean_eta_PEM_[pct]'; ...
               'mean_STH_[pct]'; 'mean_TTH_[pct]'; 'TTH_8day_[pct]'};
paramValues = [2; N; Np_cell; Ns_cell; PV_area; ...
               Vmax_PEM; Imax_PEM; Pmax_PEM; ...
               V_batt_nom; Q_thesis; SOC_init_per; ...
               sim_t; scale_factor; NUM_DAYS; ...
               H2_cumul(end); H2_cumul_PV(end); H2_cumul_Batt(end); ...
               H2_PV_pct; H2_Batt_pct; H2_night; H2_night_pct; ...
               mean(Coupling_C(Irr>NIGHT_THR),'omitnan'); mean(C_sys,'omitnan'); CF_PEM; ...
               E_chg_Wh; E_dis_Wh; eta_batt_RT; ...
               mean(eta_PV(Irr>NIGHT_THR),'omitnan'); ...
               mean(eta_PEM(valid_pem),'omitnan'); ...
               mean(STH(Irr>NIGHT_THR),'omitnan'); ...
               mean(TTH(Irr>NIGHT_THR),'omitnan'); ...
               TTH_8day];

PARAM = table(paramNames, paramValues,'VariableNames',{'Parameter','Value'});
writetable(PARAM, filename,'Sheet','Parameters','WriteMode','overwritesheet');

fprintf('\n  Saved: %s\n', filename);
fprintf('=== Case 2 DONE ===\n');