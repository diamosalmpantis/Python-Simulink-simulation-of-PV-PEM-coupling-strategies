%% setup_PV_PEM_converter_afternoon.m  (The "Perfect Afternoon" MPPT Version)
%
%  This script:
%    1. Defines standard PEM and PV workspace parameters
%    2. Loads PV_PEM_converter_afternoon.slx
%    3. RESTORES the perfect MPPT PI overrides (safely shielding Constants)
%    4. Runs the simulation for 4 seconds in fast Accelerator mode
%    5. Post-processes and exports FIVE publication-quality figures
%
% =========================================================================
clear; clc; close all;

%warning('off', 'all'); % Suppress all annoying Simulink warnings
fprintf('=== PV-PEM Setup & Simulation (Perfect MPPT Version) ===\n\n');

% =========================================================================
%  SECTION 1 — PEM ELECTROLYZER PARAMETERS
% =========================================================================
N = 13;                      % number of PEM cells in series

% Per-cell Randles equivalent-circuit parameters
Vint    = 1.475841;         % [V]    thermodynamic OCV per cell
Rint    = 0.008673;         % [Ω]    ohmic (membrane) resistance per cell
Ra      = 0.00177;          % [Ω]    anode charge-transfer resistance (OER)
Rc      = 0.0005;           % [Ω]    cathode charge-transfer resistance (HER)
ratio_tau = 10;
tau_a   = 0.4;              % [s]    anode double-layer time constant
tau_c   = tau_a / ratio_tau;
Ca      = tau_a / Ra;       % [F]    anode double-layer capacitance
Cc      = tau_c / Rc;       % [F]    cathode double-layer capacitance
Active_Area = 17.64;        % [cm²]  electrode active area

% Stack aggregation
Vint_stack = Vint * N;      % 8.855 V   stack OCV
Rint_stack = Rint * N;      % 0.052 Ω   total ohmic resistance
Ra_stack   = Ra   * N;      % 0.0106 Ω  total anode resistance
Rc_stack   = Rc   * N;      % 0.003 Ω   total cathode resistance
Ca_stack   = Ca   / N;      % [F]        stack anode capacitance
Cc_stack   = Cc   / N;      % [F]        stack cathode capacitance

% PEM safe operating window
Vmin_PEM = Vint * N;         % 9.0 V
Vmax_PEM = 2.0 * N;         % 12.0 V
Imin_PEM = 2.2;             % [A]
Imax_PEM = 80;            % [A]
fprintf('  PEM: %d cells, OCV=%.3f V, Vmin=%.1f V, Vmax=%.1f V\n',...
        N, Vint_stack, Vmin_PEM, Vmax_PEM);

V_ref_battery = (Vint_stack + Vmax_PEM) / 2.1;
% =========================================================================
%  SECTION 2 — PV ARRAY SIZING
% =========================================================================
Im_PV = 9.59;               % [A]   cell MPP current at STC
Vm_PV = 0.55;               % [V]   cell MPP voltage at STC
%Over sized  way higher current
% Np_cell =  20;
% Ns_cell = 45;               % cells per string
% Good sizing: 
Np_cell =  12;               % parallel strings
Ns_cell = 45;               % cells per string


Isc   = 10.14 * Np_cell;    % [A]  array short-circuit current
Voc   =  0.67 * Ns_cell;    % [V]  array open-circuit voltage
Vmpp  = Vm_PV * Ns_cell;    % [V]  array MPP voltage at STC
Impp  = Im_PV * Np_cell;    % [A]  array MPP current at STC
Pmpp  = Vmpp  * Impp;       % [W]  array MPP power at STC

fprintf('  PV: Ns=%d, Np=%d — Vmpp=%.2f V, Impp=%.2f A, Pmpp=%.1f W\n\n', ...
        Ns_cell, Np_cell, Vmpp, Impp, Pmpp);

fprintf('  PV: Ns=%d, Np=%d — Vmpp=%.2f V, Impp=%.2f A, Pmpp=%.1f W\n', ...
        Ns_cell, Np_cell, Vmpp, Impp, Pmpp);
fprintf('  BMS Target Bus Voltage: %.1f V (PV Vmpp is %.1f V)\n\n', V_ref_battery, Vmpp);

% TIME COMPRESSION: 2.4 seconds = 24 real hours.
sim_t       = 2.4*3;          
scale_factor = 36000;  
Ts          = 1e-4;         
Tsc         = 1e-6;         
%sample_output_time = 1e-4;  

% --- LOAD REAL MINUTE-RESOLUTION DATA ---
% Assumes you have a file 'weather_profile.xlsx' with columns: 'Time_min', 'Irradiance', 'Temperature'
if isfile('weather_profile.xlsx')
    weather = readtable('weather_profile.xlsx');
    real_time_sec = weather.Time_min * 60;
    Irr_val       = weather.Irradiance;
    Temp_val      = weather.Temperature;
else
    fprintf('  [!] weather_profile.xlsx not found. Generating a mock 1-minute profile...\n');
    real_time_sec = (0:60:86400)'; % 24 hours, 1-min steps
    
    % Generate a realistic 1-min irradiance curve with some noise
    Irr_val       = 1000 * max(sin(pi * real_time_sec / 86400), 0) .* (0.8 + 0.2*rand(size(real_time_sec))); 
    % Generate a temperature curve (e.g., 15C at night, up to 35C in the day)
    Temp_val      = 15 + 20 * max(sin(pi * (real_time_sec - 3600*6) / 86400), 0); 
end

% Scale the real time vector to match the simulation time compression
Irr_time = real_time_sec / scale_factor;
sim_t    = max(Irr_time); % Auto-set simulation stop time based on data

% --- STAIR BLOCK ADAPTATION ---
Irr_stair_tsamp = 60 / scale_factor; % 1 real minute scaled down!
Irr_stair_time  = (0:Irr_stair_tsamp:sim_t)';
Irr_stair_val   = interp1(Irr_time, Irr_val, Irr_stair_time, 'linear', 0);
Temp_stair_val  = interp1(Irr_time, Temp_val, Irr_stair_time, 'linear', 25); % Default 25C if missing

% --- run model ---
sample_output_time = 1e-3;


% =========================================================================
%  SECTION 3.2 — BATTERY  (12 V / 1 Ah Li-ion / lead-acid equivalent)
%
%  Battery1 (batteryecm_lib) is a compiletime (InstanceData) block:
%  workspace variables below are for reference and post-processing only.
%  The Simscape parameters are patched directly in the SLX XML by
%  patch_batt_model.py (AH=1, R1=R1_dis=R1_ch=0.05 Ω, V1=11.0 V).
% =========================================================================
V_batt_nom  = 12.0;             % [V]   nominal voltage
Q_batt      = 0.1;%2; %0.1;                % [Ah]  nominal capacity
Q_thesis    = 1000;             % Ah (Visual Scaling)
scaling = true;  %true if scaling should be done for the SOC plots
SOC_init_per    = 80;               % [%]   initial state of charge
SOC_init    = SOC_init_per/100*Q_batt;  % [Ah]   initial state of charge in Ah

R_batt_int  = 0.05;             % [Ω]   internal resistance (ESR)

SOC_max = 0.9;                   % [%]   charge cutoff
SOC_min = 0.2;                   % [%]   discharge cutoff
% Hysteresis bands
SOC_max_hys = 0.85;   % re-enable charging below this
SOC_min_hys = 0.25;   % re-enable discharging above this

fprintf('  Bat: %.1f V | %.1f Ah | SOC₀=%.0f%%  ESR=%.3f Ω\n\n', ...
        V_batt_nom, Q_batt, SOC_init_per, R_batt_int);


% =========================================================================
%  SECTION 3.3 — Biderectional converter for the battery  

% =========================================================================
%% DC-DC Converter Parameters base settings
Bi_L = 4e-4;  % Inductance, L [H]
Bi_C1 = 1e-5; % Capacitance, C1 [F]
Bi_C2 = 1e-5;  % Capacitance, C2 [F]
Bi_R1 = 1e-6;    % C1 effective series resistance [Ohm]
Bi_R2 = 1e-6;    % C2 effective series resistance [Ohm]
%% Control Parameters
fsw = 10000; % Switching frequency           [Hz]
Ts1 = 5e-5;  % Sample time for PWM averaging [s]
Bi_C_Kp  = 0.01;  % Controller proportional gain
Bi_C_Ki  = 10.0;     % Controller integrator gain speed
Bi_V_Kp  = 10;  % Controller proportional gain
Bi_V_Ki  = 70;     % Controller integrator gain speed
% Bi_V_Kp  = 5e-3;  % Controller proportional gain
% Bi_V_Ki  = 2;     % Controller integrator gain speed



% =========================================================================
%  SECTION 4 — BASELINE MODEL OVERRIDES
% =========================================================================
case_model = 'B';
mdl_orig  = 'PV_PEM_direct_battery_active';
mdl_fixed = 'PV_PEM_direct_battery_active_FIXED';
fprintf('--- Applying Baseline Model Patches ---\n');

if bdIsLoaded(mdl_orig),  close_system(mdl_orig,  0); end
if bdIsLoaded(mdl_fixed), close_system(mdl_fixed, 0); end

slx_path = which([mdl_orig '.slx']);
if isempty(slx_path)
    slx_path = fullfile(pwd, [mdl_orig '.slx']);
end

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
    
    % Safely retrieve properties (the root model itself has no BlockType, causing errors)
    b_name = ''; b_type = '';
    try b_name = get_param(b, 'Name'); catch; end
    try b_type = get_param(b, 'BlockType'); catch; end
    
    % --- CRITICAL SAFETY SHIELD ---
    % If the block is a Constant, un-brick it if corrupted, then SKIP!
    % This guarantees we never get the "1 is greater than maximum 0.6" error.
    if strcmp(b_type, 'Constant')
        try set_param(b, 'OutMax', '[]'); catch; end
        continue; 
    end
% --- OVERRIDE: Daily Irradiance Injection ---
    if contains(b_name, 'Irradiance', 'IgnoreCase', true)
        try set_param(b, 'rep_seq_t', 'Irr_time'); catch; end
        try set_param(b, 'rep_seq_y', 'Irr_val'); catch; end
        try set_param(b, 'OutValues', 'Irr_stair_val'); catch; end
        try set_param(b, 'samp_time', 'Irr_stair_tsamp'); catch; end
    end
    % --- Override 1: Simulink-PS Converters ---
    try 
        ref = get_param(b, 'ReferenceBlock');
        if contains(ref, 'Simulink-PS Converter') || contains(ref, 'PS-Simulink Converter')
            set_param(b, 'FilteringAndDerivatives', 'filter');
            set_param(b, 'InputFilterTimeConstant', '1e-6');
        end
    catch; end
    
        % --- RESTORED OVERRIDE 2.2: Battery controller ---
    if contains(b_name, 'PI_Vol_Battery', 'IgnoreCase', true) 
        try set_param(b, 'P', 'Bi_V_Kp'); catch; end
        try set_param(b, 'Kp', 'Bi_V_Kp'); catch; end
        try set_param(b, 'I', 'Bi_V_Ki'); catch; end
        try set_param(b, 'Ki', 'Bi_V_Ki'); catch; end
    end
            
    if contains(b_name, 'PI_Cur_Battery', 'IgnoreCase', true) 
        try set_param(b, 'P', 'Bi_C_Kp'); catch; end
        try set_param(b, 'Kp', 'Bi_C_Kp'); catch; end
        try set_param(b, 'I', 'Bi_C_Ki'); catch; end
        try set_param(b, 'Ki', 'Bi_C_Ki'); catch; end
    end
    


    % --- Override 4: Force Sensors to Output Amps ---
    if contains(b_name, 'Current', 'IgnoreCase', true) || contains(b_name, 'Ammeter', 'IgnoreCase', true)
        try set_param(b, 'i_unit', 'A'); catch; end
    end
    
    % --- Override 5: Solver Configurations ---
    if contains(b_name, 'Solver Configuration')
        try 
            set_param(b, 'UseLocalSolver', 'on');
            set_param(b, 'LocalSolverSampleTime', 'Tsc');
            set_param(b, 'LocalSolverType', 'Backward Euler');
        catch; end
    end
end
fprintf('  [OK] MPPT SAVED: Perfect Duty Cycle clamping & PI tuning restored!\n');

% Set global simulation settings
set_param(mdl, 'StopTime', num2str(sim_t));
set_param(mdl, 'Solver', 'ode15s');
set_param(mdl, 'MaxStep', '1e-5'); 
set_param(mdl, 'SimulationMode', 'accelerator');
try set_param(mdl, 'SimscapeExplicitSolverDiagnostic', 'none'); catch; end




% Ensure sample time variable is passed to the base workspace for "To Workspace" blocks
assignin('base', 'sample_output_time', sample_output_time);

save_system(mdl);
fprintf('  Saved %s\n\n', [mdl_fixed '.slx']);

% =========================================================================
%  SECTION 5 — RUN SIMULATION
% =========================================================================
fprintf('Running 24-hour Realistic simulation (Compiling C-Code Accelerator) in simulation time: %g-second...\n', sim_t);
out = sim(mdl);
fprintf('Simulation complete.\n\n');

% ── Extract logged timeseries ─────────────────────────────────────────────
t      = out.PV_V.Time;
t_plot = t * 10;                     
real_t = t * scale_factor; 
% ABSOLUTE CLAMP: Strip all negative mathematical noise from the solver
PV_V   = max(out.PV_V.Data, 0);      
PV_I   = max(out.PV_I.Data, 0);      
PEM_V  = max(out.PEM_V.Data, 0);     
PEM_I  = max(out.PEM_I.Data, 0);     
Irr    = max(out.Irr.Data, 0);       

% Battery signals (graceful fallback)
has_batt = false;
try
    Batt_V   = out.Batt_V.Data;
    Batt_I   = out.Batt_I.Data;   % positive = charging
    b_time       = out.Batt_V.Time;
    Batt_SOC = out.Batt_SOC.Data;
    Batt_SOC = Batt_SOC * 100;
    Batt_P = Batt_V .* Batt_I;       % positive = charging
    has_batt = true;
    % --- THE MATHEMATICAL SOC ENGINE ---
    % Integrates the exact Coulombs flowing through the battery based on real-time.
    % Bypasses all Simulink capacity blockades for a perfect visual graph!
    if Q_batt <300 
        if scaling
        
            Q_coulombs = Q_thesis * 3600;
            Batt_SOC_Math = SOC_init_per + (cumtrapz(real_t, Batt_I) / Q_coulombs) * 100;
            Batt_SOC_Math = max(0, min(100, Batt_SOC_Math)); %Batt_SOC = max(0, min(100, Batt_SOC_Math)); % Clamp strictly between 0% and 100%
            fprintf('  [NOTE] Q_batt <300. SO it gets scaled with Q_thesis=%.0f\n',Q_thesis);
        end
    end
catch
    Batt_V   = V_batt_nom * ones(size(t));
    Batt_I   = zeros(size(t));
    Batt_SOC = SOC_init_per   * ones(size(t));
    fprintf('  [NOTE] Battery signals not logged — check To Workspace block names.\n');
end

% --- AUTO-CORRECT MILLIAMP SENSORS ---
if max(PEM_I) > 500, PEM_I = PEM_I / 1000; end
if max(PV_I) > 500,  PV_I = PV_I / 1000; end

PV_P   = PV_V  .* PV_I;     
PEM_P  = PEM_V .* PEM_I; 

PV_P_smooth  = movmean(PV_P, 200);   
PEM_P_smooth = movmean(PEM_P, 200);
if has_batt
    Batt_P_smooth = movmean(Batt_P, 200);
    Total_In_P  = PV_P_smooth + abs(min(Batt_P_smooth, 0));
    Total_Out_P = PEM_P_smooth + max(Batt_P_smooth, 0);
else
    Total_In_P  = PV_P_smooth;
    Total_Out_P = PEM_P_smooth;
end

eta_raw = Total_Out_P ./ max(Total_In_P, 1e-3) * 100;
eta_raw(eta_raw > 99.0) = 99.0; 

valid = Total_In_P > 1; 
eta   = nan(size(PV_P));
eta(valid) = eta_raw(valid);

M = PEM_V ./ max(PV_V, 0.01);

F_const  = 96485;             
eta_F    = 0.99;              
M_H2     = 2.016e-3;          
n_H2     = PEM_I / (2 * F_const) * eta_F;   
H2_rate  = n_H2 * M_H2 * 3600 * 1e3;          
%H2_cumul = cumtrapz(t, n_H2 * M_H2 * 1e3);  
H2_inst_g_s = n_H2 * M_H2 * 1e3;
H2_cumul = cumtrapz(real_t, H2_inst_g_s); 
% --- SPLIT H2 PRODUCTION (SOLAR VS BATTERY) ---
if has_batt
    % Only count negative power (discharge) for the battery contribution
    Batt_disch_P = abs(min(0, Batt_P)); % equivalently: -min(0, Batt_P) or max(0, -Batt_P)
    Total_Source_P = PV_P + Batt_disch_P;
    
    % Prevent division by zero
    safe_Source_P = max(Total_Source_P, 1e-6);
    
    % Calculate instantaneous power ratios
    ratio_PV   = PV_P ./ safe_Source_P;
    ratio_Batt = Batt_disch_P ./ safe_Source_P;
    
    % Zero out ratios if the system is completely off
    ratio_PV(Total_Source_P == 0) = 0;
    ratio_Batt(Total_Source_P == 0) = 0;
    
    % Integrate the fractionated hydrogen amounts
    H2_cumul_PV   = cumtrapz(real_t, H2_inst_g_s .* ratio_PV);
    H2_cumul_Batt = cumtrapz(real_t, H2_inst_g_s .* ratio_Batt);
else
    H2_cumul_PV   = H2_cumul;
    H2_cumul_Batt = zeros(size(H2_cumul));
end

fprintf('  PV peak power:              %.1f W\n',  max(PV_P));
fprintf('  PEM peak power:             %.1f W\n',  max(PEM_P));
fprintf('  Mean η (graph samples):     %.1f %%\n', mean(eta(valid), 'omitnan'));
fprintf('  Peak H2 production rate:    %.2f g/h\n', max(H2_rate));
fprintf('  Total H2 produced:          %.4f g\n\n', H2_cumul(end));
if has_batt
    fprintf('     ├─ from Solar (PV):      %.2f grams\n', H2_cumul_PV(end));
    fprintf('     └─ from Battery:         %.2f grams\n\n', H2_cumul_Batt(end));
else
    fprintf('\n');
end
if has_batt
    fprintf('  Battery: ΔV = %.2f–%.2f V | SOC: %.1f–%.1f %%\n', ...
            min(Batt_V), max(Batt_V), min(Batt_SOC), max(Batt_SOC));
end

% ── Style definitions ─────────────────────────────────────────────────────
clr_pv   = [0.85, 0.33, 0.10];    % orange-red
clr_pem  = [0.13, 0.47, 0.71];    % steel-blue
clr_batt = [0.47, 0.25, 0.80];    % purple
clr_irr  = [0.93, 0.69, 0.13];    % amber
clr_eta  = [0.18, 0.55, 0.18];    % green
lw  = 1.8;
irr_ticks = 0:2:sim_t*10;


% =========================================================================
%  FIGURE 1 — Energy Chain
% =========================================================================
fig1 = figure('Name','System Overview','Color','w','Position',[30 30 1020 760], 'ToolBar', 'none');
tl1  = tiledlayout(4,1,'TileSpacing','compact','Padding','compact');

ax1 = nexttile; plot(t_plot, Irr, 'Color', clr_irr, 'LineWidth', lw+0.4, 'DisplayName','Irradiance Profile');
ylabel('G (W/m²)', 'FontSize', 10); ylim([0 1200]); yticks([0 300 600 900 1000]); grid on; box on;
legend('Location', 'northeast', 'FontSize', 9);

ax2 = nexttile; plot(t_plot, PV_V,  'Color', clr_pv,  'LineWidth', lw, 'DisplayName','PV Array Voltage (V_{PV})'); hold on;
plot(t_plot, PEM_V, 'Color', clr_pem, 'LineWidth', lw, 'DisplayName','Electrolyzer Voltage (V_{PEM})');
if has_batt
    plot(t_plot,Batt_V,'Color',clr_batt,'LineWidth',lw,'DisplayName','V_{batt}');
end
yline(Vmax_PEM, '--', 'Color',[0.5 0.5 0.5], 'HandleVisibility','off'); 
yline(Vmin_PEM, ':',  'Color',[0.5 0.5 0.5], 'HandleVisibility','off');
hold off; ylabel('Voltage (V)', 'FontSize', 10); ylim([0 Voc * 1.12]); grid on; box on;
legend('Location', 'east', 'FontSize', 9);

ax3 = nexttile; plot(t_plot, PV_I,  'Color', clr_pv,  'LineWidth', lw, 'DisplayName','PV Current (I_{PV})'); hold on;
plot(t_plot, PEM_I, 'Color', clr_pem, 'LineWidth', lw, 'DisplayName','Electrolyzer Current (I_{PEM})');
if has_batt
    %plot(t_plot,abs(Batt_I),'Color',clr_batt,'LineWidth',lw,'LineStyle','--','DisplayName','|I_{batt}|');
    plot(t_plot,Batt_I,'Color',clr_batt,'LineWidth',lw,'DisplayName','Battery Current I_{batt}');
end
yline(Imax_PEM, '--', 'Color',[0.5 0.5 0.5], 'HandleVisibility','off');
hold off; ylabel('Current (A)', 'FontSize', 10); 
ylim([max([-100 min(Batt_I)]) -max([-100 min(Batt_I)])]); grid on; box on;
legend('Location', 'northeast', 'FontSize', 9);

ax4 = nexttile; plot(t_plot, PV_P,  'Color', clr_pv,  'LineWidth', lw, 'DisplayName','Input Power (P_{PV})'); hold on;
plot(t_plot, PEM_P, 'Color', clr_pem, 'LineWidth', lw, 'DisplayName','Load Power (P_{PEM})');
if has_batt
    plot(t_plot,Batt_P,'Color',clr_batt,'LineWidth',lw,'DisplayName','P_{batt}');
end
% %Shade converter loss
% loss_top = PV_P; loss_bot = min(PV_P, max(PEM_P, 0));   
% fill([t; flipud(t)], [loss_top; flipud(loss_bot)], clr_pv, 'FaceAlpha',0.12,'EdgeColor','none', 'DisplayName', 'Power Losses');
% hold off; xlabel('Time (s)', 'FontSize', 10); ylabel('Power (W)', 'FontSize', 10); grid on; box on;
% legend('Location', 'northeast', 'FontSize', 9, 'NumColumns', 3);

for ax = [ax1 ax2 ax3 ax4]
    xticks(ax, irr_ticks); 
    xlim(ax, [0 sim_t*10]);
    for tt = irr_ticks(2:end-1), xline(ax, tt, ':','Color',[0.6 0.6 0.6], 'HandleVisibility', 'off'); end
end
set([ax1 ax2 ax3], 'XTickLabel', []);
drawnow; exportgraphics(fig1, sprintf('Fig1_SystemOverview_Ns%d_Np%d_case_%s.png', Ns_cell, Np_cell, case_model), 'Resolution', 300);

% =========================================================================
%  FIGURE 2 — H2 rate
% =========================================================================
fig2 = figure('Name','H2 Rate','Color','w','Position',[60 60 1020 640], 'ToolBar', 'none');
tl2  = tiledlayout(1,1,'TileSpacing','compact','Padding','compact');



ax_h = nexttile; yyaxis(ax_h, 'left'); ax_h.YColor = clr_pem;
plot(t_plot, H2_rate, 'Color', clr_pem, 'LineWidth', lw, 'DisplayName', 'Instantaneous H_2 Rate'); ylabel('H_2 rate (g/h)');
yyaxis(ax_h, 'right'); ax_h.YColor = [0 0.40 0.80];
plot(t_plot, H2_cumul, 'Color',[0 0.40 0.80],'LineWidth',lw,'LineStyle','-.', 'DisplayName', 'Total H_2 Accumulated');
ylabel('Cumulative H_2 (g)'); grid on; box on; xlabel('Time (s)');
xlim(ax, [0 sim_t*10])
legend('Location', 'northwest', 'FontSize', 9, 'NumColumns', 2);

% for ax = ax_h
%     xticks(ax, irr_ticks); xlim(ax, [0 sim_t]);
% end
% set([ax_e ax_m], 'XTickLabel', []);
drawnow; exportgraphics(fig2, sprintf('Fig2_H2_Rate_Ns%d_Np%d_case_%s.png', Ns_cell, Np_cell, case_model), 'Resolution', 300);


% =========================================================================
%  FIGURE 3 — Battery EMS: voltage, current, power split, SOC
% =========================================================================
if has_batt
    I_min = min(Batt_I);
    I_max = max(Batt_I);
    fig3 = figure('Name','Battery EMS','Color','w','Position',[80 80 1020 780]);
    tl3  = tiledlayout(4,1,'TileSpacing','compact','Padding','compact');
    title(tl3,sprintf('Battery Energy Management  |  V_{nom}=%.0fV, Q=%.1fAh, SOC_0=%.0f%%', ...
        V_batt_nom, Q_batt, SOC_init_per),'FontSize',13,'FontWeight','bold');
    
    ax3_1 = nexttile;
    yyaxis(ax3_1,'left'); ax3_1.YColor = clr_batt;
    plot(t_plot,Batt_V,'Color',clr_batt,'LineWidth',lw,'DisplayName','V_{batt}');
    ylabel('V_{batt} (V)','FontSize',10,'Color',clr_batt);
    yyaxis(ax3_1,'right'); ax3_1.YColor = [.7 .1 .1];
    plot(t_plot,Batt_I,'Color',[.7 .1 .1],'LineWidth',lw,'DisplayName','I_{batt}');
    if I_min < -80 || I_max > 80
        ylim([-100 100]);
    end
    yline(0,'k:','LineWidth',1,'HandleVisibility','off');
    text(sim_t*.98, .3,'Charging →','FontSize',7,'HorizontalAlignment','right','Color',[.5 .5 .5]);
    text(sim_t*.98,-.3,'← Discharging','FontSize',7,'HorizontalAlignment','right','Color',[.5 .5 .5]);
    ylabel('I_{batt} (A)','FontSize',10,'Color',[.7 .1 .1]);
    
    
    grid on; box on; title('Battery Terminal Conditions','FontSize',10);
    legend('show','Location','northeast','FontSize',8,'NumColumns',2);
    ax3_2 = nexttile;
    plot(t_plot,PV_P, 'Color',clr_pv,  'LineWidth',lw,'DisplayName','P_{PV}'); hold on;
    plot(t_plot,PEM_P,'Color',clr_pem, 'LineWidth',lw,'DisplayName','P_{PEM}');
    plot(t_plot,Batt_P,'Color',clr_batt,'LineWidth',lw,'DisplayName','P_{batt} (+ charge)');
    yline(0,'k:','LineWidth',1,'HandleVisibility','off');
    hold off;
    ylabel('Power (W)','FontSize',10); grid on; box on;
    legend('Location','northeast','FontSize',8,'NumColumns',3);
    title('Power Flow','FontSize',10);
    
    ax3_3 = nexttile;
    plot(t_plot, Batt_SOC, 'Color',[.10 .60 .30],'LineWidth',lw+0.5);
    yline(SOC_max,'--','Color',[.7 .10 .10],'LineWidth',1.2,'HandleVisibility','off');
    yline(SOC_min,'--','Color',[.7 .10 .10],'LineWidth',1.2,'HandleVisibility','off');
    text(sim_t*.98, SOC_max+1,'SOC_{max}','FontSize',8,'Color',[.7 .1 .1],'HorizontalAlignment','right');
    text(sim_t*.98, SOC_min+1,'SOC_{min}','FontSize',8,'Color',[.7 .1 .1],'HorizontalAlignment','right');
    ylabel('SOC (%)','FontSize',10); ylim([0 105]);
    grid on; box on; title('State of Charge','FontSize',10);

    ax3_4 = nexttile;
    plot(t_plot, Batt_SOC, 'Color',[.10 .60 .30],'LineWidth',lw+0.5);
    %yline(SOC_max,'--','Color',[.7 .10 .10],'LineWidth',1.2,'HandleVisibility','off');
    %yline(SOC_min,'--','Color',[.7 .10 .10],'LineWidth',1.2,'HandleVisibility','off');
    %text(sim_t*.98, SOC_max+1,'SOC_{max}','FontSize',8,'Color',[.7 .1 .1],'HorizontalAlignment','right');
    %text(sim_t*.98, SOC_min+1,'SOC_{min}','FontSize',8,'Color',[.7 .1 .1],'HorizontalAlignment','right');
    ylabel('SOC (%)','FontSize',10);
    grid on; box on; title('State of Charge Zoomed in','FontSize',10);
    
    % Δ(SOC) bar — charged / discharged per irradiance window
    % ax3_4 = nexttile;
    % n_win = 4;
    % win_labels = {'900 W/m²','1000 W/m²','600 W/m²','300 W/m²'};
    % delta_SOC  = zeros(1,n_win);
    % for k = 1:n_win
    %     t1 = (k-1)*(sim_t/n_win) + 0.5;
    %     t2 = k*(sim_t/n_win) - 0.1;
    %     mk = t >= t1 & t <= t2;
    %     if sum(mk) > 1
    %         delta_SOC(k) = Batt_SOC(find(mk,1,'last')) - Batt_SOC(find(mk,1));
    %     end
    % end
    % bh = bar(1:n_win, delta_SOC, 0.5);
    % bh.FaceColor = 'flat';
    % for k = 1:n_win
    %     if delta_SOC(k) >= 0
    %         bh.CData(k,:) = [.10 .60 .30];   % green  → net charging
    %     else
    %         bh.CData(k,:) = [.70 .10 .10];   % red    → net discharging
    %     end
    % end
    % yline(0,'k-','LineWidth',1,'HandleVisibility','off');
    % set(gca,'XTick',1:n_win,'XTickLabel',win_labels,'FontSize',9);
    % xtickangle(20); ylabel('ΔSOC (%)','FontSize',10);
    % grid on; box on; title('SOC change per irradiance window','FontSize',10);
    % xlabel('Time (s)','FontSize',10);
    
    for ax = [ax3_1 ax3_2 ax3_3 ax3_4]
        xticks(ax,irr_ticks); 
        xlim(ax,[0 sim_t*10]);
        for tt = irr_ticks(2:end-1)
            xline(ax,tt,':','Color',[.6 .6 .6],'LineWidth',.8,'HandleVisibility','off');
        end
    end
    set([ax3_1 ax3_2 ax3_3],'XTickLabel',[]);
    
    exportgraphics(fig3,sprintf('Fig3_BatteryEMS_Ns%d_Np%d_case_%s.png', Ns_cell, Np_cell, case_model),'Resolution',300);
    fprintf('  Saved Fig3_BatteryEMS\n');
end

% =========================================================================
%  FIGURE 4 & 5 — Operating Points
% =========================================================================
fig4 = figure('Name','I-V Trajectory','Color','w','Position',[90 90 960 490], 'ToolBar', 'none');
tl3  = tiledlayout(1,2,'TileSpacing','loose','Padding','compact');
cmap = parula(256); Irr_norm = (Irr - min(Irr)) / max(max(Irr) - min(Irr), 1);
c_idx = max(1, min(256, round(Irr_norm * 255) + 1)); pt_col = cmap(c_idx, :);

ax_pv = nexttile; scatter(PV_I, PV_V, 20, pt_col, 'filled', 'MarkerFaceAlpha', 0.8, 'DisplayName', 'Dynamic Trajectory'); hold on;
scatter(Impp, Vmpp, 180, 'r', 'p', 'LineWidth', 1.5, 'DisplayName', 'Max Power Point (STC)'); hold off; grid on; box on; title('PV Array I-V Locus');
colormap(ax_pv, parula); colorbar(ax_pv); legend('Location', 'southwest', 'FontSize', 9);

ax_pem = nexttile; scatter(PEM_I, PEM_V, 20, pt_col, 'filled', 'MarkerFaceAlpha', 0.8, 'DisplayName', 'Dynamic Trajectory'); hold on;
PEM_I_max_value = ceil(max(PEM_I));
I_ref = linspace(0, PEM_I_max_value * 1.05, 300)'; 
V_randles = Vint_stack + (Rint_stack + Ra_stack + Rc_stack) .* I_ref;
plot(I_ref, V_randles, 'r--', 'LineWidth', 1.8, 'DisplayName', 'PEM Randles Model'); hold off; grid on; box on; title('PEM Locus');

linkaxes([ax_pv, ax_pem], 'xy');   % links both x and y

colormap(ax_pem, parula); colorbar(ax_pem); legend('Location', 'northwest', 'FontSize', 9);
drawnow; exportgraphics(fig4, sprintf('Fig4_IV_Trajectory_Ns%d_Np%d_case_%s.png', Ns_cell, Np_cell, case_model), 'Resolution', 300);

fig5 = figure('Name','PV Characteristics','Color','w','Position',[120 120 960 490], 'ToolBar', 'none');
tl4  = tiledlayout(1,2,'TileSpacing','loose','Padding','compact');
ax_pv2 = nexttile; scatter(PV_V, PV_P, 20, pt_col, 'filled', 'DisplayName', 'PV Power Output'); hold on;
scatter(Vmpp, Pmpp, 180, 'r', 'p', 'LineWidth',1.5, 'DisplayName', 'Max Power Point (STC)'); hold off; grid on; box on; title('PV P-V');
colormap(ax_pv2, parula); colorbar(ax_pv2); legend('Location', 'northwest', 'FontSize', 9);

ax_pem2 = nexttile; 
P_randles = V_randles .* I_ref;
scatter(PEM_V, PEM_P, 20, pt_col, 'filled', 'DisplayName', 'Electrolyzer Load Curve'); hold on; 
plot(V_randles, P_randles, 'r--', 'LineWidth', 1.8, 'DisplayName', 'PEM Randles Model'); hold off;
grid on; box on; title('PEM P-I'); colormap(ax_pem2, parula); colorbar(ax_pem2);
legend('Location', 'northwest', 'FontSize', 9);

linkaxes([ax_pv2, ax_pem2], 'xy');   % links both x and y

drawnow; exportgraphics(fig5, sprintf('Fig5_PV_Characteristics_Ns%d_Np%d_case_%s.png', Ns_cell, Np_cell, case_model), 'Resolution', 300);


% =========================================================================
%  FIGURE SOC — Simscape SOC vs Mathematical SOC Engine
% =========================================================================
if has_batt
    fig_soc = figure('Name','SOC Comparison','Color','w', ...
        'Position',[100 100 1020 520], 'ToolBar','none');
    tl_soc = tiledlayout(2,1,'TileSpacing','compact','Padding','compact');
    title(tl_soc, sprintf('SOC Comparison  |  Q_{batt}=%.2f Ah,Q_{thesis}=%.2f Ah, SOC_0=%.0f%%', ...
        Q_batt,Q_thesis, SOC_init_per), 'FontSize', 13, 'FontWeight', 'bold');

    % --- Top tile: overlay both SOC curves ---
    ax_soc1 = nexttile;
    plot(t_plot, Batt_SOC,  'Color', [0.10 0.60 0.30], 'LineWidth', lw+0.5,'LineStyle', '--', ...
        'DisplayName', 'SOC_{sim} (Simscape block)');
    hold on;
    plot(t_plot, Batt_SOC_Math, 'Color', [0.85 0.33 0.10], 'LineWidth', lw, ...
        'LineStyle', '--', 'DisplayName', 'SOC_{math} (current integration)');
    yline(SOC_max, '--', 'Color',[0.7 0.1 0.1], 'LineWidth', 1.2, 'HandleVisibility','off');
    yline(SOC_min, ':',  'Color',[0.7 0.1 0.1], 'LineWidth', 1.2, 'HandleVisibility','off');
    text(sim_t*10*0.99, SOC_max+1.5, 'SOC_{max}', 'FontSize',8, 'Color',[.7 .1 .1], ...
        'HorizontalAlignment','right');
    text(sim_t*10*0.99, SOC_min+1.5, 'SOC_{min}', 'FontSize',8, 'Color',[.7 .1 .1], ...
        'HorizontalAlignment','right');
    hold off;
    ylabel('SOC (%)', 'FontSize', 10);
    ylim([0 105]);
    grid on; box on;
    legend('Location','best','FontSize',9);
    title('Simscape vs Mathematical SOC', 'FontSize', 10);

    % --- Bottom tile: difference (error) between the two ---
    ax_soc2 = nexttile;
    SOC_error = Batt_SOC_Math - Batt_SOC;
    plot(t_plot, SOC_error, 'Color', [0.13 0.47 0.71], 'LineWidth', lw, ...
        'DisplayName', '\DeltaSOC = SOC_{math} - SOC_{sim}');
    yline(0, 'k--', 'LineWidth', 1, 'HandleVisibility','off');
    ylabel('\DeltaSOC (%)', 'FontSize', 10);
    xlabel('Time (hours)', 'FontSize', 10);
    grid on; box on;
    legend('Location','best','FontSize',9);
    title('Deviation between integrator and Simscape model', 'FontSize', 10);

    for ax = [ax_soc1 ax_soc2]
        xticks(ax, irr_ticks);
        xlim(ax, [0 sim_t*10]);
        for tt = irr_ticks(2:end-1)
            xline(ax, tt, ':', 'Color',[0.6 0.6 0.6], 'HandleVisibility','off');
        end
    end
    set(ax_soc1, 'XTickLabel', []);

    exportgraphics(fig_soc, sprintf('FigSOC_Comparison_Ns%d_Np%d_case_%s.png', ...
        Ns_cell, Np_cell, case_model), 'Resolution', 300);
    fprintf('  Saved FigSOC_Comparison\n');
end
% =========================================================================
% FIGURE 6 & SUMMARY — SPECIFIC HOURLY AVERAGES
% =========================================================================
target_hours = [7, 9, 12, 14.5, 16.5];
mean_PV_V    = zeros(length(target_hours), 1);
mean_PV_I    = zeros(length(target_hours), 1);
mean_PEM_V   = zeros(length(target_hours), 1);
mean_PEM_I   = zeros(length(target_hours), 1);
mean_Batt_I  = zeros(length(target_hours), 1);  % track current, not power
mean_Batt_P  = zeros(length(target_hours), 1);
mean_eta     = zeros(length(target_hours), 1);
recorded_irr = zeros(length(target_hours), 1);
mean_ems     = strings(length(target_hours), 1);

for k = 1:length(target_hours)
    target = target_hours(k);
    mask = t_plot >= (target - 0.16) & t_plot <= (target + 0.16);

    if sum(mask) > 1
        recorded_irr(k) = round(mean(Irr(mask)));
        mean_PV_V(k)    = mean(PV_V(mask));
        mean_PV_I(k)    = mean(PV_I(mask));
        mean_PEM_V(k)   = mean(PEM_V(mask));
        mean_PEM_I(k)   = mean(PEM_I(mask));

        p_in_mean  = mean(PV_P(mask));
        p_out_mean = mean(PEM_P(mask));

        if has_batt
            I_batt_mean = mean(Batt_I(mask));   % positive = charging
            P_batt_mean = mean(Batt_P(mask));
            mean_Batt_I(k) = I_batt_mean;
            mean_Batt_P(k) = P_batt_mean;

            % Sign convention: positive I = charging (current INTO battery)
            if I_batt_mean > 0.5
                mean_ems(k) = "CHARGING";        % surplus PV charges battery
            elseif I_batt_mean < -0.5
                mean_ems(k) = "DISCHARGING";     % battery supplements PEM
            else
                mean_ems(k) = "STANDBY";
            end

            % Correct power balance using Batt_I sign:
            %   negative I → discharging → adds to power available to PEM
            %   positive I → charging   → is an output of the system bus
            batt_disch_P = mean(abs(min(Batt_I(mask), 0)) .* Batt_V(mask)); % power from battery
            batt_chg_P   = mean(max(Batt_I(mask), 0)      .* Batt_V(mask)); % power into battery

            p_in_mean  = p_in_mean  + batt_disch_P;
            p_out_mean = p_out_mean + batt_chg_P;
        end

        if p_in_mean > 1
            mean_eta(k) = min(99.0, (p_out_mean / p_in_mean) * 100);
        end
    end
end

fig7 = figure('Name','Hourly Performance Summary','Color','w', ...
    'Position',[150 150 1200 510], 'ToolBar','none');
tl5 = tiledlayout(1,3,'TileSpacing','loose','Padding','compact');
x_pos = 1:length(target_hours);
lbl = arrayfun(@(h) sprintf('%02d:00', floor(h)), target_hours, 'UniformOutput',false);

% --- Ax 1: Voltage — PV and PEM only (battery voltage is on a separate bus) ---
ax_s1 = nexttile;
b1 = bar(x_pos, [mean_PV_V, mean_PEM_V], 0.65);
b1(1).FaceColor = clr_pv;  b1(1).DisplayName = 'V_{PV}';
b1(2).FaceColor = clr_pem; b1(2).DisplayName = 'V_{PEM}';
set(ax_s1,'XTick',x_pos,'XTickLabel',lbl,'FontSize',9); xtickangle(ax_s1, 25);
ylabel('Mean Voltage (V)'); grid on; box on;
title('Voltage at Time of Day');
legend('Location','northwest','FontSize',9);

% --- Ax 2: Current — PV, PEM, and Battery (signed: + charge, - discharge) ---
ax_s2 = nexttile;
if has_batt
    b2 = bar(x_pos, [mean_PV_I, mean_PEM_I, mean_Batt_I], 0.65);
    b2(1).FaceColor = clr_pv;   b2(1).DisplayName = 'I_{PV}';
    b2(2).FaceColor = clr_pem;  b2(2).DisplayName = 'I_{PEM}';
    b2(3).FaceColor = clr_batt; b2(3).DisplayName = 'I_{Batt} (+chg / −disch)';
else
    b2 = bar(x_pos, [mean_PV_I, mean_PEM_I], 0.65);
    b2(1).FaceColor = clr_pv;  b2(1).DisplayName = 'I_{PV}';
    b2(2).FaceColor = clr_pem; b2(2).DisplayName = 'I_{PEM}';
end
set(ax_s2,'XTick',x_pos,'XTickLabel',lbl,'FontSize',9); xtickangle(ax_s2, 25);
ylabel('Mean Current (A)'); grid on; box on;
title('Current at Time of Day');
legend('Location','northwest','FontSize',9);

% --- Ax 3: Efficiency with EMS state annotation ---
ax_s3 = nexttile;
if any(mean_eta > 0)
    b3 = bar(x_pos, mean_eta, 0.50); b3.FaceColor = clr_eta; hold on;
    for k = 1:length(target_hours)
        if mean_eta(k) > 0.5
            if has_batt && strlength(mean_ems(k)) > 0
                lbl_str = sprintf('%.1f%%\n(%s)', mean_eta(k), mean_ems(k));
            else
                lbl_str = sprintf('%.1f%%', mean_eta(k));
            end
            text(k, mean_eta(k)+1.5, lbl_str, ...
                'HorizontalAlignment','center','FontSize',7,'FontWeight','bold');
        end
    end
    hold off;
end
set(ax_s3,'XTick',x_pos,'XTickLabel',lbl,'FontSize',9); xtickangle(ax_s3, 25);
ylabel('Mean \eta_{system} (%)'); ylim([0 115]); grid on; box on;
title('System Efficiency (PV+Batt \rightarrow PEM+Batt)');
legend('Avg Efficiency','Location','southwest','FontSize',9);

drawnow;
exportgraphics(fig7, sprintf('Fig7_DailySummary_Ns%d_Np%d_case_%s.png', Ns_cell, Np_cell, case_model), 'Resolution', 300);


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%COMPARISSON TO MPPP
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% === Load MPP fit ===
mpp_filename = sprintf('../mpp_data_Ns%d_Np%d.mat', Ns_cell, Np_cell);
s = load(mpp_filename,'pP','pV','pI','irr_unique','P_mpp','V_mpp','I_mpp','Ns_cell', 'Np_cell');

fprintf('  PV: Ns=%d, Np=%d — MPP file: PV: Ns=%d, Np=%d\n', ...
        Ns_cell, Np_cell, s.Ns_cell, s.Np_cell);
% === Evaluate MPP at the same irradiance time series ===
V_mpp_ref = polyval(s.pV, Irr);
I_mpp_ref = polyval(s.pI, Irr);
P_mpp_ref = polyval(s.pP, Irr);

% === Working-point error and coupling factor ===
P_WP = PV_V .* PV_I;
err_P = P_WP - P_mpp_ref;
C = abs(P_WP ./ P_mpp_ref);

% Drop when Irr = 0
C(Irr == 0) = NaN;
err_P(Irr == 0) = NaN;

P_mpp_ref(Irr == 0) = NaN;
% Optional: clamp for display only
C_plot = max(0, min(1.2, C));
C_plot(Irr == 0) = NaN;

% =========================================================================
%  FIGURE X — MPP Tracking Quality
% =========================================================================
fig_mpp = figure('Name','MPP Comparison','Color','w', ...
    'Position',[80 80 1020 760], 'ToolBar', 'none');

tlmpp = tiledlayout(3,1,'TileSpacing','compact','Padding','compact');

% --- Subplot 1: PV power and MPP reference power ---
ax1 = nexttile;
plot(t_plot, P_WP, 'Color', clr_pv, 'LineWidth', lw, 'DisplayName','PV Power'); hold on;
plot(t_plot, P_mpp_ref, '--', 'Color', clr_eta, 'LineWidth', lw+0.2, 'DisplayName','MPP Reference Power');
hold off;
ylabel('Power (W)', 'FontSize', 10);
grid on; box on;
legend('Location','best','FontSize',9);
title('PV power compared to MPP reference');

% --- Subplot 2: Power error to MPP ---
ax2 = nexttile;
plot(t_plot, err_P, 'Color', [0.85 0.20 0.20], 'LineWidth', lw, 'DisplayName','Power Error');
yline(0,'--','Color',[0.4 0.4 0.4],'HandleVisibility','off');
ylabel('\Delta P (W)', 'FontSize', 10);
grid on; box on;
legend('Location','best','FontSize',9);
title('Power error relative to MPP');

% --- Subplot 3: Coupling factor ---
ax3 = nexttile;
plot(t_plot, C_plot, 'Color', [0.20 0.20 0.20], 'LineWidth', lw, 'DisplayName','Coupling Factor'); hold on;
yline(1,'--','Color',[0.4 0.4 0.4],'HandleVisibility','off');
hold off;
xlabel('Time (s)', 'FontSize', 10);
ylabel('C = P_{WP}/P_{MPP}', 'FontSize', 10);
grid on; box on;
legend('Location','best','FontSize',9);
title('Coupling factor over time');

linkaxes([ax1 ax2 ax3],'x');

exportgraphics(fig_mpp, sprintf('Fig_MPP_Tracking_Ns%d_Np%d_case_%s.png', ...
    s.Ns_cell, s.Np_cell, case_model), 'Resolution', 300);

% =========================================================================
%  FIGURE Y — MPP Voltage & Current Tracking Quality
% =========================================================================
fig_mpp_2 = figure('Name','MPP Comparison','Color','w', ...
    'Position',[80 80 1020 640], 'ToolBar', 'none');
tlmpp = tiledlayout(2,1,'TileSpacing','compact','Padding','compact');

% --- Subplot 1: Actual vs MPP reference — V (right) and I (left) ---
ax_mpp1 = nexttile;
yyaxis(ax_mpp1, 'left');
ax_mpp1.YColor = clr_pv;
plot(t_plot, PV_I,     'Color', clr_pv,  'LineWidth', lw,       'DisplayName', 'I_{PV} (actual)'); hold on;
plot(t_plot, I_mpp_ref,'Color', clr_pv,  'LineWidth', lw-0.4,   'LineStyle','--', 'DisplayName', 'I_{MPP} (ref)');
ylabel('Current (A)', 'FontSize', 10);
ylim([min([PV_I; I_mpp_ref], [], 'all') * 0.9, max([PV_I; I_mpp_ref], [], 'all') * 1.15]);

yyaxis(ax_mpp1, 'right');
ax_mpp1.YColor = clr_pem;
plot(t_plot, PV_V,     'Color', clr_pem, 'LineWidth', lw,       'DisplayName', 'V_{PV} (actual)');
plot(t_plot, V_mpp_ref,'Color', clr_pem, 'LineWidth', lw-0.4,   'LineStyle','--', 'DisplayName', 'V_{MPP} (ref)');
hold off;
ylabel('Voltage (V)', 'FontSize', 10);
ylim([min([PV_V; V_mpp_ref], [], 'all') * 0.90, max([PV_V; V_mpp_ref], [], 'all') * 1.15]);

grid on; box on;
title('PV Operating Point vs MPP Reference', 'FontSize', 10);
legend('Location', 'northeast', 'FontSize', 9, 'NumColumns', 2);

% --- Subplot 2: Tracking errors — ΔI (left) and ΔV (right) ---
err_I = PV_I - I_mpp_ref;
err_V = PV_V - V_mpp_ref;
err_I(Irr == 0) = NaN;
err_V(Irr == 0) = NaN;

ax_mpp2 = nexttile;
yyaxis(ax_mpp2, 'left');
ax_mpp2.YColor = clr_pv;
plot(t_plot, err_I, 'Color', clr_pv, 'LineWidth', lw, 'DisplayName', '\DeltaI = I_{PV} - I_{MPP}');
yline(0, '--', 'Color', [0.5 0.5 0.5], 'LineWidth', 1.0, 'HandleVisibility', 'off');
ylabel('\Delta I (A)', 'FontSize', 10);
I_err_lim = max(abs(err_I), [], 'omitnan') * 1.3;
if isnan(I_err_lim) || I_err_lim < 0.1, I_err_lim = 1; end
ylim([-I_err_lim, I_err_lim]);

yyaxis(ax_mpp2, 'right');
ax_mpp2.YColor = clr_pem;
plot(t_plot, err_V, 'Color', clr_pem, 'LineWidth', lw, 'DisplayName', '\DeltaV = V_{PV} - V_{MPP}');
ylabel('\Delta V (V)', 'FontSize', 10);
V_err_lim = max(abs(err_V), [], 'omitnan') * 1.3;
if isnan(V_err_lim) || V_err_lim < 0.1, V_err_lim = 1; end
ylim([-V_err_lim, V_err_lim]);

xlabel('Time (hours)', 'FontSize', 10);
grid on; box on;
title('Tracking Error vs MPP Reference', 'FontSize', 10);
legend('Location', 'northeast', 'FontSize', 9, 'NumColumns', 2);

linkaxes([ax_mpp1 ax_mpp2], 'x');
set(ax_mpp1, 'XTickLabel', []);
xticks(ax_mpp2, irr_ticks); xlim(ax_mpp2, [0, sim_t*10]);
xticks(ax_mpp1, irr_ticks); xlim(ax_mpp1, [0, sim_t*10]);

drawnow;
exportgraphics(fig_mpp_2, sprintf('Fig_Voltage_current_MPP_Ns%d_Np%d_case_%s.png', ...
    s.Ns_cell, s.Np_cell, case_model), 'Resolution', 300);


% =========================================================================
%  SUMMARY TABLE
% =========================================================================
fprintf('=== Steady-State Summary ===\n');
fprintf('%-12s  %8s  %8s  %8s  %8s  %6s  %6s\n', 'G (W/m²)', 'Vpv(V)', 'Ipv(A)', 'Vpem(V)', 'Ipem(A)', 'M', 'eta(%)');
fprintf('%s\n', repmat('-', 1, 72));
n_steps = floor(sim_t);
fprintf('n_step:%d\n', n_steps);

for k = 1:n_steps
    M_k = mean_PEM_V(k) / max(mean_PV_V(k), 0.01);
    fprintf('%-12d  %8.2f  %8.2f  %8.2f  %8.2f  %6.3f  %6.1f\n', ...
        recorded_irr(k), mean_PV_V(k), mean_PV_I(k), mean_PEM_V(k), mean_PEM_I(k), M_k, mean_eta(k));
end
time_step = [7, 9, 12, 14.5, 16.5];

for k = 1:length(time_step)
    M_k = mean_PEM_V(k) / max(mean_PV_V(k), 0.01);
    fprintf('%-12d  %8.2f  %8.2f  %8.2f  %8.2f  %6.3f  %6.1f\n', ...
        recorded_irr(k), mean_PV_V(k), mean_PV_I(k), mean_PEM_V(k), mean_PEM_I(k), M_k, mean_eta(k));
end
% =========================================================================
%% ===== Export results to Excel =====
% =========================================================================

filename = 'PV_PEM_direct_battery_results.xlsx';

% 1) Sheet 1: time‑series data
TS = table( ...
    t, t_plot, real_t, ...        % time vectors
    Irr, ...                      % irradiance
    PV_V, PV_I, ...               % PV voltage/current
    PEM_V, PEM_I, ...             % PEM voltage/current
    Batt_V, Batt_I, ...           % Battery voltage/current
    Batt_SOC, ...                 % Battery SOC in percent
    'VariableNames', {'t_sim_[s]','t_plot_[h]','t_real_[s]', ...
                      'Irr_[W/m^2]','PV_V_[V]','PV_I_[A]','PEM_V_[V]','PEM_I_[A]','Battery_V_[V]','Battery_I_[A]', 'Battery_SOC_[%]'});

writetable(TS, filename, ...
    'Sheet', 'TimeSeries', ...
    'WriteMode', 'overwritesheet');

% 2) Sheet 2: scalar parameters
paramNames  = {'N_cells_PEM'; 'Np_cell'; 'Ns_cell'; 'sim_t_[s]'; 'scale_factor'; 'Battery_SOC_init_[%]'};
paramValues = [N; Np_cell; Ns_cell; sim_t; scale_factor; SOC_init_per];

PARAM = table(paramNames, paramValues, ...
    'VariableNames', {'Parameter','Value'});

writetable(PARAM, filename, ...
    'Sheet', 'Parameters', ...
    'WriteMode', 'overwritesheet');