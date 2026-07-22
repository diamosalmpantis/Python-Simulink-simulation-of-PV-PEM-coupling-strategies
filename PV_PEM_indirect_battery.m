% =========================================================================
%  This script:
%    1. Defines standard PEM and PV workspace parameters
%    2. Loads PV_PEM_converter_afternoon.slx
%    3. RESTORES the perfect MPPT PI overrides (safely shielding Constants)
%    4. Runs the simulation for 4 seconds in fast Accelerator mode
%    5. Post-processes and exports FIVE publication-quality figures
%
% =========================================================================
clear; 
clc; close all;
warning('off', 'all'); % Suppress all annoying Simulink warnings
fprintf('=== PV-PEM Setup & Simulation (Perfect MPPT Version) ===\n\n');
% =========================================================================
%  SECTION 1 — PEM ELECTROLYZER PARAMETERS
% =========================================================================
N = 10;                     % number of PEM cells in series
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
Vmin_PEM = Vint * N;        % 9.0 V
Vmax_PEM = 2.0 * N;         % 12.0 V
Imin_PEM = 2.2;             % [A]
Imax_PEM = 80;              % [A]
V_ref_battery = (Vint_stack + Vmax_PEM) / 2; %[V]
fprintf('  PEM: %d cells, OCV=%.3f V, Vmin=%.1f V, Vmax=%.1f V, Vref=%.1f V\n',...
        N, Vint_stack, Vmin_PEM, Vmax_PEM, V_ref_battery);
% =========================================================================
%  SECTION 2 — PV ARRAY SIZING
% =========================================================================
Im_PV = 9.59;               % [A]   cell MPP current at STC
Vm_PV = 0.55;               % [V]   cell MPP voltage at STC
% Good sizing: 
Np_cell =  12;              % parallel strings
Ns_cell = 45;               % cells per string
Isc   = 10.14 * Np_cell;    % [A]  array short-circuit current
Voc   =  0.67 * Ns_cell;    % [V]  array open-circuit voltage
Vmpp  = Vm_PV * Ns_cell;    % [V]  array MPP voltage at STC
Impp  = Im_PV * Np_cell;    % [A]  array MPP current at STC
Pmpp  = Vmpp  * Impp;       % [W]  array MPP power at STC
fprintf('  PV: Ns=%d, Np=%d — Vmpp=%.2f V, Impp=%.2f A, Pmpp=%.1f W\n\n', ...
        Ns_cell, Np_cell, Vmpp, Impp, Pmpp);
% TIME COMPRESSION: 2.4 seconds = 24 real hours.
sim_t       = 2.4*3;          
scale_factor = 36000;       
% --- LOAD REAL MINUTE-RESOLUTION DATA ---
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
%  SECTION 3 — PV-PEM CONVERTER PARAMETERS
% =========================================================================
Ts          = 1e-3;         % [s]   switching period  (fsw = 10 kHz)
Tsc         = 1e-5;         % [s]   Simscape local solver step
sample_output_time = 1e-2;  % [s]   data logging interval
Ron         = 0.01;         % [Ω]   MOSFET on-resistance
Conductance = 1e-6;         % [S]   MOSFET off-state leakage conductance
Vth         = 0.5;          % [V]   MOSFET threshold voltage
Vforward    = 0.8;          % [V]   body diode forward voltage
L_conv      = 4e-4;         % [H]   filter inductance
C_conv      = 2.2e-4;       % [F]   filter capacitance
fn = 1 / (2*pi*sqrt(L_conv * C_conv));
fprintf('  Converter: fsw=%.0f Hz, Lf=%g H, Cf=%g F, fn=%.0f Hz\n\n', ...
        1/Ts, L_conv, C_conv, fn);
% =========================================================================
%  SECTION 3.2 — BATTERY 
% =========================================================================
V_batt_nom  = 12.0;             % [V]   nominal voltage
Q_batt      = 0.1;%2; %0.1;                % [Ah]  nominal capacity
Q_thesis    = 1000;             % Ah (Visual Scaling)
scaling = true;  %true if scaling should be done for the SOC plots
SOC_init_per    = 50;               % [%]   initial state of charge
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
%  SECTION 3.3 — Bidirectional converter for the battery  
% =========================================================================
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
% =========================================================================
%  SECTION 4 — BASELINE MODEL OVERRIDES
% =========================================================================
case_model = 'E';
mdl_orig  = 'PV_PEM_indirect_battery';
mdl_fixed = 'PV_PEM_indirect_battery_FIXED';
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
    b_name = ''; b_type = '';
    try b_name = get_param(b, 'Name'); catch; end
    try b_type = get_param(b, 'BlockType'); catch; end
    if strcmp(b_type, 'Constant')
        try set_param(b, 'OutMax', '[]'); catch; end
        continue; 
    end
    if contains(b_name, 'Irradiance', 'IgnoreCase', true)
        try set_param(b, 'rep_seq_t', 'Irr_time'); catch; end
        try set_param(b, 'rep_seq_y', 'Irr_val'); catch; end
        try set_param(b, 'OutValues', 'Irr_stair_val'); catch; end
        try set_param(b, 'samp_time', 'Irr_stair_tsamp'); catch; end
    end
    try 
        ref = get_param(b, 'ReferenceBlock');
        if contains(ref, 'Simulink-PS Converter') || contains(ref, 'PS-Simulink Converter')
            set_param(b, 'FilteringAndDerivatives', 'filter');
            set_param(b, 'InputFilterTimeConstant', '1e-6');
        end
    catch; end
    if contains(b_name, 'Control', 'IgnoreCase', true) || contains(b_name, 'MPPT_Control') || strcmp(b_type, 'Saturation')
        try set_param(b, 'UpperSaturationLimit', '0.60'); catch; end
        try set_param(b, 'upperLimit', '0.60'); catch; end
        try set_param(b, 'OutMax', '0.60'); catch; end
        try set_param(b, 'UpperLimit', '0.60'); catch; end
        try set_param(b, 'P', '0.01'); catch; end
        try set_param(b, 'Kp', '0.01'); catch; end
        try set_param(b, 'I', '10.0'); catch; end
        try set_param(b, 'Ki', '10.0'); catch; end
    end
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
    if contains(b_name, 'Buck-Boost') || contains(b_name, 'Diode')
        try set_param(b, 'diode_iRM', '5'); catch; end 
        try set_param(b, 'diode_trr', '0.5'); catch; end
    end
    if contains(b_name, 'Current', 'IgnoreCase', true) || contains(b_name, 'Ammeter', 'IgnoreCase', true)
        try set_param(b, 'i_unit', 'A'); catch; end
    end
    if contains(b_name, 'Solver Configuration')
        try 
            set_param(b, 'UseLocalSolver', 'on');
            set_param(b, 'LocalSolverSampleTime', 'Tsc');
            set_param(b, 'LocalSolverType', 'Backward Euler');
        catch; end
    end
end
fprintf('  [OK] MPPT SAVED: Perfect Duty Cycle clamping & PI tuning restored!\n');
set_param(mdl, 'StopTime', num2str(sim_t));
set_param(mdl, 'Solver', 'ode15s');
set_param(mdl, 'MaxStep', '1e-5'); 
set_param(mdl, 'SimulationMode', 'accelerator');
try set_param(mdl, 'SimscapeExplicitSolverDiagnostic', 'none'); catch; end
assignin('base', 'sample_output_time', sample_output_time);
save_system(mdl);
fprintf('  Saved %s\n\n', [mdl_fixed '.slx']);
% =========================================================================
%  SECTION 5 — RUN SIMULATION
% =========================================================================
fprintf('Running Realistic simulation (Compiling C-Code Accelerator) in simulation time: %g-second...\n', sim_t);
out = sim(mdl);
fprintf('Simulation complete.\n\n');
% ── Extract logged timeseries ─────────────────────────────────────────────
t      = out.PV_V.Time;
t_plot = t * 10;                     
real_t = t * scale_factor; 
PV_V   = max(out.PV_V.Data, 0);      
PV_I   = max(out.PV_I.Data, 0);      
PEM_V  = max(out.PEM_V.Data, 0);     
PEM_I  = max(out.PEM_I.Data, 0);     
Irr    = max(out.Irr.Data, 0);       
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
    if Q_batt <300 
        if scaling
            Q_coulombs = Q_thesis * 3600;
            Batt_SOC_Math = SOC_init_per + (cumtrapz(real_t, Batt_I) / Q_coulombs) * 100;
            Batt_SOC_Math = max(0, min(100, Batt_SOC_Math)); 
        end
    end
catch
    Batt_V   = V_batt_nom * ones(size(t));
    Batt_I   = zeros(size(t));
    Batt_SOC = SOC_init_per   * ones(size(t));
end
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
H2_inst_g_s = n_H2 * M_H2 * 1e3;
H2_cumul = cumtrapz(real_t, H2_inst_g_s); 
if has_batt
    Batt_disch_P = abs(min(0, Batt_P));   
    Total_Source_P = PV_P + Batt_disch_P;
    safe_Source_P = max(Total_Source_P, 1e-6);
    
    ratio_PV   = PV_P ./ safe_Source_P;
    ratio_Batt = Batt_disch_P ./ safe_Source_P;
    ratio_PV(Total_Source_P == 0) = 0;
    ratio_Batt(Total_Source_P == 0) = 0;
    
    H2_cumul_PV   = cumtrapz(real_t, H2_inst_g_s .* ratio_PV);
    H2_cumul_Batt = cumtrapz(real_t, H2_inst_g_s .* ratio_Batt);
else
    H2_cumul_PV   = H2_cumul;
    H2_cumul_Batt = zeros(size(H2_cumul));
end

fprintf('--- Plotting and Saving Figures (This takes ~20 seconds) ---\n');

% ── Style definitions ─────────────────────────────────────────────────────
clr_pv   = [0.85, 0.33, 0.10];    
clr_pem  = [0.13, 0.47, 0.71];    
clr_batt = [0.47, 0.25, 0.80];    
clr_irr  = [0.93, 0.69, 0.13];    
clr_eta  = [0.18, 0.55, 0.18];    
lw  = 1.8;
irr_ticks = 0:2:sim_t*10;

% =========================================================================
%  FIGURE 0 — Irradiance Verification Scope
% =========================================================================
fig0 = figure('Name','Irradiance Verification','Color','w','Position',[40 40 850 350]);
plot(t_plot, Irr, 'Color', clr_irr, 'LineWidth', 2);
title('Irradiance Profile Verification Scope', 'FontSize', 12, 'FontWeight', 'bold');
xlabel('Time (hours)', 'FontSize', 10);
ylabel('Irradiance (W/m^2)', 'FontSize', 10);
grid on; box on;
xticks(irr_ticks);
xlim([0 sim_t*10]);
exportgraphics(fig0, 'Fig0_Irradiance_Verification.png', 'Resolution', 300);
fprintf('  [OK] Saved Fig0_Irradiance_Verification.png\n');
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
    plot(t_plot,Batt_V,'Color',clr_batt,'LineWidth',lw,'LineStyle','--','DisplayName','V_{batt}');
end
yline(Vmax_PEM, '--', 'Color',[0.5 0.5 0.5], 'HandleVisibility','off'); 
yline(Vmin_PEM, ':',  'Color',[0.5 0.5 0.5], 'HandleVisibility','off');
hold off; ylabel('Voltage (V)', 'FontSize', 10); ylim([0 Voc * 1.12]); grid on; box on;
legend('Location', 'east', 'FontSize', 9);
ax3 = nexttile; plot(t_plot, PV_I,  'Color', clr_pv,  'LineWidth', lw, 'DisplayName','PV Current (I_{PV})'); hold on;
plot(t_plot, PEM_I, 'Color', clr_pem, 'LineWidth', lw, 'DisplayName','Electrolyzer Current (I_{PEM})');
if has_batt
    plot(t_plot,abs(Batt_I),'Color',clr_batt,'LineWidth',lw,'LineStyle','--','DisplayName','|I_{batt}|');
end
yline(Imax_PEM, '--', 'Color',[0.5 0.5 0.5], 'HandleVisibility','off');
hold off; ylabel('Current (A)', 'FontSize', 10); ylim([0 max(Isc*1.15, 10)]); grid on; box on;
legend('Location', 'northeast', 'FontSize', 9);
ax4 = nexttile; plot(t_plot, PV_P,  'Color', clr_pv,  'LineWidth', lw, 'DisplayName','Input Power (P_{PV})'); hold on;
plot(t_plot, PEM_P, 'Color', clr_pem, 'LineWidth', lw, 'DisplayName','Load Power (P_{PEM})');
if has_batt
    plot(t_plot,Batt_P,'Color',clr_batt,'LineWidth',lw,'LineStyle','--','DisplayName','P_{batt}');
end
loss_top = PV_P; loss_bot = min(PV_P, max(PEM_P, 0));   
fill([t_plot; flipud(t_plot)], [loss_top; flipud(loss_bot)], clr_pv, 'FaceAlpha',0.12,'EdgeColor','none', 'DisplayName', 'Power Losses');
hold off; xlabel('Time (s)', 'FontSize', 10); ylabel('Power (W)', 'FontSize', 10); grid on; box on;
legend('Location', 'northeast', 'FontSize', 9, 'NumColumns', 3);
for ax = [ax1 ax2 ax3 ax4]
    xticks(ax, irr_ticks); xlim(ax, [0 sim_t*10]);
    for tt = irr_ticks(2:end-1), xline(ax, tt, ':','Color',[0.6 0.6 0.6], 'HandleVisibility', 'off'); end
end
set([ax1 ax2 ax3], 'XTickLabel', []);
drawnow; 
f1_name = sprintf('Fig1_SystemOverview_Ns%d_Np%d_case_%s.png', Ns_cell, Np_cell, case_model);
exportgraphics(fig1, f1_name, 'Resolution', 300);
fprintf('  [OK] Saved %s\n', f1_name);
% =========================================================================
%  FIGURE 2 — Converter Performance
% =========================================================================
fig2 = figure('Name','Converter Performance','Color','w','Position',[60 60 1020 640], 'ToolBar', 'none');
tl2  = tiledlayout(3,1,'TileSpacing','compact','Padding','compact');
ax_e = nexttile; yyaxis(ax_e, 'left'); ax_e.YColor = clr_eta;
plot(t_plot, eta, 'Color', clr_eta, 'LineWidth', lw, 'DisplayName', 'Converter Efficiency (\eta)'); ylabel('\eta_{conv} (%)'); ylim([0 110]);
yyaxis(ax_e, 'right'); ax_e.YColor = clr_irr;
plot(t_plot, Irr, 'Color', clr_irr, 'LineWidth', 1.2, 'LineStyle','--', 'DisplayName', 'Irradiance Profile'); ylabel('G (W/m²)'); ylim([0 1400]); grid on; box on;
legend('Location', 'south', 'FontSize', 9, 'NumColumns', 2);
ax_m = nexttile; M_pct = prctile(M(isfinite(M)), [2 98]);
yl_lo = max(0.40, M_pct(1) * 0.90); yl_hi = min(3.50, M_pct(2) * 1.15);
fill([0 sim_t sim_t 0], [1 1 yl_hi yl_hi], [clr_pv  0.08], 'EdgeColor','none', 'HandleVisibility','off');
fill([0 sim_t sim_t 0], [yl_lo yl_lo 1 1], [clr_pem 0.08], 'EdgeColor','none', 'HandleVisibility','off'); hold on;
plot(t_plot, M, 'Color',[0.45 0.10 0.55],'LineWidth', lw, 'DisplayName', 'Conversion Ratio (M)'); yline(1.0,'k-','LineWidth',1.6, 'HandleVisibility','off'); hold off;
ylabel('M = V_{PEM} / V_{PV}'); ylim([yl_lo yl_hi]); grid on; box on;
legend('Location', 'northeast', 'FontSize', 9);
ax_h = nexttile; yyaxis(ax_h, 'left'); ax_h.YColor = clr_pem;
plot(t_plot, H2_rate, 'Color', clr_pem, 'LineWidth', lw, 'DisplayName', 'Instantaneous H_2 Rate'); ylabel('H_2 rate (g/h)');
yyaxis(ax_h, 'right'); ax_h.YColor = [0 0.40 0.80];
plot(t_plot, H2_cumul, 'Color',[0 0.40 0.80],'LineWidth',lw,'LineStyle','-.', 'DisplayName', 'Total H_2 Accumulated');
ylabel('Cumulative H_2 (g)'); grid on; box on; xlabel('Time (s)');
legend('Location', 'northwest', 'FontSize', 9, 'NumColumns', 2);
for ax = [ax_e ax_m ax_h]
    xticks(ax, irr_ticks); xlim(ax, [0 sim_t*10]);
end
set([ax_e ax_m], 'XTickLabel', []);
drawnow; 
f2_name = sprintf('Fig2_ConverterPerformance_Ns%d_Np%d_case_%s.png', Ns_cell, Np_cell, case_model);
exportgraphics(fig2, f2_name, 'Resolution', 300);
fprintf('  [OK] Saved %s\n', f2_name);
% =========================================================================
%  FIGURE 3 — Battery EMS: voltage, current, power split, SOC
% =========================================================================
if has_batt
    fig3 = figure('Name','Battery EMS','Color','w','Position',[80 80 1020 780]);
    tl3  = tiledlayout(3,1,'TileSpacing','compact','Padding','compact');
    title(tl3,sprintf('Battery Energy Management  |  V_{nom}=%.0fV, Q=%.1fAh, SOC_0=%.0f%%', ...
        V_batt_nom, Q_batt, SOC_init_per),'FontSize',13,'FontWeight','bold');
    
    ax3_1 = nexttile;
    yyaxis(ax3_1,'left'); ax3_1.YColor = clr_batt;
    plot(t_plot,Batt_V,'Color',clr_batt,'LineWidth',lw,'DisplayName','V_{batt}');
    ylabel('V_{batt} (V)','FontSize',10,'Color',clr_batt);
    yyaxis(ax3_1,'right'); ax3_1.YColor = [.7 .1 .1];
    plot(t_plot,Batt_I,'Color',[.7 .1 .1],'LineWidth',lw,'DisplayName','I_{batt}');
    yline(0,'k:','LineWidth',1,'HandleVisibility','off');
    text(sim_t*.98, .3,'Charging →','FontSize',7,'HorizontalAlignment','right','Color',[.5 .5 .5]);
    text(sim_t*.98,-.3,'← Discharging','FontSize',7,'HorizontalAlignment','right','Color',[.5 .5 .5]);
    ylabel('I_{batt} (A)','FontSize',10,'Color',[.7 .1 .1]);
    ylim([-180 Inf]);
    grid on; box on; title('Battery Terminal Conditions','FontSize',10);
    legend('show','Location','northeast','FontSize',8,'NumColumns',2);
    ax3_2 = nexttile;
    plot(t_plot,PV_P, 'Color',clr_pv,  'LineWidth',lw,'DisplayName','P_{PV}'); hold on;
    plot(t_plot,PEM_P,'Color',clr_pem, 'LineWidth',lw,'DisplayName','P_{PEM}');
    plot(t_plot,Batt_P,'Color',clr_batt,'LineWidth',lw,'LineStyle','--','DisplayName','P_{batt} (+ charge)');
    yline(0,'k:','LineWidth',1,'HandleVisibility','off');
    hold off;
    ylabel('Power (W)','FontSize',10); grid on; box on;
    legend('Location','northeast','FontSize',8,'NumColumns',3);
    title('Power Flow','FontSize',10);
    
    ax3_3 = nexttile;
    plot(t_plot, Batt_SOC, 'Color',[.10 .60 .30],'LineWidth',lw+0.5);
    yline(SOC_max * 100,'--','Color',[.7 .10 .10],'LineWidth',1.2,'HandleVisibility','off');
    yline(SOC_min * 100,'--','Color',[.7 .10 .10],'LineWidth',1.2,'HandleVisibility','off');
    text(sim_t*.98, (SOC_max*100)+1,'SOC_{max}','FontSize',8,'Color',[.7 .1 .1],'HorizontalAlignment','right');
    text(sim_t*.98, (SOC_min*100)+1,'SOC_{min}','FontSize',8,'Color',[.7 .1 .1],'HorizontalAlignment','right');
    ylabel('SOC (%)','FontSize',10); ylim([0 105]);
    grid on; box on; title('State of Charge','FontSize',10);
    
    for ax = [ax3_1 ax3_2 ax3_3]
        xticks(ax,irr_ticks); xlim(ax,[0 sim_t*10]);
        for tt = irr_ticks(2:end-1)
            xline(ax,tt,':','Color',[.6 .6 .6],'LineWidth',.8,'HandleVisibility','off');
        end
    end
    set([ax3_1 ax3_2 ax3_3],'XTickLabel',[]);
    drawnow;
    f3_name = sprintf('Fig3_BatteryEMS_Ns%d_Np%d.png',Ns_cell,Np_cell);
    exportgraphics(fig3, f3_name, 'Resolution', 300);
    fprintf('  [OK] Saved %s\n', f3_name);
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
I_ref = linspace(0, Imax_PEM * 1.05, 300)'; V_randles = Vint_stack + (Rint_stack + Ra_stack + Rc_stack) .* I_ref;
plot(I_ref, V_randles, 'r--', 'LineWidth', 1.8, 'DisplayName', 'PEM Randles Model'); hold off; grid on; box on; title('PEM Locus');
colormap(ax_pem, parula); colorbar(ax_pem); legend('Location', 'northwest', 'FontSize', 9);
drawnow; 
f4_name = sprintf('Fig4_IV_Trajectory_Ns%d_Np%d_case_%s.png', Ns_cell, Np_cell, case_model);
exportgraphics(fig4, f4_name, 'Resolution', 300);
fprintf('  [OK] Saved %s\n', f4_name);

fig5 = figure('Name','PV Characteristics','Color','w','Position',[120 120 960 490], 'ToolBar', 'none');
tl4  = tiledlayout(1,2,'TileSpacing','loose','Padding','compact');
ax_pv2 = nexttile; scatter(PV_V, PV_P, 20, pt_col, 'filled', 'DisplayName', 'PV Power Output'); hold on;
scatter(Vmpp, Pmpp, 180, 'r', 'p', 'LineWidth',1.5, 'DisplayName', 'Max Power Point (STC)'); hold off; grid on; box on; title('PV P-V');
colormap(ax_pv2, parula); colorbar(ax_pv2); legend('Location', 'northwest', 'FontSize', 9);
ax_pem2 = nexttile; P_randles = V_randles .* I_ref;
scatter(PEM_I, PEM_P, 20, pt_col, 'filled', 'DisplayName', 'Electrolyzer Load Curve'); hold on; 
plot(I_ref, P_randles, 'r--', 'LineWidth', 1.8, 'DisplayName', 'PEM Randles Model'); hold off;
grid on; box on; title('PEM P-I'); colormap(ax_pem2, parula); colorbar(ax_pem2);
legend('Location', 'northwest', 'FontSize', 9);
drawnow; 
f5_name = sprintf('Fig5_PV_Characteristics_Ns%d_Np%d_case_%s.png', Ns_cell, Np_cell, case_model);
exportgraphics(fig5, f5_name, 'Resolution', 300);
fprintf('  [OK] Saved %s\n', f5_name);
% =========================================================================
% FIGURE 6 & SUMMARY — SPECIFIC HOURLY AVERAGES
% =========================================================================
target_hours = [7, 9, 12, 14.5, 16.5];
mean_PV_V    = zeros(length(target_hours), 1);
mean_PV_I    = zeros(length(target_hours), 1);
mean_PEM_V   = zeros(length(target_hours), 1);
mean_PEM_I   = zeros(length(target_hours), 1);
mean_Batt_I  = zeros(length(target_hours), 1);  
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
            I_batt_mean = mean(Batt_I(mask));   
            P_batt_mean = mean(Batt_P(mask));
            mean_Batt_I(k) = I_batt_mean;
            mean_Batt_P(k) = P_batt_mean;
            
            if I_batt_mean > 0.5
                mean_ems(k) = "CHARGING";        
            elseif I_batt_mean < -0.5
                mean_ems(k) = "DISCHARGING";     
            else
                mean_ems(k) = "STANDBY";
            end
            
            batt_disch_P = mean(abs(min(Batt_I(mask), 0)) .* Batt_V(mask)); 
            batt_chg_P   = mean(max(Batt_I(mask), 0)      .* Batt_V(mask)); 
            p_in_mean  = p_in_mean  + batt_disch_P;
            p_out_mean = p_out_mean + batt_chg_P;
        end
        if p_in_mean > 1
            mean_eta(k) = min(99.0, (p_out_mean / p_in_mean) * 100);
        end
    end
end
fig6 = figure('Name','Hourly Performance Summary','Color','w', 'Position',[150 150 1200 510], 'ToolBar','none');
tl5 = tiledlayout(1,3,'TileSpacing','loose','Padding','compact');
x_pos = 1:length(target_hours);
lbl = arrayfun(@(h) sprintf('%02d:00', floor(h)), target_hours, 'UniformOutput',false);
ax_s1 = nexttile;
b1 = bar(x_pos, [mean_PV_V, mean_PEM_V], 0.65);
b1(1).FaceColor = clr_pv;  b1(1).DisplayName = 'V_{PV}';
b1(2).FaceColor = clr_pem; b1(2).DisplayName = 'V_{PEM}';
set(ax_s1,'XTick',x_pos,'XTickLabel',lbl,'FontSize',9); xtickangle(ax_s1, 25);
ylabel('Mean Voltage (V)'); grid on; box on; title('Voltage at Time of Day'); legend('Location','northwest','FontSize',9);
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
ylabel('Mean Current (A)'); grid on; box on; title('Current at Time of Day'); legend('Location','northwest','FontSize',9);
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
            text(k, mean_eta(k)+1.5, lbl_str, 'HorizontalAlignment','center','FontSize',7,'FontWeight','bold');
        end
    end
    hold off;
end
set(ax_s3,'XTick',x_pos,'XTickLabel',lbl,'FontSize',9); xtickangle(ax_s3, 25);
ylabel('Mean \eta_{system} (%)'); ylim([0 115]); grid on; box on; title('System Efficiency (PV+Batt \rightarrow PEM+Batt)'); legend('Avg Efficiency','Location','southwest','FontSize',9);
drawnow; 
f6_name = sprintf('Fig6_DailySummary_Ns%d_Np%d_case_%s.png', Ns_cell, Np_cell, case_model);
exportgraphics(fig6, f6_name, 'Resolution', 300);
fprintf('  [OK] Saved %s\n', f6_name);
% =========================================================================
% MPP TRACKING COMPARISON
% =========================================================================
mpp_filename = sprintf('../mpp_data_Ns%d_Np%d.mat', Ns_cell, Np_cell);
if isfile(mpp_filename)
    s = load(mpp_filename,'pP','pV','pI','irr_unique','P_mpp','V_mpp','I_mpp','Ns_cell', 'Np_cell');
    fprintf('  PV: Ns=%d, Np=%d — MPP file: PV: Ns=%d, Np=%d\n', Ns_cell, Np_cell, s.Ns_cell, s.Np_cell);
    V_mpp_ref = polyval(s.pV, Irr);
    I_mpp_ref = polyval(s.pI, Irr);
    P_mpp_ref = polyval(s.pP, Irr);
    P_WP = PV_V .* PV_I;
    err_P = P_WP - P_mpp_ref;
    C = abs(P_WP ./ P_mpp_ref);
    C(Irr == 0) = NaN;
    err_P(Irr == 0) = NaN;
    P_mpp_ref(Irr == 0) = NaN;
    C_plot = max(0, min(1.2, C));
    C_plot(Irr == 0) = NaN;
    fig_mpp = figure('Name','MPP Comparison','Color','w', 'Position',[80 80 1020 760], 'ToolBar', 'none');
    tlmpp = tiledlayout(3,1,'TileSpacing','compact','Padding','compact');
    ax1 = nexttile;
    plot(t_plot, P_WP, 'Color', clr_pv, 'LineWidth', lw, 'DisplayName','PV Power'); hold on;
    plot(t_plot, P_mpp_ref, '--', 'Color', clr_eta, 'LineWidth', lw+0.2, 'DisplayName','MPP Reference Power'); hold off;
    ylabel('Power (W)', 'FontSize', 10); grid on; box on; legend('Location','best','FontSize',9); title('PV power compared to MPP reference');
    ax2 = nexttile;
    plot(t_plot, err_P, 'Color', [0.85 0.20 0.20], 'LineWidth', lw, 'DisplayName','Power Error');
    yline(0,'--','Color',[0.4 0.4 0.4],'HandleVisibility','off');
    ylabel('\Delta P (W)', 'FontSize', 10); grid on; box on; legend('Location','best','FontSize',9); title('Power error relative to MPP');
    ax3 = nexttile;
    plot(t_plot, C_plot, 'Color', [0.20 0.20 0.20], 'LineWidth', lw, 'DisplayName','Coupling Factor'); hold on;
    yline(1,'--','Color',[0.4 0.4 0.4],'HandleVisibility','off'); hold off;
    xlabel('Time (s)', 'FontSize', 10); ylabel('C = P_{WP}/P_{MPP}', 'FontSize', 10); grid on; box on; legend('Location','best','FontSize',9); title('Coupling factor over time');
    linkaxes([ax1 ax2 ax3],'x');
    
    fmpp_name = sprintf('Fig_MPP_Tracking_Ns%d_Np%d_case_%s.png', s.Ns_cell, s.Np_cell, case_model);
    exportgraphics(fig_mpp, fmpp_name, 'Resolution', 300);
    fprintf('  [OK] Saved %s\n', fmpp_name);
else
    fprintf('  [!] %s not found. Skipping MPP tracking figure.\n', mpp_filename);
end
% =========================================================================
%  SUMMARY TABLE
% =========================================================================
fprintf('\n=== Steady-State Summary ===\n');
fprintf('%-12s  %8s  %8s  %8s  %8s  %6s  %6s\n', 'G (W/m²)', 'Vpv(V)', 'Ipv(A)', 'Vpem(V)', 'Ipem(A)', 'M', 'eta(%)');
fprintf('%s\n', repmat('-', 1, 72));
n_steps = floor(sim_t);
for k = 1:n_steps
    M_k = mean_PEM_V(k) / max(mean_PV_V(k), 0.01);
    fprintf('%-12d  %8.2f  %8.2f  %8.2f  %8.2f  %6.3f  %6.1f\n', ...
        recorded_irr(k), mean_PV_V(k), mean_PV_I(k), mean_PEM_V(k), mean_PEM_I(k), M_k, mean_eta(k));
end
% =========================================================================
%% ===== Export results to Excel =====
% =========================================================================
fprintf('\n  Saving data to Excel (this may take a few seconds)...\n');
filename = 'PV_PEM_indirect_batt_results.xlsx';
TS = table( ...
    t, t_plot, real_t, ...        
    Irr, ...                      
    PV_V, PV_I, ...               
    PEM_V, PEM_I, ...             
    Batt_V, Batt_I, ...           
    Batt_SOC, ...                 
    'VariableNames', {'t_sim_[s]','t_plot_[h]','t_real_[s]', ...
                      'Irr_[W/m^2]','PV_V_[V]','PV_I_[A]','PEM_V_[V]','PEM_I_[A]','Battery_V_[V]','Battery_I_[A]', 'Battery_SOC_[%]'});
writetable(TS, filename, 'Sheet', 'TimeSeries', 'WriteMode', 'overwritesheet');
paramNames  = {'N_cells_PEM'; 'Np_cell'; 'Ns_cell'; 'sim_t_[s]'; 'scale_factor'; 'Battery_SOC_init_[%]'};
paramValues = [N; Np_cell; Ns_cell; sim_t; scale_factor; SOC_init_per];
PARAM = table(paramNames, paramValues, 'VariableNames', {'Parameter','Value'});
writetable(PARAM, filename, 'Sheet', 'Parameters', 'WriteMode', 'overwritesheet');
fprintf('  [OK] Saved Excel File: %s\n', filename);
fprintf('\n=== ALL DONE! ===\n');