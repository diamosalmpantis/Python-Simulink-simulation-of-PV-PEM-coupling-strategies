% STREAMING_CHUNK:Initializing simulation environment and PEM parameters...
clear; clc; close all;
warning('off', 'all');
fprintf('=== PV-PEM Indirect Coupling — 340-Day Simulation ===\n\n');
 
% =========================================================================
%  SECTION 1 — PEM ELECTROLYZER PARAMETERS
% =========================================================================
N = 13;
 
Vint    = 1.475841;         % [V]
Rint    = 0.008673;         % [Ohm]
Ra      = 0.00177;          % [Ohm]
Rc      = 0.0005;           % [Ohm]
 
ratio_tau = 10;
tau_a   = 0.4;              % [s]
tau_c   = tau_a / ratio_tau;
Ca      = tau_a / Ra;       % [F]
Cc      = tau_c / Rc;       % [F]
Active_Area = 17.64;        % [cm²]
 
% STREAMING_CHUNK:Calculating PEM stack aggregates and limits...
Vint_stack = Vint * N;
Rint_stack = Rint * N;
Ra_stack   = Ra   * N;
Rc_stack   = Rc   * N;
Ca_stack   = Ca   / N;
Cc_stack   = Cc   / N;
 
Vmin_PEM = Vint * N;
Vmax_PEM = 2.0  * N;
Imin_PEM = 2.2;
Imax_PEM = 80;
 
fprintf('  PEM: %d cells | OCV = %.3f V | Vmin = %.1f V | Vmax = %.1f V\n', ...
    N, Vint_stack, Vmin_PEM, Vmax_PEM);
 
% =========================================================================
%  SECTION 2 — PV ARRAY PARAMETERS
% =========================================================================
% STREAMING_CHUNK:Setting up PV Array variables...
Im_PV = 9.59;
Vm_PV = 0.55;
 
Np_cell = 7;
Ns_cell = 45;
Isc     = 10.14 * Np_cell;
Voc     =  0.67 * Ns_cell;
Vmpp    = Vm_PV * Ns_cell;
Impp    = Im_PV * Np_cell;
Pmpp    = Vmpp  * Impp;
 
fprintf('  PV : Ns=%d, Np=%d | Vmpp=%.2f V | Impp=%.2f A | Pmpp=%.1f W\n\n', ...
    Ns_cell, Np_cell, Vmpp, Impp, Pmpp);
 
% =========================================================================
%  SECTION 3 — CONVERTER PARAMETERS
% =========================================================================
% STREAMING_CHUNK:Defining power converter properties...
Ts          = 1e-3;         % [s]   switching period  (fsw = 1 kHz)
Tsc         = 1e-5;         % [s]   Simscape local solver step
sample_output_time = 1e-2;  % [s]   data logging interval
 
Ron         = 0.01;         % [Ohm] MOSFET on-resistance
Conductance = 1e-6;         % [S]   MOSFET off-state leakage
Vth         = 0.5;          % [V]   MOSFET threshold voltage
Vforward    = 0.8;          % [V]   body diode forward voltage
 
L_conv      = 4e-4;         % [H]   filter inductance
C_conv      = 2.2e-4;       % [F]   filter capacitance
fn = 1 / (2*pi*sqrt(L_conv * C_conv));
 
fprintf('  Converter: fsw=%.0f Hz | Lf=%g H | Cf=%g F | fn=%.0f Hz\n\n', ...
    1/Ts, L_conv, C_conv, fn);
 
% =========================================================================
%  SECTION 4 — TIME & WEATHER DATA  (340 days, 1-min resolution)
% =========================================================================
% STREAMING_CHUNK:Loading and configuring environmental dataset...
scale_factor = 36000;
has_batt     = false;
 
% ---- Expected dataset properties ----------------------------------------
expected_rows   = 340 * 24 * 60;   % 489,600
excel_row_limit = 1048576;
 
fprintf('Dataset check:\n');
fprintf('  Expected rows  : %d\n',   expected_rows);
fprintf('  Excel row limit: %d\n',   excel_row_limit);
fprintf('  Rows available : %d\n\n', excel_row_limit - 1);
 
if isfile('weather_profile_week.xlsx')
    fprintf('Loading weather_profile_week.xlsx ...\n');
    weather       = readtable('weather_profile_week.xlsx');
    real_time_sec = weather.Time_min * 60;
    Irr_val       = weather.Irradiance;
    Temp_val      = weather.Temperature;
    fprintf('  Loaded %d rows (%.1f days at 1-min resolution)\n\n', ...
        height(weather), height(weather)/1440);
else
    fprintf('[!] weather_profile_week.xlsx not found — generating 340-day mock.\n');
    real_time_sec = (0 : 60 : 3*86400)';
    day_of_year   = real_time_sec / 86400;
    time_of_day   = mod(real_time_sec, 86400);
    seasonal_env  = 700 + 300 * sin(2*pi*(day_of_year - 80) / 365);
    Irr_val = seasonal_env .* max(sin(pi * time_of_day / 86400), 0) ...
              .* (0.85 + 0.15 * rand(size(real_time_sec)));
    Irr_val(time_of_day < 3600*6 | time_of_day > 3600*20) = 0;
    Temp_val = 15 + 15*sin(2*pi*(day_of_year-80)/365) ...
             +  8*max(sin(pi*time_of_day/86400), 0);
end
 
% STREAMING_CHUNK:Applying data smoothing and interpolation...
% -----------------------------------------------------------------
%  FIX 1 — SMOOTH IRRADIANCE (3-point moving average)
%  Removes minute-to-minute step discontinuities that cause the
%  Ra capacitor state derivative to become non-finite.
% -----------------------------------------------------------------
Irr_val  = movmean(Irr_val,  3);
Temp_val = movmean(Temp_val, 3);
Irr_val  = max(Irr_val,  0);
Temp_val = max(Temp_val, -50);
 
Irr_time = real_time_sec / scale_factor;
sim_t    = max(Irr_time);
 
fprintf('Simulation horizon:\n');
fprintf('  Real duration : %.1f days\n',  sim_t * scale_factor / 86400);
fprintf('  Sim-time span : %.4f s\n\n',   sim_t);
 
% -----------------------------------------------------------------
%  FIX 2 — ZERO-ORDER HOLD INTERPOLATION
%  'previous' avoids ramp artefacts that the Simscape solver
%  must differentiate, amplifying numerical noise near large steps.
% -----------------------------------------------------------------
Irr_stair_tsamp = 60 / scale_factor;
Irr_stair_time  = (0 : Irr_stair_tsamp : sim_t)';
Irr_stair_val   = interp1(Irr_time, Irr_val,  Irr_stair_time, 'previous', 0);
Temp_stair_val  = interp1(Irr_time, Temp_val, Irr_stair_time, 'previous', 25);
 
assignin('base', 'sample_output_time', sample_output_time);
assignin('base', 'Tsc',                Tsc);
 
% =========================================================================
%  SECTION 5 — MODEL COPY & BLOCK OVERRIDES
% =========================================================================
% STREAMING_CHUNK:Configuring Simulink model and block parameters...
case_model = 'D';
mdl_orig   = 'PV_PEM_indirect';
mdl_fixed  = 'PV_PEM_indirect_FIXED';
 
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
% STREAMING_CHUNK:Iterating through Simulink blocks to inject overrides...
for i = 1:length(blocks)
    b      = blocks{i};
    b_name = ''; b_type = '';
    try b_name = get_param(b, 'Name');      catch; end
    try b_type = get_param(b, 'BlockType'); catch; end
 
    % Safety shield: never modify Constant block values
    if strcmp(b_type, 'Constant')
        try set_param(b, 'OutMax', '[]'); catch; end
        continue;
    end
 
    % Irradiance source injection
    if contains(b_name, 'Irradiance', 'IgnoreCase', true)
        try set_param(b, 'rep_seq_t',  'Irr_time');        catch; end
        try set_param(b, 'rep_seq_y',  'Irr_val');         catch; end
        try set_param(b, 'OutValues',  'Irr_stair_val');   catch; end
        try set_param(b, 'samp_time',  'Irr_stair_tsamp'); catch; end
    end
 
    % Temperature source injection
    if contains(b_name, 'Temperature', 'IgnoreCase', true) || ...
       contains(b_name, 'Temp',        'IgnoreCase', true)
        try set_param(b, 'rep_seq_t',  'Irr_time');         catch; end
        try set_param(b, 'rep_seq_y',  'Temp_val');         catch; end
        try set_param(b, 'OutValues',  'Temp_stair_val');   catch; end
        try set_param(b, 'samp_time',  'Irr_stair_tsamp');  catch; end
    end
 
    % -----------------------------------------------------------------
    %  FIX 3 — PS CONVERTER FILTER TIME CONSTANT = tau_a/100 = 4 ms
    %  The original 1e-3 s filter is acceptable here (closer to tau_a
    %  than in the direct script), but we tighten it to tau_a/100 for
    %  consistency and to prevent near-impulsive inputs on large steps.
    % -----------------------------------------------------------------
    try
        ref = get_param(b, 'ReferenceBlock');
        if contains(ref, 'Simulink-PS Converter') || ...
           contains(ref, 'PS-Simulink Converter')
            set_param(b, 'FilteringAndDerivatives', 'filter');
            set_param(b, 'InputFilterTimeConstant',  num2str(tau_a / 100));
        end
    catch; end
 
    % MPPT controller and saturation limits
    if contains(b_name, 'Control', 'IgnoreCase', true) || ...
       contains(b_name, 'MPPT_Control') || strcmp(b_type, 'Saturation')
        try set_param(b, 'UpperSaturationLimit', '0.60'); catch; end
        try set_param(b, 'upperLimit',           '0.60'); catch; end
        try set_param(b, 'OutMax',               '0.60'); catch; end
        try set_param(b, 'UpperLimit',           '0.60'); catch; end
        try set_param(b, 'P',  '0.01'); catch; end
        try set_param(b, 'Kp', '0.01'); catch; end
        try set_param(b, 'I',  '10.0'); catch; end
        try set_param(b, 'Ki', '10.0'); catch; end
    end
 
    % Diode reverse recovery
    if contains(b_name, 'Buck-Boost') || contains(b_name, 'Diode')
        try set_param(b, 'diode_iRM', '5');   catch; end
        try set_param(b, 'diode_trr', '0.5'); catch; end
    end
 
    % Current sensors: enforce Ampere output
    if contains(b_name, 'Current', 'IgnoreCase', true) || ...
       contains(b_name, 'Ammeter', 'IgnoreCase', true)
        try set_param(b, 'i_unit', 'A'); catch; end
    end
 
    % Solver Configuration
    if contains(b_name, 'Solver Configuration')
        try
            set_param(b, 'UseLocalSolver',        'on');
            set_param(b, 'LocalSolverSampleTime',  'Tsc');
            set_param(b, 'LocalSolverType',        'Backward Euler');
        catch; end
    end
 
    % -----------------------------------------------------------------
    %  FIX 4 — SCOPE BUFFER SIZED FOR 340-DAY DATASET
    %  489,600 samples expected; buffer = 520,000 (6% margin).
    % -----------------------------------------------------------------
    if strcmp(b_type, 'Scope')
        try
            set_param(b, 'DataLogging',     'off');
            set_param(b, 'MaxDataPoints',   '520000');
            set_param(b, 'LimitDataPoints', 'on');
            set_param(b, 'SaveToWorkspace', 'off');
        catch; end
    end
end
fprintf('  [OK] MPPT PI tuning and duty-cycle clamping applied.\n');
 
% STREAMING_CHUNK:Finalizing solver parameters and running simulation...
% -----------------------------------------------------------------
%  FIX 5 — TIGHTENED SOLVER SETTINGS
%  RelTol/AbsTol tightened; MaxStep tied to input sample period.
%  NormControl is NOT a valid set_param key and is omitted.
% -----------------------------------------------------------------
set_param(mdl, 'StopTime',       num2str(sim_t));
set_param(mdl, 'Solver',         'ode15s');
set_param(mdl, 'RelTol',         '1e-5');
set_param(mdl, 'AbsTol',         '1e-7');
set_param(mdl, 'MaxStep',        num2str(Irr_stair_tsamp / 10));
set_param(mdl, 'SimulationMode', 'accelerator');
try set_param(mdl, 'SimscapeExplicitSolverDiagnostic', 'none'); catch; end
 
save_system(mdl);
fprintf('  Saved %s\n\n', [mdl_fixed '.slx']);
 
% =========================================================================
%  SECTION 6 — RUN SIMULATION
% =========================================================================
fprintf('Running simulation...\n');
fprintf('  Sim-time : %.4f s  |  Real-time : %.1f days\n\n', ...
    sim_t, sim_t * scale_factor / 86400);
 
open_system(mdl);
solve_timer    = tic;
out            = sim(mdl);
solve_time_sec = toc(solve_timer);
 
fprintf('Simulation complete. Solver time: %.2f s\n\n', solve_time_sec);
 
% STREAMING_CHUNK:Processing simulation output arrays and efficiencies...
% =========================================================================
%  SECTION 7 — POST-PROCESSING
% =========================================================================
t      = out.PV_V.Time;
t_plot = (t * scale_factor) / 3600;   % [h]  real-world hours
real_t =  t * scale_factor;           % [s]  real-world seconds
 
PV_V  = max(out.PV_V.Data,  0);
PV_I  = max(out.PV_I.Data,  0);
PEM_V = max(out.PEM_V.Data, 0);
PEM_I = max(out.PEM_I.Data, 0);
Irr   = max(out.Irr.Data,   0);
 
if max(PEM_I) > 500, PEM_I = PEM_I / 1000; end
if max(PV_I)  > 500, PV_I  = PV_I  / 1000; end
 
PV_P  = PV_V  .* PV_I;
PEM_P = PEM_V .* PEM_I;
 
valid_pwr         = PV_P > 70;
eta_raw           = nan(size(PV_P));
eta_raw(valid_pwr)= (PEM_P(valid_pwr) ./ PV_P(valid_pwr)) * 100;
eta_raw(eta_raw > 99.5) = 99.5;
eta               = movmean(eta_raw, 100, 'omitnan');
 
M           = nan(size(PV_V));
M(valid_pwr)= PEM_V(valid_pwr) ./ PV_V(valid_pwr);
 
% STREAMING_CHUNK:Calculating total Hydrogen yield...
F_const     = 96485;
eta_F       = 0.99;
M_H2        = 2.016e-3;
n_H2        = PEM_I / (2 * F_const) * eta_F;
n_H2(Irr < 70)   = 0;                                % Night / sub-threshold cutoff
H2_rate     = n_H2 * M_H2 * 3600 * 1e3;
H2_inst_g_s = n_H2 * M_H2 * 1e3;
H2_cumul    = cumtrapz(real_t, H2_inst_g_s);

% Conditional statistics (irradiance threshold > 70 W/m²)
active_mask    = Irr > 70;
avg_eta_active = mean(eta(active_mask), 'omitnan');
%avg_C_active   = mean(C(active_mask),   'omitnan');

fprintf('=== Simulation Summary ===\n');
fprintf('  PV peak power              : %.1f W\n',   max(PV_P));
fprintf('  PEM peak power             : %.1f W\n',   max(PEM_P));
fprintf('  Mean η (G > 70 W)           : %.1f %%\n', mean(eta(valid_pwr),'omitnan'));
fprintf('  Peak H2 rate               : %.2f g/h\n', max(H2_rate));
fprintf('  Total H2 produced          : %.4f g\n',   H2_cumul(end));
fprintf('  Total H2 produced          : %.4f kg\n\n',H2_cumul(end));

 
% =========================================================================
%  SECTION 8 — FIGURES
% =========================================================================
% STREAMING_CHUNK:Generating energy chain and converter performance plots...
clr_pv   = [0.85, 0.33, 0.10];
clr_pem  = [0.13, 0.47, 0.71];
clr_irr  = [0.93, 0.69, 0.13];
clr_eta  = [0.18, 0.55, 0.18];
lw = 1.8;
 
% --- Figure 1: Energy Chain ---
fig1 = figure('Name','System Overview','Color','w','Position',[30 30 1020 760],'ToolBar','none');
tiledlayout(4,1,'TileSpacing','compact','Padding','compact');
 
ax1 = nexttile;
plot(t_plot, Irr,'Color',clr_irr,'LineWidth',lw+0.4,'DisplayName','Irradiance');
ylabel('G (W/m²)'); ylim([0 max(max(Irr)*1.1,1000)]);
grid on; box on; legend('Location','northeast','FontSize',9);
 
ax2 = nexttile;
plot(t_plot, PV_V, 'Color',clr_pv, 'LineWidth',lw+1.5,'DisplayName','V_{PV}'); hold on;
plot(t_plot, PEM_V,'Color',clr_pem,'LineWidth',lw,'LineStyle','--','DisplayName','V_{PEM}');
yline(Vmax_PEM,'--','Color',[0.5 0.5 0.5],'HandleVisibility','off');
yline(Vmin_PEM,':','Color',[0.5 0.5 0.5],'HandleVisibility','off');
hold off; ylabel('Voltage (V)');
ylim([max(0,Vmin_PEM*0.8) max(Voc,Vmax_PEM)*1.05]);
grid on; box on; legend('Location','east','FontSize',9);
 
ax3 = nexttile;
plot(t_plot, PV_I, 'Color',clr_pv, 'LineWidth',lw+1.5,'DisplayName','I_{PV}'); hold on;
plot(t_plot, PEM_I,'Color',clr_pem,'LineWidth',lw,'LineStyle','--','DisplayName','I_{PEM}');
yline(Imax_PEM,'--','Color',[0.5 0.5 0.5],'HandleVisibility','off');
hold off; ylabel('Current (A)');
ylim([0 max([max(PV_I),max(PEM_I)])*1.2+1e-3]);
grid on; box on; legend('Location','northeast','FontSize',9);
 
ax4 = nexttile;
plot(t_plot, PV_P, 'Color',clr_pv, 'LineWidth',lw+1.5,'DisplayName','P_{PV}'); hold on;
plot(t_plot, PEM_P,'Color',clr_pem,'LineWidth',lw,'LineStyle','--','DisplayName','P_{PEM}');
loss_top = PV_P; loss_bot = min(PV_P, max(PEM_P,0));
fill([t_plot; flipud(t_plot)],[loss_top; flipud(loss_bot)], ...
    clr_pv,'FaceAlpha',0.12,'EdgeColor','none','DisplayName','Power Losses');
hold off; xlabel('Time (h)'); ylabel('Power (W)');
ylim([0 max([max(PV_P),max(PEM_P)])*1.2+1e-3]);
grid on; box on; legend('Location','northeast','FontSize',9,'NumColumns',3);
 
linkaxes([ax1 ax2 ax3 ax4],'x'); xlim(ax4,[0 max(t_plot)]);
set([ax1 ax2 ax3],'XTickLabel',[]);
drawnow;
exportgraphics(fig1,sprintf('Fig1_SystemOverview_Ns%d_Np%d_case_%s.png', ...
    Ns_cell,Np_cell,case_model),'Resolution',300);
 
% STREAMING_CHUNK:Plotting PV vs PEM voltages and H2 accumulations...
% --- Figure 2: Converter Performance ---
fig2 = figure('Name','Converter Performance','Color','w','Position',[60 60 1020 640],'ToolBar','none');
tiledlayout(3,1,'TileSpacing','compact','Padding','compact');
 
ax_e = nexttile;
yyaxis(ax_e,'left'); ax_e.YColor = clr_eta;
plot(t_plot, eta,'Color',clr_eta,'LineWidth',lw,'DisplayName','η_{conv}');
ylabel('η_{conv} (%)'); ylim([0 110]);
yyaxis(ax_e,'right'); ax_e.YColor = clr_irr;
plot(t_plot, Irr,'Color',clr_irr,'LineWidth',1.2,'LineStyle','--','DisplayName','Irradiance');
ylabel('G (W/m²)'); ylim([0 max(max(Irr)*1.1,1000)]);
grid on; box on; legend('Location','south','FontSize',9,'NumColumns',2);
 
ax_m = nexttile;
M_pct = prctile(M(valid_pwr),[2 98]);
if isempty(M_pct)||isnan(M_pct(1)), M_pct=[0.8 1.2]; end
yl_lo = max(0.5,M_pct(1)*0.95); yl_hi = min(3.0,M_pct(2)*1.05);
fill([0 max(t_plot) max(t_plot) 0],[1 1 yl_hi yl_hi], ...
    [clr_pv  0.08],'EdgeColor','none','HandleVisibility','off');
fill([0 max(t_plot) max(t_plot) 0],[yl_lo yl_lo 1 1], ...
    [clr_pem 0.08],'EdgeColor','none','HandleVisibility','off'); hold on;
plot(t_plot, M,'Color',[0.45 0.10 0.55],'LineWidth',lw,'DisplayName','M = V_{PEM}/V_{PV}');
yline(1.0,'k-','LineWidth',1.6,'HandleVisibility','off'); hold off;
ylabel('M = V_{PEM}/V_{PV}'); ylim([yl_lo yl_hi]);
grid on; box on; legend('Location','northeast','FontSize',9);
 
ax_h = nexttile;
yyaxis(ax_h,'left'); ax_h.YColor = clr_pem;
plot(t_plot, H2_rate,'Color',clr_pem,'LineWidth',lw,'DisplayName','Instantaneous H_2 Rate');
ylabel('H_2 rate (g/h)'); ylim([0 max(max(H2_rate)*1.15,1)]);
yyaxis(ax_h,'right'); ax_h.YColor = [0 0.40 0.80];
plot(t_plot, H2_cumul,'Color',[0 0.40 0.80],'LineWidth',lw,'LineStyle','-.','DisplayName','Cumulative H_2');
ylabel('Cumulative H_2 (g)');
grid on; box on; xlabel('Time (h)');
legend('Location','northwest','FontSize',9,'NumColumns',2);
 
linkaxes([ax_e ax_m ax_h],'x'); xlim(ax_h,[0 max(t_plot)]);
set([ax_e ax_m],'XTickLabel',[]);
drawnow;
exportgraphics(fig2,sprintf('Fig2_ConverterPerformance_Ns%d_Np%d_case_%s.png', ...
    Ns_cell,Np_cell,case_model),'Resolution',300);
 
% STREAMING_CHUNK:Loading Maximum Power Point mapping details...
% =========================================================================
%  SECTION 9 — MPP REFERENCE
% =========================================================================
mpp_filename = sprintf('../mpp_data_Ns%d_Np%d.mat', Ns_cell, Np_cell);
try
    s         = load(mpp_filename,'pP','pV','pI','Ns_cell','Np_cell');
    V_mpp_ref = polyval(s.pV, Irr);
    I_mpp_ref = polyval(s.pI, Irr);
    P_mpp_ref = polyval(s.pP, Irr);
    fprintf('  Loaded MPP file: Ns=%d, Np=%d\n', s.Ns_cell, s.Np_cell);
catch
    fprintf('  MPP file not found — using analytical STC approximation.\n');
    s.Ns_cell = Ns_cell; s.Np_cell = Np_cell;
    G_ratio   = Irr / 1000;
    V_mpp_ref = Vmpp * (1 + 0.02 * log(max(G_ratio, 1e-3)));
    V_mpp_ref(Irr < 10) = 0;
    I_mpp_ref = Impp .* G_ratio;
    P_mpp_ref = V_mpp_ref .* I_mpp_ref;
end
 
P_WP  = PV_V .* PV_I;
err_P = P_WP - P_mpp_ref;
C     = abs(P_WP ./ max(P_mpp_ref, 1e-6));
C(Irr < 10)     = NaN;
err_P(Irr < 10) = NaN;
P_mpp_ref(Irr < 10) = NaN;
C_plot = max(0,min(1.2,C)); C_plot(Irr < 10) = NaN;
 
% STREAMING_CHUNK:Plotting PV Loci and scatter data maps...
% --- Figure 4: I-V Trajectories ---
fig4 = figure('Name','I-V Trajectory','Color','w','Position',[90 90 960 490],'ToolBar','none');
tiledlayout(1,2,'TileSpacing','loose','Padding','compact');
 
ax_pv = nexttile;
scatter(PV_I,PV_V,10,Irr,'filled','MarkerFaceAlpha',0.8,'DisplayName','PV Trajectory'); hold on;
scatter(I_mpp_ref(Irr>10),V_mpp_ref(Irr>10),8,[0.4 0.8 0.4],'filled','DisplayName','MPP Locus');
scatter(Impp,Vmpp,180,'r','p','LineWidth',1.5,'DisplayName','STC MPP');
hold off; grid on; box on; title('PV Array I-V Locus');
colormap(ax_pv,parula); cb1 = colorbar(ax_pv);
cb1.Label.String = 'Irradiance (W/m²)'; clim(ax_pv,[0 max(max(Irr),10)]);
legend('Location','southwest','FontSize',9);
xlim(ax_pv,[0 Isc*1.05]); ylim(ax_pv,[0 Voc*1.1]);
 
ax_pem = nexttile;
scatter(PEM_I,PEM_V,10,Irr,'filled','MarkerFaceAlpha',0.8,'DisplayName','PEM Trajectory'); hold on;
I_ref     = linspace(0, ceil(max(PEM_I))*1.05, 300)';
V_randles = Vint_stack + (Rint_stack + Ra_stack + Rc_stack) .* I_ref;
plot(I_ref,V_randles,'r--','LineWidth',1.8,'DisplayName','Randles Model');
hold off; grid on; box on; title('PEM I-V Locus');
colormap(ax_pem,parula); cb2 = colorbar(ax_pem);
cb2.Label.String = 'Irradiance (W/m²)'; clim(ax_pem,[0 max(max(Irr),10)]);
legend('Location','northwest','FontSize',9);
xlim(ax_pem,[0 max(Imax_PEM,max(PEM_I))*1.1]);
ylim(ax_pem,[Vmin_PEM*0.9 Vmax_PEM*1.1]);
drawnow;
exportgraphics(fig4,sprintf('Fig4_IV_Trajectory_Ns%d_Np%d_case_%s.png', ...
    Ns_cell,Np_cell,case_model),'Resolution',300);
 
% --- Figure 5: P-V & P-V (PEM) ---
fig5 = figure('Name','PV Characteristics','Color','w','Position',[120 120 960 490],'ToolBar','none');
tiledlayout(1,2,'TileSpacing','loose','Padding','compact');
 
ax_pv2 = nexttile;
scatter(PV_V,PV_P,10,Irr,'filled','DisplayName','PV Power'); hold on;
scatter(V_mpp_ref(Irr>10),P_mpp_ref(Irr>10),8,[0.4 0.8 0.4],'filled','DisplayName','MPP Curve');
scatter(Vmpp,Pmpp,180,'r','p','LineWidth',1.5,'DisplayName','STC MPP');
hold off; grid on; box on; title('PV P-V');
colormap(ax_pv2,parula); cb3 = colorbar(ax_pv2);
cb3.Label.String = 'Irradiance (W/m²)'; clim(ax_pv2,[0 max(max(Irr),10)]);
legend('Location','northwest','FontSize',9);
xlim(ax_pv2,[0 Voc*1.1]); ylim(ax_pv2,[0 max(Pmpp*1.15,100)]);
 
ax_pem2 = nexttile;
P_randles = V_randles .* I_ref;
scatter(PEM_V,PEM_P,10,Irr,'filled','DisplayName','PEM Load Curve'); hold on;
plot(V_randles,P_randles,'r--','LineWidth',1.8,'DisplayName','Randles Model');
hold off; grid on; box on; title('PEM P-V');
colormap(ax_pem2,parula); cb4 = colorbar(ax_pem2);
cb4.Label.String = 'Irradiance (W/m²)'; clim(ax_pem2,[0 max(max(Irr),10)]);
legend('Location','northwest','FontSize',9);
xlim(ax_pem2,[0 Vmax_PEM*1.1]); ylim(ax_pem2,[0 max(Pmpp*1.15,100)]);
drawnow;
exportgraphics(fig5,sprintf('Fig5_PV_Characteristics_Ns%d_Np%d_case_%s.png', ...
    Ns_cell,Np_cell,case_model),'Resolution',300);
 
% STREAMING_CHUNK:Computing hourly averages and specific hour bar charts...
% --- Figure 6: Hourly Averages ---
target_hours = [7, 9, 12, 14.5, 16.5];
nH = length(target_hours);
mean_PV_V    = zeros(nH,1); mean_PV_I    = zeros(nH,1);
mean_PEM_V   = zeros(nH,1); mean_PEM_I   = zeros(nH,1);
mean_eta_bar = zeros(nH,1); recorded_irr = zeros(nH,1);
mean_ems     = strings(nH,1);
 
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
        if p_in > 5, mean_eta_bar(k) = min(99.5,(p_out/p_in)*100); end
    end
end
 
fig6 = figure('Name','Hourly Summary','Color','w','Position',[150 150 1200 510],'ToolBar','none');
tiledlayout(1,3,'TileSpacing','loose','Padding','compact');
x_pos = 1:nH;
lbl   = arrayfun(@(h) sprintf('%02d:00',floor(h)),target_hours,'UniformOutput',false);
 
ax_s1 = nexttile;
b1 = bar(x_pos,[mean_PV_V, mean_PEM_V],0.65);
b1(1).FaceColor=clr_pv;  b1(1).DisplayName='V_{PV}';
b1(2).FaceColor=clr_pem; b1(2).DisplayName='V_{PEM}';
set(ax_s1,'XTick',x_pos,'XTickLabel',lbl,'FontSize',9); xtickangle(ax_s1,25);
ylabel('Mean Voltage (V)'); grid on; box on; title('Voltage at Time of Day');
legend('Location','northwest','FontSize',9);
 
ax_s2 = nexttile;
b2 = bar(x_pos,[mean_PV_I, mean_PEM_I],0.65);
b2(1).FaceColor=clr_pv;  b2(1).DisplayName='I_{PV}';
b2(2).FaceColor=clr_pem; b2(2).DisplayName='I_{PEM}';
set(ax_s2,'XTick',x_pos,'XTickLabel',lbl,'FontSize',9); xtickangle(ax_s2,25);
ylabel('Mean Current (A)'); grid on; box on; title('Current at Time of Day');
legend('Location','northwest','FontSize',9);
 
ax_s3 = nexttile;
if any(mean_eta_bar > 0)
    b3 = bar(x_pos,mean_eta_bar,0.50,'DisplayName','Avg Efficiency');
    b3.FaceColor = clr_eta; hold on;
    for k = 1:nH
        if mean_eta_bar(k) > 0.5
            text(k,mean_eta_bar(k)+1.5,sprintf('%.1f%%',mean_eta_bar(k)),...
                'HorizontalAlignment','center','FontSize',7,'FontWeight','bold');
        end
    end
    hold off;
end
set(ax_s3,'XTick',x_pos,'XTickLabel',lbl,'FontSize',9); xtickangle(ax_s3,25);
ylabel('Mean η_{system} (%)'); ylim([0 115]); grid on; box on;
title('System Efficiency (PV→PEM)');
legend('Avg Efficiency','Location','southwest','FontSize',9);
drawnow;
exportgraphics(fig6,sprintf('Fig6_DailySummary_Ns%d_Np%d_case_%s.png', ...
    Ns_cell,Np_cell,case_model),'Resolution',300);
 
% STREAMING_CHUNK:Plotting PV MPP comparisons...
% --- Figure MPP: Power tracking ---
fig_mpp = figure('Name','MPP Power','Color','w','Position',[80 80 1020 760],'ToolBar','none');
tiledlayout(3,1,'TileSpacing','compact','Padding','compact');
 
ax_m1 = nexttile;
plot(t_plot,P_WP,'Color',clr_pv,'LineWidth',lw+1.5,'DisplayName','PV Power'); hold on;
plot(t_plot,P_mpp_ref,'--','Color',clr_eta,'LineWidth',lw,'DisplayName','MPP Reference');
hold off; ylabel('Power (W)'); grid on; box on;
legend('Location','best','FontSize',9); title('PV Power vs MPP Reference');
 
ax_m2 = nexttile;
plot(t_plot,err_P,'Color',[0.85 0.20 0.20],'LineWidth',lw,'DisplayName','Power Error');
yline(0,'--','Color',[0.4 0.4 0.4],'HandleVisibility','off');
ylabel('ΔP (W)'); grid on; box on;
legend('Location','best','FontSize',9); title('Power Error vs MPP');
 
ax_m3 = nexttile;
plot(t_plot,C_plot,'Color',[0.20 0.20 0.20],'LineWidth',lw,'DisplayName','Coupling Factor'); hold on;
yline(1,'--','Color',[0.4 0.4 0.4],'HandleVisibility','off'); hold off;
xlabel('Time (h)'); ylabel('C = P_{WP}/P_{MPP}');
grid on; box on; legend('Location','best','FontSize',9); title('Coupling Factor');
linkaxes([ax_m1 ax_m2 ax_m3],'x'); xlim(ax_m3,[0 max(t_plot)]);
drawnow;
exportgraphics(fig_mpp,sprintf('Fig_MPP_Tracking_Ns%d_Np%d_case_%s.png', ...
    s.Ns_cell,s.Np_cell,case_model),'Resolution',300);
 
% --- Figure MPP: V & I tracking ---
fig_mpp2 = figure('Name','MPP V-I','Color','w','Position',[80 80 1020 640],'ToolBar','none');
tiledlayout(2,1,'TileSpacing','compact','Padding','compact');
 
ax_vi1 = nexttile;
yyaxis(ax_vi1,'left'); ax_vi1.YColor = clr_pv;
plot(t_plot,PV_I,    'Color',clr_pv,'LineWidth',lw+1.5,'DisplayName','I_{PV}'); hold on;
plot(t_plot,I_mpp_ref,'Color',clr_pv,'LineWidth',lw,'LineStyle','--','DisplayName','I_{MPP}');
ylabel('Current (A)'); ylim([0 max([PV_I;I_mpp_ref],[],'all')*1.15]);
yyaxis(ax_vi1,'right'); ax_vi1.YColor = clr_pem;
plot(t_plot,PV_V,    'Color',clr_pem,'LineWidth',lw+1.5,'DisplayName','V_{PV}');
plot(t_plot,V_mpp_ref,'Color',clr_pem,'LineWidth',lw,'LineStyle','--','DisplayName','V_{MPP}');
hold off; ylabel('Voltage (V)');
ylim([max(0,Vmin_PEM*0.8) max([PV_V;V_mpp_ref],[],'all')*1.15]);
grid on; box on; title('PV Operating Point vs MPP Reference');
legend('Location','northeast','NumColumns',2,'FontSize',9);
 
err_I = PV_I - I_mpp_ref; err_I(Irr<10) = NaN;
err_V = PV_V - V_mpp_ref; err_V(Irr<10) = NaN;
 
ax_vi2 = nexttile;
yyaxis(ax_vi2,'left'); ax_vi2.YColor = clr_pv;
plot(t_plot,err_I,'Color',clr_pv,'LineWidth',lw,'DisplayName','ΔI');
yline(0,'--','Color',[0.5 0.5 0.5],'LineWidth',1.0,'HandleVisibility','off');
ylabel('ΔI (A)');
I_lim = max(abs(err_I),[],'omitnan')*1.3;
if isnan(I_lim)||I_lim<0.1, I_lim=1; end
ylim([-I_lim I_lim]);
yyaxis(ax_vi2,'right'); ax_vi2.YColor = clr_pem;
plot(t_plot,err_V,'Color',clr_pem,'LineWidth',lw,'DisplayName','ΔV');
ylabel('ΔV (V)');
V_lim = max(abs(err_V),[],'omitnan')*1.3;
if isnan(V_lim)||V_lim<0.1, V_lim=1; end
ylim([-V_lim V_lim]);
xlabel('Time (h)'); grid on; box on; title('Tracking Error vs MPP Reference');
legend('Location','northeast','NumColumns',2,'FontSize',9);
linkaxes([ax_vi1 ax_vi2],'x'); set(ax_vi1,'XTickLabel',[]);
xlim(ax_vi2,[0 max(t_plot)]);
drawnow;
exportgraphics(fig_mpp2,sprintf('Fig_Voltage_current_MPP_Ns%d_Np%d_case_%s.png', ...
    s.Ns_cell,s.Np_cell,case_model),'Resolution',300);
 
% STREAMING_CHUNK:Printing text summaries and prepping data for export...
% =========================================================================
%  SECTION 10 — STEADY-STATE SUMMARY TABLE
% =========================================================================
fprintf('=== Steady-State Operating Point Summary ===\n');
fprintf('%-12s  %8s  %8s  %8s  %8s  %6s  %6s\n', ...
    'G (W/m²)','Vpv(V)','Ipv(A)','Vpem(V)','Ipem(A)','M','eta(%)');
fprintf('%s\n',repmat('-',1,72));
for k = 1:nH
    M_k = mean_PEM_V(k)/max(mean_PV_V(k),0.01);
    fprintf('%-12d  %8.2f  %8.2f  %8.2f  %8.2f  %6.3f  %6.1f\n', ...
        recorded_irr(k),mean_PV_V(k),mean_PV_I(k), ...
        mean_PEM_V(k),mean_PEM_I(k),M_k,mean_eta_bar(k));
end
fprintf('\n');
 
% =========================================================================
%  SECTION 11 — EXCEL EXPORT  (APPEND-SAFE, SINGLE SHEET)
%
%  Row budget for 340-day dataset:
%    489,600 data rows + 1 header = 489,601 rows used
%    Excel limit = 1,048,576 rows → 558,975 rows remaining
% =========================================================================
filename = 'PV_PEM_indirect_results_week_new.xlsx';
 
% --- Derived quantities ---
PV_area = Ns_cell * Np_cell * 1.689;  % [m²]
LHV_H2  = 119960;                      % [J/g]
STH = ((H2_rate/3600) .* LHV_H2) ./ max(PV_area .* Irr, 1e-3) * 1000;
 
% --- Final data cleanup ---
C(isnan(C)          | Irr==0) = 0;
err_P(isnan(err_P)  | Irr==0) = 0;
P_mpp_ref(isnan(P_mpp_ref) | Irr==0) = 0;
V_mpp_ref(isnan(V_mpp_ref) | Irr==0) = 0;
I_mpp_ref(isnan(I_mpp_ref) | Irr==0) = 0;
STH(isnan(STH)      | Irr==0) = 0;
C(C > 1) = 1;
eta_export = eta; eta_export(isnan(eta_export)) = 0;
M_export   = M;   M_export(isnan(M_export))     = 0;
 
% --- Run identification column ---
run_id = repmat({datestr(now,'yyyy-mm-dd HH:MM:SS')}, length(t), 1);
 
% --- Assemble output table ---
TS = table( ...
    t, t_plot, real_t, Irr, ...
    PV_V, PV_I, PV_P, PEM_V, PEM_I, PEM_P, ...
    eta_export, M_export, H2_rate, H2_cumul, ...
    P_mpp_ref, V_mpp_ref, I_mpp_ref, ...
    err_P, C, STH, run_id, ...
    'VariableNames', { ...
        't_sim_[s]',         't_plot_[h]',       't_real_[s]', ...
        'Irr_[W/m2]', ...
        'PV_V_[V]',          'PV_I_[A]',         'PV_P_[W]', ...
        'PEM_V_[V]',         'PEM_I_[A]',        'PEM_P_[W]', ...
        'eta_conv_[pct]',    'M_ratio', ...
        'H2_rate_[g_h]',     'H2_cumul_[g]', ...
        'P_MPP_ref_[W]',     'V_MPP_ref_[V]',    'I_MPP_ref_[A]', ...
        'Power_Error_[W]',   'Coupling_Factor_C', 'STH_[pct]', ...
        'Run_Timestamp'});
 
% STREAMING_CHUNK:Writing correctly to Excel using append without Range...
% -----------------------------------------------------------------
%  FIX 6 — APPEND-SAFE WRITER
%  Branch 1 — fresh file: write with header
%  Branch 2 — existing data: append rows only, no header
% -----------------------------------------------------------------
write_header = true;
next_row     = 2;
 
if isfile(filename)
    try
        existing   = readtable(filename,'Sheet','TimeSeries', ...
                                'VariableNamingRule','preserve');
        n_existing = height(existing);
        if n_existing > 0
            projected_last = n_existing + 1 + height(TS);
            if projected_last > excel_row_limit
                warning(['Excel row limit will be exceeded! ' ...
                    'Existing: %d rows | New: %d rows | Limit: %d. ' ...
                    'Consider splitting into monthly sheets.'], ...
                    n_existing, height(TS), excel_row_limit);
            end
            next_row     = n_existing + 2;
            write_header = false;
            fprintf('  [INFO] Existing data: %d rows. Appending from row %d.\n', ...
                n_existing, next_row);
        else
            fprintf('  [INFO] Sheet empty — writing fresh.\n');
        end
    catch
        fprintf('  [INFO] TimeSeries sheet not found — writing fresh.\n');
    end
end
 
if write_header
    writetable(TS, filename,'Sheet','TimeSeries','WriteMode','overwritesheet');
    fprintf('  [OK] Created %s with header + %d data rows.\n', filename, height(TS));
else
    % FIXED ERROR HERE: Removed 'Range' parameter as it is invalid when WriteMode is 'append'
    writetable(TS, filename, ...
        'Sheet',              'TimeSeries', ...
        'WriteMode',          'append', ...
        'WriteVariableNames', false);
    fprintf('  [OK] Appended %d rows (sheet ends at row %d).\n', ...
        height(TS), next_row + height(TS) - 1);
end
 
% Parameters sheet (written once on first run only)
if write_header
    paramNames  = {'N_cells_PEM';'Np_cell';'Ns_cell'; ...
                   'sim_t_[s]';'scale_factor';'PV_Area_[m2]'; ...
                   'L_conv_[H]';'C_conv_[F]';'fsw_[Hz]'; ...
                   'Dataset_days';'Dataset_rows'};
    paramValues = [N; Np_cell; Ns_cell; sim_t; scale_factor; PV_area; ...
                   L_conv; C_conv; 1/Ts; 340; expected_rows];
    PARAM = table(paramNames, paramValues,'VariableNames',{'Parameter','Value'});
    writetable(PARAM, filename,'Sheet','Parameters','WriteMode','overwritesheet');
    fprintf('  [OK] Parameters sheet written.\n');
end
 
fprintf('\n=== ALL DONE ===\n');
fprintf('  Total H2 yield : %.4f g  (%.4f kg)\n', H2_cumul(end), H2_cumul(end)/1000);
fprintf('  Solver time    : %.2f s\n',  solve_time_sec);
fprintf('  Output file    : %s\n',      filename); 
