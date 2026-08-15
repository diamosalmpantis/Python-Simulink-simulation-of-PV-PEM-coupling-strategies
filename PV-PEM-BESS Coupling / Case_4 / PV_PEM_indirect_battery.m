%% 
% =========================================================================
%  PV_PEM_indirect_batt_week.m
%  Case 4 – Indirect PV-Battery-PEM  (DC-DC converter + battery management)
%
%  Topology:  PV  ──►  Buck-Boost Converter  ──►  PEM Electrolyzer
%                              ▲▼
%                           Battery (bidirectional)
%t
%  The active power converter sits between PV and PEM, enabling voltage
%  level-shifting and MPPT.  The battery is integrated into the same
%  converter stage for energy buffering.
%
%  Simulink model : PV_PEM_converter_battery.slx
%  Weather input  : weather_profile_week.xlsx  (8-day, 1-min resolution)
%  Output Excel   : PV_PEM_indirect_batt_results_week.xlsx
% =========================================================================
clear; clc; close all;
warning('off','all');
fprintf('=== Case 1 – Indirect PV-Batt-PEM  (8-day simulation) ===\n\n');

% =========================================================================
%  SECTION 1 – PEM ELECTROLYZER PARAMETERS
%  N=13 cells chosen for converter topology (Vmax=20V matches boost output)
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

Vmin_PEM    = Vint_stack;                              % 14.76 V  (N=10)
Vmax_PEM    = 2.0 * N;                                 % 20.00 V  (N=10)
Imin_PEM    = 2.2;                                     % [A]  minimum operating current
Imax_PEM    = 80;                                      % [A]  hardware protection limit

% Rated operating point: Randles load-line intersection at Vmax
I_rated_PEM = (Vmax_PEM - Vint_stack) / R_total;      
P_rated_PEM = Vmax_PEM * I_rated_PEM;                  
Pmax_PEM    = P_rated_PEM;                             % used for plot limit lines

V_ref_battery=(Vint_stack + Vmax_PEM) / 2;   
fprintf('  PEM: %d cells | Vint=%.2f V | Vmin=%.1f V | Vmax=%.1f V | I_rated=%.1f A | P_rated=%.0f W\n', ...
        N, Vint_stack, Vmin_PEM, Vmax_PEM, I_rated_PEM, Pmax_PEM);

% =========================================================================
%  SECTION 2 – PV ARRAY
% =========================================================================
Im_PV = 9.59;  Vm_PV = 0.55;
Np_cell = 7;   Ns_cell = 60;
Isc_cell = 10.14; Voc_cell = 0.67;
alpha_Isc = 0.0005; beta_Vmpp = -0.0035;

Isc  = Isc_cell  * Np_cell;
Voc  = Voc_cell  * Ns_cell;
Vmpp = Vm_PV     * Ns_cell;   % 33.0 V  (Ns=60)
Impp = Im_PV     * Np_cell;
Pmpp = Vmpp      * Impp;
cell_area = 1.689 / 60;                       % 0.02815 m² per cell  (panel area 1.689 m²)
PV_area   = Np_cell * Ns_cell * cell_area;    % 7×60×0.02815 = 11.823 m²
fprintf('  PV : Ns=%d, Np=%d | Vmpp=%.2f V | Impp=%.2f A | Pmpp=%.0f W | Area=%.3f m²\n\n', ...
        Ns_cell, Np_cell, Vmpp, Impp, Pmpp, PV_area);

% =========================================================================
%  SECTION 3 – WEATHER DATA  (8-day, 1-min resolution)
% =========================================================================
WEATHER_FILE = 'weather_profile_week.xlsx';
scale_factor = 36000;   % 1 sim-second = 10 real hours

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

% -----------------------------------------------------------------
%  FIX 1 — 3-point smoothing removes minute-to-minute step
%  discontinuities that cause Ra capacitor derivatives to blow up.
% -----------------------------------------------------------------
Irr_val  = movmean(Irr_val,  3);
Temp_val = movmean(Temp_val, 3);
Irr_val  = max(Irr_val,  0);
Temp_val = max(Temp_val, -50);

% Scale to simulation time
Irr_time = real_time_sec / scale_factor;
sim_t    = max(Irr_time);
Irr_stair_tsamp = 60 / scale_factor;
Irr_stair_time  = (0 : Irr_stair_tsamp : sim_t)';

% -----------------------------------------------------------------
%  FIX 2 — Zero-order-hold ('previous') interpolation.
%  'linear' creates ramps that Simscape must differentiate,
%  amplifying numerical noise on large irradiance steps.
% -----------------------------------------------------------------
Irr_stair_val  = interp1(Irr_time, Irr_val,  Irr_stair_time, 'previous', 0);
Temp_stair_val = interp1(Irr_time, Temp_val, Irr_stair_time, 'previous', 25);

NIGHT_THR = 70;  % W/m² – irradiance below which battery discharges to PEM
%  (battery discharges when Irr ≤ 70, charges when Irr > 70)
%  Setting to 0 would mean discharge ONLY at complete darkness — not desired.

% =========================================================================
%  SECTION 4 – CONVERTER & BATTERY PARAMETERS
% =========================================================================
Ts  = 1e-3;  Tsc = 1e-5;  Ron = 0.01;  Conductance = 1e-6;
Vth = 0.5;   Vforward = 0.8;
L_conv = 4e-4;  C_conv = 2.2e-4;

% V_batt_nom = V_ref_battery → equal usable energy across ALL cases:
%   27.81 V × 250 Ah × (0.90-0.20) = 4867 Wh  (same for Indirect and Direct)
V_batt_nom   = 12;  % [V]  ≈ 27.81 V for N=16
Q_thesis     = 580;   % [Ah] real-world battery capacity
Q_batt       = Q_thesis / scale_factor;   % time-compressed capacity
SOC_init_per = 25;
SOC_init     = SOC_init_per / 100 * Q_batt;
R_batt_int   = 0.05;
SOC_max      = 0.90;   % fraction → 90 %  hard charge cutoff
SOC_min      = 0.20;   % fraction → 20 %  hard discharge cutoff
SOC_max_hys  = 0.85;   % re-enable charging below this
SOC_min_hys  = 0.25;   % re-enable discharging above this

Bi_L  = 4e-4;  Bi_C1 = 1e-5;  Bi_C2 = 1e-5;
Bi_R1 = 1e-6;  Bi_R2 = 1e-6;
fsw   = 10000; Ts1   = 5e-5;
Bi_C_Kp = 0.01;  Bi_C_Ki = 10.0;
Bi_V_Kp = 10;    Bi_V_Ki = 70;

sample_output_time = Irr_stair_tsamp;   % 1 output point per weather minute

fprintf('  Batt: %.1f V | Q_sim=%.5f Ah (=Q_thesis/scale_factor) | Q_thesis=%.0f Ah | SOC₀=%.0f%%\n\n', ...
        V_batt_nom, Q_batt, Q_thesis, SOC_init_per);

% =========================================================================
%  SECTION 4c – BATTERY BMS DAY/NIGHT MODE SWITCHING
%
%  Problem:  Both the PV converter and the battery bidirectional (BiDi)
%            converter regulate V_bus = V_ref_battery ≈ 20V simultaneously.
%            They fight: battery settles at near-zero current → no cycling.
%
%  Fix: Give the BiDi converter a DIFFERENT V_Ref during daytime:
%    DAY   (Irr > NIGHT_THR): V_Ref_bms = V_ref_chg ≈ V_batt_nom (12V)
%          → error = 12 - 20 = −8V → PID output saturates low (D ≈ 0)
%          → D < SOC (0.25) always → CHARGE mode → battery charges from PV bus
%
%    NIGHT (Irr ≤ NIGHT_THR): V_Ref_bms = V_ref_battery (20V)
%          → PV converter drops out (V_PV=0 → zero output)
%          → BiDi PID takes over V_bus regulation → DISCHARGE → powers PEM
%
%  Requires Simulink change inside BMS subsystem:
%    • Add Inport 4: 'Day_mode' (0=night, 1=day)
%    • Add Switch block before Sum junction (+) input:
%        u1 = V_ref_chg constant  (day)
%        u2 = Day_mode signal     (selector, threshold=0.5)
%        u3 = V_Ref inport        (night)
%    • Wire Switch output → Sum junction (replaces direct V_Ref wire)
%    • Add From Workspace block at top level → port 4 of BMS Subsystem
%      Variable name: 'Day_mode_ts', SampleTime: Irr_stair_tsamp
% =========================================================================
% V_ref_chg: must be BELOW V_bus so PID error is always negative → charge mode.
% Vmin_PEM (= Vint_stack ≈ 23.6 V) is below V_bus (= V_ref_battery ≈ 27.8 V)
% → error = 23.6 − 27.8 = −4.2 V → PID saturates low → charge mode ✓
V_ref_chg = Vmin_PEM;            % [V]  forces charge mode during day

% Build the day/night switching signal (same time grid as irradiance)
Day_mode_val = double(Irr_stair_val > NIGHT_THR);   % 1=day, 0=night

% Smoothed transition: 3-sample ramp avoids a step-discontinuity at the
% dawn/dusk edge (avoids integrator windup during mode switch).
Day_mode_val = movmean(Day_mode_val, 3);

Day_mode_ts  = timeseries(Day_mode_val, Irr_stair_time, ...
                           'Name', 'Day_mode');

assignin('base', 'Day_mode_ts',  Day_mode_ts);
assignin('base', 'V_ref_chg',    V_ref_chg);

fprintf('  Batt: V_nom=%.2f V (= V_ref_battery, equal energy to direct cases) | Q=%.0f Ah | SOC0=%.0f%%\n', ...
        V_batt_nom, Q_thesis, SOC_init_per);
fprintf('  BMS day/night: V_ref_day=%.2fV (=Vmin_PEM, charge) | V_ref_night=%.2fV (discharge)\n', ...
        V_ref_chg, V_ref_battery);
fprintf('  Day samples: %d  |  Night samples: %d\n', ...
        sum(Day_mode_val > 0.5), sum(Day_mode_val <= 0.5));

% =========================================================================
%  SECTION 4b – CONVERTER PARAMETER SCALING FOR TIME COMPRESSION
%
%  Root cause of RefGen chaos even after Vrefinit fix:
%    Irr_stair_tsamp = 60/36000 = 1.667e-3 s per weather minute.
%    With Ts = 1e-3 s (1 kHz), only ~1.67 switching cycles exist per
%    weather step → P&O never converges (needs >>1 cycle).
%    With MaxStep = 1e-5 s, RefGen runs ~167 times per weather step
%    → Vref bounces between [12 V, 30.15 V] chaotically.
%
%  Fix: scale Ts, L, C together so N_sw_per_step cycles occur per step.
%    Ts_sim   = Irr_stair_tsamp / N_sw_per_step
%    L_sim    = L_real × scale_Ts   (fn ∝ 1/√(LC) stays proportional)
%    C_sim    = C_real × scale_Ts
%    Ki_sim   = Ki_real / scale_Ts  (preserve integral bandwidth)
%    MaxStep  = Ts_sim / 5          (resolve each scaled switching cycle)
%    → RefGen runs N_sw_per_step × 5 ≈ 10 times per weather step ✓
% =========================================================================
N_sw_per_step = 2;                           % switching cycles per 1-min step
Ts_real       = Ts;                          % save real-world reference
L_conv_real   = L_conv;
C_conv_real   = C_conv;

Ts_sim    = Irr_stair_tsamp / N_sw_per_step; % [s] scaled switching period
scale_Ts  = Ts_sim / Ts_real;               % < 1 if Ts_real > Irr_stair_tsamp/2

L_conv = L_conv_real * scale_Ts;            % [H] scaled (fn/fsw unchanged)
C_conv = C_conv_real * scale_Ts;            % [F] scaled

Kp_sim = 0.01;                              % frequency-independent
Ki_sim = 10.0 / scale_Ts;                   % scaled: preserve integral bandwidth

% Tsc must stay at 1e-5 for the bidirectional converter (fsw=10kHz, Ts1=5e-5).
% Simscape local solver needs ≥5 steps per switching cycle → Tsc ≤ Ts1/5 = 1e-5.
% Note: global ODE MaxStep (=Ts_sim/5) and Tsc are INDEPENDENT.
Tsc = 1e-5;

fprintf('--- Converter scaling for time compression ---\n');
fprintf('  Irr_stair_tsamp : %.4e s  |  N_sw_per_step : %d\n', ...
        Irr_stair_tsamp, N_sw_per_step);
fprintf('  Ts_real=%.2e → Ts_sim=%.2e s  (scale_Ts=%.3f)\n', ...
        Ts_real, Ts_sim, scale_Ts);
fprintf('  L_conv : %.2e → %.2e H\n', L_conv_real, L_conv);
fprintf('  C_conv : %.2e → %.2e F\n', C_conv_real, C_conv);
fprintf('  Ki     : %.1f → %.2f  |  Kp=%.4f (unchanged)\n', 10.0, Ki_sim, Kp_sim);
fprintf('  Tsc    : %.2e s  |  MaxStep will be %.2e s\n\n', Tsc, Ts_sim/5);

% Push scaled values to workspace so Simulink blocks pick them up
assignin('base', 'L_conv', L_conv);
assignin('base', 'C_conv', C_conv);
assignin('base', 'Tsc',    Tsc);
% =========================================================================
%  SECTION 5 – MODEL SETUP & PATCHES
% =========================================================================
case_model = '1_Indirect';
mdl_orig   = 'PV_PEM_converter_battery';
mdl_fixed  = 'PV_PEM_converter_battery_FIXED';

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

% =========================================================================
%  REFGEN – BUCK-MODE MPPT  (Vref within PEM operating range)
%
%  History of MPPT attempts (kept for reference):
%   • Boost Vrefinit=500V  → Vref >> bus; P&O never converges (C_PV=60%).
%   • Boost Vrefinit=24.75V + D_max=0.85 → startup spike → crash.
%   • Boost Vrefinit=62V, D_max=0.60  → converges, BUT bus=62V >> Vmax_PEM=26V
%     → PEM permanently in over-limit (PEM_over=true all day) → zero daytime
%     H₂, bus collapse from PEM over-current, η_PV falls to ~9%.  WRONG.
%
%  CORRECT APPROACH — Buck mode targeting V_ref_battery ≈ 22.6 V:
%   Vmpp = 24.75 V  >  V_ref_battery ≈ 22.6 V  → converter BUCKS (D < 1).
%   D_opt = V_ref_battery / Vmpp ≈ 0.913   (no startup spike possible).
%   Vrefmax = Vmax_PEM = 26 V  →  PEM never exceeds hardware limit.
%   Vrefmin ≈ 20 V  →  PEM always above Vint_stack = 19.2 V (onset).
%   → P&O perturbs ±0.5 V around 22.6 V; PEM produces H₂ during DAY too.
%   → Fig 4 (converter-mode diagnostic) already assumes this strategy.
% =========================================================================
D_boost_max    = 0.60;                              % kept for reference / Fig 4 labels
%  ── BUCK-mode MPPT  (replaces the old boost-to-62 V strategy) ───────────
%
%  WHY boost mode (Vref=62 V) was WRONG:
%    • Vmax_PEM = 2.0×N = 26 V  →  bus at 62 V puts PEM in over-limit ALWAYS.
%    • PEM_over = (PEM_V > 26) = true for every daytime sample
%      → PEM_I_eff = 0 → H₂ = 0 during day → C_sys ≈ 0.
%    • Randles PEM model tries to draw (62−14.8)/0.14 ≈ 330 A from bus;
%      boost converter can only supply ~27 A → bus collapses → MPPT fails
%      → η_PV falls to 9 % (should be ~17–20 %).
%    • Fig 4 diagnostic code already assumes BUCK mode (D_opt=V_ref/Vmpp).
%
%  FIX (updated for N=16): Vmpp=33V > Vmax_PEM=32V → converter BUCKS (D<1).
%    D_opt = V_ref_battery / Vmpp = 27.81/33 = 0.843  (comfortably < 1).
%    PEM sees 23.6–32 V → operates in full rated range during day AND night.
% ─────────────────────────────────────────────────────────────────────────
Vref_nat       = V_ref_battery;   % ≈ 27.81 V  (PEM midpoint for N=16, kept for reference)
%  ── PEM UTILISATION FIX (N=16) ───────────────────────────────────────────
%  To maximise PEM utilisation target V_bus as HIGH as possible (up to Vmax_PEM=32V):
%    At 25.1 V → I_PEM = (25.1−23.613)/0.17509 ≈  8.5 A → P_PEM ≈  213 W (10% of Pmpp)
%    At 28.0 V → I_PEM = (28.0−23.613)/0.17509 ≈ 25.1 A → P_PEM ≈  702 W (32% of Pmpp)
%    At 32.0 V → I_PEM = (32.0−23.613)/0.17509 ≈ 47.9 A → P_PEM ≈ 1533 W (RATED)
%  Fix: Vrefmax = Vmax_PEM so P&O hunts in [Vmin_PEM+1.5, Vmax_PEM] = [25.1, 32] V.
Vref_max_mppt  = Vmax_PEM;                         % 32 V = Vmax_PEM  (< Vmpp=33V → BUCK ✓)
Vref_init_mppt = Vref_max_mppt - 0.5;             % 31.5 V — start near rated limit for max PEM
Vref_min_mppt  = Vmin_PEM + 1.5;                  % ≈ 25.1 V — 1.5V margin above PEM onset
%  P&O hunts in 25.1–32 V → P_PEM range 213–1533 W (vs old 13–550 W with N=13 params)
fprintf('  RefGen BUCK-MPPT (N=16): Vrefinit=%.1fV  Vrefmax=%.1fV  Vrefmini=%.1fV\n', ...
        Vref_init_mppt, Vref_max_mppt, Vref_min_mppt);
fprintf('  D_opt(buck) = %.3f  |  PEM op range: %.1f–%.1f V  |  Vmpp=%.2f V\n', ...
        Vref_nat/Vmpp, Vmin_PEM, Vref_max_mppt, Vmpp);

refgen_ok = false;
rg_vmax   = sprintf('Vrefmax = %.4f;',  Vref_max_mppt);
rg_vmin   = sprintf('Vrefmini = %.4f;', Vref_min_mppt);
rg_vinit  = sprintf('Vrefinit = %.4f;', Vref_init_mppt);
rg_step   = 'baseDeltaVref = 0.15;';   % reduced from 0.5 → less hunting, smaller bus excursions
% Adaptive step – also tighten the cap from 1.5 V to 0.4 V to prevent large single-step overshoots
rg_dv_new = 'deltaVref = min(0.4, baseDeltaVref * (1 + abs(dP) / max(abs(P), 10)));';

% METHOD A – Stateflow API  (R2017b+)
% For MATLAB Function blocks (Stateflow.EMChart), the function code lives in
% ch.Script (chart-level), NOT in the child state's LabelString which just
% holds the wrapper call 'eML_blk_kernel()'.  Try chart-level first, then
% fall back to state-level .Script (R2019a+), then state-level eml property.
try
    rt = sfroot;
    em_charts = rt.find('-isa','Stateflow.EMChart');
    fprintf('  [RefGen A] Found %d Stateflow.EMChart object(s)\n', numel(em_charts));
    % A1: search all EMCharts regardless of machine name
    for ch = em_charts'
        sc = '';
        try sc = ch.Script; catch; end          % chart-level Script (primary)
        if isempty(sc)
            % Some MATLAB versions expose it via the inner EML state
            for st = ch.find('-isa','Stateflow.State')'
                try sc = st.Script;   catch; end
                if ~isempty(sc), break; end
                try sc = st.LabelString; catch; end  % fallback (will be 'eML_blk_kernel()')
            end
        end
        if ~contains(sc,'Vrefinit','IgnoreCase',true), continue; end
        % Replace whatever value the user may have typed — cover all variants
        sc2 = sc;
        % --- Vrefmax: replace any number after 'Vrefmax = ' ---
        sc2 = regexprep(sc2, 'Vrefmax\s*=\s*[\d.]+\s*;', rg_vmax);
        % --- Vrefmini: replace any number ---
        sc2 = regexprep(sc2, 'Vrefmini\s*=\s*[\d.]+\s*;', rg_vmin);
        % --- Vrefinit: replace any number ---
        sc2 = regexprep(sc2, 'Vrefinit\s*=\s*[\d.]+\s*;', rg_vinit);
        % --- baseDeltaVref: replace any number ---
        sc2 = regexprep(sc2, 'baseDeltaVref\s*=\s*[\d.]+\s*;', rg_step);
        % --- deltaVref adaptive line: restore original (no max() guard) ---
        sc2 = regexprep(sc2, 'deltaVref\s*=\s*min\([^;]+\)\s*;', rg_dv_new);
        set_ok = false;
        try ch.Script = sc2; set_ok = true; catch; end   % set at chart level
        if ~set_ok
            for st = ch.find('-isa','Stateflow.State')'
                try st.Script = sc2; set_ok = true; break; catch; end
            end
        end
        if set_ok
            refgen_ok = true;
            fprintf('  [RefGen OK-A] Restored: Vrefinit=500  Vrefmax=1000  (Stateflow.EMChart.Script)\n');
        end
        break;
    end
catch eA
    fprintf('  [RefGen] Method A error: %s\n', eA.message);
end

% METHOD B – SFBlockHandle → chart object → patch Script
% Works when Method A's EMChart class iteration missed it (older MATLAB).
if ~refgen_ok
    try
        rt2 = sfroot;
        blks = find_system(mdl,'LookUnderMasks','all','BlockType','SubSystem','SFBlockType','MATLAB Function');
        fprintf('  [RefGen B] Found %d MATLAB Function block(s)\n', numel(blks));
        for bi = 1:numel(blks)
            sc = '';
            ch_obj = [];
            try
                ch_id  = get_param(blks{bi},'SFBlockHandle');
                % Try different idToHandle forms (varies by MATLAB version)
                try ch_obj = idToHandle(rt2, ch_id); catch; end
                if isempty(ch_obj), try ch_obj = rt2.idToHandle(ch_id); catch; end; end
                if ~isempty(ch_obj), try sc = ch_obj.Script; catch; end; end
            catch; end
            if ~contains(sc,'Vrefinit','IgnoreCase',true), continue; end
            sc2 = strrep(sc,'Vrefmax = 1000;',    rg_vmax);
            sc2 = strrep(sc2,'Vrefmini = 0;',      rg_vmin);
            sc2 = strrep(sc2,'Vrefinit = 500;',    rg_vinit);
            sc2 = strrep(sc2,'baseDeltaVref = 1;', rg_step);
            sc2 = strrep(sc2,'deltaVref = baseDeltaVref * (1 + abs(dP) / P);', rg_dv_new);
            ch_obj.Script = sc2;
            refgen_ok = true;
            fprintf('  [RefGen OK-B] Fixed via SFBlockHandle→Script  block=%s\n', blks{bi});
            break;
        end
    catch eB
        fprintf('  [RefGen] Method B error: %s\n', eB.message);
    end
end

% METHOD C – edit chart_11.xml inside the FIXED SLX (unzip→patch→rezip→reload)
if ~refgen_ok
    try
        tmp_dir = fullfile(tempdir,'refgen_patch_slx');
        if exist(tmp_dir,'dir'), rmdir(tmp_dir,'s'); end
        mkdir(tmp_dir);
        unzip(fixed_path, tmp_dir);
        chart_xml = fullfile(tmp_dir,'simulink','stateflow','chart_11.xml');
        if isfile(chart_xml)
            raw = fileread(chart_xml);
            if contains(raw,'Vrefinit = 500')
                raw = strrep(raw,'Vrefmax = 1000;',    rg_vmax);
                raw = strrep(raw,'Vrefmini = 0;',      rg_vmin);
                raw = strrep(raw,'Vrefinit = 500;',    rg_vinit);
                raw = strrep(raw,'baseDeltaVref = 1;', rg_step);
                raw = strrep(raw,'deltaVref = baseDeltaVref * (1 + abs(dP) / P);', rg_dv_new);
                fid = fopen(chart_xml,'w','n','UTF-8'); fprintf(fid,'%s',raw); fclose(fid);
                % Re-zip as SLX and reload
                close_system(mdl, 0);
                old_dir = cd(tmp_dir);
                zip(fixed_path, '.');   % zip() puts files from cwd into archive
                cd(old_dir);
                % MATLAB zip() appends .zip — handle if needed
                if ~isfile(fixed_path) && isfile([fixed_path '.zip'])
                    movefile([fixed_path '.zip'], fixed_path);
                end
                load_system(fixed_path);
                refgen_ok = true;
                fprintf('  [RefGen OK-C] Patched via XML + reload\n');
            end
        end
        if exist(tmp_dir,'dir'), rmdir(tmp_dir,'s'); end
    catch eC
        fprintf('  [RefGen] Method C error: %s\n', eC.message);
    end
end

if ~refgen_ok
    fprintf(['  *** [RefGen MANUAL ACTION REQUIRED] ***\n' ...
             '  Open the RefGen MATLAB Function block in Simulink and set:\n' ...
             '    Vrefmax       → %.1f   (= Vmpp/(1-0.60) × 1.5)\n' ...
             '    Vrefmini      → %.0f     (> Voc=%.2fV → always boost)\n' ...
             '    Vrefinit      → %.1f   (= Vmpp/(1-0.60), natural MPP point)\n' ...
             '    baseDeltaVref → 0.5\n' ...
             '    deltaVref line → deltaVref = min(1.5, baseDeltaVref * (1 + abs(dP) / max(abs(P), 10)));\n' ...
             '  Saturation block upper limit stays at 0.60 (do NOT change)\n'], ...
             Vref_max_mppt, Vref_min_mppt, Voc, Vref_init_mppt);
end

for b = find_system(mdl,'LookUnderMasks','all')'
    b = b{1};
    b_name=''; b_type='';
    try b_name = get_param(b,'Name');      catch; end
    try b_type = get_param(b,'BlockType'); catch; end
    if strcmp(b_type,'Constant')
        try set_param(b,'OutMax','[]'); catch; end; continue
    end
    if contains(b_name,'Irradiance','IgnoreCase',true)
        try set_param(b,'OutValues',  'Irr_stair_val');  catch; end
        try set_param(b,'samp_time',  'Irr_stair_tsamp'); catch; end
        try set_param(b,'rep_seq_t',  'Irr_time');        catch; end
        try set_param(b,'rep_seq_y',  'Irr_val');         catch; end
    end
    try
        ref = get_param(b,'ReferenceBlock');
        if contains(ref,'Simulink-PS Converter') || contains(ref,'PS-Simulink Converter')
            set_param(b,'FilteringAndDerivatives','filter');
            set_param(b,'InputFilterTimeConstant', num2str(tau_a / 100)); % 4e-3 s (tau_a=0.4/100)
        end
    catch; end
    % D_max = 0.60 patch applies ONLY to the main PV buck-boost converter.
    % EXCLUDE the battery BMS Subsystem — its internal saturation block
    % must stay at [0, 1] so that D can exceed SOC (which rises to ~72 %
    % after day-charging) and the '>= comparator' can enable discharge.
    % If we cap D at 0.60 and SOC > 0.60, the comparison D >= SOC is ALWAYS
    % FALSE → battery locked in charge mode forever → no nighttime H2.
    b_in_bms = contains(b, [mdl '/Subsystem']);   % true for blocks inside BMS controller
    if (contains(b_name,'Control','IgnoreCase',true) || strcmp(b_type,'Saturation')) && ~b_in_bms
        % D_max = 0.60 safe limit for main BOOST converter only.
        % In boost: V_bus = V_PV/(1-D) → D=0.60 → V_bus_max = Voc/0.40 = 75V.
        try set_param(b,'UpperSaturationLimit','0.60'); catch; end
        try set_param(b,'upperLimit','0.60');           catch; end
        try set_param(b,'OutMax','0.60');               catch; end
        try set_param(b,'P',  num2str(Kp_sim)); catch; end
        try set_param(b,'Kp', num2str(Kp_sim)); catch; end
        try set_param(b,'I',  num2str(Ki_sim)); catch; end  % scaled bandwidth
        try set_param(b,'Ki', num2str(Ki_sim)); catch; end
    end
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
    % Battery block: patch nominal voltage to V_batt_nom = V_ref_battery (≈27.81 V)
    if contains(b_name,'Battery','IgnoreCase',true)
        try set_param(b,'Vnom', num2str(V_batt_nom));          catch; end
        try set_param(b,'V1',   num2str(V_batt_nom * 0.917));  catch; end
        try set_param(b,'Vexp', num2str(V_batt_nom * 1.067));  catch; end
        try set_param(b,'Vfull',num2str(V_batt_nom * 1.15));   catch; end
    end
    % MPPT converter filter inductor/capacitor — set to workspace variables
    % so the converter scaling (Section 4b) actually takes effect.
    % Bidirectional converter uses Bi_L / Bi_C1 / Bi_C2 (unchanged).
    b_path = b;
    is_bidi = contains(b_path,'Bidi','IgnoreCase',true) || ...
              contains(b_path,'Bidirectional','IgnoreCase',true) || ...
              contains(b_path,'Battery','IgnoreCase',true);
    if ~is_bidi
        if contains(b_name,'Inductor','IgnoreCase',true)
            try set_param(b,'l',         'L_conv'); catch; end
            try set_param(b,'Inductance','L_conv'); catch; end
        end
        if contains(b_name,'Capacitor','IgnoreCase',true)
            try set_param(b,'c',          'C_conv'); catch; end
            try set_param(b,'Capacitance','C_conv'); catch; end
        end
    end
    if contains(b_name,'Solver Configuration')
        try set_param(b,'UseLocalSolver','on');
             set_param(b,'LocalSolverSampleTime','Tsc');
             set_param(b,'LocalSolverType','Backward Euler');
        catch; end
    end
    % Fix: Scope – disable point limit and close window (rendering costs CPU)
    if strcmp(b_type,'Scope')
        try set_param(b,'LimitDataPoints','off'); catch; end
        try set_param(b,'DataPoints','500000');   catch; end
        try set_param(b,'Open','off');            catch; end
    end
end

% ── Critical post-loop fix: ensure BiDi BMS saturation is [0, 1] ──────────
% Belt-and-suspenders: even if the exclusion above missed a block, this
% explicitly resets the saturation inside the battery BMS Subsystem.
% Root cause: the block scan sets ALL Saturation blocks to 0.60.  When SOC
% rises above 0.60 (after successful day-charging), D_max=0.60 < SOC means
% the '>= comparator' in the BMS is always FALSE → charge mode locked → no
% night discharge.  Must restore to [0, 1] so D can exceed SOC at any level.
bms_ctrl_path = [mdl '/Subsystem'];
try
    bms_sats = find_system(bms_ctrl_path,'LookUnderMasks','all','BlockType','Saturation');
    for kk = 1:numel(bms_sats)
        set_param(bms_sats{kk},'UpperSaturationLimit','1');
        set_param(bms_sats{kk},'LowerSaturationLimit','0');
        fprintf('  [BMS-FIX] Saturation reset to [0,1]: ...%s\n', ...
                bms_sats{kk}(length(bms_ctrl_path)+1:end));
    end
    if isempty(bms_sats)
        fprintf('  [BMS-FIX] No Saturation block found in %s\n', bms_ctrl_path);
        fprintf('            Check: does the BMS subsystem block name = "Subsystem"?\n');
    end
catch eSatFix
    fprintf('  [BMS-FIX WARNING] Auto-reset failed: %s\n', eSatFix.message);
    fprintf('  Manual fix: open model → Subsystem → set Saturation Upper=1, Lower=0\n');
end

set_param(mdl,'StopTime',num2str(sim_t),'Solver','ode15s',...
    'MaxStep',num2str(Ts_sim/5),'SimulationMode','accelerator');  % resolves each scaled switching cycle
try set_param(mdl,'SimscapeExplicitSolverDiagnostic','none'); catch; end
assignin('base','sample_output_time', sample_output_time);
assignin('base','V_ref_battery',     V_ref_battery);   % explicit push so Simulink always reads updated value
% Push SOC limits to base workspace so Simulink BMS block reads them
assignin('base','SOC_max',     SOC_max);       % fraction: 0.90
assignin('base','SOC_min',     SOC_min);       % fraction: 0.20
assignin('base','SOC_max_hys', SOC_max_hys);   % fraction: 0.85
assignin('base','SOC_min_hys', SOC_min_hys);   % fraction: 0.25
assignin('base','SOC_init',    SOC_init);
% Also push percent form in case BMS block uses 0–100 scale
assignin('base','SOC_max_pct', SOC_max * 100); % 90
assignin('base','SOC_min_pct', SOC_min * 100); % 20
assignin('base','SOC_init_pct',SOC_init_per);  % 50
% =========================================================================
%  SECTION 5b – SAFE MODEL PATCHES  (Scope only – no BMS topology changes)
%  SOC limits and night cutoff are enforced in post-processing (Section 7).
% =========================================================================
for bb = find_system(mdl,'LookUnderMasks','all','BlockType','Scope')'
    b = bb{1};
    try set_param(b,'LimitDataPoints','off'); catch; end
    try set_param(b,'DataPoints','500000');   catch; end
    try set_param(b,'Open','off');            catch; end
end

% ---- Targeted PID patch (library link broken first) ----------------------
pid_path = [mdl '/Subsystem/PID Controller'];
pid_ok   = false;
try
    set_param(pid_path, 'LinkStatus',                    'none');
    set_param(pid_path, 'LimitOutput',                   'on');
    set_param(pid_path, 'UpperSaturationLimit',          '0.9');
    set_param(pid_path, 'LowerSaturationLimit',          '0.1');
    set_param(pid_path, 'AntiWindupMode',                'clamping');
    set_param(pid_path, 'InitialConditionForIntegrator', '0.1');
    set_param(pid_path, 'InitialConditionForFilter',     '0.1');
    fprintf('  [PID PATCH OK] LimitOutput=%s | LowerSat=%s | AntiWindup=%s\n', ...
        get_param(pid_path,'LimitOutput'), ...
        get_param(pid_path,'LowerSaturationLimit'), ...
        get_param(pid_path,'AntiWindupMode'));
    pid_ok = true;
catch e
    fprintf('  [PID PATCH FAILED] %s\n', e.message);
end

% ---- Discharge relay: tighten hysteresis so SOC can escape the dead zone -
dis_path = [mdl '/Subsystem/Discharge enable1'];
try
    set_param(dis_path, 'OnSwitchValue',  '0.21');   % [CHANGED] from '0.21'
    set_param(dis_path, 'OffSwitchValue', '0.20');   % [CHANGED] from '0.20'
    fprintf('  [RELAY PATCH OK] Discharge enable hysteresis: ON=21, OFF=20\n');
catch e
    fprintf('  [RELAY PATCH FAILED] %s\n', e.message);
end

% NOTE: PID stays in CONTINUOUS-TIME (do NOT switch to discrete inside a
% Simscape model – mixed solver causes algebraic loop amplification).

% ---- Suppress algebraic loop from MPPT feedback (loop is 1-step lag, safe) -
try set_param(mdl, 'AlgebraicLoopMsg',          'warning'); catch; end
try set_param(mdl, 'ArtificialAlgebraicLoopMsg','warning'); catch; end

% ---- Adaptive zero-crossing algorithm (solver-level safety net) ----------
set_param(mdl, 'ZeroCrossAlgorithm', 'Adaptive');
try set_param(mdl, 'ZeroCrossControl', 'UseLocalSettings'); catch; end

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
t_plot = t * scale_factor / 3600;   % hours
real_t = t * scale_factor;          % real seconds

PV_V  = max(out.PV_V.Data,  0);
PV_I  = max(out.PV_I.Data,  0);
PEM_V = max(out.PEM_V.Data, 0);
PEM_I = max(out.PEM_I.Data, 0);
Irr   = max(out.Irr.Data,   0);
if max(PEM_I) > 500, PEM_I = PEM_I / 1000; end
if max(PV_I)  > 500, PV_I  = PV_I  / 1000; end

% --- PEM operating limit enforcement ---
% Exclude samples that exceed V, I, OR power rating from H2 accounting
PEM_over = (PEM_V > Vmax_PEM) | (PEM_I > Imax_PEM) | (PEM_V .* PEM_I > Pmax_PEM);
PEM_I_eff = PEM_I;  PEM_I_eff(PEM_over) = 0;
PEM_V_eff = PEM_V;  PEM_V_eff(PEM_over) = 0;
n_over = sum(PEM_over);
if n_over > 0
    fprintf('  [NOTE] PEM over-limit: %d samples (%.1f%% of data) excluded from H2\n', ...
            n_over, 100*n_over/numel(PEM_I));
end

% --- Battery signals ---
has_batt = false;
try
    Batt_V   = out.Batt_V.Data;
    Batt_I   = out.Batt_I.Data;
    Batt_SOC = out.Batt_SOC.Data;
    if mean(Batt_SOC) <= 1.0, Batt_SOC = Batt_SOC * 100; end  % 0-1 → 0-100%

    % Unit check: some Simscape sensor configurations output mA not A.
    % If peak > 2000 the signal is almost certainly in mA → convert.
    if max(abs(Batt_I)) > 2000
        Batt_I = Batt_I / 1000;
        fprintf('  [Batt] Unit correction: sensor was in mA → converted to A\n');
    end

    Batt_P   = Batt_V .* Batt_I;
    has_batt = true;

    meas_I_peak   = max(abs(Batt_I));
    sim_soc_range = range(Batt_SOC);

    fprintf('  [Batt] Sensor peak=%.3f A  |  Simscape SOC range=%.2f%%\n', ...
            meas_I_peak, sim_soc_range);

    % Simscape SOC is the ground truth (matches the scope).
    Batt_SOC_Math = Batt_SOC;

    if meas_I_peak > 0.5
        % Path A: current sensor is live — use it for Batt_P (charge/discharge).
        % This is the correct path: real circuit currents, real Watts.
        fprintf('  [Batt] Path A — current sensor OK (%.2f A peak)\n', meas_I_peak);
    else
        % Path B: sensor reads near-zero.
        % Root cause in Case 1: the main PV converter AND the battery converter
        % both regulate V_bus=%.1fV simultaneously → they compete → battery
        % settles at near-zero current.  This is real simulation behaviour,
        % not a calculation error.  We derive I from dSOC/dt as best estimate.
        fprintf('  [Batt] Path B — sensor ~0 A (dual-converter bus conflict).\n');
        fprintf('         Deriving I from Simscape SOC gradient instead.\n');
        dSOC_dt = gradient(Batt_SOC, real_t);        % [%%/s] real-time rate
        Batt_I  = dSOC_dt * Q_thesis * 3600 / 100;  % [A]  real-scale derived
        Batt_I  = movmean(Batt_I, 51);               % smooth numerical noise
        Batt_P  = Batt_V .* Batt_I;
        fprintf('  [Batt] Path B SOC-derived I peak=%.3f A  (SOC range=%.2f%%)\n', ...
                max(abs(Batt_I)), sim_soc_range);
    end

    % No night mask on Batt_P in Case 1 (Indirect): battery intentionally
    % discharges at night to power the PEM — that is correct operation.
catch
    Batt_V        = V_batt_nom * ones(size(t));
    Batt_I        = zeros(size(t));
    Batt_SOC      = SOC_init_per * ones(size(t));
    Batt_P        = zeros(size(t));
    Batt_SOC_Math = Batt_SOC;
    fprintf('  [NOTE] Battery signals not found in simulation output.\n');
end
% Charge / discharge power split (always ≥ 0)
Batt_P_chg = max(0,  Batt_P);   % [W] power INTO  battery (charging)
Batt_P_dis = max(0, -Batt_P);   % [W] power FROM battery (discharging)

% =========================================================================
%  SECTION 8 – DERIVED QUANTITIES
% =========================================================================
PV_P  = PV_V .* PV_I;
PEM_P = PEM_V_eff .* PEM_I_eff;

% P_mpp: analytical STC estimate (Np*Impp*(G/1000)*Ns*Vmpp, T=25°C assumed)
pv_Pu = Im_PV * Vm_PV * Ns_cell;   % 241.7 W/string at STC
P_mpp = max(0, Np_cell * pv_Pu * (Irr / 1000));
P_mpp(Irr <= NIGHT_THR) = NaN;
Coupling_C = PV_P ./ max(P_mpp, 1e-3);
Coupling_C = max(0, min(1.0, Coupling_C));
Coupling_C(Irr <= NIGHT_THR) = 0;

% System efficiency: PEM output / total electrical input (PV + battery discharge)
% Case 1: use full Batt_P — nighttime battery discharge to PEM is real operation.
if has_batt
    Batt_disch = max(0, -Batt_P);   % unmasked: includes nighttime discharge
    Total_in   = movmean(PV_P + Batt_disch, 200);
else
    Total_in   = movmean(PV_P, 200);
end
eta_raw = movmean(PEM_P, 200) ./ max(Total_in, 1e-3) * 100;
eta_raw(eta_raw > 99) = 99;
Eta_pct = nan(size(t));
valid   = Total_in > 1;
Eta_pct(valid) = eta_raw(valid);

% H2 production  (N multiplier: each cell contributes independently)
F_const = 96485;  eta_F = 0.99;  M_H2 = 2.016e-3;
n_H2     = (N * PEM_I_eff) / (2 * F_const) * eta_F;   % mol/s
H2_inst  = n_H2 * M_H2 * 1e3;     % g/s
H2_rate  = H2_inst * 3600;         % g/h
H2_cumul = cumtrapz(real_t, H2_inst);   % g

if has_batt
    Batt_P_attr = Batt_P;   % full signal for attribution
    safe_src = max(PV_P + max(0,-Batt_P_attr), 1e-6);
    H2_cumul_PV   = cumtrapz(real_t, H2_inst .* PV_P               ./ safe_src);
    H2_cumul_Batt = cumtrapz(real_t, H2_inst .* max(0,-Batt_P_attr) ./ safe_src);
else
    H2_cumul_PV   = H2_cumul;
    H2_cumul_Batt = zeros(size(H2_cumul));
end

% PV efficiency
G_safe = max(Irr, 10);
eta_PV = PV_P ./ (PV_area .* G_safe) * 100;
eta_PV(Irr <= NIGHT_THR) = NaN;
eta_PV = max(0, min(100, eta_PV));

% PEM electrochemical efficiency  η = Vint_stack / V_op
eta_PEM = NaN(size(PEM_V_eff));
valid_pem = PEM_V_eff > (Vint_stack + 0.1);
eta_PEM(valid_pem) = (Vint_stack ./ PEM_V_eff(valid_pem)) * 100;
eta_PEM = max(0, min(100, eta_PEM));

% Solar-to-Hydrogen (STH) and Total-to-Hydrogen (TTH)
LHV_H2  = 119.96e6;   % J/kg
pv_frac = PV_P ./ max(PV_P + max(0,-Batt_P), 1e-6);
pv_frac = min(1, max(0, pv_frac));
H2_power_solar = H2_inst .* pv_frac * 1e-3 * LHV_H2;
STH = H2_power_solar ./ (PV_area .* G_safe) * 100;
STH(Irr <= NIGHT_THR) = NaN;
STH = max(0, STH);

H2_power_total = H2_inst * 1e-3 * LHV_H2;
TTH = H2_power_total ./ (PV_area .* G_safe) * 100;
TTH(Irr <= NIGHT_THR) = NaN;
TTH = max(0, TTH);
TTH_8day = (H2_cumul(end) * 1e-3 * LHV_H2) / trapz(real_t, Irr .* PV_area) * 100;

% ── System coupling  C_sys = P_PEM / P_mpp  ─────────────────────────────
% C_PV  = P_PV  / P_mpp  → how well PV operates at its MPP (already: Coupling_C)
% C_sys = P_PEM / P_mpp  → how much of available solar reaches PEM input
%         including battery discharge augmentation on top of PV during daylight.
%         Defined only during daylight (NaN at night, no solar reference).
C_sys = PEM_P ./ max(P_mpp, 1e-3);
C_sys(Irr <= NIGHT_THR) = NaN;
C_sys = min(C_sys, 2.0);   % cap at 200 % (battery can at most double PV)

% ── PEM capacity factor  CF_PEM = mean(P_PEM, all hours) / P_rated ──────
% Higher CF_PEM means the battery keeps the PEM running longer (incl. night).
CF_PEM = mean(PEM_P, 'omitnan') / max(Pmax_PEM, 1) * 100;   % [%]

% ── Battery round-trip efficiency  η_batt = E_dis / E_chg ───────────────
E_chg_Wh = trapz(real_t, Batt_P_chg) / 3600;   % [Wh] energy stored during sim
E_dis_Wh = trapz(real_t, Batt_P_dis) / 3600;   % [Wh] energy recovered during sim
% Correct for initial SOC: battery may start above SOC_min and discharge
% that pre-stored energy without it ever being charged during the simulation.
% Use V_ref_battery (actual bus voltage) not V_batt_nom (nominal label) so
% the Wh scale is correct.  Cap at 99% — physically realisable upper bound.
V_batt_avg    = mean(Batt_V,'omitnan');          % actual operating voltage
V_batt_scale  = max(V_batt_avg, V_batt_nom);    % use whichever is larger
SOC_final     = Batt_SOC_Math(end);
E_initial_Wh  = max(0, (SOC_init_per - SOC_final) / 100 * Q_thesis * V_batt_scale);
E_dis_cycle   = max(0, E_dis_Wh - E_initial_Wh);  % only cycling discharge
if E_chg_Wh > 1
    eta_batt_RT = min(99, E_dis_cycle / E_chg_Wh * 100);   % hard cap at 99%
else
    eta_batt_RT = NaN;
end

% ── Nighttime H2 production ──────────────────────────────────────────────
% H2 produced when Irr ≤ NIGHT_THR (battery-only operation, Case 1 key metric).
nm_mask = Irr <= NIGHT_THR;
%  FIX: trapz(t(mask), y(mask)) connects non-consecutive nighttime samples
%  across daytime gaps and inflates the integral ~5×. Correct approach:
%  zero out daytime values and integrate the full time vector.
H2_inst_night           = H2_inst;
H2_inst_night(~nm_mask) = 0;
H2_night = trapz(real_t, H2_inst_night);   % [g]
H2_night_pct  = H2_night  / max(H2_cumul(end), 1e-6) * 100;   % [%]
H2_PV_pct     = H2_cumul_PV(end)   / max(H2_cumul(end), 1e-6) * 100;
H2_Batt_pct   = H2_cumul_Batt(end) / max(H2_cumul(end), 1e-6) * 100;

% ── Console summary ──────────────────────────────────────────────────────
sep1 = repmat('-',1,52);
fprintf('\n%s\n  CASE 1 — Indirect PV-Batt-PEM  KPI Summary\n%s\n', sep1, sep1);
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
    fprintf('  Batt round-trip η      : n/a (no charging detected)\n');
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
day_labels = arrayfun(@(d) sprintf('Day %d', d), 0:NUM_DAYS, 'UniformOutput', false);

% ── Fig 1: System Overview ──────────────────────────────────────────────
fig1 = figure('Name','System Overview','Color','w','Position',[30 30 1100 760]);
tl1  = tiledlayout(4,1,'TileSpacing','compact','Padding','compact');
title(tl1, sprintf('Case 1 – Indirect PV–Batt–PEM  |  N=%d cells | Np=%d strings | Q=%.0f Ah', ...
      N, Np_cell, Q_thesis), 'FontSize', 12, 'FontWeight', 'bold');

nexttile; plot(t_plot, Irr, 'Color', clr_irr, 'LineWidth', lw);
ylabel('G (W/m²)'); ylim([0 1200]); grid on; box on;

nexttile; hold on;
plot(t_plot, PV_V,  'Color', clr_pv,  'LineWidth', lw, 'DisplayName', 'V_{PV}');
plot(t_plot, PEM_V, 'Color', clr_pem, 'LineWidth', lw, 'DisplayName', 'V_{PEM}');
if has_batt, plot(t_plot, Batt_V, 'Color', clr_batt, 'LineWidth', lw, 'DisplayName', 'V_{batt}'); end
yline(Vmax_PEM,'--','Color',[0.5 0.5 0.5],'HandleVisibility','off');
yline(Vmin_PEM,':' ,'Color',[0.5 0.5 0.5],'HandleVisibility','off');
hold off; ylabel('Voltage (V)'); grid on; box on; legend('Location','east');

nexttile; hold on;
plot(t_plot, PV_I,  'Color', clr_pv,  'LineWidth', lw, 'DisplayName', 'I_{PV}');
plot(t_plot, PEM_I, 'Color', clr_pem, 'LineWidth', lw, 'DisplayName', 'I_{PEM}');
if has_batt, plot(t_plot, Batt_I, 'Color', clr_batt, 'LineWidth', lw, 'DisplayName', 'I_{batt}'); end
yline(Imax_PEM,'--','Color',[0.5 0.5 0.5],'HandleVisibility','off');
hold off; ylabel('Current (A)'); grid on; box on; legend('Location','northeast');

nexttile; hold on;
plot(t_plot, PV_P,  'Color', clr_pv,  'LineWidth', lw, 'DisplayName', 'P_{PV}');
plot(t_plot, PEM_P, 'Color', clr_pem, 'LineWidth', lw, 'DisplayName', 'P_{PEM}');
if has_batt, plot(t_plot, Batt_P, 'Color', clr_batt, 'LineWidth', lw, 'DisplayName', 'P_{batt}'); end
yline(Pmax_PEM,'--','Color',[0.5 0.5 0.5],'HandleVisibility','off');
hold off; xlabel('Time (hours)'); ylabel('Power (W)'); grid on; box on; legend('Location','northeast');

for ax = findobj(fig1,'Type','Axes')'
    xticks(ax, day_ticks); xlim(ax, [0 NUM_DAYS*24]);
    for d = day_ticks(2:end-1), xline(ax, d, ':','Color',[0.7 0.7 0.7],'HandleVisibility','off'); end
end
drawnow; exportgraphics(fig1, 'Fig1_SystemOverview_Case1.png', 'Resolution', 300);

% ── Fig 2: H2 + SOC ────────────────────────────────────────────────────
fig2 = figure('Name','H2 & SOC','Color','w','Position',[60 60 1100 560]);
tl2  = tiledlayout(2,1,'TileSpacing','compact','Padding','compact');

ax2a = nexttile; yyaxis(ax2a,'left'); ax2a.YColor = clr_pem;
plot(t_plot, H2_rate, 'Color', clr_pem, 'LineWidth', lw, 'DisplayName','H₂ rate (g/h)');
ylabel('H₂ rate (g h^{-1})');
yyaxis(ax2a,'right'); ax2a.YColor = [0 0.4 0.8];
plot(t_plot, H2_cumul,'Color',[0 0.4 0.8],'LineWidth', lw,'LineStyle','-.','DisplayName','Cumulative H₂ (g)');
ylabel('H₂ cumul. (g)'); grid on; box on;
legend('Location','northwest','NumColumns',2);

if has_batt
    ax2b = nexttile;
    plot(t_plot, Batt_SOC_Math, 'Color', clr_batt, 'LineWidth', lw+0.4);
    yline(SOC_max*100,'--','Color',[0.7 0.1 0.1],'LineWidth',1.2,'HandleVisibility','off');
    yline(SOC_min*100,'--','Color',[0.7 0.1 0.1],'LineWidth',1.2,'HandleVisibility','off');
    ylabel('SOC (%)'); ylim([0 105]); grid on; box on;
    xlabel('Time (hours)');
else
    nexttile; axis off;
end

for ax = findobj(fig2,'Type','Axes')'
    try xticks(ax, day_ticks); xlim(ax, [0 NUM_DAYS*24]); catch; end
end
drawnow; exportgraphics(fig2, 'Fig2_H2_SOC_Case1.png', 'Resolution', 300);

% ── Fig 3: Battery EMS (if available) ──────────────────────────────────
if has_batt
    fig3 = figure('Name','Battery EMS','Color','w','Position',[80 80 1100 680]);
    tl3  = tiledlayout(3,1,'TileSpacing','compact','Padding','compact');
    title(tl3, sprintf('Battery EMS  |  V_{nom}=%.0f V, Q=%.0f Ah, SOC_0=%.0f%%', ...
          V_batt_nom, Q_thesis, SOC_init_per), 'FontSize', 11, 'FontWeight','bold');

    ax3a = nexttile; yyaxis(ax3a,'left'); ax3a.YColor = clr_batt;
    plot(t_plot, Batt_V, 'Color', clr_batt, 'LineWidth', lw); ylabel('V_{batt} (V)','Color',clr_batt);
    yyaxis(ax3a,'right'); ax3a.YColor = [0.7 0.1 0.1];
    plot(t_plot, Batt_I, 'Color', [0.7 0.1 0.1], 'LineWidth', lw);
    yline(0,'k:','HandleVisibility','off'); ylabel('I_{batt} (A)'); grid on; box on;

    nexttile; hold on;
    plot(t_plot, PV_P,   'Color', clr_pv,   'LineWidth', lw, 'DisplayName', 'P_{PV}');
    plot(t_plot, PEM_P,  'Color', clr_pem,  'LineWidth', lw, 'DisplayName', 'P_{PEM}');
    plot(t_plot, Batt_P, 'Color', clr_batt, 'LineWidth', lw, 'DisplayName', 'P_{batt}(+chg)');
    yline(0,'k:','HandleVisibility','off');
    hold off; ylabel('Power (W)'); grid on; box on; legend('Location','northeast','NumColumns',3);

    nexttile;
    plot(t_plot, Batt_SOC_Math, 'Color',[0.1 0.6 0.3], 'LineWidth', lw+0.4);
    yline(SOC_max*100,'--','Color',[0.7 0.1 0.1],'LineWidth',1.2,'HandleVisibility','off');
    yline(SOC_min*100,'--','Color',[0.7 0.1 0.1],'LineWidth',1.2,'HandleVisibility','off');
    text(NUM_DAYS*24*0.99, SOC_max*100+2,'SOC_{max}','FontSize',8,'HorizontalAlignment','right','Color',[0.7 0.1 0.1]);
    text(NUM_DAYS*24*0.99, SOC_min*100+2,'SOC_{min}','FontSize',8,'HorizontalAlignment','right','Color',[0.7 0.1 0.1]);
    ylabel('SOC (%)'); ylim([0 105]); xlabel('Time (hours)'); grid on; box on;

    for ax = findobj(fig3,'Type','Axes')'
        xticks(ax,day_ticks); xlim(ax,[0 NUM_DAYS*24]);
        for d = day_ticks(2:end-1), xline(ax,d,':','Color',[0.7 0.7 0.7],'HandleVisibility','off'); end
    end
    drawnow; exportgraphics(fig3,'Fig3_BattEMS_Case1.png','Resolution',300);
end

% ── Fig 4: Converter Mode (Buck=0 / Boost=1) diagnostic ─────────────────
% Mode is inferred from logged signals: Mode = (Vref > V_PV).
% With the new BUCK-MPPT strategy Vrefmax=22V < V_PV_min≈24.75V so Mode
% should be 0 (Buck) throughout daylight.  This plot lets you verify.
try
    % Compute Mode from available signals
    % Vref is NOT directly logged, so we back-calculate from PV_P and D:
    %   In buck: V_bus = D × V_PV  → D = V_out/V_in
    %   Here we approximate Mode from the voltage ratio
    V_out_approx = PEM_V;           % bus voltage ≈ PEM voltage (direct load)
    V_in_approx  = PV_V;            % PV voltage
    D_approx     = V_out_approx ./ max(V_in_approx, 1);   % duty cycle estimate
    D_approx     = min(max(D_approx, 0), 1);
    Mode_approx  = double(V_out_approx > V_in_approx);    % 1=Boost if Vout>Vin
    Mode_approx(Irr <= NIGHT_THR) = NaN;                  % mask night

    fig4 = figure('Name','Converter Mode Analysis','Color','w','Position',[100 100 1100 680]);
    tl4  = tiledlayout(3,1,'TileSpacing','compact','Padding','compact');
    title(tl4, 'Case 1 – Converter Mode & MPPT Analysis', 'FontSize', 12, 'FontWeight','bold');

    % --- Subplot 1: Voltages ---
    nexttile; hold on;
    plot(t_plot, PV_V,  'Color', clr_pv,  'LineWidth', lw, 'DisplayName', 'V_{PV}');
    plot(t_plot, PEM_V, 'Color', clr_pem, 'LineWidth', lw, 'DisplayName', 'V_{PEM} (bus)');
    yline(Vmpp,          '--', 'Color',[0.5 0.5 0.5], 'LineWidth', 1, 'HandleVisibility','off');
    yline(V_ref_battery, ':',  'Color',[0.5 0.5 0.5], 'LineWidth', 1, 'HandleVisibility','off');
    text(1, Vmpp+0.8, sprintf('V_{mpp}=%.1fV', Vmpp), 'FontSize', 8, 'Color', [0.4 0.4 0.4]);
    text(1, V_ref_battery+0.8, sprintf('V_{bus,ref}=%.1fV', V_ref_battery), 'FontSize', 8, 'Color', [0.4 0.4 0.4]);
    hold off; ylabel('Voltage (V)'); grid on; box on;
    legend('Location','northeast','NumColumns',2);

    % --- Subplot 2: Duty cycle estimate & mode ---
    nexttile; hold on;
    plot(t_plot, D_approx, 'Color',[0.2 0.6 0.2], 'LineWidth', lw, 'DisplayName','D = V_{bus}/V_{PV}');
    yline(D_boost_max,'--','Color',[0.7 0 0],'LineWidth',1.2,'DisplayName',sprintf('D_{max}=%.2f',D_boost_max));
    yline(V_ref_battery/Vmpp,':', 'Color',[0 0 0.7],'LineWidth',1.2, ...
          'DisplayName', sprintf('D_{opt}=%.3f', V_ref_battery/Vmpp));
    hold off; ylabel('Duty cycle D (-)'); ylim([0 1.1]); grid on; box on;
    legend('Location','northeast','NumColumns',3);

    % --- Subplot 3: Mode + C_PV ---
    nexttile; hold on;
    yyaxis left;
    stairs(t_plot, Mode_approx, 'Color',[0.9 0.4 0], 'LineWidth', lw);
    ylabel('Mode  (0=Buck, 1=Boost)'); ylim([-0.2 1.5]);
    yticks([0 1]); yticklabels({'Buck','Boost'});
    yyaxis right;
    plot(t_plot, Coupling_C, 'Color', clr_pv, 'LineWidth', lw-0.4, 'DisplayName','C_{PV}');
    ylabel('C_{PV} (-)'); ylim([0 1.1]);
    yline(mean(Coupling_C(Irr>NIGHT_THR),'omitnan'), '--', 'Color', clr_pv, ...
          'LineWidth', 1.0, 'HandleVisibility','off');
    hold off; xlabel('Time (hours)'); grid on; box on;

    for ax = findobj(fig4,'Type','Axes')'
        try xticks(ax, day_ticks); xlim(ax, [0 NUM_DAYS*24]); catch; end
        for d = day_ticks(2:end-1)
            xline(ax, d, ':', 'Color',[0.7 0.7 0.7], 'HandleVisibility','off');
        end
    end
    drawnow;
    exportgraphics(fig4,'Fig4_ConverterMode_Case1.png','Resolution',300);
    fprintf('  Saved: Fig4_ConverterMode_Case1.png\n');
    fprintf('  Mode stats (daytime): Buck=%.1f%%  Boost=%.1f%%\n', ...
            100*mean(Mode_approx(Irr>NIGHT_THR)==0,'omitnan'), ...
            100*mean(Mode_approx(Irr>NIGHT_THR)==1,'omitnan'));
catch eM
    fprintf('  [Fig4 skipped] %s\n', eM.message);
end

% =========================================================================
%  SECTION 10 – EXCEL EXPORT (standardised columns for compare_batt_cases.m)
% =========================================================================
filename = 'PV_PEM_indirect_batt_results_week.xlsx';
if isfile(filename), delete(filename); end

TS = table( ...
    t_plot, real_t, Irr, ...
    PV_V, PV_I, PV_P, ...
    PEM_V, PEM_I, PEM_P, ...
    Batt_V, Batt_I, Batt_P, Batt_P_chg, Batt_P_dis, Batt_SOC_Math, ...
    H2_rate, H2_cumul, H2_cumul_PV, H2_cumul_Batt, ...
    Coupling_C, C_sys, Eta_pct, eta_PV, eta_PEM, STH, TTH, ...
    'VariableNames', { ...
        't_plot_[h]','t_real_[s]','Irr_[W/m2]', ...
        'PV_V_[V]','PV_I_[A]','PV_P_[W]', ...
        'PEM_V_[V]','PEM_I_[A]','PEM_P_[W]', ...
        'Batt_V_[V]','Batt_I_[A]','Batt_P_[W]','Batt_P_chg_[W]','Batt_P_dis_[W]','Batt_SOC_[%]', ...
        'H2_rate_[g_h]','H2_cumul_[g]','H2_cumul_PV_[g]','H2_cumul_Batt_[g]', ...
        'Coupling_C','C_sys','Eta_pct','eta_PV_[pct]','eta_PEM_[pct]','STH_[pct]','TTH_[pct]'});

writetable(TS, filename, 'Sheet','TimeSeries','WriteMode','overwritesheet');

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
paramValues = [1; N; Np_cell; Ns_cell; PV_area; ...
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
PARAM = table(paramNames, paramValues, 'VariableNames',{'Parameter','Value'});
writetable(PARAM, filename,'Sheet','Parameters','WriteMode','overwritesheet');

fprintf('\n  Saved: %s\n', filename);
fprintf('=== Case 1 DONE ===\n');
