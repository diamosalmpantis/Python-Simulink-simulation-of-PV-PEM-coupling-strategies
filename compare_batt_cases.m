% =========================================================================
%  compare_batt_cases.m  (v7 – 5 cases, S4–S6, S7–S8)
%
%  Loads post-simulation Excel results from five PV-PEM-Battery topologies
%  and generates publication-quality comparison figures.
%  (Case S7 Direct PV+PEM+Indirect Batt has been removed.)
%
%  Case S4 – Indirect Coupling + Indirect Batt (BMS)       → PV_PEM_indirect_batt_results_week.xlsx
%  Case S5 – Indirect Coupling + Indirect Batt (EMS)       → Indirect_EMS_batt_results.xlsx
%  Case S6 – Direct PV + PEM + Passive Battery             → PV_PEM_direct_batt_results_week.xlsx
%  Case S7 – Reconfigurable Direct PV+PEM + Indirect Batt  → PV_PEM_rec_batt_results_week.xlsx
%  Case S8 – Reconfigurable PV+PEM + Batt on PV Strings    → PV_PEM_rec_pv_batt_results_week.xlsx
%
%  Run all five simulation scripts first, then run this script.
%
%  FIXES vs v3:
%    • Case 1b (Real Indirect EMS) added as Case 5
%    • H2_night trapz bug fixed (zero-mask approach, same as individual scripts)
%    • bar_lbl helper uses 1:numel(vals) — works for any NC
%    • B5/B6/B8 figures extended to NC panels
%    • B10 xlim and annotations updated for NC bars
% =========================================================================
clear; clc; close all;
warning('off','all');

% ── Global plot style ─────────────────────────────────────────────────────
set(groot, ...
    'defaultAxesFontSize',   11, ...
    'defaultAxesFontName',   'Arial', ...
    'defaultAxesBox',        'on', ...
    'defaultAxesXGrid',      'on', ...
    'defaultAxesYGrid',      'on', ...
    'defaultAxesLineWidth',  0.8, ...
    'defaultFigureColor',    'w');

% ── Number of cases ───────────────────────────────────────────────────────
NC = 4;

% ── Colors — Wong (2011) colorblind-safe palette ─────────────────────────
%  Case 4: blue       – Indirect coupling + Active battery (EMS)
%  Case 5: red-orange – Direct coupling   + Passive battery (voltage-driven only)
%  Case 6: green      – Direct coupling   + Active battery  (converter-controlled)
%  Case 7: purple     – Direct coupling   + Active battery  + PV Reconfiguration
clr(1,:) = [0.35, 0.70, 0.90];   % light blue    – Case 4: Indirect + Active Battery
clr(2,:) = [0.85, 0.33, 0.10];   % red-orange    – Case 5: Direct   + Passive Battery
clr(3,:) = [0.00, 0.53, 0.55];   % teal          – Case 6: Direct   + Active Battery
                                 %   (was green [0.47 0.67 0.19], too close to the
                                 %    "From PV" / "Solar-sourced" green used inside the
                                 %    stacked bars; teal is bluer and reads as a case
                                 %    colour rather than an energy-source colour)
clr(4,:) = [0.49, 0.18, 0.56];   % violet        – Case 7: Direct   + Active Battery + Reconfig
                                 %   (was reddish-purple [0.80 0.47 0.65], too close in hue to
                                 %    the Case 5 red-orange above; reviewer comment)
clr_irr  = [0.93, 0.69, 0.13];   % gold          – irradiance

ls  = {'-', '--', '-', '-.'};   % Case 7 changed from '--' to '-.' so it is
                                % distinguishable from Case 5 in line plots
                                % (and in greyscale print), not only by colour.
lw  = 1.8;    % main line width
lws = 1.2;    % secondary line width

NM{1}       = 'Case 4: Indirect PV–PEM + Active Battery';
NM{2}       = 'Case 5: Direct PV–PEM + Passive Battery';
NM{3}       = 'Case 6: Direct PV–PEM + Active Battery';
NM{4}       = 'Case 7: Reconfigurable PV–PEM + Active Battery';
NM_SHORT{1} = 'Case 4';
NM_SHORT{2} = 'Case 5';
NM_SHORT{3} = 'Case 6';
NM_SHORT{4} = 'Case 7';
NM_BAR      = {'Case 4', 'Case 5', 'Case 6', 'Case 7'};

NIGHT_THR = 70;   % W/m² — must match simulation scripts
DPI       = 300;

OUTDIR = 'comparison_batt_plots_CNR';
if ~isfolder(OUTDIR), mkdir(OUTDIR); end

% MATLAB 2026a compatible save
savefig_fn = @(fig, nm) print(fig, fullfile(OUTDIR, nm), '-dpng', sprintf('-r%d', DPI));

% =========================================================================
%  1 – LOAD EXCEL DATA
% =========================================================================
fprintf('=== Battery Topology Comparison — Cases 4–7 ===\n');
fprintf('  Case 4: Indirect PV-PEM  + Active Battery\n');
fprintf('  Case 5: Direct PV-PEM    + Passive Battery\n');
fprintf('  Case 6: Direct PV-PEM    + Active Battery\n');
fprintf('  Case 7: Reconfigurable PV-PEM + Active Battery\n\n');
fprintf('Loading simulation results...\n');

% Case 4 – Indirect PV-PEM + Active Battery (EMS power-flow model)
FILES{1} = 'Indirect_EMS_batt_results_CNR.xlsx';
% Case 5 – Direct PV-PEM + Passive Battery (directly on PEM bus, no converter)
FILES{2} = 'PV_PEM_direct_PEM_batt_results_week_CNR.xlsx';
% Case 6 – Direct PV-PEM + Active Battery (converter-controlled, no reconfiguration)
FILES{3} = 'PV_PEM_direct_batt_results_week_CNR.xlsx';
% Case 7 – Reconfigurable PV-PEM + Active Battery on DC Bus
FILES{4} = 'PV_PEM_rec_batt_results_week_CNR.xlsx';

for k = 1:NC
    if ~isfile(FILES{k})
        error('Results file missing for Case %d:\n  %s\nRun simulation script first.', k, FILES{k});
    end
    fprintf('  Case %d  ←  %s ...', k, FILES{k});
    T{k} = readtable(FILES{k}, 'Sheet','TimeSeries','VariableNamingRule','preserve');
    fprintf(' %d rows\n', height(T{k}));
end
fprintf('\n');

% =========================================================================
%  2 – EXTRACT COLUMNS  (col_safe returns a default if column is missing)
% =========================================================================
for k = 1:NC
    n  = height(T{k});
    z  = zeros(n,1);  nv = nan(n,1);

    t_h{k}        = T{k}.("t_plot_[h]");
    Irr{k}        = max(col_safe(T{k}, 'Irr_[W/m2]',        z),  0);
    PV_P{k}       = max(col_safe(T{k}, 'PV_P_[W]',          z),  0);
    PEM_P{k}      = max(col_safe(T{k}, 'PEM_P_[W]',         z),  0);
    Batt_P{k}     =     col_safe(T{k}, 'Batt_P_[W]',        z);
    Batt_P_chg{k} = max(0, col_safe(T{k}, 'Batt_P_chg_[W]', z));
    Batt_P_dis{k} = max(0, col_safe(T{k}, 'Batt_P_dis_[W]', z));
    SOC{k}        =     col_safe(T{k}, 'Batt_SOC_[%]',      50*ones(n,1));
    H2r{k}        = max(col_safe(T{k}, 'H2_rate_[g_h]',     z),  0);
    H2c{k}        = max(col_safe(T{k}, 'H2_cumul_[g]',      z),  0);
    H2c_PV{k}     = max(col_safe(T{k}, 'H2_cumul_PV_[g]',  z),  0);
    H2c_Batt{k}   = max(col_safe(T{k}, 'H2_cumul_Batt_[g]',z),  0);
    CC{k}         = max(0, min(1, col_safe(T{k}, 'Coupling_C',     nv)));
    eta_PV{k}     = max(0, min(100, col_safe(T{k}, 'eta_PV_[pct]',  nv)));
    eta_PEM{k}    = max(0, min(100, col_safe(T{k}, 'eta_PEM_[pct]', nv)));
    STH{k}        = max(0, min(100, col_safe(T{k}, 'STH_[pct]',     nv)));
    TTH{k}        = max(0, min(100, col_safe(T{k}, 'TTH_[pct]',     nv)));

    % C_sys: read directly, or derive from C_PV + PV_P if column absent
    raw_csys = col_safe(T{k}, 'C_sys', nan(n,1));
    if all(isnan(raw_csys))
        cc_valid          = CC{k} > 0.02;
        P_mpp_k           = nan(n,1);
        P_mpp_k(cc_valid) = PV_P{k}(cc_valid) ./ CC{k}(cc_valid);
        raw_csys          = PEM_P{k} ./ max(P_mpp_k, 1e-3);
        raw_csys(~cc_valid) = NaN;
    end
    C_sys{k} = min(max(raw_csys, 0), 2.0);
end

% ── NUM_DAYS, Pmax_PEM, E_init_SOC, PV_area and TTH_8day from Parameters sheet ─
NUM_DAYS   = 8;
% Fallback Pmax_PEM computed for N=16 configuration:
%   Vmax=32V, Vint_stack=23.613V, R_total=16×(0.008673+0.00177+0.0005)=0.17509Ω
%   I_rated = (32-23.613)/0.17509 = 47.9 A  →  Pmax = 32×47.9 = 1533 W
Pmax_PEM   = ones(1, NC) * 1533;  % [W]  fallback for N=16 (updated from 200W)
E_init_Wh  = zeros(1, NC);        % initial SOC energy contribution [Wh]
PV_area    = ones(1, NC) * 11.823; % [m²] fallback: 7×60×(1.689/60) = 11.823 m²
TTH_8day_param = nan(1, NC);       % 8-day integrated TTH read from Parameters sheet
for k = 1:NC
    try
        P  = readtable(FILES{k}, 'Sheet','Parameters','VariableNamingRule','preserve');
        pm = containers.Map(P{:,1}, P{:,2});
        if isKey(pm,'NUM_DAYS'),         NUM_DAYS          = pm('NUM_DAYS');           end
        if isKey(pm,'Pmax_PEM_[W]'),     Pmax_PEM(k)       = pm('Pmax_PEM_[W]');      end
        if isKey(pm,'E_init_SOC_[Wh]'),  E_init_Wh(k)      = pm('E_init_SOC_[Wh]');   end
        if isKey(pm,'PV_area_[m2]'),     PV_area(k)        = pm('PV_area_[m2]');      end
        if isKey(pm,'TTH_8day_[pct]'),   TTH_8day_param(k) = pm('TTH_8day_[pct]');    end
    catch; end
end

% ── Clamp PEM_P to rated power ────────────────────────────────────────────────
% Removes simulation switching transients (e.g. S8 spikes to 8000W on reconfig events).
% Must be done BEFORE resampling so the 10-min grid never sees the inflated values.
for k = 1:NC
    PEM_P{k} = min(PEM_P{k}, Pmax_PEM(k));
end
fprintf('  [OK] PEM_P clamped to Pmax_PEM per case (removes switching transients).\n\n');

day_ticks  = 0 : 24 : NUM_DAYS*24;
day_labels = arrayfun(@(d) sprintf('Day %d',d), 0:NUM_DAYS, 'UniformOutput', false);
x_lim      = [0, NUM_DAYS*24];

% ── Common 10-minute grid and resampling ──────────────────────────────────
t_c   = (0 : 10/60 : NUM_DAYS*24)';
nan2z = @(v) fillmissing(v, 'constant', 0);

for k = 1:NC
    Irr_c{k}         = si_safe(t_h{k}, Irr{k},            t_c);
    PV_P_c{k}        = si_safe(t_h{k}, PV_P{k},           t_c);
    PEM_P_c{k}       = si_safe(t_h{k}, PEM_P{k},          t_c);
    Batt_P_c{k}      = si_safe(t_h{k}, Batt_P{k},         t_c);
    Batt_P_chg_c{k}  = si_safe(t_h{k}, Batt_P_chg{k},     t_c);
    Batt_P_dis_c{k}  = si_safe(t_h{k}, Batt_P_dis{k},     t_c);
    SOC_c{k}         = si_safe(t_h{k}, SOC{k},             t_c);
    H2r_c{k}         = si_safe(t_h{k}, H2r{k},             t_c);
    H2c_c{k}         = si_safe(t_h{k}, H2c{k},             t_c);
    H2c_PV_c{k}      = si_safe(t_h{k}, H2c_PV{k},          t_c);
    H2c_Batt_c{k}    = si_safe(t_h{k}, H2c_Batt{k},        t_c);
    CC_c{k}          = si_safe(t_h{k}, nan2z(CC{k}),        t_c);
    C_sys_c{k}       = si_safe(t_h{k}, nan2z(C_sys{k}),     t_c);
    etaPV_c{k}       = si_safe(t_h{k}, nan2z(eta_PV{k}),    t_c);
    etaPEM_c{k}      = si_safe(t_h{k}, nan2z(eta_PEM{k}),   t_c);
    STH_c{k}         = si_safe(t_h{k}, nan2z(STH{k}),       t_c);
    TTH_c{k}         = si_safe(t_h{k}, nan2z(TTH{k}),       t_c);
end

% ── KPI computation ───────────────────────────────────────────────────────
for k = 1:NC
    dm       = Irr{k} > NIGHT_THR;   % daytime mask
    nm       = ~dm;                   % night mask
    real_t_k = T{k}.("t_real_[s]");

    % H2 totals
    kpi.H2_tot(k)      = H2c{k}(end);
    kpi.H2_PV(k)       = H2c_PV{k}(end);
    kpi.H2_Batt(k)     = H2c_Batt{k}(end);
    kpi.H2_PV_pct(k)   = kpi.H2_PV(k)   / max(kpi.H2_tot(k), 1e-6) * 100;
    kpi.H2_Batt_pct(k) = kpi.H2_Batt(k) / max(kpi.H2_tot(k), 1e-6) * 100;

    % Nighttime H2 — FIX: zero daytime, integrate full vector (avoids ~5× inflation
    % from connecting non-consecutive nighttime samples across daytime gaps).
    H2_inst_k            = max(H2r{k}, 0) / 3600;   % [g/s]
    H2_inst_night_k      = H2_inst_k;
    H2_inst_night_k(dm)  = 0;    % zero daytime; nighttime samples intact
    kpi.H2_night(k)      = trapz(real_t_k, H2_inst_night_k);
    kpi.H2_night_pct(k)  = kpi.H2_night(k) / max(kpi.H2_tot(k), 1e-6) * 100;

    % Efficiency & coupling (daytime only)
    kpi.C_PV(k)         = mean(CC{k}(dm),      'omitnan');
    kpi.C_sys(k)        = mean(C_sys{k}(dm),   'omitnan');
    kpi.mean_eta_pv(k)  = mean(eta_PV{k}(dm),  'omitnan');
    kpi.mean_eta_pem(k) = mean(eta_PEM{k}(dm), 'omitnan');
    kpi.mean_sth(k)     = mean(STH{k}(dm),     'omitnan');
    % TTH_8day: 8-day integrated Total-to-Hydrogen efficiency.
    % This MUST use the integrated formula (H2_total × LHV / ∫G·A dt) rather than
    % the daytime instantaneous mean, because the battery produces H2 at night
    % (when Irr ≤ threshold → TTH is NaN-masked in each script). Using the daytime
    % mean gives TTH ≡ STH for any case where the battery only charges during the day.
    LHV_H2_comp = 119.96e6;  % J/kg
    E_solar_k   = trapz(real_t_k, Irr{k} .* PV_area(k));   % [J]
    kpi.TTH_8day(k) = H2c{k}(end) * 1e-3 * LHV_H2_comp / max(E_solar_k, 1) * 100;
    % Override with the pre-computed value from Parameters sheet if available
    % (eliminates any small numerical difference due to resampling of Irr).
    if isfinite(TTH_8day_param(k)) && TTH_8day_param(k) > 0
        kpi.TTH_8day(k) = TTH_8day_param(k);
    end
    kpi.mean_tth(k) = kpi.TTH_8day(k);   % keep field name for downstream figure code

    % PEM capacity factor
    kpi.CF_PEM(k) = mean(PEM_P{k}, 'omitnan') / max(Pmax_PEM(k), 1) * 100;

    % Battery SOC range
    kpi.SOC_min(k) = min(SOC{k});
    kpi.SOC_max(k) = max(SOC{k});

    % Battery energy throughput [Wh]
    kpi.E_chg(k) = trapz(real_t_k, Batt_P_chg{k}) / 3600;
    kpi.E_dis(k) = trapz(real_t_k, Batt_P_dis{k}) / 3600;

    % Battery round-trip efficiency [%]
    % Denominator = E_chg + E_init_SOC so that cases where the battery
    % begins with stored energy (SOC_init > SOC_final) are handled correctly.
    % E_init_Wh is read from the Parameters sheet (0 for cases that don't write it).
    E_in_total = kpi.E_chg(k) + E_init_Wh(k);
    if E_in_total > 1
        kpi.eta_batt(k) = min(99, kpi.E_dis(k) / E_in_total * 100);
    else
        kpi.eta_batt(k) = NaN;
    end

    kpi.peak_H2(k) = max(H2r{k});
end

% Clamp SOC_min to the 20 % BMS discharge floor.
% Simulink cases (especially Indirect) occasionally dip fractionally below 20 %
% due to solver overshoot; those sub-floor values are artefacts, not real operation.
% Clamping here fixes both the B3 legend labels and the B10 SOC-range bars in one go.
kpi.SOC_min = max(kpi.SOC_min, 20);

fprintf('\n%-26s  %7s  %7s  %7s  %7s  %7s  %7s  %7s  %8s  %8s  %8s  %13s\n', ...
    'Case', 'H2(g)', 'H2%PV', 'H2%Bat', 'H2%ngt', ...
    'η_PV%', 'STH%', 'TTH%', 'C_PV', 'C_sys', 'CF_PEM%', 'η_batt(RT%)');
for k = 1:NC
    fprintf('  %-24s  %7.1f  %7.1f  %7.1f  %7.1f  %7.2f  %7.3f  %7.3f  %8.3f  %8.3f  %8.1f  %13.1f\n', ...
        NM{k}, kpi.H2_tot(k), kpi.H2_PV_pct(k), kpi.H2_Batt_pct(k), kpi.H2_night_pct(k), ...
        kpi.mean_eta_pv(k), kpi.mean_sth(k), kpi.mean_tth(k), ...
        kpi.C_PV(k), kpi.C_sys(k), kpi.CF_PEM(k), kpi.eta_batt(k));
end
fprintf('\n');

% Helper: vertical day separators
function add_day_sep(ax, dticks)
    for d = dticks(2:end-1)
        xline(ax, d, ':', 'Color', [0.72 0.72 0.72], 'HandleVisibility','off');
    end
end

% =========================================================================
%  FIGURE B1 – IRRADIANCE + PEM POWER
% =========================================================================
fprintf('Generating Fig B1: PEM Power overview...\n');
fig1 = figure('Position',[30 30 1200 540]);
tl1  = tiledlayout(2,1,'TileSpacing','compact','Padding','compact');
% title(tl1,'PEM Power and Irradiance – 8-Day Overview','FontSize',13,'FontWeight','bold');

ax1a = nexttile;
fill([t_c; flipud(t_c)], [Irr_c{1}; zeros(size(t_c))], ...
    clr_irr, 'FaceAlpha',0.35, 'EdgeColor','none');
ylabel('G  (W m^{-2})'); ylim([0 1300]);
text(0.01, 0.90, 'Solar irradiance', 'Units','normalized','FontSize',9,'Color',[0.55 0.48 0]);

ax1b = nexttile; hold on;
for k = 1:NC
    lw_k = lw;
    plot(t_c, PEM_P_c{k}, 'Color',clr(k,:), 'LineStyle',ls{k}, ...
         'LineWidth',lw_k, 'DisplayName',NM_SHORT{k});
end
hold off; ylabel('P_{PEM}  (W)');
legend('Location','northeast','FontSize',9);
xlabel('Time (hours)');

for ax = [ax1a ax1b]
    xticks(ax, day_ticks); xticklabels(ax, day_labels); xlim(ax, x_lim);
    add_day_sep(ax, day_ticks);
end
set(ax1a,'XTickLabel',[]);
drawnow; savefig_fn(fig1, 'B1_PEM_Power_Overview');

% =========================================================================
%  FIGURE B2 – CUMULATIVE H2 PRODUCTION
% =========================================================================
fprintf('Generating Fig B2: Cumulative H2...\n');
fig2 = figure('Position',[40 40 1200 430]);
ax2  = axes('Parent',fig2); hold(ax2,'on');
% title(ax2,'Cumulative Hydrogen Production – 8-Day','FontSize',13,'FontWeight','bold');
for k = 1:NC
    lw_k = lw + 0.2;
    plot(ax2, t_c, H2c_c{k}, 'Color',clr(k,:), 'LineStyle',ls{k}, ...
         'LineWidth',lw_k, ...
         'DisplayName', sprintf('%s  →  %.1f g', NM_SHORT{k}, kpi.H2_tot(k)));
end
hold(ax2,'off');
xlabel(ax2,'Time (hours)'); ylabel(ax2,'Cumulative H_2  (g)');
legend(ax2,'Location','northwest','FontSize',10);
xticks(ax2,day_ticks); xticklabels(ax2,day_labels); xlim(ax2,x_lim);
add_day_sep(ax2, day_ticks);
drawnow; savefig_fn(fig2,'B2_Cumulative_H2');

% =========================================================================
%  FIGURE B3 – BATTERY STATE OF CHARGE
% =========================================================================
fprintf('Generating Fig B3: Battery SOC...\n');
fig3 = figure('Position',[50 50 1200 500]);
ax3  = axes('Parent',fig3); hold(ax3,'on');
% title(ax3,'Battery State of Charge – 8-Day','FontSize',13,'FontWeight','bold');
for k = 1:NC
    lw_k = lw;
    plot(ax3, t_c, max(SOC_c{k}, 20), 'Color',clr(k,:), 'LineStyle',ls{k}, ...
         'LineWidth',lw_k, ...
         'DisplayName', sprintf('%s  (%3.0f – %3.0f %%)', NM_SHORT{k}, kpi.SOC_min(k), kpi.SOC_max(k)));
end
yline(ax3, 90, '--', 'Color',[0.6 0.1 0.1], 'LineWidth',1.2, 'HandleVisibility','off');
yline(ax3, 20, ':',  'Color',[0.6 0.1 0.1], 'LineWidth',1.2, 'HandleVisibility','off');
text(ax3, NUM_DAYS*24*0.995, 92, 'SOC_{max}=90%', ...
    'HorizontalAlignment','right','FontSize',8,'Color',[0.6 0.1 0.1]);
text(ax3, NUM_DAYS*24*0.995, 21.5, 'SOC_{min}=20%', ...
    'HorizontalAlignment','right','FontSize',8,'Color',[0.6 0.1 0.1]);
hold(ax3,'off');
xlabel(ax3,'Time (hours)'); ylabel(ax3,'SOC  (%)');
% Clip at 19 % — hides sub-20% Simulink overshoot from Indirect case;
% the 20% BMS floor is still visible as a reference line at the bottom.
ylim(ax3,[0 100]);
legend(ax3,'Location','southoutside','FontSize',9,'NumColumns',3);
xticks(ax3,day_ticks); xticklabels(ax3,day_labels); xlim(ax3,x_lim);
add_day_sep(ax3, day_ticks);
drawnow; savefig_fn(fig3,'B3_Battery_SOC');

% =========================================================================
%  FIGURE B4 – EFFICIENCY CHAIN  (η_PV · η_PEM · STH · TTH)
% =========================================================================
fprintf('Generating Fig B4: Efficiency chain...\n');
fig4 = figure('Position',[60 60 1200 840]);
tl4  = tiledlayout(4,1,'TileSpacing','compact','Padding','compact');
% title(tl4,'Efficiency Metrics – 8-Day Overview','FontSize',13,'FontWeight','bold');

ax4a = nexttile; hold on;
for k = 1:NC
    lw_k = lw;
    plot(t_c, etaPV_c{k}, 'Color',clr(k,:), 'LineStyle',ls{k}, 'LineWidth',lw_k, ...
         'DisplayName', sprintf('%s  (%.1f%%)', NM_SHORT{k}, kpi.mean_eta_pv(k)));
end
hold off; ylabel('\eta_{PV}  (%)'); ylim([0 30]);
legend('Location','northeast','FontSize',9);

ax4b = nexttile; hold on;
for k = 1:NC
    lw_k = lw;
    plot(t_c, etaPEM_c{k}, 'Color',clr(k,:), 'LineStyle',ls{k}, 'LineWidth',lw_k, ...
         'DisplayName', sprintf('%s  (%.1f%%)', NM_SHORT{k}, kpi.mean_eta_pem(k)));
end
hold off; ylabel('\eta_{PEM}  (%)'); ylim([60 100]);
legend('Location','best','FontSize',9);

ax4c = nexttile; hold on;
for k = 1:NC
    lw_k = lw;
    plot(t_c, STH_c{k}, 'Color',clr(k,:), 'LineStyle',ls{k}, 'LineWidth',lw_k, ...
         'DisplayName', sprintf('%s  (%.2f%%)', NM_SHORT{k}, kpi.mean_sth(k)));
end
hold off; ylabel('STH  (%)'); ylim([0 25]);
legend('Location','northeast','FontSize',9);

ax4d = nexttile; hold on;
for k = 1:NC
    lw_k = lw;
    plot(t_c, TTH_c{k}, 'Color',clr(k,:), 'LineStyle',ls{k}, 'LineWidth',lw_k, ...
         'DisplayName', sprintf('%s  (8-day TTH=%.2f%%)', NM_SHORT{k}, kpi.mean_tth(k)));
end
hold off; ylabel('TTH  (%)'); ylim([0 25]);
legend('Location','northeast','FontSize',9);
xlabel('Time (hours)');
% Note: legend shows the 8-day integrated TTH in the label, while the curve
% shows the instantaneous TTH time-series. The label value correctly accounts
% for nighttime battery-sourced H2 production.

for ax = [ax4a ax4b ax4c ax4d]
    xticks(ax,day_ticks); xticklabels(ax,day_labels); xlim(ax,x_lim);
    add_day_sep(ax, day_ticks);
end
set(ax4a,'XTickLabel',[]); set(ax4b,'XTickLabel',[]); set(ax4c,'XTickLabel',[]);
drawnow; savefig_fn(fig4,'B4_Efficiency_Chain');

% =========================================================================
%  FIGURE B5 – H2 RATE VS IRRADIANCE  (scatter, one panel per case)
% =========================================================================
fprintf('Generating Fig B5: H2 rate scatter...\n');
fig5 = figure('Position',[70 70 max(2000, 330*NC) 420]);
tl5  = tiledlayout(1,NC,'TileSpacing','loose','Padding','compact');
% title(tl5,'H_2 Production Rate vs Solar Irradiance  (daytime only)', ...
%     'FontSize',13,'FontWeight','bold');

for k = 1:NC
    dm  = Irr{k} > NIGHT_THR;
    idx = find(dm);
    if numel(idx) > 6000, idx = idx(round(linspace(1,numel(idx),6000))); end
    nexttile;
    scatter(Irr{k}(idx), H2r{k}(idx), 12, clr(k,:), 'filled', 'MarkerFaceAlpha',0.45);
    xlabel('G  (W m^{-2})'); ylabel('H_2 rate  (g h^{-1})');
    title(NM_SHORT{k},'FontSize',10,'FontWeight','bold');
    xlim([0 1100]); ylim([0 25]); grid on; box on;
end
drawnow; savefig_fn(fig5,'B5_H2Rate_vs_Irradiance');

% ── Shared y-limits for B6 (computed once, applied to every panel) ────────
pb_max = max(cellfun(@(v) max(v, [], 'omitnan'), PV_P_c))  * 1.15;
pb_min = -max(cellfun(@(v) max(v, [], 'omitnan'), Batt_P_dis_c)) * 1.15;
if ~isfinite(pb_max) || pb_max <= 0, pb_max = 2000; end
if pb_min >= 0, pb_min = -pb_max * 0.12; end   % ensure visible negative headroom
pb_lim = [pb_min, pb_max];

% =========================================================================
%  FIGURE B6 – POWER BALANCE  (shaded, one panel per case)
% =========================================================================
fprintf('Generating Fig B6: Power balance...\n');
fig6 = figure('Position',[80 80 1200 max(1075, 195*NC)]);
tl6  = tiledlayout(NC,1,'TileSpacing','compact','Padding','compact');
% title(tl6,'Power Balance – PV | PEM | Battery','FontSize',13,'FontWeight','bold');

for k = 1:NC
    ax = nexttile; hold(ax,'on');
    fill(ax, [t_c; flipud(t_c)], [PV_P_c{k}; zeros(size(t_c))], ...
        clr_irr, 'FaceAlpha',0.30, 'EdgeColor','none', 'DisplayName','P_{PV}');
    plot(ax, t_c, PEM_P_c{k}, 'Color',clr(k,:), 'LineWidth',lw, 'DisplayName','P_{PEM}');
    fill(ax, [t_c; flipud(t_c)], [Batt_P_chg_c{k}; zeros(size(t_c))], ...
        [0.47 0.25 0.80], 'FaceAlpha',0.22, 'EdgeColor','none', 'DisplayName','P_{chg}');
    fill(ax, [t_c; flipud(t_c)], [-Batt_P_dis_c{k}; zeros(size(t_c))], ...
        [0.13 0.60 0.90], 'FaceAlpha',0.28, 'EdgeColor','none', 'DisplayName','P_{disch}');
    yline(ax,0,'k:','HandleVisibility','off');
    hold(ax,'off');
    ylim(ax, pb_lim);          % identical y-axis on every panel
    ylabel(ax,'Power  (W)');
    title(ax, NM{k},'FontSize',9,'FontWeight','bold');
    legend(ax,'Location','northeast','FontSize',8,'NumColumns',2);
    xticks(ax,day_ticks); xticklabels(ax,day_labels); xlim(ax,x_lim);
    add_day_sep(ax, day_ticks);
end
xlabel('Time (hours)');
drawnow; savefig_fn(fig6,'B6_Power_Balance');

% =========================================================================
%  FIGURE B7 – KPI SUMMARY  (2 × 4 panels)
% =========================================================================
fprintf('Generating Fig B7: KPI summary (2×4)...\n');
fig7 = figure('Position',[90 90 1920 760]);
tl7  = tiledlayout(2,4,'TileSpacing','loose','Padding','compact');
% title(tl7,'Key Performance Indicators – 8-Day Summary','FontSize',14,'FontWeight','bold');
x = 1:NC;

% bar_lbl: works for any number of bars
bar_lbl = @(ax,vals,fmt,off) arrayfun(@(k) ...
    text(ax,k,vals(k)+off,sprintf(fmt,vals(k)), ...
    'HorizontalAlignment','center','FontSize',9,'FontWeight','bold'), 1:numel(vals));

% ── Row 1 / Panel 1: Total H2 (stacked: PV + Battery) ────────────────────
ax7a = nexttile;
H2_stack7 = [kpi.H2_PV', kpi.H2_Batt'];
bh7a = bar(ax7a, x, H2_stack7, 0.55, 'stacked');
bh7a(1).FaceColor = [0.22 0.63 0.22];   % green → solar
bh7a(2).FaceColor = [0.47 0.25 0.80];   % purple → battery
set(ax7a,'XTick',x,'XTickLabel',NM_BAR); xtickangle(ax7a,0);
ylabel(ax7a,'H_2  (g)');
h2_ymax = max(kpi.H2_tot)*1.22; if ~isfinite(h2_ymax)||h2_ymax<=0, h2_ymax=10; end
ylim(ax7a,[0 h2_ymax]);
title(ax7a,'H_2 Produced (PV + Batt)','FontWeight','bold');
grid(ax7a,'on'); box(ax7a,'on');
legend(ax7a,{'From PV','From Battery'},'Location','north','FontSize',8);
for k = 1:NC
    text(ax7a,k,kpi.H2_tot(k)+h2_ymax*0.02, sprintf('%.0f g',kpi.H2_tot(k)), ...
        'HorizontalAlignment','center','FontSize',8,'FontWeight','bold');
end

% ── Row 1 / Panel 2: η_PV ────────────────────────────────────────────────
ax7b = nexttile;
bh7b = bar(ax7b, x, kpi.mean_eta_pv, 0.55);  bh7b.FaceColor = 'flat';
for k = 1:NC, bh7b.CData(k,:) = clr(k,:); end
set(ax7b,'XTick',x,'XTickLabel',NM_BAR); xtickangle(ax7b,0);
ylabel(ax7b,'\eta_{PV}  (%)');
epv_mx = max(kpi.mean_eta_pv)*1.28; if ~isfinite(epv_mx)||epv_mx<=0, epv_mx=25; end
ylim(ax7b,[0 epv_mx]);
title(ax7b,'PV Panel Efficiency','FontWeight','bold'); grid(ax7b,'on'); box(ax7b,'on');
bar_lbl(ax7b, kpi.mean_eta_pv, '%.1f%%', epv_mx*0.025);

% ── Row 1 / Panel 3: STH ─────────────────────────────────────────────────
ax7c = nexttile;
bh7c = bar(ax7c, x, kpi.mean_sth, 0.55);  bh7c.FaceColor = 'flat';
for k = 1:NC, bh7c.CData(k,:) = clr(k,:); end
set(ax7c,'XTick',x,'XTickLabel',NM_BAR); xtickangle(ax7c,0);
ylabel(ax7c,'STH  (%)');
sth_mx = max(kpi.mean_sth)*1.28; if ~isfinite(sth_mx)||sth_mx<=0, sth_mx=15; end
ylim(ax7c,[0 sth_mx]);
title(ax7c,'Solar-to-H_2 Efficiency (STH)','FontWeight','bold');
grid(ax7c,'on'); box(ax7c,'on');
bar_lbl(ax7c, kpi.mean_sth, '%.2f%%', sth_mx*0.025);

% ── Row 1 / Panel 4: TTH (8-day integrated) ──────────────────────────────
% NOTE: TTH is plotted as the 8-day integrated metric
%   TTH_8day = (H2_total × LHV) / ∫(G × A_PV) dt × 100   [%]
% This correctly captures nighttime battery-sourced H2. The instantaneous
% daytime mean (the original formula) gives TTH ≡ STH for topologies where
% the battery charges during the day and only discharges at night, because
% all daytime H2 is solar-attributed (pv_frac = 1) and nighttime TTH is NaN.
ax7d = nexttile;
bh7d = bar(ax7d, x, kpi.mean_tth, 0.55);  bh7d.FaceColor = 'flat';
for k = 1:NC, bh7d.CData(k,:) = clr(k,:); end
set(ax7d,'XTick',x,'XTickLabel',NM_BAR); xtickangle(ax7d,0);
ylabel(ax7d,'TTH  (%)');
tth_mx = max(kpi.mean_tth)*1.28; if ~isfinite(tth_mx)||tth_mx<=0, tth_mx=15; end
ylim(ax7d,[0 tth_mx]);
title(ax7d,'Total-to-H_2 Efficiency, 8-day integrated (TTH)','FontWeight','bold');
grid(ax7d,'on'); box(ax7d,'on');
bar_lbl(ax7d, kpi.mean_tth, '%.2f%%', tth_mx*0.025);

% ── Row 2 / Panel 5: C_PV vs C_sys (grouped bar) ─────────────────────────
ax7e = nexttile; hold(ax7e,'on');
C_data = [kpi.C_PV', kpi.C_sys'];
bh7e   = bar(ax7e, x, C_data, 0.65, 'grouped');
bh7e(1).FaceColor = [0.22 0.60 0.82];   % blue → C_PV
bh7e(2).FaceColor = [0.95 0.60 0.15];   % orange → C_sys
hold(ax7e,'off');
set(ax7e,'XTick',x,'XTickLabel',NM_BAR); xtickangle(ax7e,0);
ylabel(ax7e,'Coupling factor'); ylim(ax7e,[0 1.35]);
title(ax7e,'C_{PV} vs C_{sys}  (daytime mean)','FontWeight','bold');
legend(ax7e,{'C_{PV} = P_{PV}/P_{mpp}','C_{sys} = P_{PEM}/P_{mpp}'}, ...
    'Location','north','FontSize',8);
grid(ax7e,'on'); box(ax7e,'on');
for k = 1:NC
    text(ax7e,k-0.17, kpi.C_PV(k)+0.03,  sprintf('%.3f',kpi.C_PV(k)), ...
        'HorizontalAlignment','center','FontSize',8);
    text(ax7e,k+0.17, kpi.C_sys(k)+0.03, sprintf('%.3f',kpi.C_sys(k)), ...
        'HorizontalAlignment','center','FontSize',8);
end

% ── Row 2 / Panel 6: PEM Capacity Factor ─────────────────────────────────
ax7f = nexttile;
bh7f = bar(ax7f, x, kpi.CF_PEM, 0.55);  bh7f.FaceColor = 'flat';
for k = 1:NC, bh7f.CData(k,:) = clr(k,:); end
set(ax7f,'XTick',x,'XTickLabel',NM_BAR); xtickangle(ax7f,0);
ylabel(ax7f,'CF_{PEM}  (%)');
cf_mx = max([kpi.CF_PEM, 10])*1.28;
ylim(ax7f,[0 cf_mx]);
title(ax7f,'PEM Capacity Factor','FontWeight','bold'); grid(ax7f,'on'); box(ax7f,'on');
bar_lbl(ax7f, kpi.CF_PEM, '%.1f%%', cf_mx*0.025);

% ── Row 2 / Panel 7: Battery round-trip efficiency ────────────────────────
ax7g = nexttile;
eta_b_plot = kpi.eta_batt;
eta_b_plot(~isfinite(eta_b_plot)) = 0;
bh7g = bar(ax7g, x, eta_b_plot, 0.55);  bh7g.FaceColor = 'flat';
for k = 1:NC, bh7g.CData(k,:) = clr(k,:); end
set(ax7g,'XTick',x,'XTickLabel',NM_BAR); xtickangle(ax7g,0);
ylabel(ax7g,'\eta_{batt,RT}  (%)'); ylim(ax7g,[0 105]);
title(ax7g,'Battery Round-Trip Efficiency','FontWeight','bold');
grid(ax7g,'on'); box(ax7g,'on');
for k = 1:NC
    if isfinite(kpi.eta_batt(k)) && kpi.eta_batt(k) > 0
        text(ax7g,k,kpi.eta_batt(k)+2.5,sprintf('%.1f%%',kpi.eta_batt(k)), ...
            'HorizontalAlignment','center','FontSize',9,'FontWeight','bold');
    else
        text(ax7g,k,3,'n/a','HorizontalAlignment','center','FontSize',8,'Color',[0.5 0.5 0.5]);
    end
end

% ── Row 2 / Panel 8: H2 source attribution ────────────────────────────────
ax7h = nexttile;
H2_attr = [kpi.H2_PV_pct', kpi.H2_Batt_pct'];
bh7h = bar(ax7h, x, H2_attr, 0.55, 'stacked');
bh7h(1).FaceColor = [0.22 0.63 0.22];   % green → PV
bh7h(2).FaceColor = [0.47 0.25 0.80];   % purple → battery
set(ax7h,'XTick',x,'XTickLabel',NM_BAR); xtickangle(ax7h,0);
ylabel(ax7h,'H_2 attribution  (%)'); ylim(ax7h,[0 120]);
title(ax7h,'H_2 Source Attribution','FontWeight','bold');
grid(ax7h,'on'); box(ax7h,'on');
legend(ax7h,{'Solar-sourced','Battery-sourced'},'Location','north','FontSize',8);
for k = 1:NC
    if kpi.H2_PV_pct(k) > 5
        text(ax7h,k,kpi.H2_PV_pct(k)/2, sprintf('%.0f%%',kpi.H2_PV_pct(k)), ...
            'HorizontalAlignment','center','FontSize',8,'Color','w','FontWeight','bold');
    end
    if kpi.H2_Batt_pct(k) > 5
        text(ax7h,k,kpi.H2_PV_pct(k)+kpi.H2_Batt_pct(k)/2, ...
            sprintf('%.0f%%',kpi.H2_Batt_pct(k)), ...
            'HorizontalAlignment','center','FontSize',8,'Color','w','FontWeight','bold');
    end
end

% Suppress the interactive axes toolbar: when the figure is printed from a
% non-interactive session it is otherwise rasterised into the top-right
% panel and overlaps the title.
for a7 = findall(fig7,'Type','axes')'
    if isprop(a7,'Toolbar') && ~isempty(a7.Toolbar)
        a7.Toolbar.Visible = 'off';
    end
end
drawnow; savefig_fn(fig7,'B7_KPI_Summary');

% =========================================================================
%  FIGURE B10 – BATTERY SYSTEM CHARACTERISATION
% =========================================================================
fprintf('Generating Fig B10: Battery characterisation...\n');
fig10 = figure('Position',[120 120 1300 480]);
tl10  = tiledlayout(1,2,'TileSpacing','loose','Padding','compact');
% title(tl10,'Battery System Characterisation – 8-Day','FontSize',13,'FontWeight','bold');

ax10a = nexttile;
E_data = [kpi.E_chg', kpi.E_dis'];
bh10a  = bar(ax10a, x, E_data, 0.65, 'grouped');
bh10a(1).FaceColor = [0.47 0.25 0.80];   % purple → charge
bh10a(2).FaceColor = [0.13 0.60 0.90];   % teal → discharge
set(ax10a,'XTick',x,'XTickLabel',NM_BAR); xtickangle(ax10a,45);
ylabel(ax10a,'Energy  (Wh)');
e_mx = max([kpi.E_chg, kpi.E_dis, 1])*1.25;
ylim(ax10a,[0 e_mx]);
title(ax10a,'Battery Energy Throughput','FontWeight','bold');
legend(ax10a,{'Charged (Wh)','Discharged (Wh)'},'Location','north','FontSize',9);
grid(ax10a,'on'); box(ax10a,'on');
for k = 1:NC
    text(ax10a,k-0.18, kpi.E_chg(k)+e_mx*0.02, sprintf('%.0f',kpi.E_chg(k)), ...
        'HorizontalAlignment','center','FontSize',8);
    text(ax10a,k+0.18, kpi.E_dis(k)+e_mx*0.02, sprintf('%.0f',kpi.E_dis(k)), ...
        'HorizontalAlignment','center','FontSize',8);
end

ax10b = nexttile; hold(ax10b,'on');
for k = 1:NC
    fill(ax10b, [k-0.30 k+0.30 k+0.30 k-0.30], ...
        [kpi.SOC_min(k) kpi.SOC_min(k) kpi.SOC_max(k) kpi.SOC_max(k)], ...
        clr(k,:), 'FaceAlpha',0.50, 'EdgeColor',clr(k,:)*0.65, 'LineWidth',1.5);
    plot(ax10b, k, mean([kpi.SOC_min(k) kpi.SOC_max(k)]), ...
        'k_', 'MarkerSize',18, 'LineWidth',2);
    text(ax10b, k, kpi.SOC_max(k)+3.0, sprintf('%.0f%%',kpi.SOC_max(k)), ...
        'HorizontalAlignment','center','FontSize',9,'FontWeight','bold');
    text(ax10b, k, kpi.SOC_min(k)-2.0, sprintf('%.0f%%',kpi.SOC_min(k)), ...
        'HorizontalAlignment','center','FontSize',9);
end
yline(ax10b, 90, '--r', 'LineWidth',1.2, 'HandleVisibility','off');
yline(ax10b, 20, ':r',  'LineWidth',1.2, 'HandleVisibility','off');
text(ax10b, NC+0.42, 91.5, 'SOC_{max}=90%', 'FontSize',8, 'Color',[0.6 0.1 0.1]);
text(ax10b, NC+0.42, 17.5, 'SOC_{min}=20%', 'FontSize',8, 'Color',[0.6 0.1 0.1]);
hold(ax10b,'off');
set(ax10b,'XTick',x,'XTickLabel',NM_BAR); xtickangle(ax10b,45);
ylabel(ax10b,'SOC  (%)'); ylim(ax10b,[15 110]); xlim(ax10b,[0.5 NC+0.5]);
title(ax10b,'SOC Operating Range (min – max)','FontWeight','bold');
grid(ax10b,'on'); box(ax10b,'on');

drawnow; savefig_fn(fig10,'B10_Battery_Characterisation');

% ── Shared y-limit for B8 left axis (H2 rate) ────────────────────────────
h2r_max = max(cellfun(@(v) max(v, [], 'omitnan'), H2r_c)) * 1.15;
if ~isfinite(h2r_max) || h2r_max <= 0, h2r_max = 25; end

% =========================================================================
%  FIGURE B8 – H2 RATE + IRRADIANCE  (one panel per case)
% =========================================================================
fprintf('Generating Fig B8: H2 rate daily rhythm...\n');
fig8 = figure('Position',[100 100 1200 max(1075, 195*NC)]);
tl8  = tiledlayout(NC,1,'TileSpacing','compact','Padding','compact');
% title(tl8,'H_2 Production Rate vs Irradiance Profile','FontSize',13,'FontWeight','bold');

for k = 1:NC
    ax = nexttile;
    yyaxis(ax,'left');  ax.YColor = clr(k,:);
    plot(ax, t_c, H2r_c{k}, 'Color',clr(k,:), 'LineWidth',lw, 'DisplayName','H_2 rate');
    ylim(ax, [0, h2r_max]);    % identical left-axis scale on every panel
    ylabel(ax,'H_2 rate  (g h^{-1})');
    yyaxis(ax,'right'); ax.YColor = clr_irr;
    plot(ax, t_c, Irr_c{k}, 'Color',clr_irr, 'LineWidth',lws, 'LineStyle','--', 'DisplayName','G');
    ylabel(ax,'G  (W m^{-2})'); ylim(ax,[0 1400]);
    title(ax, NM{k}, 'FontSize',10,'FontWeight','bold');
    legend(ax,'Location','northeast','FontSize',8,'NumColumns',2);
    xticks(ax,day_ticks); xticklabels(ax,day_labels); xlim(ax,x_lim);
    add_day_sep(ax, day_ticks);
end
xlabel('Time (hours)');
drawnow; savefig_fn(fig8,'B8_H2Rate_Daily_Rhythm');

% =========================================================================
%  FIGURE B9 – H2 ATTRIBUTION  (PV-sourced vs Battery-sourced)
% =========================================================================
fprintf('Generating Fig B9: H2 attribution PV vs Battery...\n');
fig9 = figure('Position',[110 110 1400 600]);
tl9  = tiledlayout(1,2,'TileSpacing','loose','Padding','compact');
% title(tl9,'Hydrogen Production Attribution – PV vs Battery','FontSize',13,'FontWeight','bold');

ax9a = nexttile;
H2_stack = [kpi.H2_PV', kpi.H2_Batt'];
bh9 = bar(ax9a, 1:NC, H2_stack, 0.55, 'stacked');
bh9(1).FaceColor = [0.22 0.63 0.22];
bh9(2).FaceColor = [0.47 0.25 0.80];
set(ax9a,'XTick',1:NC,'XTickLabel',NM_BAR); xtickangle(ax9a,45);
ylabel(ax9a,'Cumulative H_2  (g)');
ylim_top = max(kpi.H2_tot) * 1.25;
if ylim_top <= 0 || ~isfinite(ylim_top), ylim_top = 10; end
ylim(ax9a,[0, ylim_top]);
title(ax9a,'Total H_2: PV vs Battery','FontWeight','bold');
grid(ax9a,'on'); box(ax9a,'on');
legend(ax9a, {'H_2 from PV','H_2 from Battery'}, 'Location','northeast','FontSize',9);
for k = 1:NC
    if kpi.H2_PV(k) > 0.05 * kpi.H2_tot(k)
        text(ax9a, k, kpi.H2_PV(k)/2, sprintf('%.1fg', kpi.H2_PV(k)), ...
            'HorizontalAlignment','center','FontSize',8,'Color','w','FontWeight','bold');
    end
    if kpi.H2_Batt(k) > 0.05 * kpi.H2_tot(k)
        text(ax9a, k, kpi.H2_PV(k) + kpi.H2_Batt(k)/2, ...
            sprintf('%.1fg', kpi.H2_Batt(k)), ...
            'HorizontalAlignment','center','FontSize',8,'Color','w','FontWeight','bold');
    end
    text(ax9a, k, kpi.H2_tot(k) + ylim_top*0.02, ...
        sprintf('%.0fg', kpi.H2_tot(k)), ...
        'HorizontalAlignment','center','FontSize',9,'FontWeight','bold');
end

ax9b = nexttile; hold(ax9b,'on');
title(ax9b,'Cumulative H_2 Over Time','FontWeight','bold');
for k = 1:NC
    lw_k = lw;
    plot(ax9b, t_c, H2c_PV_c{k}, 'Color',clr(k,:), 'LineStyle',ls{k}, ...
         'LineWidth',lw_k, 'DisplayName', sprintf('%s – PV', NM_SHORT{k}));
    plot(ax9b, t_c, H2c_Batt_c{k}, 'Color',clr(k,:)*0.65, 'LineStyle',':', ...
         'LineWidth',lws, 'DisplayName', sprintf('%s – Batt', NM_SHORT{k}));
end
hold(ax9b,'off');
xlabel(ax9b,'Time (hours)'); ylabel(ax9b,'Cumulative H_2  (g)');
legend(ax9b,'Location','northwest','FontSize',8,'NumColumns',2);
xticks(ax9b,day_ticks); xticklabels(ax9b,day_labels); xlim(ax9b,x_lim);
add_day_sep(ax9b, day_ticks);

drawnow; savefig_fn(fig9,'B9_H2_Attribution_PV_vs_Batt');

% =========================================================================
%  CONSOLE SUMMARY
% =========================================================================
fprintf('\n=== Final KPI Summary ===\n');
sep = repmat('─',1,130); fprintf('%s\n',sep);
fprintf('%-26s  %7s  %6s  %6s  %6s  %7s  %7s  %7s  %6s  %6s  %7s  %8s  %13s\n', ...
    'Case','H2(g)','PV%','Bat%','Ngt%','η_PV','STH','TTH','C_PV','C_sys','CF_PEM','η_batt','SOC min–max');
fprintf('%s\n',sep);
for k = 1:NC
    eta_b_str = 'n/a';
    if isfinite(kpi.eta_batt(k)), eta_b_str = sprintf('%.1f%%',kpi.eta_batt(k)); end
    fprintf('  %-24s  %7.1f  %5.1f%%  %5.1f%%  %5.1f%%  %6.2f%%  %6.3f%%  %6.3f%%  %5.3f  %5.3f  %6.1f%%  %8s  %5.0f – %5.0f %%\n', ...
        NM{k}, kpi.H2_tot(k), kpi.H2_PV_pct(k), kpi.H2_Batt_pct(k), kpi.H2_night_pct(k), ...
        kpi.mean_eta_pv(k), kpi.mean_sth(k), kpi.mean_tth(k), ...
        kpi.C_PV(k), kpi.C_sys(k), kpi.CF_PEM(k), eta_b_str, ...
        kpi.SOC_min(k), kpi.SOC_max(k));
end
fprintf('%s\n',sep);
fprintf('\n  Column key:\n');
fprintf('    H2(g)  = total H2 produced over 8 days\n');
fprintf('    PV%%    = fraction sourced from solar\n');
fprintf('    Bat%%   = fraction sourced from battery discharge\n');
fprintf('    Ngt%%   = fraction produced at night (Irr < %d W/m²)\n', NIGHT_THR);
fprintf('    C_PV   = PV coupling to MPP  = mean(P_PV/P_mpp) daytime\n');
fprintf('    C_sys  = system coupling     = mean(P_PEM/P_mpp) daytime\n');
fprintf('    CF_PEM = PEM capacity factor = mean(P_PEM)/P_rated (all hours)\n');
fprintf('    eta_batt = battery RT eff.  = min(99%%, E_dis/(E_chg+E_init) x 100%%)\n');
fprintf('             E_init = initial SOC energy drawn (from Parameters sheet; 0 if absent)\n');
fprintf('\n  Figures saved → %s\n', fullfile(pwd, OUTDIR));
fprintf('=== compare_batt_cases DONE ===\n\n');

% =========================================================================
%  LOCAL HELPER FUNCTIONS
% =========================================================================
function y = col_safe(Tbl, colname, default)
%COL_SAFE  Read a table column by name; return default if absent.
    try
        y = Tbl.(colname);
    catch
        y = default;
        fprintf('    [NOTE] Column "%s" not found — using default.\n', colname);
    end
end

function yq = si_safe(ts, ys, tq)
%SI_SAFE  Interpolate to tq; tolerates duplicate timestamps.
    [ts_u, ia] = unique(ts, 'stable');
    ys_u = ys(ia);
    yq   = interp1(ts_u, ys_u, tq, 'linear', 'extrap');
end
