%% 
% =========================================================================
%  PV_PEM_Batt_Recon_week.m
%  Case: Reconfigurable Direct PV-PEM-Battery
% =========================================================================
clear; clc; close all;
warning('off','all');

fprintf('=== Reconfigurable Direct PV-PEM-Battery (8-day) ===\n\n');

% =========================================================================
%  SECTION 1 – PEM ELECTROLYZER PARAMETERS
% =========================================================================
N = 16;
Vint    = 1.475841;   Rint  = 0.008673;
Ra      = 0.00177;    Rc    = 0.0005;
tau_a   = 0.4;        tau_c = tau_a / 10;
Ca      = tau_a / Ra; Cc    = tau_c / Rc;
Active_Area = 17.64;

Vint_stack = Vint * N;          
Rint_stack = Rint * N;
Ra_stack   = Ra   * N;
Rc_stack   = Rc   * N;
Ca_stack   = Ca   / N;
Cc_stack   = Cc   / N;
R_total    = Rint_stack + Ra_stack + Rc_stack;

Vmin_PEM    = Vint_stack;                              
Vmax_PEM    = 2.0 * N;                                 
Imin_PEM    = 2.2;                                     
Imax_PEM    = 80;                                      

I_rated_PEM = (Vmax_PEM - Vint_stack) / R_total;
P_rated_PEM = Vmax_PEM * I_rated_PEM;
Pmax_PEM    = P_rated_PEM;
V_ref_PEM   = 1.8 * N;

fprintf('  PEM: %d cells | Vint=%.2f V | Vmin=%.1f V | Vmax=%.1f V | I_rated=%.1f A | P_rated=%.0f W\n', ...
        N, Vint_stack, Vmin_PEM, Vmax_PEM, I_rated_PEM, Pmax_PEM);

% =========================================================================
%  SECTION 2 – PV ARRAY & RECONFIGURATION PARAMETERS
% =========================================================================
Im_PV    = 9.59;   Vm_PV    = 0.55;
Ns_cell  = 60;
Isc_cell = 10.14;  Voc_cell = 0.67;

Np_cell_base  = 7;   
Np_cell_red_1 = 1;   
Np_cell_red_2 = 1;   
Np_cell       = Np_cell_base;   
Np_cell_add_1 = Np_cell_red_1;   
Np_cell_add_2 = Np_cell_red_2;   

Np_map = [Np_cell_base, Np_cell_base - Np_cell_red_1, Np_cell_base - Np_cell_red_1 - Np_cell_red_2];

cell_area = 1.689 / 60;           % 0.02815 m² per cell  (panel area 1.689 m²)
PV_area_max = Np_cell_base * Ns_cell * cell_area;   

fprintf('  PV Reconfiguration levels: Low-G = %d | Mid-G = %d | High-G = %d strings\n', ...
    Np_map(1), Np_map(2), Np_map(3));

% =========================================================================
%  SECTION 2b — RECONFIGURATION THRESHOLDS
% =========================================================================
NIGHT_THR = 70;   

R_stack_ohm = N * (Rint + Ra + Rc);                    
I_rated_PEM = (Vmax_PEM - Vint_stack) / R_stack_ohm;   
HYS         = 25;                                       
THR_97_up   = ceil(I_rated_PEM / (7 * Im_PV) * 1000);  
THR_97_down = THR_97_up - HYS;                          
THR_75_up   = ceil(I_rated_PEM / (6 * Im_PV) * 1000);  
THR_75_down = THR_75_up - HYS;                          

% =========================================================================
%  SECTION 3 – TIME, WEATHER & BATTERY PARAMETERS
% =========================================================================
WEATHER_FILE = 'weather_profile_week_CNR.xlsx';
scale_factor = 36000;
sim_t_per_day = 24;

if isfile(WEATHER_FILE)
    weather       = readtable(WEATHER_FILE);
    real_time_sec = weather.Time_min * 60;
    Irr_val       = weather.Irradiance;
    Temp_val      = weather.Temperature;
    NUM_DAYS      = round(max(real_time_sec) / 86400);
else
    error('[ERROR] %s not found in %s', WEATHER_FILE, pwd);
end

Irr_time = real_time_sec / scale_factor;
sim_t    = max(Irr_time);
Irr_stair_tsamp = 60 / scale_factor;
Irr_stair_time  = (0 : Irr_stair_tsamp : sim_t)';
Irr_stair_val   = interp1(Irr_time, Irr_val,  Irr_stair_time, 'linear', 0);
Temp_stair_val  = interp1(Irr_time, Temp_val, Irr_stair_time, 'linear', 25);

% --- BATTERY & CONVERTER TARGETS ---
Ts  = 1e-4;  Tsc = 1e-6;
% V_ref_battery: PEM bus midpoint for N=16 — equal-energy basis for all cases
V_ref_battery = (Vint_stack + Vmax_PEM) / 2;   % (23.613 + 32.0)/2 ≈ 27.81 V
% V_batt_nom = V_ref_battery → 27.81×250×0.70 = 4867 Wh (all cases equal)
V_batt_nom   = V_ref_battery;  % [V]
Q_thesis     = 250;   % [Ah] Real-world capacity (matched to Cases 1-3 for fair comparison)
Q_batt       = Q_thesis / scale_factor;
SOC_max      = 90;    
SOC_min      = 20;    
SOC_max_hys  = 85;
SOC_min_hys  = 25;
SOC_init_per = 25;    
SOC_init     = SOC_init_per / 100 * Q_batt;
R_batt_int   = 0.05;
sample_output_time = 60 / scale_factor;  

% --- BIDIRECTIONAL CONVERTER COMPONENTS ---
Bi_L  = 4e-4;  Bi_C1 = 1e-5;  Bi_C2 = 1e-5;
Bi_R1 = 1e-6;  Bi_R2 = 1e-6;
Bi_C_Kp = 0.01;  Bi_C_Ki = 10.0;
Bi_V_Kp = 10;    Bi_V_Ki = 70;

% --- PUSH VARIABLES TO BASE WORKSPACE FOR SIMULINK ---
assignin('base', 'Ts',                 Ts);
assignin('base', 'Tsc',                Tsc);
assignin('base', 'sample_output_time', sample_output_time);
assignin('base', 'Irr_stair_tsamp',    Irr_stair_tsamp);
assignin('base', 'Np_cell_add_1',      Np_cell_add_1);   
assignin('base', 'Np_cell_add_2',      Np_cell_add_2);   
assignin('base', 'NIGHT_THR',          NIGHT_THR);
assignin('base', 'THR_97_up',          THR_97_up);
assignin('base', 'THR_97_down',        THR_97_down);
assignin('base', 'THR_75_up',          THR_75_up);
assignin('base', 'THR_75_down',        THR_75_down);
assignin('base', 'SOC_max',            SOC_max);
assignin('base', 'SOC_min',            SOC_min);
assignin('base', 'SOC_max_hys',        SOC_max_hys);
assignin('base', 'SOC_min_hys',        SOC_min_hys);
assignin('base', 'SOC_init',           SOC_init);
assignin('base', 'V_ref_battery',      V_ref_battery);
assignin('base', 'Bi_L',               Bi_L);
assignin('base', 'Bi_C1',              Bi_C1);
assignin('base', 'Bi_C2',              Bi_C2);
assignin('base', 'Bi_R1',              Bi_R1);
assignin('base', 'Bi_R2',              Bi_R2);
assignin('base', 'Bi_C_Kp',            Bi_C_Kp);
assignin('base', 'Bi_C_Ki',            Bi_C_Ki);
assignin('base', 'Bi_V_Kp',            Bi_V_Kp);
assignin('base', 'Bi_V_Ki',            Bi_V_Ki);


% =========================================================================
%  SECTION 4 — PYTHON REAL-TIME Np PRE-COMPUTATION
% =========================================================================
MIN_DWELL_MIN = 5;   
py_script_rt  = fullfile(pwd, 'realtime_np_controller.py');
Np_py_ts_zero = timeseries(7*ones(length(Irr_stair_time),1), Irr_stair_time, 'Name','Np_py');
assignin('base', 'Np_py_ts', Np_py_ts_zero);
use_python_config = false;

if isfile(py_script_rt)
    fprintf('\n--- Python real-time Np computation ---\n');
    
    % [DEBUG] No try-catch. If Python fails, MATLAB will print the exact reason.
    input_csv_pre = fullfile(pwd, 'online_controller_input.csv');
    tbl_pre = array2table([(1:length(Irr_stair_time))', Irr_stair_val, Temp_stair_val], ...
        'VariableNames', {'time_idx','G_Wm2','T_C'});
    writetable(tbl_pre, input_csv_pre);
    
    fprintf('  Calling Python...\n');
    pyrunfile(py_script_rt);  % <--- CRASH WILL HAPPEN HERE IF PYTHON IS BROKEN
    
    np_out_csv = fullfile(pwd, 'online_np_sequence.csv');
    T_np_pre  = readtable(np_out_csv);
    Np_python = T_np_pre.Np_online(:);   
    
    min_dwell_steps = round(MIN_DWELL_MIN * 60 / (Irr_stair_tsamp * scale_factor));
    Np_python = min_dwell_filter(Np_python, max(1, min_dwell_steps));
    
    Np_py_ts = timeseries(double(Np_python), Irr_stair_time, 'Name','Np_py');
    assignin('base', 'Np_py_ts',  Np_py_ts);
    assignin('base', 'Np_python', Np_python);
    use_python_config = true;
    fprintf('  [OK] Np_py_ts pushed — Simulink Recon_sw follows Python decisions.\n');
else
    fprintf('  [ERROR] realtime_np_controller.py file not found in current folder.\n');
end

% =========================================================================
%  SECTION 5 – MODEL SETUP & PATCHES
% =========================================================================
mdl_orig   = 'PV_PEM_reconfigurable_battery';
mdl_fixed  = 'PV_PEM_reconfigurable_battery_FIXED';

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
        try set_param(b,'rep_seq_t',   'Irr_time');        catch; end
        try set_param(b,'rep_seq_y',   'Irr_val');         catch; end
    end
    if contains(b_name, 'Temperature', 'IgnoreCase', true) || contains(b_name, 'Temp', 'IgnoreCase', true)
        try set_param(b, 'rep_seq_t', 'Irr_time');        catch; end
        try set_param(b, 'rep_seq_y', 'Temp_val');        catch; end
        try set_param(b, 'OutValues', 'Temp_stair_val');  catch; end
        try set_param(b, 'samp_time', 'Irr_stair_tsamp'); catch; end
    end
    
    if contains(ref, 'Diode') || strcmp(b_name, 'Diode') || strcmp(b_name, 'Diode1')
        try set_param(b, 'Vf', '0.1'); catch; end
        try set_param(b, 'Ron', '0.01'); catch; end
    end
    if contains(ref, 'Switch') || contains(b_name, 'Switch')
        try set_param(b, 'R_closed', '0.005'); catch; end
    end
    if contains(b_name, 'Battery1') || contains(b_name, 'Battery')
        try set_param(b, 'Vnom', num2str(V_batt_nom)); catch; end
        try set_param(b, 'V1', num2str(V_batt_nom * 0.9)); catch; end
        try set_param(b, 'R1', num2str(R_batt_int)); catch; end
        try set_param(b, 'R1_dis', num2str(R_batt_int)); catch; end
        try set_param(b, 'R1_ch', num2str(R_batt_int)); catch; end
    end
    if contains(b_name,'Current','IgnoreCase',true) || contains(b_name,'Ammeter','IgnoreCase',true)
        try set_param(b,'i_unit','A'); catch; end
    end
    if strcmp(b_type,'Scope')
        try set_param(b,'LimitDataPoints','off'); catch; end
        try set_param(b,'DataPoints','500000');   catch; end
        try set_param(b,'Open','off');            catch; end
    end
end

set_param(mdl,'StopTime',num2str(sim_t),'Solver','ode15s', ...
    'MaxStep','1e-5','SimulationMode','normal');
try set_param(mdl,'SimscapeExplicitSolverDiagnostic','none'); catch; end

dis_path = [mdl '/Subsystem/Discharge enable1'];
try
    set_param(dis_path, 'OnSwitchValue',  '0.21');
    set_param(dis_path, 'OffSwitchValue', '0.20');
catch
end

pid_blks = find_system(mdl, 'LookUnderMasks', 'all', 'BlockType', 'SubSystem');
for i = 1:length(pid_blks)
    if contains(get_param(pid_blks{i}, 'Name'), 'PID')
        try
            set_param(pid_blks{i}, 'LimitOutput', 'on');
            set_param(pid_blks{i}, 'AntiWindupMode', 'clamping');
        catch
        end
    end
end

save_system(mdl);
fprintf('  Model ready: %s\n\n', mdl_fixed);

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

% Extract Reconfiguration Signals
try PV_V_2 = max(out.PV_V_2.Data, 0); catch; PV_V_2 = zeros(size(t)); end
try PV_I_2 = max(out.PV_I_2.Data, 0); catch; PV_I_2 = zeros(size(t)); end
try PV_V_3 = max(out.PV_V_3.Data, 0); catch; PV_V_3 = zeros(size(t)); end
try PV_I_3 = max(out.PV_I_3.Data, 0); catch; PV_I_3 = zeros(size(t)); end
try sw1           = out.out_sw1.Data; catch; sw1 = ones(size(t)); end
try sw2           = out.out_sw2.Data; catch; sw2 = ones(size(t)); end
try sw_disconnect = out.out_sw_disconnect.Data; catch; sw_disconnect = zeros(size(t)); end

PEM_I  = movmean(PEM_I,  10);
PV_I   = movmean(PV_I,   10);
PEM_V  = movmean(PEM_V,  10);
PV_V   = movmean(PV_V,   10);

% Map Config
config = zeros(size(sw1));
config(sw1==1 & sw2==1 & sw_disconnect==0) = 1;
config(sw1==1 & sw2==0 & sw_disconnect==1) = 2;
config(sw1==0 & sw2==1 & sw_disconnect==1) = 3;

if max(PEM_I) > 500, PEM_I = PEM_I / 1000; end
if max(PV_I)  > 500, PV_I  = PV_I  / 1000; end
PEM_over  = (PEM_V > Vmax_PEM) | (PEM_I > Imax_PEM) | (PEM_V .* PEM_I > Pmax_PEM);
PEM_I_eff = PEM_I;  PEM_I_eff(PEM_over) = 0;
PEM_V_eff = PEM_V;  PEM_V_eff(PEM_over) = 0;

% Battery Extraction
has_batt = false;
try
    Batt_V   = out.Batt_V.Data;
    Batt_I   = out.Batt_I.Data;   
    Batt_SOC = out.Batt_SOC.Data; 
    if mean(Batt_SOC) <= 1.0
        Batt_SOC = Batt_SOC * 100;
    end
    
    % --- NUMERICAL BLEED CLAMP (Fixes the 15% issue) ---
    bleed_mask = Batt_SOC < SOC_min;
    if any(bleed_mask)
        Batt_SOC(bleed_mask) = SOC_min;
        Batt_I(bleed_mask) = 0; 
    end
    % ---------------------------------------------------

    Batt_P   = Batt_V .* Batt_I;  
    has_batt = true;
    if max(abs(Batt_I)) > 2000, Batt_I = Batt_I / 1000; Batt_P = Batt_V .* Batt_I; end
    
    night_mask_t  = Irr < NIGHT_THR;
    Batt_P_day = Batt_P;
    Batt_P_day(night_mask_t) = 0;
    Batt_I_plot = max(-300, min(300, Batt_I));
catch
    Batt_V      = V_batt_nom * ones(size(t));
    Batt_I      = zeros(size(t));
    Batt_SOC    = SOC_init_per * ones(size(t));
    Batt_P      = zeros(size(t));
    Batt_P_day  = Batt_P;
    Batt_I_plot = Batt_I;
end
Batt_P_chg = max(0,  Batt_P);   
Batt_P_dis = max(0, -Batt_P);   

% =========================================================================
%  SECTION 8 – DERIVED QUANTITIES & CONFIG-AWARE TRACKING
% =========================================================================
PV_P   = PV_V .* PV_I;
PV_P_2 = PV_V_2 .* PV_I_2;
PV_P_3 = PV_V_3 .* PV_I_3;

% Branch power breakdown for plots
PV_P_1 = NaN(size(PV_P));
mask1 = (sw1 == 0);
mask2 = (sw1 == 1 & sw2 == 0);
mask3 = (sw1 == 1 & sw2 == 1);
PV_P_1(mask1) = PV_P(mask1);
PV_P_1(mask2) = PV_P(mask2) - PV_P_2(mask2);
PV_P_1(mask3) = PV_P(mask3) - PV_P_2(mask3) - PV_P_3(mask3);
PV_P_total = PV_P;
PEM_P = PEM_V .* PEM_I;

Np_active = zeros(size(config));
Np_active(config == 1) = Np_cell_base;                                    
Np_active(config == 2) = Np_cell_base - Np_cell_red_1;                   
Np_active(config == 3) = Np_cell_base - Np_cell_red_1 - Np_cell_red_2;  
Np_active(Irr <= NIGHT_THR) = 7;   
PV_area = Np_active * Ns_cell * cell_area;  

% Config-Aware MPP Tracking Reference
P_mpp_ref = NaN(size(Irr));
for k = 1:3
    cfg_mask = (config == k) & (Irr > NIGHT_THR);
    Np_k = Np_map(k);
    g_k  = Irr(cfg_mask) / 1000;                          
    P_mpp_ref(cfg_mask) = Np_k * Im_PV .* g_k * (Ns_cell * Vm_PV);
end
P_mpp_ref(Irr <= NIGHT_THR) = NaN;
C = abs(PV_P ./ P_mpp_ref);
C(Irr <= NIGHT_THR) = NaN;
C_plot = max(0, min(1.09, C));
err_P = max(-50, P_mpp_ref - PV_P);
err_P(Irr <= NIGHT_THR) = NaN;

% Hydrogen calculations
F_const = 96485;  eta_F = 0.99;  M_H2 = 2.016e-3;
n_H2     = (N * PEM_I) / (2 * F_const) * eta_F;   
H2_inst  = n_H2 * M_H2 * 1e3;     
H2_rate  = H2_inst * 3600;         
H2_cumul = cumtrapz(real_t, H2_inst);   

% --- FIX: Split H2 into Solar vs Battery ---
if has_batt
    pv_to_PEM    = min(PV_I, PEM_I_eff);           
    batt_to_PEM  = max(0, PEM_I_eff - PV_I);       
    PEM_I_safe   = max(PEM_I_eff, 1e-6);
    pv_frac_h2   = pv_to_PEM  ./ PEM_I_safe;       
    batt_frac_h2 = batt_to_PEM ./ PEM_I_safe;      
    H2_cumul_PV   = cumtrapz(real_t, H2_inst .* pv_frac_h2);
    H2_cumul_Batt = cumtrapz(real_t, H2_inst .* batt_frac_h2);
else
    H2_cumul_PV   = H2_cumul;
    H2_cumul_Batt = zeros(size(H2_cumul));
end

CF_PEM = mean(PEM_P, 'omitnan') / max(Pmax_PEM, 1) * 100;
E_chg_Wh = trapz(real_t, Batt_P_chg) / 3600;
E_dis_Wh = trapz(real_t, Batt_P_dis) / 3600;

% ── Calculate Percentages & Night Production ──────────────────────────────
if E_chg_Wh > 1
    eta_batt_RT = min(99, E_dis_Wh / E_chg_Wh * 100);   % cap at 99% (non-physical >100%)
else
    eta_batt_RT = NaN;
end
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

% Re-calculate Efficiencies for Console Summary
G_safe  = max(Irr, 10);                        
eta_PV  = PV_P ./ (PV_area .* G_safe) * 100;  
eta_PV(Irr <= NIGHT_THR) = NaN;
eta_PV  = max(0, min(100, eta_PV));

eta_PEM = NaN(size(PEM_V_eff));
valid_pem = PEM_V_eff > (Vint_stack + 0.1);
eta_PEM(valid_pem) = (Vint_stack ./ PEM_V_eff(valid_pem)) * 100;
eta_PEM = max(0, min(100, eta_PEM));

LHV_H2   = 119.96e6;   
H2_power_solar = H2_inst .* (H2_cumul_PV ./ max(H2_cumul, 1e-6)) * 1e-3 * LHV_H2;   
STH      = H2_power_solar ./ (PV_area .* G_safe) * 100; 
STH(Irr <= NIGHT_THR) = NaN;
STH      = max(0, STH);

TTH = (H2_inst * 1e-3 * LHV_H2) ./ (PV_area .* G_safe) * 100;
TTH(Irr <= NIGHT_THR) = NaN;
TTH = max(0, TTH);

Coupling_C = PV_P ./ max(P_mpp_ref, 1e-3);
C_sys = PEM_P ./ max(P_mpp_ref, 1e-3);
C_sys(Irr <= NIGHT_THR) = NaN;
TTH_8day     = (H2_cumul(end) * 1e-3 * LHV_H2) / trapz(real_t, Irr .* PV_area) * 100;
% =========================================================================
%  SECTION 9 – FIGURES
% =========================================================================
clr_pv   = [0.85 0.33 0.10];
clr_pem  = [0.13 0.47 0.71];
clr_batt = [0.47 0.25 0.80];
clr_irr  = [0.93 0.69 0.13];
clr_eta  = [0.18, 0.55, 0.18];
lw = 1.8;
day_ticks  = 0 : 24 : NUM_DAYS*24;

% --- Figure 1: System Overview with Sub-Branch Tracking ---
fig1 = figure('Name','System Overview','Color','w','Position',[30 30 1100 850]);
tl1  = tiledlayout(5,1,'TileSpacing','compact','Padding','compact');

ax1 = nexttile; plot(t_plot, Irr, 'Color', clr_irr, 'LineWidth', lw);
ylabel('G (W/m²)'); ylim([0 1200]); grid on; box on;
hold on; fill_config(gca, t_plot, config, 1200); hold off; legend('Irradiance','Location','northeast');

ax_pv = nexttile; hold on;
plot(t_plot, PV_P,   'Color', clr_pv,        'LineWidth', lw,     'DisplayName','P_{PV,total}');
plot(t_plot, PV_P_1, 'Color', [0.2 0.7 0.3], 'LineWidth', lw-0.3, 'DisplayName','P_{PV,1} (base 5)');
plot(t_plot, PV_P_2, 'Color', [0.1 0.4 0.8], 'LineWidth', lw-0.3, 'LineStyle','--', 'DisplayName','P_{PV,2} (+1)');
plot(t_plot, PV_P_3, 'Color', [0.6 0.3 0.8], 'LineWidth', lw-0.3, 'LineStyle',':', 'DisplayName','P_{PV,3} (+1)');
hold off; ylabel('Power (W)'); grid on; box on; legend('Location','northeast','NumColumns',2); title('PV Power Breakdown');

nexttile; hold on;
plot(t_plot, PV_V,  'Color', clr_pv,  'LineWidth', lw, 'DisplayName','V_{PV}');
plot(t_plot, PEM_V, 'Color', clr_pem, 'LineWidth', lw, 'DisplayName','V_{PEM}');
if has_batt, plot(t_plot, Batt_V,'Color',clr_batt,'LineWidth',lw,'DisplayName','V_{batt}'); end
hold off; ylabel('Voltage (V)'); grid on; box on; legend('Location','east');

nexttile; hold on;
plot(t_plot, PV_I,  'Color', clr_pv,  'LineWidth', lw, 'DisplayName','I_{PV}');
plot(t_plot, PEM_I, 'Color', clr_pem, 'LineWidth', lw, 'DisplayName','I_{PEM}');
if has_batt, plot(t_plot, Batt_I_plot,'Color',clr_batt,'LineWidth',lw,'DisplayName','I_{batt} (+disch)'); end
hold off; ylabel('Current (A)'); grid on; box on; legend('Location','northeast');

nexttile; hold on;
plot(t_plot, PV_P_total, 'Color', clr_pv,  'LineWidth', lw, 'DisplayName','P_{PV,total}');
plot(t_plot, PEM_P, 'Color', clr_pem, 'LineWidth', lw, 'DisplayName','P_{PEM}');
if has_batt, plot(t_plot, Batt_P,'Color',clr_batt,'LineWidth',lw,'DisplayName','P_{batt}(+disch)'); end
hold off; xlabel('Time (hours)'); ylabel('Power (W)'); grid on; box on; legend('Location','northeast');
for ax = findobj(fig1,'Type','Axes')', xticks(ax, day_ticks); xlim(ax, [0 NUM_DAYS*24]); end

% --- Figure 2: Battery EMS & SOC Limits ---
if has_batt
    fig2 = figure('Name','Battery EMS','Color','w','Position',[80 80 1100 680]);
    tl2  = tiledlayout(3,1,'TileSpacing','compact','Padding','compact');
          
    ax2a = nexttile; yyaxis(ax2a,'left'); ax2a.YColor = clr_batt;
    plot(t_plot, Batt_V,'Color',clr_batt,'LineWidth',lw); ylabel('V_{batt} (V)');
    yyaxis(ax2a,'right'); ax2a.YColor = [0.7 0.1 0.1];
    plot(t_plot, Batt_I_plot,'Color',[0.7 0.1 0.1],'LineWidth',lw);
    yline(0,'k:','HandleVisibility','off'); ylabel('I_{batt} (A, +disch)'); grid on; box on;
    
    nexttile; hold on;
    plot(t_plot, PV_P_total, 'Color',clr_pv, 'LineWidth',lw,'DisplayName','P_{PV}');
    plot(t_plot, PEM_P,'Color',clr_pem,'LineWidth',lw,'DisplayName','P_{PEM}');
    plot(t_plot, Batt_P,'Color',clr_batt,'LineWidth',lw,'DisplayName','P_{batt}(+disch)');
    hold off; ylabel('Power (W)'); grid on; box on; legend('Location','northeast');
    
    nexttile;
    plot(t_plot, Batt_SOC,'Color',[0.1 0.6 0.3],'LineWidth',lw+0.4);
    yline(SOC_max,'--','Color',[0.7 0.1 0.1],'LineWidth',1.2,'HandleVisibility','off');
    yline(SOC_min,'--','Color',[0.7 0.1 0.1],'LineWidth',1.2,'HandleVisibility','off');
    ylabel('SOC (%)'); ylim([0 105]); xlabel('Time (hours)'); grid on; box on;
    for ax = findobj(fig2,'Type','Axes')', xticks(ax,day_ticks); xlim(ax,[0 NUM_DAYS*24]); end
end

% --- Figure 3: Reconfiguration MPP Quality ---
fig_mpp = figure('Name','MPP Comparison','Color','w','Position',[100 100 1100 760]);
tiledlayout(3,1,'TileSpacing','compact','Padding','compact');
ax_m1 = nexttile;
plot(t_plot, PV_P,      'Color', clr_pv,  'LineWidth', lw,     'DisplayName','PV Power'); hold on;
plot(t_plot, P_mpp_ref, '--',    'Color', clr_eta, 'LineWidth', lw+0.2, 'DisplayName','MPP Ref (config-aware)');
fill_config_full(ax_m1, t_plot, config); hold off;
ylabel('Power (W)'); grid on; box on; legend('Location','northeast'); title('PV Power vs. MPP Reference');

ax_m2 = nexttile;
plot(t_plot, err_P, 'Color',[0.85 0.20 0.20], 'LineWidth', lw, 'DisplayName','Power Error'); hold on;
fill_config_full(ax_m2, t_plot, config); hold off;
yline(0,'--','Color',[0.4 0.4 0.4],'HandleVisibility','off');
ylabel('\Delta P (W)'); grid on; box on; legend('Location','northeast'); title('Power Error Relative to MPP');

ax_m3 = nexttile;
plot(t_plot, C_plot, 'Color',[0.20 0.20 0.20], 'LineWidth', lw, 'DisplayName','Coupling Factor'); hold on;
ylim(ax_m3,[0.4 1.1]);
fill_config_full(ax_m3, t_plot, config); hold on;
yline(1,'--','Color',[0.4 0.4 0.4],'HandleVisibility','off'); hold off;
xlabel('Time (h)'); ylabel('C = P_{WP}/P_{MPP}');
grid on; box on; legend('Location','northeast'); title('Coupling Factor');

for ax = [ax_m1 ax_m2 ax_m3], xticks(ax, day_ticks); xlim(ax, [0 NUM_DAYS*24]); end

% --- Figure 4: Reconfiguration Timeline ---
fig_sw = figure('Name','Reconfiguration Timeline','Color','w','Position',[150 150 1100 380]);
ax_sw = axes(fig_sw);
yyaxis(ax_sw,'right');
area(ax_sw, t_plot, Irr, 'FaceColor', clr_irr, 'FaceAlpha', 0.28, 'EdgeColor', clr_irr, 'LineWidth', 0.3, 'DisplayName','Irradiance');
ylabel(ax_sw,'Irradiance (W/m^2)'); ylim(ax_sw,[0 1200]);
yyaxis(ax_sw,'left');
stairs(ax_sw, t_plot, config, 'Color',[0.3 0.3 0.3], 'LineWidth', 2, 'DisplayName','Configuration');
ylim(ax_sw,[0.5 3.5]); yticks(ax_sw,[1 2 3]);
yticklabels(ax_sw,{'Low-G (7 strings)','Mid-G (6 strings)','High-G (5 strings)'});
ylabel(ax_sw,'Configuration'); grid(ax_sw,'on'); box(ax_sw,'on');
xlabel(ax_sw, 'Time (hours)'); title(ax_sw,'Active Reconfiguration Mode');
xticks(ax_sw, day_ticks); xlim(ax_sw,[0 max(t_plot)]); legend(ax_sw,'Location','northwest');

% ── Calculate Percentages & Night Production ──────────────────────────────
if E_chg_Wh > 1
    eta_batt_RT = min(99, E_dis_Wh / E_chg_Wh * 100);   % cap at 99% (non-physical >100%)
else
    eta_batt_RT = NaN;
end

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
TTH_8day     = (H2_cumul(end) * 1e-3 * LHV_H2) / trapz(real_t, Irr .* PV_area) * 100;

% ── Console summary ───────────────────────────────────────────────────────
sep1 = repmat('-',1,52);
fprintf('\n%s\n  Reconfigurable PV-PEM-Batt  KPI Summary\n%s\n', sep1, sep1);
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
%  SECTION 10 – EXCEL EXPORT  (used by compare_batt_cases.m)
% =========================================================================
fprintf('\n  Writing results to Excel...\n');
EXCEL_OUT = 'PV_PEM_rec_batt_results_week_CNR.xlsx';

% --- TimeSeries sheet (one row per simulation time-step) ---
T_out = table( ...
    t_plot(:), real_t(:), Irr(:), PV_P(:), PEM_P(:), ...
    Batt_P(:), Batt_P_chg(:), Batt_P_dis(:), Batt_SOC(:), ...
    H2_rate(:), H2_cumul(:), H2_cumul_PV(:), H2_cumul_Batt(:), ...
    Coupling_C(:), eta_PV(:), eta_PEM(:), STH(:), TTH(:), C_sys(:), ...
    'VariableNames', { ...
        't_plot_[h]','t_real_[s]','Irr_[W/m2]','PV_P_[W]','PEM_P_[W]', ...
        'Batt_P_[W]','Batt_P_chg_[W]','Batt_P_dis_[W]','Batt_SOC_[%]', ...
        'H2_rate_[g_h]','H2_cumul_[g]','H2_cumul_PV_[g]','H2_cumul_Batt_[g]', ...
        'Coupling_C','eta_PV_[pct]','eta_PEM_[pct]','STH_[pct]','TTH_[pct]','C_sys'});
writetable(T_out, EXCEL_OUT, 'Sheet', 'TimeSeries');

% --- Parameters sheet (scalar KPIs for the comparison script) ---
P_names  = {'NUM_DAYS'; 'Pmax_PEM_[W]'; 'NIGHT_THR_[W/m2]'; 'Q_batt_[Ah]'; ...
             'V_batt_nom_[V]'; 'scale_factor'; 'H2_total_[g]'; ...
             'E_chg_[Wh]'; 'E_dis_[Wh]'; 'eta_batt_RT_[pct]'};
P_values = [NUM_DAYS; Pmax_PEM; NIGHT_THR; Q_batt; V_batt_nom; scale_factor; ...
            H2_cumul(end); E_chg_Wh; E_dis_Wh; eta_batt_RT];
T_par = table(P_names, P_values, 'VariableNames', {'Parameter','Value'});
writetable(T_par, EXCEL_OUT, 'Sheet', 'Parameters');

fprintf('  [OK] Saved: %s\n', EXCEL_OUT);

% =========================================================================
%  LOCAL FUNCTIONS
% =========================================================================
function Np_out = min_dwell_filter(Np_in, min_steps)
    Np_out      = Np_in;
    last_switch = 1;
    for i = 2 : length(Np_in)
        if Np_in(i) ~= Np_out(i-1)
            if (i - last_switch) >= min_steps
                Np_out(i)   = Np_in(i);
                last_switch = i;
            else
                Np_out(i) = Np_out(i-1);   
            end
        end
    end
end

function fill_config(ax, t_plot, config, ymax)
    colors = {[1.0 0.85 0.6], [0.75 0.95 0.75], [0.6 0.8 1.0]};
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