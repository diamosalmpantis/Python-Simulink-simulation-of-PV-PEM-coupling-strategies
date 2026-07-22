clear; clc; close all;
warning('off', 'all'); % Suppress all Simulink warnings
fprintf('=== PV-PEM Setup & Simulation ===\n\n');

% =========================================================================
%  SECTION 1 — ELECTROLYZER PARAMETERS
% =========================================================================
N       = 13;           % Number of PEM cells
Vint    = 1.475841;     % [V]   Internal (reversible) voltage per cell
Rint    = 0.008673;     % [Ohm] Internal ohmic resistance per cell
Ra      = 0.00177;      % [Ohm] Anode charge-transfer resistance per cell
Rc      = 0.0005;       % [Ohm] Cathode charge-transfer resistance per cell

ratio_tau   = 10;               % Ratio tau_a : tau_c
tau_a       = 0.4;              % [s] Anode RC time constant
tau_c       = tau_a / ratio_tau;% [s] Cathode RC time constant
Ca          = tau_a / Ra;       % [F] Anode double-layer capacitance
Cc          = tau_c / Rc;       % [F] Cathode double-layer capacitance
Active_Area = 17.64;            % [cm²] Active membrane area

% Stack-level scaling (N cells in series)
Vint_stack = Vint * N;
Rint_stack = Rint * N;
Ra_stack   = Ra   * N;
Rc_stack   = Rc   * N;
Ca_stack   = Ca   / N;   % Capacitances scale inversely in series
Cc_stack   = Cc   / N;

% PEM operating limits
Vmin_PEM = 1.5 * N;  % [V]
Vmax_PEM = 2.0 * N;  % [V]
Imin_PEM = 2.2;       % [A]
Imax_PEM = 80;        % [A]

% =========================================================================
%  SECTION 2 — PV ARRAY PARAMETERS
% =========================================================================
Im_PV   = 9.59;             % [A]  Cell MPP current at STC
Vm_PV   = 0.55;             % [V]  Cell MPP voltage at STC

Np_cell = 7;               % Parallel strings
Ns_cell = 45;               % Cells per string
Isc     = 10.14 * Np_cell;  % [A]  Array short-circuit current at STC
Voc     =  0.67 * Ns_cell;  % [V]  Array open-circuit voltage at STC
Vmpp    = Vm_PV * Ns_cell;  % [V]  Array MPP voltage at STC
Impp    = Im_PV * Np_cell;  % [A]  Array MPP current at STC
Pmpp    = Vmpp  * Impp;     % [W]  Array MPP power at STC

fprintf('PV Array: Ns = %d (series), Np = %d (parallel)\n', Ns_cell, Np_cell);
fprintf('STC MPP:  Vmpp = %.2f V | Impp = %.2f A | Pmpp = %.1f W\n\n', Vmpp, Impp, Pmpp);

% =========================================================================
%  SECTION 3 — TIME & WEATHER DATA
% =========================================================================
% TIME COMPRESSION: scale_factor maps real seconds to simulation seconds
% e.g., scale_factor = 36000 means 1 sim-second = 10 real hours
scale_factor = 36000;

if isfile('weather_profile_week.xlsx')
    fprintf('Loading weather data from weather_profile_week.xlsx...\n');
    weather       = readtable('weather_profile_week.xlsx');
    real_time_sec = weather.Time_min * 60;   % Convert minutes to seconds
    Irr_val       = weather.Irradiance;      % [W/m²]
    Temp_val      = weather.Temperature;     % [°C]
else
    fprintf('[!] weather_profile_week.xlsx not found — generating mock annual profile.\n');
    % Annual mock: 365 days at 1-minute resolution
    real_time_sec = (0 : 60 : 365*86400)';
    day_of_year   = real_time_sec / 86400;
    time_of_day   = mod(real_time_sec, 86400);

    % Seasonal envelope (peak ~1000 W/m² in summer, ~400 W/m² in winter)
    seasonal_env  = 700 + 300 * sin(2*pi*(day_of_year - 80) / 365);
    % Diurnal profile
    Irr_val = seasonal_env .* max(sin(pi * time_of_day / 86400), 0) ...
              .* (0.85 + 0.15 * rand(size(real_time_sec)));
    Irr_val(time_of_day < 3600*6 | time_of_day > 3600*20) = 0; % Night cutoff

    % Seasonal temperature: 0°C winter, 30°C summer
    Temp_val = 15 + 15 * sin(2*pi*(day_of_year - 80)/365) ...
             +  8 * max(sin(pi * time_of_day / 86400), 0);
end

% Scale time axis to simulation time
Irr_time = real_time_sec / scale_factor;
sim_t    = max(Irr_time);

% Stair-interpolated inputs (for Simulink From Workspace / Repeating Sequence blocks)
Irr_stair_tsamp = 60 / scale_factor;
Irr_stair_time  = (0 : Irr_stair_tsamp : sim_t)';
Irr_stair_val   = interp1(Irr_time, Irr_val,  Irr_stair_time, 'linear', 0);
Temp_stair_val  = interp1(Irr_time, Temp_val, Irr_stair_time, 'linear', 25);

sample_output_time = 60 / scale_factor;
assignin('base', 'sample_output_time', sample_output_time);
assignin('base', 'Tsc', sample_output_time);

% =========================================================================
%  SECTION 4 — BASELINE MODEL OVERRIDES & COPY
% =========================================================================
case_model = 'A';
mdl_orig   = 'PV_PEM_direct';
mdl_fixed  = 'PV_PEM_direct_FIXED';

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
    b      = blocks{i};
    b_name = ''; b_type = '';
    try b_name = get_param(b, 'Name');      catch; end
    try b_type = get_param(b, 'BlockType'); catch; end

    % Constant blocks: remove output saturation
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

    % Simulink-PS / PS-Simulink converters: add derivative filter
    try
        ref = get_param(b, 'ReferenceBlock');
        if contains(ref, 'Simulink-PS Converter') || ...
           contains(ref, 'PS-Simulink Converter')
            set_param(b, 'FilteringAndDerivatives',  'filter');
            set_param(b, 'InputFilterTimeConstant',  '1e-6');
        end
    catch; end

    % Current sensors: enforce Ampere output unit
    if contains(b_name, 'Current',  'IgnoreCase', true) || ...
       contains(b_name, 'Ammeter',  'IgnoreCase', true)
        try set_param(b, 'i_unit', 'A'); catch; end
    end

    % Solver Configuration: use local backward-Euler solver
    if contains(b_name, 'Solver Configuration')
        try
            set_param(b, 'UseLocalSolver',        'on');
            set_param(b, 'LocalSolverSampleTime',  'Tsc');
            set_param(b, 'LocalSolverType',        'Backward Euler');
        catch; end
    end

    % Scopes: disable data logging to prevent memory overflow
    if strcmp(b_type, 'Scope')
        try set_param(b, 'DataLogging', 'off'); catch; end
    end
end

% Global solver settings
set_param(mdl, 'StopTime',        num2str(sim_t));
set_param(mdl, 'Solver',          'ode15s');
set_param(mdl, 'MaxStep',         '1e-5');
set_param(mdl, 'SimulationMode',  'accelerator');
try set_param(mdl, 'SimscapeExplicitSolverDiagnostic', 'none'); catch; end

save_system(mdl);
fprintf('  Saved %s\n\n', [mdl_fixed '.slx']);

% =========================================================================
%  SECTION 5 — RUN SIMULATION
% =========================================================================
total_days = (sim_t * scale_factor) / 86400;
fprintf('Running simulation...\n');
fprintf('Target: %.4g sim-seconds (%.1f real-world days)\n\n', sim_t, total_days);

open_system(mdl);
solve_timer = tic;
out         = sim(mdl);
solve_time_sec = toc(solve_timer);

fprintf('Simulation complete. Solver time: %.2f s\n\n', solve_time_sec);

% =========================================================================
%  SECTION 6 — POST-PROCESSING
% =========================================================================
t      = out.PV_V.Time;
t_plot = (t * scale_factor) / 3600;   % [h]  Real-world hours
real_t =  t * scale_factor;           % [s]  Real-world seconds

% Interpolate temperature to simulation time vector
Temp_out = interp1(Irr_time, Temp_val, t, 'linear', 'extrap');

% Clamp negative numerical noise from the solver
PV_V  = max(out.PV_V.Data,  0);
PV_I  = max(out.PV_I.Data,  0);
PEM_V = max(out.PEM_V.Data, 0);
PEM_I = max(out.PEM_I.Data, 0);
Irr   = max(out.Irr.Data,   0);

% Auto-correct milliampere sensors
if max(PEM_I) > 500, PEM_I = PEM_I / 1000; end
if max(PV_I)  > 500, PV_I  = PV_I  / 1000; end

PV_P  = PV_V  .* PV_I;
PEM_P = PEM_V .* PEM_I;

% Smoothed power traces (moving average over 200 samples)
PV_P_smooth  = movmean(PV_P,  200);
PEM_P_smooth = movmean(PEM_P, 200);

% Conversion efficiency
eta_raw = PEM_P_smooth ./ max(PV_P_smooth, 1e-3) * 100;
eta_raw(eta_raw > 99.0) = 99.0;
valid = PV_P_smooth > 1;
eta   = nan(size(PV_P));
eta(valid) = eta_raw(valid);

% =========================================================================
%  SECTION 7 — MPP REFERENCE LOADING
% =========================================================================
mpp_filename = sprintf('../mpp_data_Ns%d_Np%d.mat', Ns_cell, Np_cell);
try
    s         = load(mpp_filename, 'pP','pV','pI','irr_unique', ...
                     'P_mpp','V_mpp','I_mpp','Ns_cell','Np_cell');
    V_mpp_ref = polyval(s.pV, Irr);
    I_mpp_ref = polyval(s.pI, Irr);
    P_mpp_ref = polyval(s.pP, Irr);
catch
    % Fallback: linear approximation from STC values
    G_ratio   = Irr / 1000;
    V_mpp_ref = Vmpp * (1 + 0.02 * log(max(G_ratio, 1e-3)));
    V_mpp_ref(Irr < 10) = 0;
    I_mpp_ref = Impp .* G_ratio;
    P_mpp_ref = V_mpp_ref .* I_mpp_ref;
end

P_WP  = PV_V .* PV_I;
err_P = abs(P_WP - P_mpp_ref);
C     = P_WP ./ max(P_mpp_ref, 1e-6);
C(C > 1)      = 1;
C(Irr == 0)   = NaN;
err_P(Irr == 0) = NaN;
P_mpp_ref(Irr == 0) = NaN;

% =========================================================================
%  SECTION 8 — HYDROGEN PRODUCTION
% =========================================================================
F_const = 96485;    % [C/mol] Faraday constant
eta_F   = 0.99;     % [-]     Faraday efficiency
M_H2    = 2.016e-3; % [kg/mol] Molar mass of hydrogen

n_H2             = PEM_I / (2 * F_const) * eta_F;   % [mol/s]
n_H2(Irr < 70)   = 0;                                % Night / sub-threshold cutoff
H2_rate          = n_H2 * M_H2 * 3600 * 1e3;        % [g/h]
H2_inst_g_s      = n_H2 * M_H2 * 1e3;               % [g/s]
H2_cumul         = cumtrapz(real_t, H2_inst_g_s);   % [g]

% Conditional statistics (irradiance threshold > 70 W/m²)
active_mask    = Irr > 70;
avg_eta_active = mean(eta(active_mask), 'omitnan');
avg_C_active   = mean(C(active_mask),   'omitnan');

fprintf('=== Simulation Summary ===\n');
fprintf('  PV peak power:              %.1f W\n',   max(PV_P));
fprintf('  PEM peak power:             %.1f W\n',   max(PEM_P));
fprintf('  Mean η (when G > 70 W/m²):  %.1f %%\n', avg_eta_active);
fprintf('  Mean C (when G > 70 W/m²):  %.3f\n',    avg_C_active);
fprintf('  Peak H2 production rate:    %.2f g/h\n', max(H2_rate));
fprintf('  Total H2 produced:          %.4f g\n\n', H2_cumul(end));

% =========================================================================
%  SECTION 9 — FIGURES
% =========================================================================
clr_pv   = [0.85, 0.33, 0.10];
clr_pem  = [0.13, 0.47, 0.71];
clr_irr  = [0.93, 0.69, 0.13];
clr_eta  = [0.18, 0.55, 0.18];
clr_temp = [0.64, 0.08, 0.18];
lw = 1.8;

% --- Figure 1: Energy Chain ---
fig1 = figure('Name','System Overview','Color','w','Position',[30 30 1020 760],'ToolBar','none');
tl1  = tiledlayout(4,1,'TileSpacing','compact','Padding','compact');

ax1 = nexttile;
yyaxis(ax1,'left');
plot(t_plot, Irr, 'Color',clr_irr,'LineWidth',lw+0.4,'DisplayName','Irradiance');
ylabel('G (W/m²)'); ylim([0 max(max(Irr)*1.1, 1000)]);
ax1.YColor = [0.6 0.4 0];
yyaxis(ax1,'right');
plot(t_plot, Temp_out,'Color',clr_temp,'LineWidth',lw,'DisplayName','Temperature');
ylabel('T (°C)'); ylim([min(Temp_out)*0.9 max(Temp_out)*1.1]);
ax1.YColor = clr_temp;
grid on; box on; legend('Location','northeast','NumColumns',2,'FontSize',9);

ax2 = nexttile;
plot(t_plot, PV_V,  'Color',clr_pv, 'LineWidth',lw+1.5,'DisplayName','V_{PV}'); hold on;
plot(t_plot, PEM_V, 'Color',clr_pem,'LineWidth',lw,'LineStyle','--','DisplayName','V_{PEM}');
yline(Vmax_PEM,'--','Color',[0.5 0.5 0.5],'HandleVisibility','off');
yline(Vmin_PEM,':','Color',[0.5 0.5 0.5],'HandleVisibility','off');
hold off; ylabel('Voltage (V)'); ylim([max(0,Vmin_PEM*0.8) Voc*1.05]);
grid on; box on; legend('Location','east','FontSize',9);

ax3 = nexttile;
plot(t_plot, PV_I,  'Color',clr_pv, 'LineWidth',lw+1.5,'DisplayName','I_{PV}'); hold on;
plot(t_plot, PEM_I, 'Color',clr_pem,'LineWidth',lw,'LineStyle','--','DisplayName','I_{PEM}');
yline(Imax_PEM,'--','Color',[0.5 0.5 0.5],'HandleVisibility','off');
hold off; ylabel('Current (A)'); ylim([0 max(max(PV_I)*1.2,10)]);
grid on; box on; legend('Location','northeast','FontSize',9);

ax4 = nexttile;
plot(t_plot, PV_P,  'Color',clr_pv, 'LineWidth',lw+1.5,'DisplayName','P_{PV}'); hold on;
plot(t_plot, PEM_P, 'Color',clr_pem,'LineWidth',lw,'LineStyle','--','DisplayName','P_{PEM}');
hold off; xlabel('Time (h)'); ylabel('Power (W)');
ylim([0 max(max(PV_P)*1.2,100)]);
grid on; box on; legend('Location','northeast','FontSize',9,'NumColumns',2);

linkaxes([ax1 ax2 ax3 ax4],'x'); xlim(ax4,[0 max(t_plot)]);
set([ax1 ax2 ax3],'XTickLabel',[]);
drawnow;
exportgraphics(fig1, sprintf('Fig1_SystemOverview_Ns%d_Np%d_case_%s.png', ...
    Ns_cell, Np_cell, case_model), 'Resolution',300);

% --- Figure 2: H2 Rate ---
fig2 = figure('Name','H2 Rate','Color','w','Position',[60 60 1020 640],'ToolBar','none');
tiledlayout(1,1,'TileSpacing','compact','Padding','compact');
ax_h = nexttile;
yyaxis(ax_h,'left'); ax_h.YColor = clr_pem;
plot(t_plot, H2_rate, 'Color',clr_pem,'LineWidth',lw,'DisplayName','Instantaneous H_2 Rate');
ylabel('H_2 rate (g/h)'); ylim([0 max(max(H2_rate)*1.15,1)]);
yyaxis(ax_h,'right'); ax_h.YColor = [0 0.40 0.80];
plot(t_plot, H2_cumul,'Color',[0 0.40 0.80],'LineWidth',lw,'LineStyle','-.', ...
    'DisplayName','Cumulative H_2');
ylabel('Cumulative H_2 (g)');
grid on; box on; xlabel('Time (h)'); xlim(ax_h,[0 max(t_plot)]);
legend('Location','northwest','NumColumns',2,'FontSize',9);
drawnow;
exportgraphics(fig2, sprintf('Fig2_H2_Rate_Ns%d_Np%d_case_%s.png', ...
    Ns_cell, Np_cell, case_model), 'Resolution',300);

% --- Figure 4: I-V & P Trajectories ---
fig4 = figure('Name','I-V Trajectory','Color','w','Position',[90 90 960 490],'ToolBar','none');
tl3  = tiledlayout(1,2,'TileSpacing','loose','Padding','compact');

ax_pv = nexttile;
scatter(PV_I, PV_V, 10, Irr,'filled','MarkerFaceAlpha',0.8,'DisplayName','PV Trajectory'); hold on;
scatter(I_mpp_ref(Irr>0), V_mpp_ref(Irr>0), 8,[0.4 0.8 0.4],'filled','DisplayName','MPP Locus');
scatter(Impp, Vmpp, 180,'r','p','LineWidth',1.5,'DisplayName','STC MPP');
hold off; grid on; box on; title('PV Array I-V Locus');
colormap(ax_pv,parula);
cb1 = colorbar(ax_pv); cb1.Label.String = 'Irradiance (W/m²)';
clim(ax_pv,[0 max(max(Irr),10)]);
legend('Location','southwest','FontSize',9);
xlim(ax_pv,[0 Isc*1.05]); ylim(ax_pv,[0 Voc*1.1]);

ax_pem = nexttile;
scatter(PEM_I, PEM_V, 10, Irr,'filled','MarkerFaceAlpha',0.8,'DisplayName','PEM Trajectory'); hold on;
I_ref     = linspace(0, Imax_PEM*1.05, 300)';
V_randles = Vint_stack + (Rint_stack + Ra_stack + Rc_stack) .* I_ref;
plot(I_ref, V_randles,'r--','LineWidth',1.8,'DisplayName','Randles Model');
hold off; grid on; box on; title('PEM I-V Locus');
colormap(ax_pem,parula);
cb2 = colorbar(ax_pem); cb2.Label.String = 'Irradiance (W/m²)';
clim(ax_pem,[0 max(max(Irr),10)]);
legend('Location','northwest','FontSize',9);
xlim(ax_pem,[0 Imax_PEM*1.1]); ylim(ax_pem,[Vmin_PEM*0.9 Vmax_PEM*1.1]);
drawnow;
exportgraphics(fig4, sprintf('Fig4_IV_Trajectory_Ns%d_Np%d_case_%s.png', ...
    Ns_cell, Np_cell, case_model), 'Resolution',300);

% --- Figure 5: P-V & P-I ---
fig5 = figure('Name','PV Characteristics','Color','w','Position',[120 120 960 490],'ToolBar','none');
tl4  = tiledlayout(1,2,'TileSpacing','loose','Padding','compact');

ax_pv2 = nexttile;
scatter(PV_V, PV_P, 10, Irr,'filled','DisplayName','PV Power'); hold on;
scatter(V_mpp_ref(Irr>0), P_mpp_ref(Irr>0), 8,[0.4 0.8 0.4],'filled','DisplayName','MPP Curve');
scatter(Vmpp, Pmpp, 180,'r','p','LineWidth',1.5,'DisplayName','STC MPP');
hold off; grid on; box on; title('PV P-V');
colormap(ax_pv2,parula);
cb3 = colorbar(ax_pv2); cb3.Label.String = 'Irradiance (W/m²)';
clim(ax_pv2,[0 max(max(Irr),10)]);
legend('Location','northwest','FontSize',9);
xlim(ax_pv2,[0 Voc*1.1]); ylim(ax_pv2,[0 max(Pmpp*1.15,100)]);

ax_pem2 = nexttile;
P_randles = V_randles .* I_ref;
scatter(PEM_I, PEM_P, 10, Irr,'filled','DisplayName','PEM Load Curve'); hold on;
plot(I_ref, P_randles,'r--','LineWidth',1.8,'DisplayName','Randles Model');
hold off; grid on; box on; title('PEM P-I');
colormap(ax_pem2,parula);
cb4 = colorbar(ax_pem2); cb4.Label.String = 'Irradiance (W/m²)';
clim(ax_pem2,[0 max(max(Irr),10)]);
legend('Location','northwest','FontSize',9);
xlim(ax_pem2,[0 Imax_PEM*1.1]); ylim(ax_pem2,[0 max(Pmpp*1.15,100)]);
drawnow;
exportgraphics(fig5, sprintf('Fig5_PV_Characteristics_Ns%d_Np%d_case_%s.png', ...
    Ns_cell, Np_cell, case_model), 'Resolution',300);

% --- Figure 6: Hourly Averages ---
target_hours = [7, 9, 12, 14.5, 16.5];
nH = length(target_hours);
mean_PV_V    = zeros(nH,1); mean_PV_I    = zeros(nH,1);
mean_PEM_V   = zeros(nH,1); mean_PEM_I   = zeros(nH,1);
mean_eta_bar = zeros(nH,1); recorded_irr = zeros(nH,1);

for k = 1:nH
    tgt  = target_hours(k);
    mask = t_plot >= (tgt - 0.16) & t_plot <= (tgt + 0.16);
    if sum(mask) > 1
        recorded_irr(k)  = round(mean(Irr(mask)));
        mean_PV_V(k)     = mean(PV_V(mask));
        mean_PV_I(k)     = mean(PV_I(mask));
        mean_PEM_V(k)    = mean(PEM_V(mask));
        mean_PEM_I(k)    = mean(PEM_I(mask));
        p_in  = mean(PV_P(mask));
        p_out = mean(PEM_P(mask));
        if p_in > 1
            mean_eta_bar(k) = min(99.0, (p_out/p_in)*100);
        end
    end
end

fig6 = figure('Name','Hourly Summary','Color','w','Position',[150 150 1060 510],'ToolBar','none');
tl5  = tiledlayout(1,3,'TileSpacing','loose','Padding','compact');
x_pos = 1:nH;
lbl   = arrayfun(@(h) sprintf('%02d:00',floor(h)), target_hours,'UniformOutput',false);

ax_s1 = nexttile;
b1 = bar(x_pos,[mean_PV_V, mean_PEM_V],0.65);
b1(1).FaceColor = clr_pv;  b1(1).DisplayName = 'V_{PV}';
b1(2).FaceColor = clr_pem; b1(2).DisplayName = 'V_{PEM}';
set(ax_s1,'XTick',x_pos,'XTickLabel',lbl,'FontSize',9); xtickangle(ax_s1,25);
ylabel('Mean Voltage (V)'); grid on; box on; title('Voltage at Time of Day');
legend('Location','northwest','FontSize',9);

ax_s2 = nexttile;
b2 = bar(x_pos,[mean_PV_I, mean_PEM_I],0.65);
b2(1).FaceColor = clr_pv;  b2(1).DisplayName = 'I_{PV}';
b2(2).FaceColor = clr_pem; b2(2).DisplayName = 'I_{PEM}';
set(ax_s2,'XTick',x_pos,'XTickLabel',lbl,'FontSize',9); xtickangle(ax_s2,25);
ylabel('Mean Current (A)'); grid on; box on; title('Current at Time of Day');
legend('Location','northwest','FontSize',9);

ax_s3 = nexttile;
if any(mean_eta_bar > 0)
    b3 = bar(x_pos, mean_eta_bar, 0.50,'DisplayName','Avg Efficiency');
    b3.FaceColor = clr_eta; hold on;
    for k = 1:nH
        if mean_eta_bar(k) > 0.5
            text(k, mean_eta_bar(k)+1.2, sprintf('%.1f%%',mean_eta_bar(k)), ...
                'HorizontalAlignment','center','FontSize',8,'FontWeight','bold');
        end
    end
end
set(ax_s3,'XTick',x_pos,'XTickLabel',lbl,'FontSize',9); xtickangle(ax_s3,25);
ylabel('Mean η_{conv} (%)'); ylim([0 110]); grid on; box on; title('Converter Efficiency');
legend('Location','southwest','FontSize',9);
drawnow;
exportgraphics(fig6, sprintf('Fig6_DailySummary_Ns%d_Np%d_case_%s.png', ...
    Ns_cell, Np_cell, case_model), 'Resolution',300);

% --- Figure MPP Tracking: Power ---
fig_mpp = figure('Name','MPP Power Tracking','Color','w','Position',[80 80 1020 760],'ToolBar','none');
tiledlayout(3,1,'TileSpacing','compact','Padding','compact');

ax_m1 = nexttile;
plot(t_plot, P_WP,      'Color',clr_pv, 'LineWidth',lw+1.5,'DisplayName','PV Power'); hold on;
plot(t_plot, P_mpp_ref, '--','Color',clr_eta,'LineWidth',lw,'DisplayName','MPP Reference');
hold off; ylabel('Power (W)'); grid on; box on;
legend('Location','best','FontSize',9); title('PV Power vs MPP Reference');

ax_m2 = nexttile;
plot(t_plot, err_P,'Color',[0.85 0.20 0.20],'LineWidth',lw,'DisplayName','Power Error');
yline(0,'--','Color',[0.4 0.4 0.4],'HandleVisibility','off');
ylabel('|ΔP| (W)'); grid on; box on;
legend('Location','best','FontSize',9); title('Absolute Power Error vs MPP');

ax_m3 = nexttile;
C_plot = max(0, min(1.2, C)); C_plot(Irr==0) = NaN;
plot(t_plot, C_plot,'Color',[0.20 0.20 0.20],'LineWidth',lw,'DisplayName','Coupling Factor'); hold on;
yline(1,'--','Color',[0.4 0.4 0.4],'HandleVisibility','off');
hold off; xlabel('Time (h)'); ylabel('C = P_{WP}/P_{MPP}');
grid on; box on; legend('Location','best','FontSize',9); title('Coupling Factor');

linkaxes([ax_m1 ax_m2 ax_m3],'x'); xlim(ax_m3,[0 max(t_plot)]);
drawnow;
exportgraphics(fig_mpp, sprintf('Fig_MPP_Tracking_Ns%d_Np%d_case_%s.png', ...
    Ns_cell, Np_cell, case_model), 'Resolution',300);

% --- Figure MPP Tracking: Voltage & Current ---
fig_mpp2 = figure('Name','MPP V-I Tracking','Color','w','Position',[80 80 1020 640],'ToolBar','none');
tiledlayout(2,1,'TileSpacing','compact','Padding','compact');

ax_vi1 = nexttile;
yyaxis(ax_vi1,'left'); ax_vi1.YColor = clr_pv;
plot(t_plot, PV_I,     'Color',clr_pv,'LineWidth',lw+1.5,'DisplayName','I_{PV}'); hold on;
plot(t_plot, I_mpp_ref,'Color',clr_pv,'LineWidth',lw,'LineStyle','--','DisplayName','I_{MPP}');
ylabel('Current (A)'); ylim([0 max([PV_I; I_mpp_ref],[],'all')*1.15]);
yyaxis(ax_vi1,'right'); ax_vi1.YColor = clr_pem;
plot(t_plot, PV_V,     'Color',clr_pem,'LineWidth',lw+1.5,'DisplayName','V_{PV}');
plot(t_plot, V_mpp_ref,'Color',clr_pem,'LineWidth',lw,'LineStyle','--','DisplayName','V_{MPP}');
hold off; ylabel('Voltage (V)');
ylim([max(0,Vmin_PEM*0.8) max([PV_V; V_mpp_ref],[],'all')*1.15]);
grid on; box on; title('PV Operating Point vs MPP Reference');
legend('Location','northeast','NumColumns',2,'FontSize',9);

err_I = PV_I - I_mpp_ref; err_I(Irr==0) = NaN;
err_V = PV_V - V_mpp_ref; err_V(Irr==0) = NaN;

ax_vi2 = nexttile;
yyaxis(ax_vi2,'left'); ax_vi2.YColor = clr_pv;
plot(t_plot, err_I,'Color',clr_pv,'LineWidth',lw,'DisplayName','ΔI');
yline(0,'--','Color',[0.5 0.5 0.5],'LineWidth',1.0,'HandleVisibility','off');
ylabel('ΔI (A)');
I_lim = max(abs(err_I),[],'omitnan')*1.3;
if isnan(I_lim) || I_lim < 0.1, I_lim = 1; end
ylim([-I_lim I_lim]);
yyaxis(ax_vi2,'right'); ax_vi2.YColor = clr_pem;
plot(t_plot, err_V,'Color',clr_pem,'LineWidth',lw,'DisplayName','ΔV');
ylabel('ΔV (V)');
V_lim = max(abs(err_V),[],'omitnan')*1.3;
if isnan(V_lim) || V_lim < 0.1, V_lim = 1; end
ylim([-V_lim V_lim]);
xlabel('Time (h)'); grid on; box on; title('Tracking Error vs MPP Reference');
legend('Location','northeast','NumColumns',2,'FontSize',9);

linkaxes([ax_vi1 ax_vi2],'x'); set(ax_vi1,'XTickLabel',[]);
xlim(ax_vi2,[0 max(t_plot)]);
drawnow;
exportgraphics(fig_mpp2, sprintf('Fig_VI_MPP_Ns%d_Np%d_case_%s.png', ...
    Ns_cell, Np_cell, case_model), 'Resolution',300);

% =========================================================================
%  SECTION 10 — STEADY-STATE SUMMARY TABLE
% =========================================================================
fprintf('=== Steady-State Summary ===\n');
fprintf('%-12s  %8s  %8s  %8s  %8s  %6s  %6s\n', ...
    'G (W/m²)','Vpv(V)','Ipv(A)','Vpem(V)','Ipem(A)','M','eta(%)');
fprintf('%s\n', repmat('-',1,72));
for k = 1:nH
    M_k = mean_PEM_V(k) / max(mean_PV_V(k), 0.01);
    fprintf('%-12d  %8.2f  %8.2f  %8.2f  %8.2f  %6.3f  %6.1f\n', ...
        recorded_irr(k), mean_PV_V(k), mean_PV_I(k), ...
        mean_PEM_V(k), mean_PEM_I(k), M_k, mean_eta_bar(k));
end

% =========================================================================
%  SECTION 11 — EXCEL EXPORT (APPEND-SAFE, SINGLE SHEET)
%
%  Row budget for 340-day dataset:
%    489,600 data rows + 1 header = 489,601 rows used
%    Excel limit = 1,048,576 rows  →  558,975 rows remaining
%    Safe for one full run; two runs would require splitting.
% =========================================================================
filename = 'PV_PEM_direct_results_week_new.xlsx';

% --- Extract Simulink efficiency signal and align to main time vector ---
raw_eff_data   = out.Efficiency.Data(:);
raw_eff_time   = out.Efficiency.Time(:);
sim_Efficiency = interp1(raw_eff_time, raw_eff_data, t, 'linear','extrap');

% --- Derived quantities ---
PV_area = Ns_cell * Np_cell * 1.689;  % [m²]
LHV_H2  = 119960;                      % [J/g]
STH = ((H2_rate/3600) .* LHV_H2) ./ max(PV_area .* Irr, 1e-3) * 1000; % [%]

% --- Final data cleanup ---
STH(isnan(STH)             | Irr==0) = 0;
C(isnan(C)                 | Irr==0) = 0;
err_P(isnan(err_P)         | Irr==0) = 0;
P_mpp_ref(isnan(P_mpp_ref) | Irr==0) = 0;
V_mpp_ref(isnan(V_mpp_ref) | Irr==0) = 0;
I_mpp_ref(isnan(I_mpp_ref) | Irr==0) = 0;
sim_Efficiency(isnan(sim_Efficiency)) = 0;
C(C > 1) = 1;

% --- Run identification column ---
run_id = repmat({datestr(now,'yyyy-mm-dd HH:MM:SS')}, length(t), 1);

% --- Assemble output table ---
TS = table( ...
    t, t_plot, real_t, Irr, ...
    PV_V, PV_I, PV_P, PEM_V, PEM_I, ...
    sim_Efficiency, H2_rate, ...
    P_mpp_ref, V_mpp_ref, I_mpp_ref, ...
    err_P, C, STH, run_id, ...
    'VariableNames', { ...
        't_sim_[s]',         't_plot_[h]',       't_real_[s]', ...
        'Irr_[W/m2]', ...
        'PV_V_[V]',          'PV_I_[A]',         'PV_P_[W]', ...
        'PEM_V_[V]',         'PEM_I_[A]', ...
        'Simulink_Eff_[pct]','H2_Flow_[g_h]', ...
        'P_MPP_ref_[W]',     'V_MPP_ref_[V]',    'I_MPP_ref_[A]', ...
        'Power_Error_[W]',   'Coupling_Factor_C', 'STH_[pct]', ...
        'Run_Timestamp'});

% -----------------------------------------------------------------
%  APPEND-SAFE WRITER
%  Branch 1 — fresh file (no file, or empty sheet): write with header
%  Branch 2 — file has data: append rows only, skip header
% -----------------------------------------------------------------
write_header = true;
next_row     = 2;

if isfile(filename)
    try
        existing   = readtable(filename, 'Sheet','TimeSeries', ...
                                'VariableNamingRule','preserve');
        n_existing = height(existing);

        if n_existing > 0
            % ---------------------------------------------------------
            %  ROW BUDGET CHECK
            %  Warn if the append would exceed the Excel row limit.
            % ---------------------------------------------------------
            projected_last_row = n_existing + 1 + height(TS);
            if projected_last_row > excel_row_limit
                warning(['Excel row limit will be exceeded! ' ...
                    'Current rows: %d | New rows: %d | Limit: %d. ' ...
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
    writetable(TS, filename, 'Sheet','TimeSeries','WriteMode','overwritesheet');
    fprintf('  [OK] Created %s with header + %d data rows.\n', filename, height(TS));
else
    writetable(TS, filename, ...
        'Sheet',              'TimeSeries', ...
        'WriteMode',          'append', ...
        'WriteVariableNames', false, ...
        'Range',              sprintf('A%d', next_row));
    fprintf('  [OK] Appended %d rows (sheet now ends at row %d).\n', ...
        height(TS), next_row + height(TS) - 1);
end

% --- Parameters sheet (written once on first run only) ---
if write_header
    paramNames  = {'N_cells_PEM';'Np_cell';'Ns_cell'; ...
                   'sim_t_[s]';'scale_factor';'PV_Area_[m2]'; ...
                   'Dataset_days';'Dataset_rows'};
    %paramValues = [N; Np_cell; Ns_cell; sim_t; scale_factor; PV_area; ...
                   %340; expected_rows];
    %PARAM = table(paramNames, paramValues, 'VariableNames',{'Parameter','Value'});
    %writetable(PARAM, filename,'Sheet','Parameters','WriteMode','overwritesheet');
    fprintf('  [OK] Parameters sheet written.\n');
end

fprintf('\n=== ALL DONE ===\n');
fprintf('  Total H2 yield : %.4f g  (%.4f kg)\n', H2_cumul(end), H2_cumul(end)/1000);
fprintf('  Solver time    : %.2f s\n', solve_time_sec);
fprintf('  Output file    : %s\n', filename);

if write_header
    % First-ever write: use writetable (creates file + header + data)
    writetable(TS, filename, ...
        'Sheet',    'TimeSeries', ...
        'WriteMode','overwritesheet');
    fprintf('  [OK] Created %s with header and %d data rows.\n', ...
        filename, height(TS));
else
    % Subsequent writes: append rows only, no header
    writetable(TS, filename, ...
        'Sheet',              'TimeSeries', ...
        'WriteMode',          'append', ...
        'WriteVariableNames', false, ...
        'Range',              sprintf('A%d', next_row));
    fprintf('  [OK] Appended %d rows to %s (now at row %d).\n', ...
        height(TS), filename, next_row + height(TS) - 1);
end

% --- Parameters sheet (written only on first run) ---
if write_header
    paramNames  = {'N_cells_PEM';'Np_cell';'Ns_cell'; ...
                   'sim_t_[s]';'scale_factor';'PV_Area_[m2]'};
    paramValues = [N; Np_cell; Ns_cell; sim_t; scale_factor; PV_area];
    PARAM = table(paramNames, paramValues, ...
        'VariableNames', {'Parameter','Value'});
    writetable(PARAM, filename, ...
        'Sheet',    'Parameters', ...
        'WriteMode','overwritesheet');
    fprintf('  [OK] Parameters sheet written.\n');
end

fprintf('\n=== ALL DONE! ===\n');
fprintf('  Total H2 yield this run: %.4f g\n', H2_cumul(end));
fprintf('  Output file: %s\n', filename);
