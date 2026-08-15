clear; clc; close all;
%warning('off', 'all');
fprintf('=== PV-PEM Setup & Simulation ===\n\n');

% =========================================================================
%  SIMULATION SETTINGS
% =========================================================================
sim_t_per_day  = 24;
irr_update_min = 1;
NUM_DAYS       = 8;   % actual weather dataset length [days]
sim_t          = sim_t_per_day * NUM_DAYS;

scale_factor  = (24 * 3600) / sim_t_per_day;   % = 3600
t_plot_mult   = (24 / sim_t_per_day);           % = 1

fprintf('  Simulating %d days in %.2f sim-seconds\n', NUM_DAYS, sim_t);

% =========================================================================
%  SECTION 1 — ELECTROLYZER PARAMETERS
% =========================================================================
N     = 16;
Vint  = 1.475841;   % [V]
Rint  = 0.008673;   % [Ohm]
Ra    = 0.00177;    % [Ohm]
Rc    = 0.0005;     % [Ohm]

ratio_tau = 10;
tau_a     = 0.4 / scale_factor;   % [s sim-time]
tau_c     = tau_a / ratio_tau;
Ca          = tau_a / Ra;   % [F]
Cc          = tau_c / Rc;   % [F]
Active_Area = 17.64;        % [cm²]

Vint_stack = Vint * N;
Rint_stack = Rint * N;
Ra_stack   = Ra   * N;
Rc_stack   = Rc   * N;
Ca_stack   = Ca   / N;
Cc_stack   = Cc   / N;

Vmin_PEM  = 1.5 * N;
Vmax_PEM  = 2.0 * N;
Imin_PEM  = 2.2;
Imax_PEM  = 80;
V_ref_PEM = 1.8 * N;

% =========================================================================
%  SECTION 2 — PV ARRAY PARAMETERS
% =========================================================================
Im_PV = 9.59;   % [A]  cell MPP current at STC
Vm_PV = 0.56;   % [V]  cell MPP voltage at STC

% Base = MAXIMUM strings (Low-G config); strings are REMOVED as irradiance rises
%   Low-G  → 7 strings (all connected)
%   Mid-G  → 6 strings (one removed)
%   High-G → 5 strings (two removed)
Np_cell_base  = 7;   % Low-G  config → 7 strings
Np_cell_red_1 = 1;   % Mid-G  config → 6 strings  (7 - 1)
Np_cell_red_2 = 1;   % High-G config → 5 strings  (7 - 1 - 1)
Np_cell       = Np_cell_base;   % alias
Ns_cell       = 60;

% Aliases required by Simulink Solar Cell block N_parallel parameters
% (Solar Cell1 and Solar Cell2 blocks reference these variable names directly)
Np_cell_add_1 = Np_cell_red_1;   % Solar Cell2: 1 string
Np_cell_add_2 = Np_cell_red_2;   % Solar Cell1: 1 string

% Np_map: active strings per configuration index [1=Low-G, 2=Mid-G, 3=High-G]
Np_map = [Np_cell_base, ...                               % config 1 → 7
          Np_cell_base - Np_cell_red_1, ...               % config 2 → 6
          Np_cell_base - Np_cell_red_1 - Np_cell_red_2];  % config 3 → 5

fprintf('Reconfiguration levels: Low-G = %d | Mid-G = %d | High-G = %d strings\n', ...
    Np_map(1), Np_map(2), Np_map(3));

% =========================================================================
%  SECTION 2b — RECONFIGURATION THRESHOLDS  (physics-derived, fixed)
% =========================================================================
NIGHT_THR = 70;   % [W/m²] below this → night / off state

% -------------------------------------------------------------------------
%  RECONFIGURATION OBJECTIVE
%  Single clear objective: prevent V_PEM from exceeding Vmax_PEM = 2.0×N V.
%
%  In a directly coupled PV-PEM system the operating current is set by the
%  intersection of the PV I-V curve and the PEM load line.  As irradiance G
%  rises, I_PEM rises proportionally.  The PEM voltage then rises along its
%  ohmic load line:
%
%    V_PEM(I) = Vint_stack + I × R_stack        (simplified, R_stack = N×(Rint+Ra+Rc))
%
%  The switch threshold is the G at which I_MPP(Np) = I_rated_PEM, i.e. the
%  irradiance that would push V_PEM to exactly Vmax_PEM with the current Np.
%
%  Derivation (parameters from Section 1):
%    R_stack = N × (Rint + Ra + Rc) = 13 × 0.010943 = 0.1423 Ω
%    I_rated = (Vmax_PEM - Vint_stack) / R_stack
%            = (26 - 19.186) / 0.1423 ≈ 47.9 A
%
%    G_switch(Np) = I_rated / (Np × Im_PV) × 1000
%      Np = 7  →  G_switch = 47.9 / (7 × 9.59) × 1000 ≈ 715 W/m²  (7→6)
%      Np = 6  →  G_switch = 47.9 / (6 × 9.59) × 1000 ≈ 834 W/m²  (6→5)
%
%  A 25 W/m² hysteresis band is added to avoid chattering at the boundary.
%  Secondary objective: minimise time outside the PEM rated window.
% -------------------------------------------------------------------------
R_stack_ohm = N * (Rint + Ra + Rc);                    % [Ω]  total stack resistance
I_rated_PEM = (Vmax_PEM - Vint_stack) / R_stack_ohm;   % [A]  onset of V_PEM = Vmax
HYS         = 25;                                       % [W/m²] hysteresis half-band

THR_97_up   = ceil(I_rated_PEM / (7 * Im_PV) * 1000);  % 7→6 rising  ≈ 715 W/m²
THR_97_down = THR_97_up - HYS;                          % 6→7 falling ≈ 690 W/m²
THR_75_up   = ceil(I_rated_PEM / (6 * Im_PV) * 1000);  % 6→5 rising  ≈ 834 W/m²
THR_75_down = THR_75_up - HYS;                          % 5→6 falling ≈ 809 W/m²

fprintf('  Reconfiguration thresholds (physics-derived, obj: V_PEM ≤ Vmax):\n');
fprintf('    I_rated_PEM = %.1f A  |  R_stack = %.4f Ω\n', I_rated_PEM, R_stack_ohm);
fprintf('    7→6 strings: G_up = %d W/m²  |  G_dn = %d W/m²\n', THR_97_up, THR_97_down);
fprintf('    6→5 strings: G_up = %d W/m²  |  G_dn = %d W/m²\n', THR_75_up, THR_75_down);

% STC reference based on maximum array (7 strings)
Isc  = 10.14 * Np_cell_base;
Voc  =  0.67 * Ns_cell;
Vmpp = Vm_PV * Ns_cell;
Impp = Im_PV * Np_cell_base;
Pmpp = Vmpp  * Impp;

fprintf('Ns = %d (series), Np_base = %d (parallel)\n', Ns_cell, Np_cell_base);
fprintf('STC MPP: Vmpp = %.2f V | Impp = %.2f A | Pmpp = %.1f W\n\n', Vmpp, Impp, Pmpp);

% =========================================================================
%  SECTION 3 — TIME & WEATHER DATA
% =========================================================================
scale_factor = 36000;   % redeclare (Section 1 used initial value for tau compression)

if isfile('weather_profile_week.xlsx')
    fprintf('Loading weather data from weather_profile_week.xlsx...\n');
    weather       = readtable('weather_profile_week.xlsx');
    real_time_sec = weather.Time_min * 60;
    Irr_val       = weather.Irradiance;
    Temp_val      = weather.Temperature;
else
    fprintf('[!] weather_profile_week.xlsx not found — generating mock profile.\n');
    real_time_sec = (0 : 60 : 365*86400)';
    day_of_year   = real_time_sec / 86400;
    time_of_day   = mod(real_time_sec, 86400);
    seasonal_env  = 700 + 300 * sin(2*pi*(day_of_year - 80) / 365);
    Irr_val = seasonal_env .* max(sin(pi * time_of_day / 86400), 0) ...
              .* (0.85 + 0.15 * rand(size(real_time_sec)));
    Irr_val(time_of_day < 3600*6 | time_of_day > 3600*20) = 0;
    Temp_val = 15 + 15*sin(2*pi*(day_of_year-80)/365) ...
             +  8*max(sin(pi*time_of_day/86400), 0);
end

Irr_time = real_time_sec / scale_factor;
sim_t    = max(Irr_time);

Irr_stair_tsamp = 60 / scale_factor;
Irr_stair_time  = (0 : Irr_stair_tsamp : sim_t)';
Irr_stair_val   = interp1(Irr_time, Irr_val,  Irr_stair_time, 'linear', 0);
Temp_stair_val  = interp1(Irr_time, Temp_val, Irr_stair_time, 'linear', 25);

% NOTE: Thresholds are fixed physics-derived values from Section 2b.
% No JSON files or Python scripts are needed — Simulink applies the
% thresholds in real time during the simulation.

% Sample times for MATLAB Function / Stateflow / Simscape blocks
Ts                 = 60 / scale_factor;
Tsc                = 60 / scale_factor;
sample_output_time = Ts;

assignin('base', 'Ts',                 Ts);
assignin('base', 'Tsc',                Tsc);
assignin('base', 'sample_output_time', sample_output_time);
assignin('base', 'Irr_stair_tsamp',    Irr_stair_tsamp);

fprintf('Simulation horizon: %.1f days | sim-time span: %.4f s\n\n', ...
    sim_t * scale_factor / 86400, sim_t);

% =========================================================================
%  SECTION 4 — MODEL COPY & BLOCK OVERRIDES
% =========================================================================
case_model = 'G';
pyenv('Version', 'C:\Users\Diamantis_Almpantis\anaconda3\python.exe');

mdl_orig  = 'G_recon_no_batt_model';
mdl_fixed = 'G_recon_no_batt_model_FIXED';

fprintf('--- Applying Model Patches ---\n');
if bdIsLoaded(mdl_orig),  close_system(mdl_orig,  0); end
if bdIsLoaded(mdl_fixed), close_system(mdl_fixed, 0); end

slx_path = which([mdl_orig '.slx']);
if isempty(slx_path), slx_path = fullfile(pwd, [mdl_orig '.slx']); end

slx_dir    = fileparts(slx_path);
fixed_path = fullfile(slx_dir, [mdl_fixed '.slx']);

load_system(slx_path);
save_system(mdl_orig, fixed_path);
close_system(mdl_orig, 0);
fprintf('  Working copy saved: %s\n', fixed_path);

load_system(fixed_path);
mdl = mdl_fixed;

blocks = find_system(mdl, 'LookUnderMasks', 'all');
for i = 1:length(blocks)
    b = blocks{i};
    b_name = ''; b_type = '';
    try b_name = get_param(b, 'Name');      catch; end
    try b_type = get_param(b, 'BlockType'); catch; end

    if strcmp(b_type, 'Constant')
        try set_param(b, 'OutMax', '[]'); catch; end
        continue;
    end

    % Irradiance injection
    if contains(b_name, 'Irradiance', 'IgnoreCase', true)
        try set_param(b, 'rep_seq_t', 'Irr_time');        catch; end
        try set_param(b, 'rep_seq_y', 'Irr_val');         catch; end
        try set_param(b, 'OutValues', 'Irr_stair_val');   catch; end
        try set_param(b, 'samp_time', 'Irr_stair_tsamp'); catch; end
    end

    % Temperature injection
    if contains(b_name, 'Temperature', 'IgnoreCase', true) || ...
       contains(b_name, 'Temp',        'IgnoreCase', true)
        try set_param(b, 'rep_seq_t', 'Irr_time');        catch; end
        try set_param(b, 'rep_seq_y', 'Temp_val');        catch; end
        try set_param(b, 'OutValues', 'Temp_stair_val');  catch; end
        try set_param(b, 'samp_time', 'Irr_stair_tsamp'); catch; end
    end

    % PS Converters
    try
        ref = get_param(b, 'ReferenceBlock');
        if contains(ref, 'Simulink-PS Converter') || contains(ref, 'PS-Simulink Converter')
            set_param(b, 'FilteringAndDerivatives', 'filter');
            set_param(b, 'InputFilterTimeConstant', '1e-6');
        end
    catch; end

    % Current sensors
    if contains(b_name, 'Current', 'IgnoreCase', true) || ...
       contains(b_name, 'Ammeter', 'IgnoreCase', true)
        try set_param(b, 'i_unit', 'A'); catch; end
    end

    % Solver Configuration
    % UseLocalSolver requires a C compiler (MinGW) even in Normal mode.
    % Disabled here — Simscape uses the global ode15s solver instead.
    if contains(b_name, 'Solver Configuration')
        try
            set_param(b, 'UseLocalSolver', 'off');
        catch; end
    end

    % Scope logging
    if strcmp(b_type, 'Scope')
        try set_param(b, 'DataLogging', 'off'); catch; end
    end
end
fprintf('  [OK] Model patches applied.\n');

% Global solver settings
set_param(mdl, 'StopTime',       num2str(sim_t));
set_param(mdl, 'Solver',         'ode15s');
set_param(mdl, 'MaxStep',        num2str(Irr_stair_tsamp * 0.8));
set_param(mdl, 'SimulationMode', 'normal');   % Accelerator requires C compiler (MinGW); Normal supports Python Code block
try set_param(mdl, 'SimscapeExplicitSolverDiagnostic', 'none'); catch; end

% Push ALL workspace variables required by Simulink blocks
assignin('base', 'Ts',                 Ts);
assignin('base', 'Tsc',                Tsc);
assignin('base', 'sample_output_time', sample_output_time);
assignin('base', 'Irr_stair_tsamp',    Irr_stair_tsamp);

assignin('base', 'Np_cell_add_1',      Np_cell_add_1);   % Solar Cell2 N_parallel = 1
assignin('base', 'Np_cell_add_2',      Np_cell_add_2);   % Solar Cell1 N_parallel = 1

assignin('base', 'NIGHT_THR',          NIGHT_THR);
assignin('base', 'THR_97_up',          THR_97_up);
assignin('base', 'THR_97_down',        THR_97_down);
assignin('base', 'THR_75_up',          THR_75_up);
assignin('base', 'THR_75_down',        THR_75_down);

save_system(mdl);
fprintf('  Saved %s\n\n', [mdl_fixed '.slx']);

% =========================================================================
%  SECTION 4c — PYTHON REAL-TIME Np PRE-COMPUTATION
%
%  realtime_np_controller.py processes the weather staircase sample-by-sample
%  using a 2-objective adjacent-only formulation (maximise H2 rate + PEM η).
%  Python makes a decision at every 1-minute weather step — the resulting Np
%  sequence is pushed as a timeseries to the base workspace.
%  Simulink reads it via the "From Workspace" (Np_py_ts) block in Recon_sw,
%  which drives np_override and controls the switches in real time.
%
%  If the Python script is missing or fails, Simulink falls back to the
%  fixed-threshold hysteresis switching (THR_97_up / THR_75_up).
% =========================================================================
MIN_DWELL_MIN = 5;   % [min] minimum hold time between config changes

py_script_rt  = fullfile(fileparts(which(mfilename)), 'realtime_np_controller.py');
if isempty(fileparts(py_script_rt))
    py_script_rt = fullfile(pwd, 'realtime_np_controller.py');
end

% Always push a fallback timeseries (Np=7) so From Workspace never errors
Np_py_ts_zero = timeseries(7*ones(length(Irr_stair_time),1), Irr_stair_time, 'Name','Np_py');
assignin('base', 'Np_py_ts', Np_py_ts_zero);

use_python_config = false;
if isfile(py_script_rt)
    fprintf('\n--- Python real-time Np computation (2-objective adjacent-only) ---\n');
    try
        % Write weather staircase CSV for the Python script
        input_csv_pre = fullfile(fileparts(which(mfilename)), 'online_controller_input.csv');
        if isempty(fileparts(input_csv_pre))
            input_csv_pre = fullfile(pwd, 'online_controller_input.csv');
        end
        tbl_pre = array2table( ...
            [(1:length(Irr_stair_time))', Irr_stair_val, Temp_stair_val], ...
            'VariableNames', {'time_idx','G_Wm2','T_C'});
        writetable(tbl_pre, input_csv_pre);
        fprintf('  Staircase written: %d steps  (%.1f min resolution)\n', ...
            length(Irr_stair_time), Irr_stair_tsamp * scale_factor / 60);

        % Run the Python controller
        pyrunfile(py_script_rt);

        % Read back Np sequence
        np_out_csv = fullfile(fileparts(which(mfilename)), 'online_np_sequence.csv');
        if isempty(fileparts(np_out_csv))
            np_out_csv = fullfile(pwd, 'online_np_sequence.csv');
        end
        T_np_pre  = readtable(np_out_csv);
        Np_python = T_np_pre.Np_online(:);   % values = 5, 6, or 7

        % Minimum-dwell filter: suppress switches within MIN_DWELL_MIN minutes
        min_dwell_steps = round(MIN_DWELL_MIN * 60 / (Irr_stair_tsamp * scale_factor));
        Np_python = min_dwell_filter(Np_python, max(1, min_dwell_steps));

        % Push to workspace — Simulink Recon_sw reads via From Workspace (Np_py_ts)
        Np_py_ts = timeseries(double(Np_python), Irr_stair_time, 'Name','Np_py');
        assignin('base', 'Np_py_ts',  Np_py_ts);
        assignin('base', 'Np_python', Np_python);
        use_python_config = true;

        n5 = sum(Np_python==5); n6 = sum(Np_python==6); n7 = sum(Np_python==7);
        fprintf('  Np5=%d  Np6=%d  Np7=%d steps  |  dwell=%d step(s)=%d min\n', ...
            n5, n6, n7, max(1,min_dwell_steps), MIN_DWELL_MIN);
        fprintf('  [OK] Np_py_ts pushed — Simulink Recon_sw follows Python decisions.\n');

    catch ME
        fprintf('  [SKIP] Python call failed: %s\n', ME.message);
        fprintf('         Falling back to fixed-threshold Simulink switching.\n');
    end
else
    fprintf('  [NOTE] realtime_np_controller.py not found — fixed-threshold switching active.\n');
end

% =========================================================================
%  SECTION 5 — RUN SIMULATION
% =========================================================================
fprintf('Running %d-day Reconfigurable simulation (Normal mode)...\n', NUM_DAYS);
open_system(mdl);

fprintf('  [Simulating... check bottom-right corner of Simulink window for progress]\n');

solve_timer    = tic;
out            = sim(mdl);
solve_time_sec = toc(solve_timer);

fprintf('Simulation complete.\n');
fprintf('  -> Solver execution time: %.2f seconds\n\n', solve_time_sec);

% =========================================================================
%  SECTION 6 — POST-PROCESSING
% =========================================================================
t      = out.PV_V.Time;
t_plot = t * t_plot_mult;
real_t = t * scale_factor;

PV_V   = max(out.PV_V.Data,   0);
PV_I   = max(out.PV_I.Data,   0);
PEM_V  = max(out.PEM_V.Data,  0);
PEM_I  = max(out.PEM_I.Data,  0);
Irr    = max(out.Irr.Data,    0);
PV_V_2 = max(out.PV_V_2.Data, 0);
PV_I_2 = max(out.PV_I_2.Data, 0);
PV_V_3 = max(out.PV_V_3.Data, 0);
PV_I_3 = max(out.PV_I_3.Data, 0);

% -------------------------------------------------------------------------
% DYNAMIC SMOOTHING FIX
% Calculates the moving average window dynamically based on the input step.
% If 1-minute data: ~10 sample window (10 mins).
% If 1-hour data: 1 sample window (no smoothing!) to preserve C factor.
% -------------------------------------------------------------------------
step_minutes = (Irr_stair_tsamp * scale_factor) / 60;
if step_minutes >= 50
    smooth_win = 1;
else
    smooth_win = max(1, round(10 / step_minutes));
end

PEM_I  = movmean(PEM_I,  smooth_win);
PV_I   = movmean(PV_I,   smooth_win);
PV_I_2 = movmean(PV_I_2, smooth_win);
PV_I_3 = movmean(PV_I_3, smooth_win);
PEM_V  = movmean(PEM_V,  smooth_win);
PV_V   = movmean(PV_V,   smooth_win);
PV_V_2 = movmean(PV_V_2, smooth_win);
PV_V_3 = movmean(PV_V_3, smooth_win);

sw1           = out.out_sw1.Data;
sw2           = out.out_sw2.Data;
sw_disconnect = out.out_sw_disconnect.Data;

% config: 1=Low-G (7 strings), 2=Mid-G (6 strings), 3=High-G (5 strings)
config = zeros(size(sw1));
config(sw1==1 & sw2==1 & sw_disconnect==0) = 1;
config(sw1==1 & sw2==0 & sw_disconnect==1) = 2;
config(sw1==0 & sw2==1 & sw_disconnect==1) = 3;

% Traceability: compare Python Np sequence against Simulink switch signals
if use_python_config && exist('Np_python','var') && ~isempty(Np_python)
    Np_py_on_t = interp1(Irr_stair_time, double(Np_python), t, 'nearest', 'extrap');
    Np_py_on_t = max(5, min(7, round(Np_py_on_t)));
    config_py  = 8 - Np_py_on_t;   % 7→1, 6→2, 5→3
    n_diff     = sum(config_py ~= config);
    
    fprintf('  Python vs Simulink config agreement: %d / %d differ (%.1f%%)\n', ...
        n_diff, numel(config), 100*n_diff/numel(config));
    if n_diff / numel(config) > 0.05
        fprintf('  [NOTE] >5%% mismatch — check that Np_py_ts From Workspace is connected.\n');
    end
end

if max(PEM_I) > 500, PEM_I = PEM_I / 1000; end
if max(PV_I)  > 500, PV_I  = PV_I  / 1000; end

PV_P   = PV_V   .* PV_I;
PV_P_2 = PV_V_2 .* PV_I_2;
PV_P_3 = PV_V_3 .* PV_I_3;

% Branch 1 isolated power
PV_P_1 = NaN(size(PV_P));
mask1 = (sw1 == 0);
mask2 = (sw1 == 1 & sw2 == 0);
mask3 = (sw1 == 1 & sw2 == 1);
PV_P_1(mask1) = PV_P(mask1);
PV_P_1(mask2) = PV_P(mask2) - PV_P_2(mask2);
PV_P_1(mask3) = PV_P(mask3) - PV_P_2(mask3) - PV_P_3(mask3);

PV_P_total = PV_P;
PEM_P      = PEM_V .* PEM_I;

% ---- PEM rated-point clamp (power-domain, catches ALL over-power samples) ----
R_total_stack = Rint_stack + Ra_stack + Rc_stack;
% Physical max: current-density limit x active area (NOT Randles load-line).
% Randles at Vmax gives ~30.7 A (too low); physical limit is 2.2 A/cm2 x 17.64 cm2 = 38.8 A.
I_rated   = Active_Area * 2.2;    % [A]  2.2 A/cm2 x 17.64 cm2 = 38.8 A
P_max_PEM = Vmax_PEM * I_rated;   % [W]  40 x 38.8 = 1552 W

over_P    = PEM_P > P_max_PEM;
PEM_V(over_P) = Vmax_PEM;
PEM_I(over_P) = I_rated;
PEM_P(over_P) = P_max_PEM;

fprintf('  PEM rated P_max = %.0f W  |  over-rated samples: %d / %d  (%.1f%%)\n', ...
    P_max_PEM, sum(over_P), numel(over_P), 100*mean(over_P));

PV_P_smooth  = movmean(PV_P,  smooth_win);
PEM_P_smooth = movmean(PEM_P, smooth_win);

eta_raw              = PEM_P_smooth ./ max(PV_P_smooth, 1e-3) * 100;
eta_raw(eta_raw > 99.0) = 99.0;
valid                = PV_P_smooth > 1;
eta                  = nan(size(PV_P));
eta(valid)           = eta_raw(valid);

% =========================================================================
%  SECTION 7 — HYDROGEN PRODUCTION
% =========================================================================
F_const = 96485;      % [C/mol]
eta_F   = 0.99;       % [-]
M_H2    = 2.016e-3;   % [kg/mol]

n_H2              = (N * PEM_I) / (2 * F_const) * eta_F;
n_H2(Irr < NIGHT_THR) = 0;

H2_rate     = n_H2 * M_H2 * 3600 * 1e3;
H2_inst_g_s = n_H2 * M_H2 * 1e3;
H2_cumul    = cumtrapz(real_t, H2_inst_g_s);

fprintf('  PV peak power:              %.1f W\n',  max(PV_P));
fprintf('  PEM peak power:             %.1f W\n',  max(PEM_P));
fprintf('  Mean η (active samples):    %.1f %%\n', mean(eta(valid), 'omitnan'));
fprintf('  Peak H2 production rate:    %.2f g/h\n', max(H2_rate));
fprintf('  Total H2 produced:          %.4f g\n\n', H2_cumul(end));

% =========================================================================
%  SECTION 8 — MPP REFERENCE (CONFIG-AWARE)
% =========================================================================
% The MPP reference must track the ACTIVE configuration (Np changes with G).
% C = P_WP / P_MPP(Np_active) measures how close the operating point is to
% the MPP of the currently connected array — NOT the maximum possible array.
% A value near 1 means the reconfiguration is working well.
P_mpp_ref = NaN(size(Irr));
V_mpp_ref = NaN(size(Irr));
I_mpp_ref = NaN(size(Irr));

P_mpp_all = struct();
Np_used   = unique(Np_map);

% ---- Try loading pre-computed lookup tables (highest accuracy) ----
for Np_i = Np_used(:)'
    mpp_filename = sprintf('../mpp_data_Ns%d_Np%d.mat', Ns_cell, Np_i);
    if ~isfile(mpp_filename)
        mpp_filename = sprintf('mpp_data_Ns%d_Np%d.mat', Ns_cell, Np_i);
    end
    
    if ~isfile(mpp_filename)
        continue   % will be filled by analytical fallback below
    end
    
    s   = load(mpp_filename, 'irr_unique', 'P_mpp', 'V_mpp', 'I_mpp');
    fld = sprintf('Np%d', Np_i);
    P_mpp_all.(fld) = max(interp1(s.irr_unique, s.P_mpp, Irr, 'pchip'), 0);
    
    cfg_match = find(Np_map == Np_i);
    mask = ismember(config, cfg_match) & (Irr > NIGHT_THR);
    
    P_mpp_ref(mask) = P_mpp_all.(fld)(mask);
    V_mpp_ref(mask) = max(interp1(s.irr_unique, s.V_mpp, Irr(mask), 'pchip'), 0);
    I_mpp_ref(mask) = max(interp1(s.irr_unique, s.I_mpp, Irr(mask), 'pchip'), 0);
end

% ---- Analytical fallback for any timestep still missing ----
% P_mpp(Np, G) = Np * Impp_cell * (G/1000) * Ns * Vmpp_cell
% (linear irradiance scaling — accurate to ~2 % for crystalline silicon)
nan_mask = isnan(P_mpp_ref) & (Irr > NIGHT_THR);
if any(nan_mask)
    n_fallback = sum(nan_mask);
    if n_fallback == numel(P_mpp_ref(Irr > NIGHT_THR))
        fprintf('  [NOTE] No .mat MPP files found — using analytical MPP reference.\n');
        fprintf('         P_mpp(Np,G) = Np × %.3f × (G/1000) × %.2f  [W]\n', ...
            Im_PV, Ns_cell * Vm_PV);
    else
        fprintf('  [NOTE] Analytical fallback applied to %d timesteps.\n', n_fallback);
    end
    
    for k = 1:3
        cfg_nan = (config == k) & nan_mask;
        if ~any(cfg_nan), continue; end
        
        Np_k = Np_map(k);
        g_k  = Irr(cfg_nan) / 1000;                          % dimensionless irradiance
        P_mpp_ref(cfg_nan) = Np_k * Im_PV .* g_k * (Ns_cell * Vm_PV);
        V_mpp_ref(cfg_nan) = Ns_cell * Vm_PV;                % ≈ 25.2 V, constant
        I_mpp_ref(cfg_nan) = Np_k  * Im_PV .* g_k;
    end
end

P_mpp_ref(Irr <= NIGHT_THR) = NaN;
V_mpp_ref(Irr <= NIGHT_THR) = NaN;
I_mpp_ref(Irr <= NIGHT_THR) = NaN;

P_WP  = PV_V .* PV_I;
err_P = max(-50, P_mpp_ref - P_WP);

C     = abs(P_WP ./ P_mpp_ref);
C(Irr <= NIGHT_THR)     = NaN;
err_P(Irr <= NIGHT_THR) = NaN;

C_plot = max(0, min(1.09, C));
C_plot(Irr <= NIGHT_THR) = NaN;

% =========================================================================
%  SECTION 9 — FIGURES
% =========================================================================
clr_pv   = [0.85, 0.33, 0.10];
clr_pem  = [0.13, 0.47, 0.71];
clr_irr  = [0.93, 0.69, 0.13];
clr_eta  = [0.18, 0.55, 0.18];

irr_ticks = 0:2:(sim_t_per_day * NUM_DAYS);
lw = 1.8;

% --- Figure 1: System Overview ---
fig1 = figure('Name','System Overview','Color','w','Position',[30 30 1020 950],'ToolBar','none');
tiledlayout(5,1,'TileSpacing','compact','Padding','compact');

ax1 = nexttile;
plot(t_plot, Irr, 'Color', clr_irr, 'LineWidth', lw+0.4, 'DisplayName','Irradiance'); hold on;
fill_config(ax1, t_plot, config, 1200);
yline(THR_97_up, '--', 'Color',[0.5 0.5 0.5], 'HandleVisibility','off');
yline(THR_75_up, '--', 'Color',[0.5 0.5 0.5], 'HandleVisibility','off');
hold off;
ylabel('G (W/m^2)'); ylim([0 1200]); yticks([0 300 600 800 900 1000]);
grid on; box on; legend('Location','northeast','FontSize',9);

ax_pv_split = nexttile;
plot(t_plot, PV_P,   'Color', clr_pv,        'LineWidth', lw,     'DisplayName','P_{PV,total}'); hold on;
plot(t_plot, PV_P_1, 'Color', [0.2 0.7 0.3], 'LineWidth', lw-0.3, 'DisplayName','P_{PV,1} (base 5)');
plot(t_plot, PV_P_2, 'Color', [0.1 0.4 0.8], 'LineWidth', lw-0.3, 'LineStyle','--', 'DisplayName','P_{PV,2} (+1)');
plot(t_plot, PV_P_3, 'Color', [0.6 0.3 0.8], 'LineWidth', lw-0.3, 'LineStyle',':', 'DisplayName','P_{PV,3} (+1)');
hold off;
ylabel('Power (W)'); grid on; box on;
legend('Location','northeast','FontSize',8,'NumColumns',2);
title('PV Power Breakdown','FontSize',9);

ax2 = nexttile;
plot(t_plot, PV_V,  'Color', clr_pv,  'LineWidth', lw, 'DisplayName','V_{PV}'); hold on;
plot(t_plot, PEM_V, 'Color', clr_pem, 'LineWidth', lw, 'DisplayName','V_{PEM}');
yline(Vmax_PEM,'--','Color',[0.5 0.5 0.5],'HandleVisibility','off');
yline(Vmin_PEM,':','Color',[0.5 0.5 0.5],'HandleVisibility','off');
hold off;
ylabel('Voltage (V)');
ylim([min([PV_V; PEM_V])*0.9, max([PV_V; PEM_V])*1.12]);
grid on; box on; legend('Location','east','FontSize',9);

ax3 = nexttile;
plot(t_plot, PV_I,  'Color', clr_pv,  'LineWidth', lw, 'DisplayName','I_{PV}'); hold on;
plot(t_plot, PEM_I, 'Color', clr_pem, 'LineWidth', lw, 'DisplayName','I_{PEM}');
yline(Imax_PEM,'--','Color',[0.5 0.5 0.5],'HandleVisibility','off');
hold off;
ylabel('Current (A)');
I_abs_max = max([max(abs(PV_I)), max(abs(PEM_I)), 10]) * 1.15;
ylim([0, max([Isc*1.15, I_abs_max, 10])]);
grid on; box on; legend('Location','northeast','FontSize',9);

ax4 = nexttile;
plot(t_plot, PV_P_total, 'Color', clr_pv,  'LineWidth', lw, 'DisplayName','P_{PV,total}'); hold on;
plot(t_plot, PEM_P,      'Color', clr_pem, 'LineWidth', lw, 'DisplayName','P_{PEM}');

loss_top = PV_P_total;
loss_bot = min(PV_P_total, max(PEM_P, 0));
fill([t_plot; flipud(t_plot)], [loss_top; flipud(loss_bot)], clr_pv, ...
    'FaceAlpha',0.12,'EdgeColor','none','DisplayName','Power Losses');
hold off;
xlabel(sprintf('Time (hours over %d days)', NUM_DAYS));
ylabel('Power (W)'); ylim([0, max([PV_P_total; PEM_P; 1])*1.15]);
grid on; box on; legend('Location','northeast','FontSize',9,'NumColumns',3);

for ax = [ax1 ax_pv_split ax2 ax3 ax4]
    xticks(ax, irr_ticks);
    xlim(ax, [0 max(t_plot)]);
    for tt = irr_ticks(2:end-1)
        xline(ax, tt, ':', 'Color',[0.6 0.6 0.6], 'HandleVisibility','off');
    end
end
set([ax1 ax_pv_split ax2 ax3], 'XTickLabel', []);
drawnow;
exportgraphics(fig1, sprintf('Fig1_SystemOverview_Ns%d_Np%d_case_%s.png', Ns_cell, Np_cell_base, case_model), 'Resolution', 300);

% --- Figure 2: H2 Rate ---
fig2 = figure('Name','H2 Rate','Color','w','Position',[60 60 1020 640],'ToolBar','none');
tiledlayout(1,1,'TileSpacing','compact','Padding','compact');

ax_h = nexttile;
yyaxis(ax_h,'left'); ax_h.YColor = clr_pem;
plot(t_plot, H2_rate,  'Color', clr_pem,      'LineWidth', lw, 'DisplayName','Instantaneous H_2 Rate');
ylabel('H_2 rate (g/h)');

yyaxis(ax_h,'right'); ax_h.YColor = [0 0.40 0.80];
plot(t_plot, H2_cumul, 'Color',[0 0.40 0.80], 'LineWidth', lw, 'LineStyle','-.', 'DisplayName','Total H_2 Accumulated');
ylabel('Cumulative H_2 (g)');

xlabel(sprintf('Time (hours over %d days)', NUM_DAYS));
grid on; box on; xticks(ax_h, irr_ticks); xlim(ax_h,[0 max(t_plot)]);
legend('Location','northwest','FontSize',9,'NumColumns',2);
drawnow;
exportgraphics(fig2, sprintf('Fig2_H2_Rate_Ns%d_Np%d_case_%s.png', Ns_cell, Np_cell_base, case_model), 'Resolution', 300);

% --- Figure MPP: Tracking quality ---
fig_mpp = figure('Name','MPP Comparison','Color','w','Position',[80 80 1020 760],'ToolBar','none');
tiledlayout(3,1,'TileSpacing','compact','Padding','compact');

ax_m1 = nexttile;
if exist('P_mpp_all','var')
    fnames     = fieldnames(P_mpp_all);
    colors_mpp = {[0.20 0.45 0.85],[0.15 0.65 0.30],[0.75 0.45 0.10]};
    for fi = 1:length(fnames)
        clr_i = colors_mpp{min(fi, length(colors_mpp))};
        plot(t_plot, P_mpp_all.(fnames{fi}), ':', 'Color', clr_i, 'LineWidth', 1.2, ...
            'DisplayName', sprintf('MPP curve (%s)', fnames{fi})); hold on;
    end
end
plot(t_plot, P_WP,      'Color', clr_pv,  'LineWidth', lw,     'DisplayName','PV Power'); hold on;
plot(t_plot, P_mpp_ref, '--',    'Color', clr_eta, 'LineWidth', lw+0.2, 'DisplayName','MPP Ref (per config)');
fill_config_full(ax_m1, t_plot, config); hold off;
ylabel('Power (W)'); grid on; box on;
legend('Location','best','FontSize',9);
title('PV power vs. MPP reference (config-aware)');

ax_m2 = nexttile;
plot(t_plot, err_P, 'Color',[0.85 0.20 0.20], 'LineWidth', lw, 'DisplayName','Power Error'); hold on;
fill_config_full(ax_m2, t_plot, config); hold off;
yline(0,'--','Color',[0.4 0.4 0.4],'HandleVisibility','off');
ylabel('\Delta P (W)'); grid on; box on;
legend('Location','best','FontSize',9);
title('Power error relative to MPP');

ax_m3 = nexttile;
plot(t_plot, C_plot, 'Color',[0.20 0.20 0.20], 'LineWidth', lw, 'DisplayName','Coupling Factor'); hold on;
ylim(ax_m3,[0.4 1.1]);
fill_config_full(ax_m3, t_plot, config); hold on;
yline(1,'--','Color',[0.4 0.4 0.4],'HandleVisibility','off'); hold off;
xlabel('Time (h)'); ylabel('C = P_{WP}/P_{MPP}');
grid on; box on; legend('Location','best','FontSize',9);
title('Coupling factor (MPP reference switches with config)');

linkaxes([ax_m1 ax_m2 ax_m3],'x');
xticks(ax_m1, irr_ticks); xticks(ax_m2, irr_ticks); xticks(ax_m3, irr_ticks);
xlim(ax_m3,[0 max(t_plot)]);
drawnow;
exportgraphics(fig_mpp, sprintf('Fig_MPP_Tracking_Ns%d_Np%d_case_%s.png', Ns_cell, Np_cell_base, case_model), 'Resolution', 300);

% --- Figure 3: Reconfiguration timeline ---
fig_sw = figure('Name','Reconfiguration Timeline','Color','w','Position',[200 200 1020 380],'ToolBar','none');
tiledlayout(1,1,'TileSpacing','compact','Padding','compact');

ax_sw = nexttile;
yyaxis(ax_sw,'right');
area(ax_sw, t_plot, Irr, 'FaceColor', clr_irr, 'FaceAlpha', 0.28, ...
    'EdgeColor', clr_irr, 'LineWidth', 0.3, 'DisplayName','Irradiance');
ylabel(ax_sw,'Irradiance (W/m^2)'); ylim(ax_sw,[0 1200]);

yyaxis(ax_sw,'left');
stairs(ax_sw, t_plot, config, 'Color',[0.3 0.3 0.3], 'LineWidth', 2, 'DisplayName','Configuration');
ylim(ax_sw,[0.5 3.5]); yticks(ax_sw,[1 2 3]);
yticklabels(ax_sw,{'Low-G (7 strings)','Mid-G (6 strings)','High-G (5 strings)'});
ylabel(ax_sw,'Configuration');

grid(ax_sw,'on'); box(ax_sw,'on');
xlabel(ax_sw, sprintf('Time (hours over %d days)', NUM_DAYS));
title(ax_sw,'Active Reconfiguration Mode');
xticks(ax_sw, irr_ticks); xlim(ax_sw,[0 max(t_plot)]);
legend(ax_sw,'Location','northwest');
drawnow;
exportgraphics(fig_sw, sprintf('Fig_Switches_Ns%d_Np%d_case_%s.png', Ns_cell, Np_cell_base, case_model), 'Resolution', 300);

% =========================================================================
%  SECTION 10 — STEADY-STATE SUMMARY TABLE
% =========================================================================
target_hours = [7, 9, 12, 14.5, 16.5];
nH = length(target_hours);
mean_PV_V    = zeros(nH,1); mean_PV_I    = zeros(nH,1);
mean_PEM_V   = zeros(nH,1); mean_PEM_I   = zeros(nH,1);
mean_eta_bar = zeros(nH,1); recorded_irr = zeros(nH,1);

for k = 1:nH
    tgt  = target_hours(k);
    mask = t_plot >= (tgt-0.16) & t_plot <= (tgt+0.16);
    if sum(mask) > 1
        recorded_irr(k) = round(mean(Irr(mask)));
        mean_PV_V(k)    = mean(PV_V(mask));
        mean_PV_I(k)    = mean(PV_I(mask));
        mean_PEM_V(k)   = mean(PEM_V(mask));
        mean_PEM_I(k)   = mean(PEM_I(mask));
        
        p_in  = mean(PV_P(mask));
        p_out = mean(PEM_P(mask));
        if p_in > 1, mean_eta_bar(k) = min(99.0, (p_out/p_in)*100); end
    end
end

fprintf('=== Steady-State Operating Point Summary ===\n');
fprintf('%-12s  %8s  %8s  %8s  %8s  %6s  %6s\n', ...
    'G (W/m²)','Vpv(V)','Ipv(A)','Vpem(V)','Ipem(A)','M','eta(%)');
fprintf('%s\n', repmat('-',1,72));
for k = 1:nH
    M_k = mean_PEM_V(k) / max(mean_PV_V(k), 0.01);
    fprintf('%-12d  %8.2f  %8.2f  %8.2f  %8.2f  %6.3f  %6.1f\n', ...
        recorded_irr(k), mean_PV_V(k), mean_PV_I(k), ...
        mean_PEM_V(k),   mean_PEM_I(k), M_k, mean_eta_bar(k));
end
fprintf('\n');

% =========================================================================
%  SECTION 11 — EXCEL EXPORT
% =========================================================================
filename        = 'PV_PEM_direct_reconfiguration_week_new_size.xlsx';
excel_row_limit = 1048576;
LHV_H2          = 119960;   % [J/g]

% --- Extract Simulink efficiency ---
raw_eff_data   = out.Efficiency.Data(:);
raw_eff_time   = out.Efficiency.Time(:);
sim_Efficiency = interp1(raw_eff_time, raw_eff_data, t, 'linear', 'extrap');

% --- Np_active: active parallel strings per timestep ---
Np_active = zeros(size(config));
Np_active(config == 1) = Np_cell_base;                                    % Low-G  → 7
Np_active(config == 2) = Np_cell_base - Np_cell_red_1;                   % Mid-G  → 6
Np_active(config == 3) = Np_cell_base - Np_cell_red_1 - Np_cell_red_2;  % High-G → 5
Np_active(Irr <= NIGHT_THR) = 7;   % night: disconnected

% --- PV_area: time-varying active array footprint ---
% Amerisolar 320W has 60 M6 cells per panel (166×166 mm each).
% The model uses Ns_cell=45 cells per string (Vmpp=25.2 V, within PEM range).
% Physical area of one model string = Ns_cell × cell_area (NOT full 1.689 m²).
N_cells_per_panel = 60;                               % Amerisolar 320W: 60 M6 cells/panel
panel_area        = 1.689;                            % [m²] from datasheet
cell_area         = panel_area / N_cells_per_panel;   % = 0.02815 m²/cell
PV_area           = Np_active * Ns_cell * cell_area;  % [m²] time-varying with config

fprintf('PV area @ max config (7 strings): %.4f m²  |  STC η_PV check: %.1f %%\n', ...
        Np_cell_base * Ns_cell * cell_area, Pmpp / (1000 * Np_cell_base * Ns_cell * cell_area) * 100);

% --- STH: solar-to-hydrogen efficiency [%] ---
% H2_rate [g/h] / 3600 → [g/s] × LHV_H2 [J/g] = chemical power [W]
% Divided by active solar power (G × A_active) [W], ×100 for percent.
STH = ((H2_rate/3600) .* LHV_H2) ./ max(PV_area .* Irr, 1e-3) * 100;
STH(Irr <= NIGHT_THR) = 0;

% --- PV solar-to-electric efficiency [%], config-aware ---
% η_PV measures how efficiently the ACTIVE (connected) panel area converts
% sunlight to electricity.  Denominator uses the active footprint so that
% disconnecting strings does not artificially inflate η_PV.
eta_PV = PV_P ./ max(PV_area .* Irr, 1e-3) * 100;
eta_PV(Irr <= NIGHT_THR) = NaN;

% Per-configuration η_PV breakdown (diagnostic for reconfiguration benefit)
active_day = Irr > NIGHT_THR;
fprintf('--- Config-aware PV efficiency η_PV [%%] ---\n');
for c = 1:3
    cfg_mask = (config == c) & active_day;
    if any(cfg_mask)
        fprintf('  Config %d (%d strings): mean η_PV = %.2f %%  |  n = %d samples\n', ...
            c, Np_map(c), mean(eta_PV(cfg_mask), 'omitnan'), sum(cfg_mask));
    end
end

% --- PEM electrochemical efficiency [%]  η_PEM = P_chem / P_elec_in ---
P_chem  = H2_inst_g_s .* LHV_H2;              % [W] chemical power of H2 produced
eta_PEM = P_chem ./ max(PEM_P, 1e-3) * 100;   % [%]
eta_PEM(Irr <= NIGHT_THR) = NaN;

% --- Efficiency chain consistency check ---
%   STH [%] = (η_PV/100) × (η_coupling/100) × (η_PEM/100) × 100
%           = η_PV × η_coupling × η_PEM / 10000
% η_coupling = PEM_P / PV_P (direct connection, no converter in Case G).
eta_coupling = PEM_P ./ max(PV_P, 1e-3) * 100;
eta_coupling(Irr <= NIGHT_THR) = NaN;
STH_chain    = eta_PV .* eta_coupling .* eta_PEM / 1e4;   % [%]

fprintf('--- Efficiency chain check (G > %.0f W/m²) ---\n', NIGHT_THR);
fprintf('  mean η_PV        : %.2f %%\n', mean(eta_PV(active_day),       'omitnan'));
fprintf('  mean η_coupling  : %.2f %%\n', mean(eta_coupling(active_day), 'omitnan'));
fprintf('  mean η_PEM       : %.2f %%\n', mean(eta_PEM(active_day),      'omitnan'));
fprintf('  mean STH (direct): %.3f %%\n', mean(STH(active_day),          'omitnan'));
fprintf('  mean STH (chain) : %.3f %%\n', mean(STH_chain(active_day),    'omitnan'));

% --- Configuration label ---
config_label = repmat({'Night/Off'}, length(config), 1);
config_label(config == 1) = {'Low-G (7 strings)'};
config_label(config == 2) = {'Mid-G (6 strings)'};
config_label(config == 3) = {'High-G (5 strings)'};

% --- Data cleanup ---
eta_PV_exp  = eta_PV;   eta_PV_exp(isnan(eta_PV_exp))   = 0;
eta_PEM_exp = eta_PEM;  eta_PEM_exp(isnan(eta_PEM_exp))  = 0;

STH(isnan(STH)                         | Irr==0) = 0;
C(isnan(C)                             | Irr==0) = 0;
err_P(isnan(err_P)                     | Irr==0) = 0;
P_mpp_ref(isnan(P_mpp_ref)             | Irr==0) = 0;
V_mpp_ref(isnan(V_mpp_ref)             | Irr==0) = 0;
I_mpp_ref(isnan(I_mpp_ref)             | Irr==0) = 0;
sim_Efficiency(isnan(sim_Efficiency))             = 0;
C(C > 1) = 1;

run_id = repmat({datestr(now,'yyyy-mm-dd HH:MM:SS')}, length(t), 1);

% --- Output table ---
TS = table( ...
    t, t_plot, real_t, Irr, ...
    PV_V, PV_I, PV_P, PEM_V, PEM_I, ...
    sim_Efficiency, H2_rate, H2_cumul, ...
    eta_PV_exp, eta_PEM_exp, ...
    P_mpp_ref, V_mpp_ref, I_mpp_ref, ...
    err_P, C, STH, ...
    Np_active, config_label, run_id, ...
    'VariableNames', { ...
        't_sim_[s]',          't_plot_[h]',        't_real_[s]', ...
        'Irr_[W/m2]', ...
        'PV_V_[V]',           'PV_I_[A]',          'PV_P_[W]', ...
        'PEM_V_[V]',          'PEM_I_[A]', ...
        'Simulink_Eff_[pct]', 'H2_Flow_[g_h]',     'H2_cumul_[g]', ...
        'eta_PV_[pct]',       'eta_PEM_[pct]', ...
        'P_MPP_ref_[W]',      'V_MPP_ref_[V]',     'I_MPP_ref_[A]', ...
        'Power_Error_[W]',    'Coupling_Factor_C',  'STH_[pct]', ...
        'Np_active_[-]',      'Config_Label',       'Run_Timestamp'});

write_header = true;
if isfile(filename)
    try
        existing   = readtable(filename, 'Sheet','TimeSeries', ...
                                'VariableNamingRule','preserve');
        n_existing = height(existing);
        
        if n_existing > 0
            projected_last_row = n_existing + 1 + height(TS);
            if projected_last_row > excel_row_limit
                warning(['Excel row limit will be exceeded! ' ...
                    'Current: %d | New: %d | Limit: %d.'], ...
                    n_existing, height(TS), excel_row_limit);
            end
            
            write_header = false;
            fprintf('  [INFO] Existing data: %d rows. Appending %d new rows.\n', ...
                n_existing, height(TS));
        else
            fprintf('  [INFO] Sheet empty — writing fresh.\n');
        end
    catch
        fprintf('  [INFO] TimeSeries sheet not found — writing fresh.\n');
    end
end

if write_header
    writetable(TS, filename, 'Sheet','TimeSeries','WriteMode','overwritesheet');
    fprintf('  [OK] Created %s with header + %d data rows.\n', filename, height(TS));
else
    % Use MATLAB's built-in append mode to avoid column mismatch errors during vertcat
    writetable(TS, filename, ...
        'Sheet',              'TimeSeries', ...
        'WriteMode',          'append', ...
        'WriteVariableNames', false);
    fprintf('  [OK] Successfully appended %d new rows to the Excel file.\n', height(TS));
end

% --- Parameters sheet (first run only) ---
if write_header
    paramNames = { ...
        'N_cells_PEM'; ...
        'Np_cell_base_(Low-G_max)'; ...
        'Np_cell_red_1'; ...
        'Np_cell_red_2'; ...
        'Np_Low_G'; ...
        'Np_Mid_G'; ...
        'Np_High_G'; ...
        'Ns_cell'; ...
        'sim_t_[s]'; ...
        'scale_factor'; ...
        'LHV_H2_[J/g]'; ...
        'THR_97_up'; ...
        'THR_97_down'; ...
        'THR_75_up'; ...
        'THR_75_down'; ...
        'NIGHT_THR'};
        
    paramValues = [ ...
        N; ...
        Np_cell_base; ...
        Np_cell_red_1; ...
        Np_cell_red_2; ...
        Np_map(1); ...
        Np_map(2); ...
        Np_map(3); ...
        Ns_cell; ...
        sim_t; ...
        scale_factor; ...
        LHV_H2; ...
        THR_97_up; ...
        THR_97_down; ...
        THR_75_up; ...
        THR_75_down; ...
        NIGHT_THR];
        
    assert(length(paramNames) == length(paramValues), ...
        'Parameter name/value count mismatch: %d names vs %d values', ...
        length(paramNames), length(paramValues));
        
    PARAM = table(paramNames, paramValues, 'VariableNames',{'Parameter','Value'});
    writetable(PARAM, filename, 'Sheet','Parameters','WriteMode','overwritesheet');
    fprintf('  [OK] Parameters sheet written (%d entries).\n', length(paramNames));
end

fprintf('\n=== ALL DONE ===\n');
fprintf('  Total H2 yield : %.4f g  (%.4f kg)\n', H2_cumul(end), H2_cumul(end)/1000);
fprintf('  Solver time    : %.2f s\n', solve_time_sec);
fprintf('  Output file    : %s\n', filename);

if use_python_config
    fprintf('  Np decisions   : Python 2-objective controller (realtime_np_controller.py)\n');
else
    fprintf('  Np decisions   : Simulink fixed-threshold fallback (Python unavailable)\n');
end

% =========================================================================
%  LOCAL FUNCTIONS  (must remain at the very end of the script)
% =========================================================================
function Np_out = min_dwell_filter(Np_in, min_steps)
% MIN_DWELL_FILTER  Enforce a minimum hold time between consecutive switches.
%   Suppresses any switch request that arrives before MIN_STEPS staircase
%   steps have elapsed since the last switch.  Prevents rapid toggling at
%   irradiance crossover points and reduces relay wear.
    Np_out      = Np_in;
    last_switch = 1;
    for i = 2 : length(Np_in)
        if Np_in(i) ~= Np_out(i-1)
            if (i - last_switch) >= min_steps
                Np_out(i)   = Np_in(i);
                last_switch = i;
            else
                Np_out(i) = Np_out(i-1);   % suppress early switch
            end
        end
    end
end

function fill_config(ax, t_plot, config, ymax)
    colors = {[1.0 0.85 0.6], [0.75 0.95 0.75], [0.6 0.8 1.0]};
    labels = {'Low-G (7 strings)', 'Mid-G (6 strings)', 'High-G (5 strings)'};
    for c = 1:3
        mask  = config == c;
        if ~any(mask), continue; end
        
        edges  = diff([0; mask(:); 0]);
        starts = find(edges ==  1);
        ends   = find(edges == -1) - 1;
        
        for r = 1:length(starts)
            x1 = t_plot(starts(r));
            x2 = t_plot(ends(r));
            fill(ax, [x1 x2 x2 x1], [0 0 ymax ymax], colors{c}, ...
                'FaceAlpha', 0.18, 'EdgeColor', 'none', 'HandleVisibility','off');
        end
    end
    for c = 1:3
        fill(ax, [nan nan nan nan], [nan nan nan nan], colors{c}, ...
            'FaceAlpha', 0.4, 'EdgeColor','none', 'DisplayName', labels{c});
    end
end

function fill_config_full(ax, t_plot, config)
    colors = {[1.0 0.85 0.6], [0.75 0.95 0.75], [0.6 0.8 1.0]};
    yl = ylim(ax);
    hold(ax,'on');
    for c = 1:3
        mask  = (config == c);
        if ~any(mask), continue; end
        
        edges  = diff([0; mask(:); 0]);
        starts = find(edges ==  1);
        ends   = find(edges == -1) - 1;
        
        for r = 1:length(starts)
            x1 = t_plot(starts(r));
            x2 = t_plot(ends(r));
            patch(ax, [x1 x2 x2 x1], [yl(1) yl(1) yl(2) yl(2)], colors{c}, ...
                'FaceAlpha', 0.12, 'EdgeColor', 'none', 'HandleVisibility','off');
        end
    end
    uistack(findobj(ax,'Type','patch'),'bottom');
end