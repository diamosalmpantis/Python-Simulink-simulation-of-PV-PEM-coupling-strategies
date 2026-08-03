% =============================================================================
%  compare_cases.m
%
%  Loads post-simulation results from three PV-PEM coupling topologies and
%  generates publication-quality comparison figures for a scientific paper.
%
%  Topologies compared
%    Case A – Direct Static coupling         (PV_PEM_direct_results.xlsx)
%    Case D – Indirect via Boost converter   (PV_PEM_indirect_results_week_new_size.xlsx)
%    Case G – Reconfigurable Direct coupling (PV_PEM_direct_reconfiguration_week_new_size.xlsx)
%
%  Output: PNG figures @ 300 DPI in ./comparison_plots/
%          KPI summary printed to console and saved as comparison_KPIs.mat
%
%  Run each simulation script first to generate the Excel result files.
% =============================================================================
clear; clc; close all;
warning('off','all');
% =========================================================================
%  0 – GLOBAL PLOT STYLE
% =========================================================================
set(groot, ...
    'defaultAxesFontSize',   11, ...
    'defaultAxesFontName',   'Arial', ...
    'defaultTextFontSize',   11, ...
    'defaultTextFontName',   'Arial', ...
    'defaultAxesBox',        'on', ...
    'defaultAxesXGrid',      'on', ...
    'defaultAxesYGrid',      'on', ...
    'defaultAxesLineWidth',  0.8, ...
    'defaultFigureColor',    'w');
% Colors – colorblind-safe (Wong 2011 palette)
clr.A   = [0.00, 0.45, 0.70];   % blue   – Direct Static
clr.D   = [0.85, 0.33, 0.10];   % red    – Indirect (Boost)
clr.G   = [0.47, 0.67, 0.19];   % green  – Reconfigurable
clr.irr = [0.93, 0.69, 0.13];   % gold   – Irradiance
clr.mpp = [0.30, 0.30, 0.30];   % dark grey – MPP reference
% Line styles  (helps distinguish in greyscale print)
ls.A = '-';   ls.D = '--';   ls.G = '-.';
lw  = 1.8;    % primary line width
lws = 1.2;    % secondary / reference line width
% Case display names (used in all legends, labels, and titles)
NM.A = 'Direct';
NM.D = 'Indirect';
NM.G = sprintf('Reconfigurable\nDirect Coupling');
NM_SHORT.A = 'Direct';
NM_SHORT.D = 'Indirect';
NM_SHORT.G = 'Reconfigurable';
NIGHT_THR = 70;   % W/m²  – irradiance cut-off for daytime statistics (matches simulation scripts)
DPI       = 300;
OUTDIR = 'comparison_plots_CNR';
if ~isfolder(OUTDIR), mkdir(OUTDIR); end
savefig_fn = @(fig, nm) print(fig, fullfile(OUTDIR, nm), '-dpng', sprintf('-r%d', DPI));
% =========================================================================
%  1 – LOAD EXCEL DATA
% =========================================================================
fprintf('=== PV-PEM Coupling Topology Comparison ===\n\n');
fprintf('Loading simulation results...\n');
FILES.A = 'PV_PEM_direct_results_CNR.xlsx';
FILES.D = 'PV_PEM_indirect_results_week_new_size_CNR.xlsx';
FILES.G = 'PV_PEM_direct_reconfiguration_week_new_size_CNR.xlsx';
CASES = {'A','D','G'};
for k = 1:3
    c  = CASES{k};
    fn = FILES.(c);
    if ~isfile(fn)
        error('Results file missing for Case %s:\n  %s\nRun the simulation script first.', c, fn);
    end
    fprintf('  Case %s  ←  %s ...', c, fn);
    T.(c) = readtable(fn, 'Sheet','TimeSeries', 'VariableNamingRule','preserve');
    fprintf(' %d rows\n', height(T.(c)));
end
fprintf('\n');
% =========================================================================
%  2 – EXTRACT VARIABLES (handles column-name differences between cases)
% =========================================================================
has_col = @(tbl, nm) ismember(nm, tbl.Properties.VariableNames);
% ---- Case A ----
tA      = T.A.("t_plot_[h]");
real_tA = T.A.("t_real_[s]");
IrrA    = max(T.A.("Irr_[W/m2]"), 0);
PVV_A   = max(T.A.("PV_V_[V]"),   0);
PVI_A   = max(T.A.("PV_I_[A]"),   0);
PVP_A   = max(T.A.("PV_P_[W]"),   0);
PEMV_A  = max(T.A.("PEM_V_[V]"),  0);
PEMI_A  = max(T.A.("PEM_I_[A]"),  0);
PEMP_A  = PEMV_A .* PEMI_A;
CA      = max(0, min(1, T.A.("Coupling_Factor_C")));
PerrA   = abs(T.A.("Power_Error_[W]"));
PmppA   = T.A.("P_MPP_ref_[W]");
STH_A   = T.A.("STH_[pct]");
H2A     = max(T.A.("H2_Flow_[g_h]"), 0);
H2cumA  = cumtrapz(real_tA, H2A / 3600);
etaA    = PEMP_A ./ max(PVP_A, 1e-3) * 100;
etaA    = min(etaA, 99);
% ---- Case D ----
tD      = T.D.("t_plot_[h]");
real_tD = T.D.("t_real_[s]");
IrrD    = max(T.D.("Irr_[W/m2]"), 0);
PVV_D   = max(T.D.("PV_V_[V]"),   0);
PVI_D   = max(T.D.("PV_I_[A]"),   0);
PVP_D   = max(T.D.("PV_P_[W]"),   0);
PEMV_D  = max(T.D.("PEM_V_[V]"),  0);
PEMI_D  = max(T.D.("PEM_I_[A]"),  0);
if has_col(T.D, 'PEM_P_[W]')
    PEMP_D = T.D.("PEM_P_[W]");
else
    PEMP_D = PEMV_D .* PEMI_D;
end
CD      = max(0, min(1, T.D.("Coupling_Factor_C")));
PerrD   = abs(T.D.("Power_Error_[W]"));
PmppD   = T.D.("P_MPP_ref_[W]");
STH_D   = T.D.("STH_[pct]");
if has_col(T.D, 'H2_rate_[g_h]')
    H2D = max(T.D.("H2_rate_[g_h]"), 0);
else
    H2D = max(T.D.("H2_Flow_[g_h]"), 0);
end
if has_col(T.D, 'H2_cumul_[g]')
    H2cumD = T.D.("H2_cumul_[g]");
else
    H2cumD = cumtrapz(real_tD, H2D / 3600);
end
etaD    = PEMP_D ./ max(PVP_D, 1e-3) * 100;
etaD    = min(etaD, 99);
% ---- Case G ----
tG      = T.G.("t_plot_[h]");
real_tG = T.G.("t_real_[s]");
% Detect & correct time-axis bug (sim-seconds vs hours)
if max(tG) < max(tA) * 0.2
    tG = tG * (36000 / 3600);   % scale_factor=36000 → hours
    fprintf('  [NOTE] Case G time axis auto-corrected (sim-time → hours)\n\n');
end
IrrG    = max(T.G.("Irr_[W/m2]"), 0);
PVV_G   = max(T.G.("PV_V_[V]"),   0);
PVI_G   = max(T.G.("PV_I_[A]"),   0);
PVP_G   = max(T.G.("PV_P_[W]"),   0);
PEMV_G  = max(T.G.("PEM_V_[V]"),  0);
PEMI_G  = max(T.G.("PEM_I_[A]"),  0);
PEMP_G  = PEMV_G .* PEMI_G;
CG      = max(0, min(1, T.G.("Coupling_Factor_C")));
PerrG   = abs(T.G.("Power_Error_[W]"));
PmppG   = T.G.("P_MPP_ref_[W]");
STH_G   = T.G.("STH_[pct]");
H2G     = max(T.G.("H2_Flow_[g_h]"), 0);
H2cumG  = cumtrapz(real_tG, H2G / 3600);
etaG    = PEMP_G ./ max(PVP_G, 1e-3) * 100;
etaG    = min(etaG, 99);
% ---- PV solar-to-electric efficiency η_PV [%] ----
try, etaPV_A = max(T.A.("eta_PV_[pct]"), 0); catch, etaPV_A = zeros(height(T.A),1); end
try, etaPV_D = max(T.D.("eta_PV_[pct]"), 0); catch, etaPV_D = zeros(height(T.D),1); end
try, etaPV_G = max(T.G.("eta_PV_[pct]"), 0); catch, etaPV_G = zeros(height(T.G),1); end
% ---- PEM electrochemical efficiency η_PEM [%] ----
try, etaPEM_A = max(T.A.("eta_PEM_[pct]"), 0); catch, etaPEM_A = zeros(height(T.A),1); end
try, etaPEM_D = max(T.D.("eta_PEM_[pct]"), 0); catch, etaPEM_D = zeros(height(T.D),1); end
try, etaPEM_G = max(T.G.("eta_PEM_[pct]"), 0); catch, etaPEM_G = zeros(height(T.G),1); end
% =========================================================================
%  2c – P_MPP_REF  VALIDATION AND REPAIR
%
%  If the Excel was produced when lookup .mat files were missing, the stored
%  P_MPP_ref_[W], Coupling_Factor_C, and Power_Error_[W] columns will all
%  be 0 (or near 0).  The symptom is a flat 4800-5000 Wh "mismatch" from
%  every sample hitting the −50 W clamp and an invisible dashed reference
%  line in Figure C4.
%
%  Fix: recompute from physics using the already-correct PV_P and Irr columns.
%    P_mpp(Np, G) = Np × Impp_cell × (G/1000) × Ns × Vmpp_cell   [W]
%  Cases A/D use fixed Np = 12.
%  Case G uses the Np_active_[-] column (config-aware); if that is also
%  broken (all zeros), estimate from the irradiance thresholds.
% =========================================================================
pv_Ns   = 60;     % cells in series per string  (Ns=60)
pv_Impp = 9.59;   % [A/string]  STC MPP current
pv_Vmpp = 0.55;   % [V/cell]    STC MPP voltage (matches simulation)
pv_Pu   = pv_Impp * pv_Vmpp * pv_Ns;   % = 9.59 x 0.55 x 60 = 316.5 W/string at STC
% PEM rated operating-point (Randles load-line at Vmax = 2.0 x 20 cells)
pem_N          = 16;   % N=20 PEM cells in series
pem_Vint_cell  = 1.475841;
pem_R_cell     = 0.008673 + 0.00177 + 0.0005;   % Rint + Ra + Rc per cell
pem_Vmax       = 2.0  * pem_N;                   % 40.0 V
pem_Vint_stack = pem_Vint_cell * pem_N;          % 29.52 V
pem_R_stack    = pem_R_cell    * pem_N;          % 0.3409 Ohm
pem_I_rated    = 17.64 * 2.2;                                  % 2.2 A/cm2 x 17.64 cm2 = 38.8 A
pem_P_rated    = pem_Vmax * pem_I_rated;                       % 40 x 38.8 = 1552 W
fprintf('PEM rated ceiling:  Vmax = %.1f V | I_rated = %.1f A | P_rated = %.0f W\n\n', ...
    pem_Vmax, pem_I_rated, pem_P_rated);
% Validity test: mean P_mpp_ref must be > 5 W during daytime AND
% at least 70 % of daytime samples must have P_mpp_ref ≥ 50 % of P_PV.
is_mpp_valid = @(Pm, Pv, Irr) ...
    mean(Pm(Irr > NIGHT_THR), 'omitnan') > 5 && ...
    mean(Pm(Irr > NIGHT_THR) >= Pv(Irr > NIGHT_THR) * 0.5, 'omitnan') > 0.70;
fprintf('Validating P_MPP_ref columns...\n');
% ---- Case A: Np = 7 (fixed, direct static coupling) ----
Np_A_val = 7;
if ~is_mpp_valid(PmppA, PVP_A, IrrA)
    PmppA            = max(0, Np_A_val * pv_Pu * (IrrA / 1000));
    PmppA(IrrA <= NIGHT_THR) = NaN;
    CA               = max(0, min(1.0, PVP_A ./ max(PmppA, 1e-3)));
    PerrA            = abs(PmppA - PVP_A);
    CA(IrrA    <= NIGHT_THR) = 0;
    PerrA(IrrA <= NIGHT_THR) = 0;
    fprintf('  [REPAIR] Case A: P_MPP_ref, C, Power_Error recomputed (Np=%d).\n', Np_A_val);
else
    fprintf('  [OK]     Case A: P_MPP_ref valid.\n');
end
% ---- Case D: Np = 7 (fixed, MPPT via boost converter) ----
Np_D_val = 7;
if ~is_mpp_valid(PmppD, PVP_D, IrrD)
    PmppD            = max(0, Np_D_val * pv_Pu * (IrrD / 1000));
    PmppD(IrrD <= NIGHT_THR) = NaN;
    CD               = max(0, min(1.0, PVP_D ./ max(PmppD, 1e-3)));
    PerrD            = abs(PmppD - PVP_D);
    CD(IrrD    <= NIGHT_THR) = 0;
    PerrD(IrrD <= NIGHT_THR) = 0;
    fprintf('  [REPAIR] Case D: P_MPP_ref, C, Power_Error recomputed (Np=%d).\n', Np_D_val);
else
    fprintf('  [OK]     Case D: P_MPP_ref valid.\n');
end
% ---- Case G: config-aware Np from the Np_active_[-] column ----
NpG_active = double(T.G.("Np_active_[-]"));
Np_G_lvls  = sort(unique(NpG_active(NpG_active > 0 & IrrG > NIGHT_THR)), 'ascend');
% Use RAW NpG_active for P_mpp_ref — no temporal debounce here.
% Brief chattering spikes where C would exceed 1.0 are handled by the
% min(1.0,...) clamp applied below, so they do not inflate the mean C.
% A large debounce window causes multi-minute lag at REAL transitions
% (e.g. Np=6→5 at G=725) which artificially depresses C at high irradiance.
need_G = ~is_mpp_valid(PmppG, PVP_G, IrrG);
if need_G
    if numel(Np_G_lvls) >= 2
        % Np_active has valid multi-level data → use it directly (raw)
        PmppG          = zeros(size(IrrG));
        day_ok         = IrrG > NIGHT_THR & NpG_active > 0;
        PmppG(day_ok)  = NpG_active(day_ok) .* pv_Pu .* (IrrG(day_ok) / 1000);
        PmppG(~day_ok) = NaN;
        fprintf('  [REPAIR] Case G: P_MPP_ref from Np_active column (Np ∈ [%s]).\n', ...
            num2str(Np_G_lvls(:)', '%d '));
    else
        % Np_active broken or single-valued → estimate from irradiance thresholds
        Np_G_est              = ones(size(IrrG)) * 7;   % Low-G default (most strings)
        Np_G_est(IrrG >= 450) = 6;                      % Mid-G
        Np_G_est(IrrG >= 725) = 5;                      % High-G
        PmppG                 = max(0, Np_G_est .* pv_Pu .* (IrrG / 1000));
        PmppG(IrrG <= NIGHT_THR) = NaN;
        fprintf('  [REPAIR] Case G: P_MPP_ref estimated from irradiance thresholds.\n');
    end
    CG               = max(0, min(1.0, PVP_G ./ max(PmppG, 1e-3)));
    PerrG            = abs(PmppG - PVP_G);
    CG(IrrG    <= NIGHT_THR) = 0;
    PerrG(IrrG <= NIGHT_THR) = 0;
else
    fprintf('  [OK]     Case G: P_MPP_ref valid.\n');
end
% Physical floor: the true MPP must be >= the actual operating point.
% When the analytical formula underestimates (Simulink uses full I-V curve),
% P_WP can slightly exceed the linear estimate. Clamping here keeps C <= 1
% and mismatch >= 0 without distorting the physical interpretation.
day_G = IrrG > NIGHT_THR;
PmppG(day_G) = max(PmppG(day_G), PVP_G(day_G));
CG           = max(0, min(1.0, PVP_G ./ max(PmppG, 1e-3)));
PerrG        = max(0, PmppG - PVP_G);
CG(~day_G)   = 0;
PerrG(~day_G)= 0;
fprintf('\n');
% =========================================================================
%  3 – DAYTIME MASKS & CLEAN-UP
% =========================================================================
maskA = (IrrA > NIGHT_THR) & (CA > 0);
maskD = (IrrD > NIGHT_THR) & (CD > 0);
maskG = (IrrG > NIGHT_THR) & (CG > 0);
etaA(~maskA | etaA < 1) = NaN;
etaD(~maskD | etaD < 1) = NaN;
etaG(~maskG | etaG < 1) = NaN;
CA_nan = CA;  CA_nan(~maskA)  = NaN;
CD_nan = CD;  CD_nan(~maskD)  = NaN;
CG_nan = CG;  CG_nan(~maskG)  = NaN;
STH_A(~maskA | STH_A <= 0) = NaN;
STH_D(~maskD | STH_D <= 0) = NaN;
STH_G(~maskG | STH_G <= 0) = NaN;
PerrA(~maskA) = NaN;
PerrD(~maskD) = NaN;
PerrG(~maskG) = NaN;
% =========================================================================
%  4 – KPI SUMMARY
% =========================================================================
kpi.mean_C    = [mean(CA_nan,'omitnan'), mean(CD_nan,'omitnan'), mean(CG_nan,'omitnan')];
kpi.std_C     = [std(CA_nan,'omitnan'),  std(CD_nan,'omitnan'),  std(CG_nan,'omitnan')];
kpi.mean_STH  = [mean(STH_A,'omitnan'),  mean(STH_D,'omitnan'),  mean(STH_G,'omitnan')];
kpi.mean_eta  = [mean(etaA,'omitnan'),   mean(etaD,'omitnan'),   mean(etaG,'omitnan')];
kpi.total_H2  = [H2cumA(end),            H2cumD(end),            H2cumG(end)];
kpi.mean_err  = [mean(PerrA,'omitnan'),  mean(PerrD,'omitnan'),  mean(PerrG,'omitnan')];
kpi.peak_H2   = [max(H2A),              max(H2D),               max(H2G)];
kpi.mean_etaPV  = [mean(etaPV_A(maskA  & etaPV_A >1),'omitnan'), ...
                   mean(etaPV_D(maskD  & etaPV_D >1),'omitnan'), ...
                   mean(etaPV_G(maskG  & etaPV_G >1),'omitnan')];
kpi.mean_etaPEM = [mean(etaPEM_A(maskA & etaPEM_A>1),'omitnan'), ...
                   mean(etaPEM_D(maskD & etaPEM_D>1),'omitnan'), ...
                   mean(etaPEM_G(maskG & etaPEM_G>1),'omitnan')];
% Total mismatch energy (Wh) — use each case's actual time step to handle
% different sampling rates (Case D may be 6-min, Cases A/G are 1-min)
dt_A = median(diff(tA)) ;   % [h]
dt_D = median(diff(tD)) ;   % [h]
dt_G = median(diff(tG)) ;   % [h]
kpi.sum_err_Wh = [sum(PerrA(maskA),'omitnan') * dt_A, ...
                  sum(PerrD(maskD),'omitnan') * dt_D, ...
                  sum(PerrG(maskG),'omitnan') * dt_G];
fprintf('=== KPI Summary ===\n');
fprintf('%-38s  %22s  %22s  %22s\n', 'Metric', NM.A, NM.D, NM.G);
fprintf('%s\n', repmat('-', 1, 108));
fprintf('%-38s  %22.4f  %22.4f  %22.4f\n', 'Mean Coupling Factor C  [-]',      kpi.mean_C);
fprintf('%-38s  %22.4f  %22.4f  %22.4f\n', 'Std  Coupling Factor C  [-]',      kpi.std_C);
fprintf('%-38s  %22.3f  %22.3f  %22.3f\n', 'Mean STH efficiency     [%%]',     kpi.mean_STH);
fprintf('%-38s  %22.2f  %22.2f  %22.2f\n', 'Mean system efficiency  [%%]',     kpi.mean_eta);
fprintf('%-38s  %22.2f  %22.2f  %22.2f\n', 'Mean  |power error|     [W]',      kpi.mean_err);
fprintf('%-38s  %22.2f  %22.2f  %22.2f\n', 'Total mismatch energy   [Wh]',     kpi.sum_err_Wh);
fprintf('%-38s  %22.2f  %22.2f  %22.2f\n', 'Total H2 produced       [g]',      kpi.total_H2);
fprintf('%-38s  %22.2f  %22.2f  %22.2f\n', 'Peak H2 rate            [g/h]',    kpi.peak_H2);
fprintf('%-38s  %22.2f  %22.2f  %22.2f\n', 'Mean PV efficiency      [%%]',     kpi.mean_etaPV);
fprintf('%-38s  %22.2f  %22.2f  %22.2f\n', 'Mean PEM efficiency     [%%]',     kpi.mean_etaPEM);
fprintf('\n');
save('comparison_KPIs.mat', 'kpi');
% =========================================================================
%  5 – COMMON INTERPOLATED TIME GRID (1-min resolution)
% =========================================================================
t_max_h   = min([max(tA), max(tD), max(tG)]);
t_c       = (0 : 1/60 : t_max_h)';        % common 1-min grid [h]
n_days    = floor(t_max_h / 24);
day_ticks = 0 : 24 : (n_days * 24);
day_lbls  = arrayfun(@(h) sprintf('%d', h), day_ticks, 'UniformOutput', false);
% interp1 requires strictly unique sample points.  Simulink variable-step
% output can emit duplicate timestamps (at t=0 and at configuration-switch
% events).  si_safe() removes ALL duplicates via unique() before interpolating.
si = @(ts, ys) si_safe(ts, ys, t_c);
IrrA_c  = max(0, si(tA, IrrA));
night_c = (IrrA_c <= NIGHT_THR);
% Smooth irradiance for background reference (30-min moving average)
Irr_sm  = movmean(IrrA_c, 30);
CA_c    = max(0, min(1, si(tA, CA_nan)));
CD_c    = max(0, min(1, si(tD, CD_nan)));
CG_c    = max(0, min(1, si(tG, CG_nan)));
CA_c(night_c) = NaN;  CD_c(night_c) = NaN;  CG_c(night_c) = NaN;
H2A_c   = max(0, si(tA, H2A));
H2D_c   = max(0, si(tD, H2D));
H2G_c   = max(0, si(tG, H2G));
tc_s    = t_c * 3600;
H2cumA_c = cumtrapz(tc_s, H2A_c / 3600);
H2cumD_c = cumtrapz(tc_s, H2D_c / 3600);
H2cumG_c = cumtrapz(tc_s, H2G_c / 3600);
STH_Ac  = si(tA, STH_A);  STH_Ac(night_c) = NaN;
STH_Dc  = si(tD, STH_D);  STH_Dc(night_c) = NaN;
STH_Gc  = si(tG, STH_G);  STH_Gc(night_c) = NaN;
PVP_Ac  = max(0, si(tA, PVP_A));
PVP_Dc  = max(0, si(tD, PVP_D));
PVP_Gc  = max(0, si(tG, PVP_G));
Pmpp_Ac = max(0, si(tA, PmppA));
Pmpp_Dc = max(0, si(tD, PmppD));
Pmpp_Gc = max(0, si(tG, PmppG));
PerrA_c  = max(0, si(tA, fillmissing(PerrA, 'constant', 0)));
PerrD_c  = max(0, si(tD, fillmissing(PerrD, 'constant', 0)));
PerrG_c  = max(0, si(tG, fillmissing(PerrG, 'constant', 0)));
PerrA_c(night_c) = NaN;  PerrD_c(night_c) = NaN;  PerrG_c(night_c) = NaN;
etaA_f  = fillmissing(etaA,  'constant', 0);
etaD_f  = fillmissing(etaD,  'constant', 0);
etaG_f  = fillmissing(etaG,  'constant', 0);
etaA_c  = si(tA, etaA_f);  etaA_c(night_c | etaA_c < 1) = NaN;
etaD_c  = si(tD, etaD_f);  etaD_c(night_c | etaD_c < 1) = NaN;
etaG_c  = si(tG, etaG_f);  etaG_c(night_c | etaG_c < 1) = NaN;
% η_PV on common grid
etaPV_Ac = si(tA, fillmissing(etaPV_A,'constant',0)); etaPV_Ac(night_c | etaPV_Ac < 1) = NaN;
etaPV_Dc = si(tD, fillmissing(etaPV_D,'constant',0)); etaPV_Dc(night_c | etaPV_Dc < 1) = NaN;
etaPV_Gc = si(tG, fillmissing(etaPV_G,'constant',0)); etaPV_Gc(night_c | etaPV_Gc < 1) = NaN;
% η_PEM on common grid
etaPEM_Ac = si(tA, fillmissing(etaPEM_A,'constant',0)); etaPEM_Ac(night_c | etaPEM_Ac < 1) = NaN;
etaPEM_Dc = si(tD, fillmissing(etaPEM_D,'constant',0)); etaPEM_Dc(night_c | etaPEM_Dc < 1) = NaN;
etaPEM_Gc = si(tG, fillmissing(etaPEM_G,'constant',0)); etaPEM_Gc(night_c | etaPEM_Gc < 1) = NaN;
% Smooth helpers
sm30 = @(v) movmean(v, 30, 'omitnan');
% =========================================================================
%  AUTO Y-LIMITS (computed once from data, applied to all relevant figures)
% =========================================================================
% Coupling factor: lower bound rounded DOWN to nearest 0.05
C_day_all = [CA_c(~isnan(CA_c)); CD_c(~isnan(CD_c)); CG_c(~isnan(CG_c))];
C_min_val  = min(C_day_all(isfinite(C_day_all)));
C_ylim_lo  = max(0, floor(C_min_val * 20) / 20);   % e.g. 0.73 → 0.70
C_ylim_hi  = 1.02;
% STH efficiency: upper bound rounded UP to nearest 0.05 %
STH_day_all = [STH_Ac(~isnan(STH_Ac)); STH_Dc(~isnan(STH_Dc)); STH_Gc(~isnan(STH_Gc))];
STH_max_val = max(STH_day_all(isfinite(STH_day_all)));
STH_ylim_hi = ceil(STH_max_val * 20) / 20;   % e.g. 0.37 → 0.40
% =========================================================================
%  FIGURE C1 – COUPLING FACTOR COMPARISON
% =========================================================================
fprintf('Generating Fig C1: Coupling Factor...\n');
fig1 = figure('Position', [40 40 1100 540]);
tl   = tiledlayout(2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
ax1a = nexttile;
area(t_c, Irr_sm, 'FaceColor', clr.irr, 'FaceAlpha', 0.35, ...
     'EdgeColor', clr.irr * 0.75, 'LineWidth', 0.6);
ylabel('G (W m^{-2})');
ylim([0, 1200]);  yticks(0:200:1200);
set(ax1a, 'XTickLabel', []);
legend('Solar irradiance', 'Location', 'northeast', 'FontSize', 9);
ax1b = nexttile;
plot(t_c, sm30(CA_c), ls.A, 'Color', clr.A, 'LineWidth', lw, 'DisplayName', NM.A);  hold on;
plot(t_c, sm30(CD_c), ls.D, 'Color', clr.D, 'LineWidth', lw, 'DisplayName', NM.D);
plot(t_c, sm30(CG_c), ls.G, 'Color', clr.G, 'LineWidth', lw, 'DisplayName', NM.G);
yline(1, 'k:', 'LineWidth', 1.0, 'HandleVisibility', 'off');
hold off;
ylabel('Coupling Factor  C = P_{WP}/P_{MPP}');
ylim([C_ylim_lo, C_ylim_hi]);
legend('Location', 'southeast', 'FontSize', 9, 'NumColumns', 1);
for ax = [ax1a, ax1b]
    xticks(ax, day_ticks);
    xlim(ax, [0, t_c(end)]);
end
xticklabels(ax1b, day_lbls);
xlabel(ax1b, 'Time (h)');
title(tl, 'Coupling Factor Comparison – All Topologies', 'FontSize', 12, 'FontWeight', 'bold');
drawnow;
savefig_fn(fig1, 'C1_Coupling_Factor');
% =========================================================================
%  FIGURE C2 – HYDROGEN PRODUCTION COMPARISON
% =========================================================================
fprintf('Generating Fig C2: H2 Production...\n');
fig2 = figure('Position', [50 50 1100 560]);
tl2  = tiledlayout(2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
ax2a = nexttile;
plot(t_c, sm30(H2A_c), ls.A, 'Color', clr.A, 'LineWidth', lw, 'DisplayName', NM.A);  hold on;
plot(t_c, sm30(H2D_c), ls.D, 'Color', clr.D, 'LineWidth', lw, 'DisplayName', NM.D);
plot(t_c, sm30(H2G_c), ls.G, 'Color', clr.G, 'LineWidth', lw, 'DisplayName', NM.G);
hold off;
ylabel('H_2 rate (g h^{-1})');
H2_ylim = max([max(H2A_c(isfinite(H2A_c))); max(H2D_c(isfinite(H2D_c))); max(H2G_c(isfinite(H2G_c)))]);
ylim([0, H2_ylim * 1.15 + 0.1]);
set(ax2a, 'XTickLabel', []);
legend('Location', 'northwest', 'FontSize', 9);
ax2b = nexttile;
plot(t_c, H2cumA_c, ls.A, 'Color', clr.A, 'LineWidth', lw, 'DisplayName', NM.A);  hold on;
plot(t_c, H2cumD_c, ls.D, 'Color', clr.D, 'LineWidth', lw, 'DisplayName', NM.D);
plot(t_c, H2cumG_c, ls.G, 'Color', clr.G, 'LineWidth', lw, 'DisplayName', NM.G);
hold off;
ylabel('Cumulative H_2 (g)');
legend('Location', 'northwest', 'FontSize', 9);
for ax = [ax2a, ax2b]
    xticks(ax, day_ticks);
    xlim(ax, [0, t_c(end)]);
end
xticklabels(ax2b, day_lbls);
xlabel(ax2b, 'Time (h)');
%title(tl2, 'Hydrogen Production – All Topologies', 'FontSize', 12, 'FontWeight', 'bold');
drawnow;
savefig_fn(fig2, 'C2_H2_Production');
% =========================================================================
%  FIGURE C3 – SOLAR-TO-HYDROGEN EFFICIENCY
% =========================================================================
fprintf('Generating Fig C3: STH Efficiency...\n');
fig3 = figure('Position', [60 60 1100 540]);
tl3  = tiledlayout(2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
ax3a = nexttile;
area(t_c, Irr_sm, 'FaceColor', clr.irr, 'FaceAlpha', 0.35, ...
     'EdgeColor', clr.irr * 0.75, 'LineWidth', 0.6);
ylabel('G (W m^{-2})');  ylim([0, 1200]);  yticks(0:200:1200);
set(ax3a, 'XTickLabel', []);
legend('Solar irradiance', 'Location', 'northeast', 'FontSize', 9);
ax3b = nexttile;
plot(t_c, sm30(STH_Ac), ls.A, 'Color', clr.A, 'LineWidth', lw, 'DisplayName', NM.A);  hold on;
plot(t_c, sm30(STH_Dc), ls.D, 'Color', clr.D, 'LineWidth', lw, 'DisplayName', NM.D);
plot(t_c, sm30(STH_Gc), ls.G, 'Color', clr.G, 'LineWidth', lw, 'DisplayName', NM.G);
hold off;
ylabel('Solar-to-Hydrogen Efficiency, \eta_{STH} (%)');
ylim([0, STH_ylim_hi]);
legend('Location', 'northwest', 'FontSize', 9);
for ax = [ax3a, ax3b]
    xticks(ax, day_ticks);
    xlim(ax, [0, t_c(end)]);
end
xticklabels(ax3b, day_lbls);
xlabel(ax3b, 'Time (h)');
title(tl3, 'Solar-to-Hydrogen Efficiency – All Topologies', 'FontSize', 12, 'FontWeight', 'bold');
drawnow;
savefig_fn(fig3, 'C3_STH_Efficiency');
% =========================================================================
%  FIGURE C4 – PV POWER vs MPP REFERENCE (3 stacked panels)
% =========================================================================
fprintf('Generating Fig C4: PV Power Tracking...\n');
fig4 = figure('Position', [70 70 1100 800]);
tl4  = tiledlayout(3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
ax4  = gobjects(3, 1);
panel_data = {
    t_c, sm30(PVP_Ac), sm30(Pmpp_Ac), clr.A, NM.A;
    t_c, sm30(PVP_Dc), sm30(Pmpp_Dc), clr.D, NM.D;
    t_c, sm30(PVP_Gc), sm30(Pmpp_Gc), clr.G, NM.G;
};
for p = 1:3
    ax4(p) = nexttile;
    tc_p = panel_data{p,1};
    pwr  = panel_data{p,2};
    mpp  = panel_data{p,3};
    col  = panel_data{p,4};
    lbl  = panel_data{p,5};
    fill([tc_p; flipud(tc_p)], [mpp; flipud(pwr)], col, ...
        'FaceAlpha', 0.12, 'EdgeColor', 'none', 'HandleVisibility', 'off');  hold on;
    plot(tc_p, mpp, '--', 'Color', clr.mpp, 'LineWidth', lws, 'DisplayName', 'P_{MPP} reference');
    plot(tc_p, pwr, '-',  'Color', col,     'LineWidth', lw,  'DisplayName', sprintf('P_{PV} – %s', lbl));
    hold off;
    ylabel('Power (W)');
    v_all = [mpp(isfinite(mpp)); pwr(isfinite(pwr)); 100];
    mx = max(v_all);
    ylim([0, mx * 1.12]);
    xticks(ax4(p), day_ticks);
    xlim(ax4(p), [0, t_c(end)]);
    legend('Location', 'northeast', 'FontSize', 9, 'NumColumns', 2);
    if p < 3,  set(ax4(p), 'XTickLabel', []);  end
end
% PEM rated-power ceiling line on every panel
for p = 1:3
    yline(ax4(p), pem_P_rated, ':', 'Color', [0.75 0 0.75], 'LineWidth', 1.4, ...
        'HandleVisibility', 'off');
end
text(t_c(round(end*0.02)), pem_P_rated*1.04, ...
    sprintf('PEM P_{rated} = %.0f W', pem_P_rated), ...
    'Parent', ax4(1), 'FontSize', 8, 'Color', [0.75 0 0.75]);
xticklabels(ax4(3), day_lbls);
xlabel(ax4(3), 'Time (h)');
title(tl4, 'PV Power vs MPP Reference – Shaded Area = Mismatch Loss', ...
    'FontSize', 12, 'FontWeight', 'bold');
drawnow;
savefig_fn(fig4, 'C4_Power_Tracking');
% =========================================================================
%  FIGURE C5 – ABSOLUTE POWER MISMATCH
% =========================================================================
fprintf('Generating Fig C5: Power Mismatch...\n');
fig5 = figure('Position', [80 80 1100 480]);
tl5  = tiledlayout(1, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
ax5 = nexttile;
plot(t_c, sm30(PerrA_c), ls.A, 'Color', clr.A, 'LineWidth', lw, 'DisplayName', NM.A);  hold on;
plot(t_c, sm30(PerrD_c), ls.D, 'Color', clr.D, 'LineWidth', lw, 'DisplayName', NM.D);
plot(t_c, sm30(PerrG_c), ls.G, 'Color', clr.G, 'LineWidth', lw, 'DisplayName', NM.G);
hold off;
ylabel('|Power Error|  |P_{WP} - P_{MPP}|  (W)');
Perr_max = max([max(PerrA_c(isfinite(PerrA_c))); max(PerrD_c(isfinite(PerrD_c))); max(PerrG_c(isfinite(PerrG_c)))]);
ylim([0, Perr_max * 1.12 + 1]);
xticks(ax5, day_ticks);  xticklabels(ax5, day_lbls);
xlim(ax5, [0, t_c(end)]);
xlabel('Time (h)');
legend('Location', 'northeast', 'FontSize', 9);
title('Absolute MPP Power Mismatch – All Topologies', 'FontSize', 12, 'FontWeight', 'bold');
drawnow;
savefig_fn(fig5, 'C5_Power_Mismatch');
% =========================================================================
%  FIGURE C6 – BOX PLOT STATISTICS (C, STH, η)  — 3 rows, zoomed
% =========================================================================
fprintf('Generating Fig C6: Statistical Box Plots...\n');
sub     = @(v) v(~isnan(v) & isfinite(v));
col_arr = [clr.A; clr.D; clr.G];
xlbls6  = {NM.A, NM.D, NM.G};
% Panel definitions: {data_cells, ylabel, zoom_margin, reference_line}
pdef = {
    {sub(CA_nan),  sub(CD_nan),  sub(CG_nan)},  'Coupling Factor  C  [-]',          0.05, 1.0;
    {sub(STH_A),   sub(STH_D),   sub(STH_G)},   'STH Efficiency  \eta_{STH}',  0.02, NaN;
    {sub(etaA),    sub(etaD),    sub(etaG)},     'System Efficiency  \eta  (%)',     2.0,  NaN;
};
fig6 = figure('Position', [90 90 700 820]);
tl6  = tiledlayout(3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
bw = 0.38;   % box half-width (inline constant)
for panel = 1:3
    ax6   = nexttile;
    grp   = pdef{panel, 1};
    ylbl6 = pdef{panel, 2};
    marg  = pdef{panel, 3};
    ref   = pdef{panel, 4};
    all_v = [];
    hold(ax6, 'on');
    for g = 1:3
        v = grp{g};
        if isempty(v) || length(v) < 5,  continue;  end
        q  = quantile(v, [0.05 0.25 0.50 0.75 0.95]);
        col = col_arr(g,:);
        % Jitter scatter (subsample ≤ 600 pts)
        ns = min(length(v), 600);
        vs = v(round(linspace(1, length(v), ns)));
        jx = g + (rand(ns,1) - 0.5) * bw * 1.3;
        scatter(ax6, jx, vs, 6, col, 'o', 'MarkerFaceAlpha', 0.09, ...
            'MarkerEdgeAlpha', 0, 'HandleVisibility', 'off');
        % Box body (IQR)
        fill(ax6, [g-bw g+bw g+bw g-bw], [q(2) q(2) q(4) q(4)], col, ...
            'FaceAlpha', 0.40, 'EdgeColor', col*0.65, 'LineWidth', 1.8, ...
            'HandleVisibility', 'off');
        % Median bar
        plot(ax6, [g-bw g+bw], [q(3) q(3)], '-', 'Color', col*0.5, ...
            'LineWidth', 3.0, 'HandleVisibility', 'off');
        % Lower whisker + cap (5th pct)
        plot(ax6, [g g], [q(1) q(2)], '-', 'Color', col*0.65, 'LineWidth', 1.4, ...
            'HandleVisibility', 'off');
        plot(ax6, [g-bw/2.2 g+bw/2.2], [q(1) q(1)], '-', 'Color', col*0.65, ...
            'LineWidth', 1.4, 'HandleVisibility', 'off');
        % Upper whisker + cap (95th pct)
        plot(ax6, [g g], [q(4) q(5)], '-', 'Color', col*0.65, 'LineWidth', 1.4, ...
            'HandleVisibility', 'off');
        plot(ax6, [g-bw/2.2 g+bw/2.2], [q(5) q(5)], '-', 'Color', col*0.65, ...
            'LineWidth', 1.4, 'HandleVisibility', 'off');
        % Mean diamond marker
        plot(ax6, g, mean(v), 'd', 'MarkerSize', 10, 'MarkerFaceColor', col, ...
            'MarkerEdgeColor', 'k', 'LineWidth', 1.0, 'HandleVisibility', 'off');
        all_v = [all_v; v(:)]; %#ok<AGROW>
    end
    % Reference line (C = 1 for coupling factor panel)
    if ~isnan(ref)
        yline(ax6, ref, 'k:', 'LineWidth', 1.2, 'HandleVisibility', 'off');
    end
    % Auto-zoomed y-limits
    if ~isempty(all_v)
        q_lo = quantile(all_v, 0.02);
        q_hi = quantile(all_v, 0.98);
        pad  = max((q_hi - q_lo) * 0.18, marg);
        ylim(ax6, [max(0, q_lo - pad), q_hi + pad]);
    end
    xlim(ax6, [0.4, 3.6]);
    set(ax6, 'XTick', 1:3, 'XTickLabel', xlbls6, 'FontSize', 10, ...
        'TickLabelInterpreter', 'none');
    xtickangle(ax6, 15);
    ylabel(ax6, ylbl6, 'FontSize', 11);
    grid(ax6, 'on');  box(ax6, 'on');
    hold(ax6, 'off');
end
%title(tl6, ['Daytime Statistical Distribution' newline ...
    %'(diamond = mean  |  box = IQR  |  whiskers = 5/95th pct  |  dots = data)'], ...
    %'FontSize', 10, 'FontWeight', 'bold');
drawnow;
savefig_fn(fig6, 'C6_Statistics_BoxPlots');
% =========================================================================
%  FIGURE C7 – KPI BAR CHART
% =========================================================================
fprintf('Generating Fig C7: KPI Summary Bar Chart...\n');
fig7 = figure('Position', [100 100 1100 520]);
tl7  = tiledlayout(1, 3, 'TileSpacing', 'loose', 'Padding', 'compact');
col_bar = [clr.A; clr.D; clr.G];
% Panel 1 – Total H2 yield
ax7a = nexttile;
bar_vals = kpi.total_H2;
b1 = bar(1:3, bar_vals, 0.6);
for g = 1:3,  b1.FaceColor = 'flat';  b1.CData(g,:) = col_bar(g,:);  end
for g = 1:3
    text(g, bar_vals(g) + max(bar_vals)*0.02, sprintf('%.1f g', bar_vals(g)), ...
        'HorizontalAlignment', 'center', 'FontSize', 12, 'FontWeight', 'bold');
end
set(ax7a, 'XTick', 1:3, 'XTickLabel', {NM_SHORT.A, NM_SHORT.D, NM_SHORT.G}, 'FontSize', 9);
xtickangle(ax7a, 20);
ylabel('Total H_2 produced (g)');
ylim([0, max(bar_vals)*1.3]);
title('Total H_2 Yield', 'FontSize', 13);
% Panel 2 – Mean Coupling Factor
ax7b = nexttile;
bar_vals = kpi.mean_C;
err_vals = kpi.std_C;
b2 = bar(1:3, bar_vals, 0.6);
for g = 1:3,  b2.FaceColor = 'flat';  b2.CData(g,:) = col_bar(g,:);  end
hold on;
errorbar(1:3, bar_vals, err_vals, 'k.', 'LineWidth', 1.3, 'CapSize', 8);
for g = 1:3
    text(g, bar_vals(g) + err_vals(g) + 0.03, sprintf('%.3f', bar_vals(g)), ...
        'HorizontalAlignment', 'center', 'FontSize', 12, 'FontWeight', 'bold');
end
hold off;
set(ax7b, 'XTick', 1:3, 'XTickLabel', {NM_SHORT.A, NM_SHORT.D, NM_SHORT.G}, 'FontSize', 9);
xtickangle(ax7b, 20);
ylabel('Mean Coupling Factor C  [-]');
ylim([0, 1.15]);
yline(1, 'k:', 'LineWidth', 1.0);
title('Mean C  (\pm\sigma)', 'FontSize', 11);
% Panel 3 – Mean STH
ax7c = nexttile;
bar_vals = kpi.mean_STH;
b3 = bar(1:3, bar_vals, 0.6);
for g = 1:3,  b3.FaceColor = 'flat';  b3.CData(g,:) = col_bar(g,:);  end
for g = 1:3
    text(g, bar_vals(g) + max(bar_vals)*0.035, sprintf('%.2f', bar_vals(g)), ...
        'HorizontalAlignment', 'center', 'FontSize', 12, 'FontWeight', 'bold');
end
set(ax7c, 'XTick', 1:3, 'XTickLabel', {NM_SHORT.A, NM_SHORT.D, NM_SHORT.G}, 'FontSize', 9);
xtickangle(ax7c, 20);
ylabel('Mean STH Efficiency  \eta_{STH}');
ylim([0, max(bar_vals)*1.2 + 0.1]);
title('Mean \eta_{STH}', 'FontSize', 11);
%title(tl7, 'Key Performance Indicators – Topology Comparison', ...
    %'FontSize', 12, 'FontWeight', 'bold');
drawnow;
savefig_fn(fig7, 'C7_KPI_Bar_Chart');
% =========================================================================
%  FIGURE C8 – COUPLING FACTOR vs IRRADIANCE (scatter)
% =========================================================================
fprintf('Generating Fig C8: Coupling Factor vs Irradiance...\n');
% Bin irradiance to show smoothed trend lines
Irr_bins = 50 : 50 : 1200;
trend_A = arrayfun(@(g) mean(CA_nan(IrrA >= g-25 & IrrA < g+25), 'omitnan'), Irr_bins);
trend_D = arrayfun(@(g) mean(CD_nan(IrrD >= g-25 & IrrD < g+25), 'omitnan'), Irr_bins);
trend_G = arrayfun(@(g) mean(CG_nan(IrrG >= g-25 & IrrG < g+25), 'omitnan'), Irr_bins);
% Subsample scatter (max 3000 pts each for speed)
idx_sub = @(v, irr) find(~isnan(v) & irr > NIGHT_THR);
sub_idx = @(v, n) v(round(linspace(1, length(v), min(n, length(v)))));
idxA = idx_sub(CA_nan, IrrA);  idxA = sub_idx(idxA, 3000);
idxD = idx_sub(CD_nan, IrrD);  idxD = sub_idx(idxD, 3000);
idxG = idx_sub(CG_nan, IrrG);  idxG = sub_idx(idxG, 3000);
fig8 = figure('Position', [110 110 820 540]);
ax8  = axes;
scatter(IrrA(idxA), CA_nan(idxA), 12, clr.A, 'o', 'MarkerFaceAlpha', 0.18, ...
    'MarkerEdgeAlpha', 0, 'HandleVisibility', 'off');  hold on;
scatter(IrrD(idxD), CD_nan(idxD), 12, clr.D, 'o', 'MarkerFaceAlpha', 0.18, ...
    'MarkerEdgeAlpha', 0, 'HandleVisibility', 'off');
scatter(IrrG(idxG), CG_nan(idxG), 12, clr.G, 'o', 'MarkerFaceAlpha', 0.18, ...
    'MarkerEdgeAlpha', 0, 'HandleVisibility', 'off');
valid_b = @(t) ~isnan(t);
plot(Irr_bins(valid_b(trend_A)), trend_A(valid_b(trend_A)), ls.A, ...
    'Color', clr.A, 'LineWidth', 2.4, 'DisplayName', [NM.A ' – mean']);
plot(Irr_bins(valid_b(trend_D)), trend_D(valid_b(trend_D)), ls.D, ...
    'Color', clr.D, 'LineWidth', 2.4, 'DisplayName', [NM.D ' – mean']);
plot(Irr_bins(valid_b(trend_G)), trend_G(valid_b(trend_G)), ls.G, ...
    'Color', clr.G, 'LineWidth', 2.4, 'DisplayName', [NM.G ' – mean']);
yline(1, 'k:', 'LineWidth', 1.0, 'HandleVisibility', 'off');
hold off;
xlabel('Solar Irradiance  G  (W m^{-2})');
ylabel('Coupling Factor  C = P_{WP}/P_{MPP}');
Irr_max_data = max([max(IrrA(maskA)); max(IrrD(maskD)); max(IrrG(maskG))]);
xlim([NIGHT_THR, Irr_max_data * 1.02]);
C_sc_all = [CA_nan(idxA); CD_nan(idxD); CG_nan(idxG)];
C_sc_fin = C_sc_all(isfinite(C_sc_all));
if ~isempty(C_sc_fin)
    C8_ylo = max(0, floor(quantile(C_sc_fin, 0.01) * 20)/20 - 0.05);
else
    C8_ylo = 0.0;
end
ylim([C8_ylo, 1.02]);
legend('Location', 'south', 'FontSize', 9, 'NumColumns', 1);
%title('Coupling Factor vs Irradiance (Binned Mean ± Scatter)', ...
    %'FontSize', 12, 'FontWeight', 'bold');
drawnow;
savefig_fn(fig8, 'C8_Coupling_vs_Irradiance');
% =========================================================================
%  FIGURE C9 – DAILY H2 YIELD BAR CHART
% =========================================================================
fprintf('Generating Fig C9: Daily H2 Yield...\n');
n_full_days = floor(t_max_h / 24);
daily_H2    = zeros(n_full_days, 3);
for d = 1:n_full_days
    t0 = (d-1) * 24;  t1 = d * 24;
    mask_d = (t_c >= t0) & (t_c < t1);
    daily_H2(d, 1) = trapz(tc_s(mask_d), H2A_c(mask_d) / 3600);
    daily_H2(d, 2) = trapz(tc_s(mask_d), H2D_c(mask_d) / 3600);
    daily_H2(d, 3) = trapz(tc_s(mask_d), H2G_c(mask_d) / 3600);
end
fig9 = figure('Position', [120 120 1100 450]);
ax9  = axes;
b_daily = bar(1:n_full_days, daily_H2, 0.75, 'grouped');
b_daily(1).FaceColor = clr.A;  b_daily(1).DisplayName = NM.A;
b_daily(2).FaceColor = clr.D;  b_daily(2).DisplayName = NM.D;
b_daily(3).FaceColor = clr.G;  b_daily(3).DisplayName = NM.G;
set(ax9, 'XTick', 1:n_full_days, 'XTickLabel', ...
    arrayfun(@(d) sprintf('Day %d', d), 1:n_full_days, 'UniformOutput', false));
xlabel('Day');
ylabel('Daily H_2 yield (g day^{-1})');
ylim([0, max(daily_H2(:)) * 1.18]);
legend('Location', 'northeast', 'FontSize', 9);
%title('Daily H_2 Yield – Topology Comparison', 'FontSize', 12, 'FontWeight', 'bold');
grid on;  box on;
drawnow;
savefig_fn(fig9, 'C9_Daily_H2_Yield');
% =========================================================================
%  FIGURE C10 – SYSTEM EFFICIENCY COMPARISON (time series)
% =========================================================================
fprintf('Generating Fig C10: System Efficiency...\n');
fig10 = figure('Position', [130 130 1100 480]);
tl10  = tiledlayout(1, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
ax10 = nexttile;
plot(t_c, sm30(etaA_c), ls.A, 'Color', clr.A, 'LineWidth', lw, 'DisplayName', NM.A);  hold on;
plot(t_c, sm30(etaD_c), ls.D, 'Color', clr.D, 'LineWidth', lw, 'DisplayName', NM.D);
plot(t_c, sm30(etaG_c), ls.G, 'Color', clr.G, 'LineWidth', lw, 'DisplayName', NM.G);
hold off;
ylabel('System Efficiency  \eta = P_{PEM}/P_{PV}  (%)');
ylim([0, 105]);
xticks(ax10, day_ticks);  xticklabels(ax10, day_lbls);
xlim(ax10, [0, t_c(end)]);
xlabel('Time (h)');
legend('Location', 'northeast', 'FontSize', 9);
%title('System Efficiency – All Topologies', 'FontSize', 12, 'FontWeight', 'bold');
drawnow;
savefig_fn(fig10, 'C10_System_Efficiency');
% =========================================================================
%  6 – SUPPLEMENTARY VARIABLES  (for Figs C11–C14)
% =========================================================================
% MPP reference V and I (all cases) — try/catch for robustness
try, VmppA_ref = max(T.A.("V_MPP_ref_[V]"), 0); catch, VmppA_ref = zeros(height(T.A),1); end
try, ImppA_ref = max(T.A.("I_MPP_ref_[A]"), 0); catch, ImppA_ref = zeros(height(T.A),1); end
try, VmppD_ref = max(T.D.("V_MPP_ref_[V]"), 0); catch, VmppD_ref = zeros(height(T.D),1); end
try, ImppD_ref = max(T.D.("I_MPP_ref_[A]"), 0); catch, ImppD_ref = zeros(height(T.D),1); end
try, VmppG_ref = max(T.G.("V_MPP_ref_[V]"), 0); catch, VmppG_ref = zeros(height(T.G),1); end
try, ImppG_ref = max(T.G.("I_MPP_ref_[A]"), 0); catch, ImppG_ref = zeros(height(T.G),1); end
% Voltage ratio M = V_PEM / V_PV (clamp unreasonable values)
MA = PEMV_A ./ max(PVV_A, 1e-3);
if has_col(T.D, 'M_ratio')
    MD = T.D.("M_ratio");
else
    MD = PEMV_D ./ max(PVV_D, 1e-3);
end
MG = PEMV_G ./ max(PVV_G, 1e-3);
MA(~maskA | MA > 3 | MA < 0) = NaN;
MD(~maskD | MD > 3 | MD < 0) = NaN;
MG(~maskG | MG > 3 | MG < 0) = NaN;
% Duty cycle (ideal boost: D = 1 - 1/M, valid during CCM)
DutyD_raw = 1 - 1 ./ max(MD, 0.5);
DutyD_raw(isnan(MD)) = NaN;
% Converter efficiency (Case D)
if has_col(T.D, 'eta_conv_[pct]')
    etaconv_D_raw = T.D.("eta_conv_[pct]");
    etaconv_D_raw(~maskD | etaconv_D_raw < 0 | etaconv_D_raw > 100) = NaN;
else
    etaconv_D_raw = etaD;
end
% Np active strings (Case G)
% NpG_raw     = raw 1-min sampled values (used for scatter plot in C14 Panel 2
%               so that the real hysteresis cloud is visible)
% NpG_debounce_raw = 9-min median of raw (used for the staircase in C14 Panel 1
%               and for NpG_c on the common time grid)
if has_col(T.G, 'Np_active_[-]')
    NpG_raw = double(T.G.("Np_active_[-]"));
else
    NpG_raw = repmat(12, height(T.G), 1);
end
Np_G_uniq_raw = sort(unique(NpG_raw(NpG_raw > 0)), 'ascend');
if numel(Np_G_uniq_raw) >= 2
    NpG_debounce_raw = round(medfilt1(NpG_raw, 3));  % 1-min median: removes single-sample spikes only
    NpG_debounce_raw = min(max(NpG_debounce_raw, min(Np_G_uniq_raw)), max(Np_G_uniq_raw));
else
    NpG_debounce_raw = NpG_raw;
end
% Interpolate to common grid
MA_c     = si(tA, fillmissing(MA, 'constant', 0));
MA_c(night_c | MA_c < 0.1) = NaN;
MD_c     = si(tD, fillmissing(MD, 'constant', 0));
MD_c(night_c | MD_c < 0.1) = NaN;
MG_c     = si(tG, fillmissing(MG, 'constant', 0));
MG_c(night_c | MG_c < 0.1) = NaN;
DutyD_c  = si(tD, fillmissing(DutyD_raw, 'constant', 0));
DutyD_c(night_c | MD_c < 0.5) = NaN;
etaconv_c = si(tD, fillmissing(etaconv_D_raw, 'constant', 0));
etaconv_c(night_c) = NaN;
% Use debounced Np for staircase (C14 Panel 1) — suppresses visual chattering
% Apply unique() to guard against duplicate timestamps from variable-step solver
[tG_u, ia_np] = unique(tG, 'stable');
NpG_c = interp1(tG_u, NpG_debounce_raw(ia_np), t_c, 'nearest', 'extrap');
NpG_c(night_c) = NaN;
% M auto y-limit (shared across C12/C13)
M_all = [MA_c(isfinite(MA_c)); MD_c(isfinite(MD_c)); MG_c(isfinite(MG_c))];
M_ylim_lo = max(0.80, floor(min(M_all) * 20) / 20);
M_ylim_hi = min(2.0,  ceil(max(M_all) * 10) / 10);
% Daytime subsampled index sets (max 5 000 pts per case for scatter plots)
pts_A = find(maskA);
ss_A  = pts_A(round(linspace(1, length(pts_A), min(length(pts_A), 5000))));
pts_D = find(maskD);
ss_D  = pts_D(round(linspace(1, length(pts_D), min(length(pts_D), 5000))));
pts_G = find(maskG);
ss_G  = pts_G(round(linspace(1, length(pts_G), min(length(pts_G), 5000))));
% PEM Randles V-I curve (for I-V overlay)
N_pem    = 20;   % N=20 PEM cells in series
Vint_pem = 1.475841 * N_pem;
R_pem    = (0.008673 + 0.00177 + 0.0005) * N_pem;
I_rl     = linspace(0, 90, 300)';
V_rl     = Vint_pem + R_pem .* I_rl;
% STC MPP point
Vm_stc_ADF = 0.55 * 60;      % [V]  Cases A & D (Ns=60 cells, 0.55 V/cell MPP)
Im_stc_ADF = 9.59 * 7;       % [A]  Cases A & D (Np=7 strings)
% =========================================================================
%  FIGURE C11 – PV & PEM I-V OPERATING POINT TRAJECTORIES
% =========================================================================
fprintf('Generating Fig C11: I-V Trajectories...\n');
% PEM Randles stack (N=20 cells, Vint=29.52 V, Vmax=40 V) — reuse pem_* constants from Section 2c
pem_Vint_11 = pem_Vint_stack;   % 29.52 V  (N=20)
pem_R_11    = pem_R_stack;      % 0.341 Ohm  (N=20)
pem_Vmax_11 = pem_Vmax;         % 40.0 V  (rated voltage limit)
pem_Irat_11 = pem_I_rated;      % 38.8 A  (2.2 A/cm2 x 17.64 cm2)
pem_Prat_11 = pem_P_rated;      % 1552 W
% Operational load line  (Vint → Vmax, solid)
V_ll_op = linspace(pem_Vint_11, pem_Vmax_11, 200);
I_ll_op = (V_ll_op - pem_Vint_11) / pem_R_11;
% Extension beyond rated  (Vmax to Vmax+5 V, dashed grey – theoretical only)
V_ll_ext = linspace(pem_Vmax_11, pem_Vmax_11 + 5, 80);
I_ll_ext = (V_ll_ext - pem_Vint_11) / pem_R_11;
clr_ll     = [0.50, 0.00, 0.50];    % purple – PEM load line
clr_mpp_11 = [0.13, 0.55, 0.13];   % green  – MPP locus
clr_rated  = [0.80, 0.00, 0.00];   % red    – rated operating point
% V axis limits: span all PV and PEM operating voltages in the data
all_V11 = [PVV_A(maskA); PVV_D(maskD); PVV_G(maskG); PEMV_A(maskA); PEMV_D(maskD); PEMV_G(maskG)];
all_V11 = all_V11(all_V11 > 1);
if ~isempty(all_V11)
    V_xlim11 = [max(15, floor(quantile(all_V11, 0.005)) - 2), ...
                min(55, ceil(quantile(all_V11, 0.995)) + 2)];
else
    V_xlim11 = [25, 45];
end
fig11 = figure('Position', [40 40 1380 460]);
tl11  = tiledlayout(1, 3, 'TileSpacing', 'compact', 'Padding', 'compact');

% ---- Smooth analytical MPP locus (replaces noisy Excel-scatter locus) ----
% Vmpp varies ~log with G; Impp scales linearly. Computed once for Np=7 (Cases A,D).
G_locus   = linspace(NIGHT_THR + 10, 1100, 300);
Vmpp_STC  = 0.55 * 60;          % 33.0 V  (Ns=60, 0.55 V/cell)
Impp_STC7 = 9.59 * 7;           % 67.13 A (Np=7)
V_locus7  = Vmpp_STC * (1 + 0.02 * log(max(G_locus/1000, 1e-3)));
I_locus7  = Impp_STC7 * (G_locus / 1000);

% For Case G: one smooth locus per active Np level
Np_G_loci  = sort(unique(NpG_raw(NpG_raw > 0)), 'ascend');  % e.g. [5 6 7]
n_np_loci  = numel(Np_G_loci);
np_lc_cols = {[0.20 0.45 0.85], [0.15 0.65 0.30], [0.75 0.45 0.10]};  % blue/green/orange

% Rated point: end of Randles load line (consistent with load-line model)
V_rated_vis = V_ll_op(end);
I_rated_vis = I_ll_op(end);
P_rated_vis = V_rated_vis * I_rated_vis;

c11_data = {
    ss_A, IrrA, PVV_A, PVI_A, PEMV_A, PEMI_A, NM.A, clr.A;
    ss_D, IrrD, PVV_D, PVI_D, PEMV_D, PEMI_D, NM.D, clr.D;
    ss_G, IrrG, PVV_G, PVI_G, PEMV_G, PEMI_G, NM.G, clr.G;
};
for col = 1:3
    ss_      = c11_data{col,1};   irr_     = c11_data{col,2};
    Vpv_     = c11_data{col,3};   Ipv_     = c11_data{col,4};
    Vpem_    = c11_data{col,5};   Ipem_    = c11_data{col,6};
    lbl_     = c11_data{col,7};   case_clr = c11_data{col,8};

    ax11a = nexttile(tl11, col);
    hold on;

    % 1. Extension beyond rated — dashed grey (draw first, below everything)
    plot(V_ll_ext, I_ll_ext, '--', 'Color', [0.72 0.72 0.72], 'LineWidth', 1.2, ...
        'HandleVisibility', 'off');

    % 2. Operational PEM load line — solid purple
    plot(V_ll_op, I_ll_op, '-', 'Color', clr_ll, 'LineWidth', 2.2, ...
        'DisplayName', 'PEM load line');

    % 3. Vertical dotted line at Vmax
    xline(pem_Vmax_11, ':', 'Color', clr_rated, 'LineWidth', 1.2, ...
        'HandleVisibility', 'off');

    % 4. PV operating-point cloud (circles, coloured by irradiance)
    h_pv = scatter(Vpv_(ss_), Ipv_(ss_), 16, irr_(ss_), 'o', 'filled', ...
        'MarkerFaceAlpha', 0.55, 'MarkerEdgeAlpha', 0);
    h_pv.DisplayName = 'PV op. point';

    % 5. PEM operating-point cloud (triangles, case-colour edge)
    h_pem = scatter(Vpem_(ss_), Ipem_(ss_), 13, irr_(ss_), '^', 'filled', ...
        'MarkerFaceAlpha', 0.55, 'MarkerEdgeAlpha', 0);
    h_pem.MarkerEdgeColor = case_clr;
    h_pem.DisplayName     = 'PEM op. point';

    % 6. Smooth analytical MPP locus
    h_loci = gobjects(0);
    if col <= 2
        % Cases A and D: the array is static, so a single fixed Np=7 locus
        % is the correct reference.
        plot(V_locus7, I_locus7, '--', 'Color', clr_mpp_11, 'LineWidth', 2.0, ...
            'DisplayName', 'MPP locus (N_p=7, fixed)');
    else
        % Case G: the array is reconfigurable, so ONE locus per active Np
        % level. A single Np=7 locus would misrepresent the tracked path.
        for ki = 1:n_np_loci
            Np_ki  = Np_G_loci(ki);
            I_lk   = (9.59 * Np_ki) * (G_locus / 1000);
            h_loci(end+1) = plot(V_locus7, I_lk, '--', ...
                'Color', np_lc_cols{min(ki,3)}, 'LineWidth', 1.8, ...
                'DisplayName', sprintf('MPP locus N_p=%d', Np_ki)); %#ok<SAGROW>
        end
    end

    % 7. Rated operating point — at the END of the Randles load line
    scatter(V_rated_vis, I_rated_vis, 150, 'p', 'filled', ...
        'MarkerFaceColor', clr_rated, 'MarkerEdgeColor', [0.5 0 0], ...
        'LineWidth', 1.0, ...
        'DisplayName', sprintf('Rated  (%.0f W)', P_rated_vis));

    hold off;
    colormap(ax11a, parula);  caxis(ax11a, [0 1000]);
    xlim(ax11a, V_xlim11);
    I_max11 = max([max(Ipv_(ss_)); max(Ipem_(ss_)); I_rated_vis]) * 1.12;
    ylim(ax11a, [0, I_max11]);
    xlabel('Voltage  V  (V)');
    if col == 1,  ylabel('Current  I  (A)');  end
    title(ax11a, lbl_, 'FontSize', 11, 'FontWeight', 'bold');
    grid on;  box on;

    % Panel 1 carries the shared legend (load line, op. points, rated point,
    % fixed Np=7 locus). Panel 3 needs its OWN legend because its MPP loci
    % differ: the reconfigurable array tracks a variable Np, so labelling it
    % with panel 1's fixed "Np=7" entry would be misleading.
    if col == 1
        legend('Location', 'northwest', 'FontSize', 8, 'NumColumns', 1);
    end
    if col == 3 && ~isempty(h_loci)
        legend(ax11a, h_loci, {h_loci.DisplayName}, ...
            'Location', 'northwest', 'FontSize', 8, 'NumColumns', 1);
    end
    if col == 3
        cb11a = colorbar(ax11a, 'Location', 'eastoutside');
        cb11a.Label.String = 'G  (W m^{-2})';
        cb11a.FontSize     = 9;
    end
end
drawnow;
savefig_fn(fig11, 'C11_IV_Trajectories');
% =========================================================================
%  FIGURE C12 – PV EFFICIENCY η_PV COMPARISON
%  η_PV = P_PV / (G × A_active) measures how well sunlight is converted
%  to electricity.  Case D (MPPT) tracks the true maximum η_PV; Cases A
%  and G deviate at high G because the operating point is not at MPP.
% =========================================================================
fprintf('Generating Fig C12: PV Efficiency η_PV...\n');
% Binned mean vs irradiance
Irr_bins12  = 50:50:1050;
bm12 = @(eta, irr) arrayfun(@(g) mean(eta(irr>=g-25 & irr<g+25),'omitnan'), Irr_bins12);
trendPV_A = bm12(etaPV_A, IrrA);
trendPV_D = bm12(etaPV_D, IrrD);
trendPV_G = bm12(etaPV_G, IrrG);
vb12 = @(t) ~isnan(t) & isfinite(t);
fig12 = figure('Position', [140 140 1100 580]);
tl12  = tiledlayout(2,1,'TileSpacing','compact','Padding','compact');
% --- Top: time series ---
ax12a = nexttile;
plot(t_c, sm30(etaPV_Ac), ls.A, 'Color', clr.A, 'LineWidth', lw, 'DisplayName', NM.A); hold on;
plot(t_c, sm30(etaPV_Dc), ls.D, 'Color', clr.D, 'LineWidth', lw, 'DisplayName', NM.D);
plot(t_c, sm30(etaPV_Gc), ls.G, 'Color', clr.G, 'LineWidth', lw, 'DisplayName', NM.G);
hold off;
ylabel('\eta_{PV}  (%)');
etaPV_all = [etaPV_Ac(~isnan(etaPV_Ac)); etaPV_Dc(~isnan(etaPV_Dc)); etaPV_Gc(~isnan(etaPV_Gc))];
ylim([max(0, min(etaPV_all)*0.85), min(30, max(etaPV_all)*1.12)]);
xticks(ax12a, day_ticks); xlim(ax12a,[0 t_c(end)]); set(ax12a,'XTickLabel',[]);
legend('Location','northeast','FontSize',9);
%title('PV Solar-to-Electric Efficiency  \eta_{PV} = P_{PV} / (G \cdot A_{active})', ...
   % 'FontSize',11,'FontWeight','bold');
% --- Bottom: scatter + binned mean vs G ---
ax12b = nexttile;
% Subsample scatter
ss12A = find(maskA & etaPV_A>1); ss12A = ss12A(round(linspace(1,end,min(end,2500))));
ss12D = find(maskD & etaPV_D>1); ss12D = ss12D(round(linspace(1,end,min(end,2500))));
ss12G = find(maskG & etaPV_G>1); ss12G = ss12G(round(linspace(1,end,min(end,2500))));
scatter(IrrA(ss12A), etaPV_A(ss12A), 8, clr.A, 'filled', ...
    'MarkerFaceAlpha',0.15,'MarkerEdgeAlpha',0,'HandleVisibility','off'); hold on;
scatter(IrrD(ss12D), etaPV_D(ss12D), 8, clr.D, 'filled', ...
    'MarkerFaceAlpha',0.15,'MarkerEdgeAlpha',0,'HandleVisibility','off');
scatter(IrrG(ss12G), etaPV_G(ss12G), 8, clr.G, 'filled', ...
    'MarkerFaceAlpha',0.15,'MarkerEdgeAlpha',0,'HandleVisibility','off');
plot(Irr_bins12(vb12(trendPV_A)), trendPV_A(vb12(trendPV_A)), ls.A, ...
    'Color',clr.A,'LineWidth',2.2,'DisplayName',[NM.A ' – mean']);
plot(Irr_bins12(vb12(trendPV_D)), trendPV_D(vb12(trendPV_D)), ls.D, ...
    'Color',clr.D,'LineWidth',2.2,'DisplayName',[NM.D ' – mean (MPPT)']);
plot(Irr_bins12(vb12(trendPV_G)), trendPV_G(vb12(trendPV_G)), ls.G, ...
    'Color',clr.G,'LineWidth',2.2,'DisplayName',[NM.G ' – mean']);
hold off;
xlabel('Solar Irradiance  G  (W m^{-2})');
ylabel('\eta_{PV}  (%)');
xlim([NIGHT_THR, 1050]);
etaPV_sc_all = [etaPV_A(ss12A); etaPV_D(ss12D); etaPV_G(ss12G)];
ylim([max(0,quantile(etaPV_sc_all,0.01)-1), min(30,quantile(etaPV_sc_all,0.99)+2)]);
legend('Location','southwest','FontSize',9);
grid on; box on;
% Top panel: time axis with day ticks
xticks(ax12a, day_ticks);
xlim(ax12a, [0, t_c(end)]);
xlabel(ax12a, 'Time  (h)');
% Bottom panel: irradiance axis — independent x-axis, NOT day ticks
xticks(ax12b, 100:100:1000);
xticklabels(ax12b, arrayfun(@(v) sprintf('%d',v), 100:100:1000, 'UniformOutput',false));
xlim(ax12b, [NIGHT_THR, 1050]);
xlabel(ax12b, 'Solar Irradiance  G  (W m^{-2})');
drawnow;
savefig_fn(fig12, 'C12_PV_Efficiency');
% =========================================================================
%  FIGURE C13 – BOOST CONVERTER OPERATING MODES  (Case D only)
% =========================================================================
fprintf('Generating Fig C13: Boost Converter Analysis (Case D)...\n');
fig13 = figure('Position', [60 60 1100 740]);
tl13  = tiledlayout(2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
ax13_arr = gobjects(2, 1);
% --- Panel 1: Voltage gain M vs time (imagesc background) ---
ax13_arr(1) = nexttile;
ax13 = ax13_arr(1);
Mv_D_fin = MD_c(isfinite(MD_c));
if isempty(Mv_D_fin), Mv_D_fin = [1; 2]; end
m_lo = max(0.80, quantile(Mv_D_fin, 0.01) - 0.05);
m_hi = min(1.50, quantile(Mv_D_fin, 0.99) + 0.10);
image(ax13, 'XData', [t_c(1) t_c(end)], 'YData', [m_lo m_hi], ...
    'CData', repmat(IrrA_c(:)', [2 1]), 'CDataMapping', 'scaled');
colormap(ax13, parula);  caxis(ax13, [0 1000]);
set(ax13, 'YDir', 'normal', 'Layer', 'top');
hold(ax13, 'on');
plot(ax13, t_c, sm30(MD_c), '-', 'Color', 'w',    'LineWidth', lw + 2.5, 'HandleVisibility','off');
plot(ax13, t_c, sm30(MD_c), ls.D, 'Color', clr.D, 'LineWidth', lw, 'DisplayName', 'Gain  M');
yline(ax13, 1.0, 'w--', 'LineWidth', 1.5, 'HandleVisibility', 'off');
hold(ax13, 'off');
ylim(ax13, [m_lo, m_hi]);
ylabel(ax13, 'Voltage Gain  M = V_{out}/V_{in}');
xticks(ax13, day_ticks);  xlim(ax13, [0 t_c(end)]);
legend(ax13, 'Location', 'northeast', 'FontSize', 9);
cb13 = colorbar(ax13, 'Location', 'eastoutside');
cb13.Label.String = 'G (W m^{-2})';
% --- Panel 2: Converter η vs irradiance (scatter) ---
ax13_arr(2) = nexttile;
pts_D2 = find(maskD & ~isnan(etaconv_D_raw));
ss_D2  = pts_D2(round(linspace(1, length(pts_D2), min(length(pts_D2), 4000))));
scatter(IrrD(ss_D2), etaconv_D_raw(ss_D2), 10, clr.D, 'filled', ...
    'MarkerFaceAlpha', 0.4, 'DisplayName', '\eta_{conv} data');
hold on;
% Binned mean trend
Irr_bins13 = 50:50:1200;
eta_trend   = arrayfun(@(g) mean(etaconv_D_raw(IrrD >= g-25 & IrrD < g+25 & maskD), 'omitnan'), ...
    Irr_bins13);
plot(Irr_bins13(~isnan(eta_trend)), eta_trend(~isnan(eta_trend)), ...
    'k-', 'LineWidth', 2.2, 'DisplayName', 'Binned mean');
hold off;
xlabel('Solar Irradiance  G  (W m^{-2})');
ylabel('Converter Efficiency  \eta_{conv}  (%)');
Irr_max13 = max(IrrD(maskD));
xlim([NIGHT_THR, Irr_max13 * 1.02]);
ylim(ax13_arr(2), [92, 100]);
eta_vals_13 = etaconv_D_raw(isfinite(etaconv_D_raw));
if isempty(eta_vals_13), eta_vals_13 = [50; 99]; end
eta_lo = max(0,   min(eta_vals_13) - 5);
eta_hi = min(100, max(eta_vals_13) + 5);
ylim([eta_lo, eta_hi]);
legend('Location', 'southeast', 'FontSize', 9);
grid on;  box on;
% Panel 1 is a time-series; Panel 2 is an irradiance scatter — independent x-axes.
xlabel(ax13_arr(1), 'Time (h)');
%title(tl13, sprintf('Boost Converter Operating Modes – %s', NM.D), ...
    %'FontSize', 12, 'FontWeight', 'bold');
drawnow;
savefig_fn(fig13, 'C13_Boost_Converter_Modes');
% =========================================================================
%  FIGURE C14 – RECONFIGURABLE Np  (Case G only)
% =========================================================================
fprintf('Generating Fig C14: Np Reconfiguration (Case G)...\n');
% Auto-detect actual Np levels from the Excel data — no hardcoded values
Np_unique  = sort(unique(NpG_raw(NpG_raw > 0)), 'ascend');  % e.g. [5 6 7]
n_np       = numel(Np_unique);
np_ylim_lo = Np_unique(1)   - 1.2;
np_ylim_hi = Np_unique(end) + 1.2;
% Labels: sorted ascending → fewest strings = High-G, most strings = Low-G
conf_seq  = {'High-G', 'Mid-G', 'Low-G'};
G_labels  = cell(1, n_np);
for ki = 1:n_np
    G_labels{ki} = sprintf('%d  (%s)', Np_unique(ki), conf_seq{min(ki, 3)});
end
% Zone colors: fewest strings=cool/blue, most strings=warm/orange
NP_zcol_seq = {[0.55 0.72 1.00], [0.58 0.90 0.58], [1.00 0.82 0.50]};
% Switching thresholds – read from the Parameters sheet written by the G
% simulation script so the lines always reflect the actual T-corrected
% values used in that run.  Fall back to STC defaults only if the sheet
% is absent (e.g. first run before any simulation has completed).
THR_low_up = 450;   THR_low_dn = 425;   % defaults (STC, pre-simulation)
THR_hi_up  = 725;   THR_hi_dn  = 700;
try
    param_tbl = readtable(FILES.G, 'Sheet', 'Parameters', ...
                          'VariableNamingRule', 'preserve');
    param_map  = containers.Map(param_tbl{:,1}, param_tbl{:,2});
    if isKey(param_map, 'THR_97_up'),   THR_low_up = param_map('THR_97_up');   end
    if isKey(param_map, 'THR_97_down'), THR_low_dn = param_map('THR_97_down'); end
    if isKey(param_map, 'THR_75_up'),   THR_hi_up  = param_map('THR_75_up');   end
    if isKey(param_map, 'THR_75_down'), THR_hi_dn  = param_map('THR_75_down'); end
    fprintf('  [C14] Thresholds loaded from Parameters sheet: ↑%d/↓%d (7→6)  ↑%d/↓%d (6→5) W/m²\n', ...
        round(THR_low_up), round(THR_low_dn), round(THR_hi_up), round(THR_hi_dn));
catch ME_thr
    fprintf('  [C14] Warning: could not read Parameters sheet (%s). Using STC defaults.\n', ME_thr.message);
end
fig14 = figure('Position', [70 70 920 500]);
ax14  = axes;
xmax_irr14  = max(IrrG(maskG)) * 1.02;
hold on;
% Round thresholds to integers for clean labels
r_low_up = round(THR_low_up);
r_low_dn = round(THR_low_dn);
r_hi_up  = round(THR_hi_up);
r_hi_dn  = round(THR_hi_dn);
% Background zones — labels use rounded integers, not scientific notation
patch([NIGHT_THR  THR_low_dn THR_low_dn NIGHT_THR], ...
    [np_ylim_lo np_ylim_lo np_ylim_hi np_ylim_hi], NP_zcol_seq{3}, ...
    'FaceAlpha', 0.45, 'EdgeColor', 'none', ...
    'DisplayName', sprintf('%d strings  –  Low-G   (G < %d W/m²)', Np_unique(end), r_low_dn));
patch([THR_low_dn THR_hi_dn  THR_hi_dn  THR_low_dn], ...
    [np_ylim_lo np_ylim_lo np_ylim_hi np_ylim_hi], NP_zcol_seq{2}, ...
    'FaceAlpha', 0.45, 'EdgeColor', 'none', ...
    'DisplayName', sprintf('%d strings  –  Mid-G   (%d – %d W/m²)', Np_unique(min(2,n_np)), r_low_dn, r_hi_dn));
patch([THR_hi_dn  xmax_irr14 xmax_irr14 THR_hi_dn], ...
    [np_ylim_lo np_ylim_lo np_ylim_hi np_ylim_hi], NP_zcol_seq{1}, ...
    'FaceAlpha', 0.45, 'EdgeColor', 'none', ...
    'DisplayName', sprintf('%d strings  –  High-G  (G > %d W/m²)', Np_unique(1), r_hi_dn));
% Data scatter
scatter(IrrG(ss_G), NpG_raw(ss_G), 25, clr.G, 'filled', ...
    'MarkerFaceAlpha', 0.55, 'DisplayName', 'Measured N_p');
% Hysteresis threshold lines: dashed = rising edge (↑), dotted = falling edge (↓)
xline(THR_low_up, '--', 'Color', [0.25 0.25 0.25], 'LineWidth', 1.6, 'HandleVisibility', 'off');
xline(THR_low_dn, ':',  'Color', [0.25 0.25 0.25], 'LineWidth', 1.6, 'HandleVisibility', 'off');
xline(THR_hi_up,  '--', 'Color', [0.25 0.25 0.25], 'LineWidth', 1.6, 'HandleVisibility', 'off');
xline(THR_hi_dn,  ':',  'Color', [0.25 0.25 0.25], 'LineWidth', 1.6, 'HandleVisibility', 'off');
% Shade hysteresis dead-bands
patch([THR_low_dn THR_low_up THR_low_up THR_low_dn], ...
    [np_ylim_lo np_ylim_lo np_ylim_hi np_ylim_hi], [0.7 0.7 0.7], ...
    'FaceAlpha', 0.20, 'EdgeColor', 'none', 'HandleVisibility', 'off');
patch([THR_hi_dn  THR_hi_up  THR_hi_up  THR_hi_dn], ...
    [np_ylim_lo np_ylim_lo np_ylim_hi np_ylim_hi], [0.7 0.7 0.7], ...
    'FaceAlpha', 0.20, 'EdgeColor', 'none', 'HandleVisibility', 'off');
% Threshold labels — stagger vertically so the two pairs don't overlap.
% Rising-edge labels (↑, dashed line) sit at the TOP of the plot.
% Falling-edge labels (↓, dotted line) sit just BELOW to avoid overlap.
t_top = np_ylim_hi - 0.20;   % row 1: rising-edge  ↑
t_bot = np_ylim_hi - 0.55;   % row 2: falling-edge ↓
lbl_col = [0.15 0.15 0.15];
% Low-irradiance pair  (7 → 6 transition)
text(THR_low_up + 6, t_top, sprintf('\\uparrow%d', r_low_up), ...
    'FontSize', 9, 'Color', lbl_col, 'FontWeight', 'bold', ...
    'Interpreter', 'tex');
text(THR_low_dn - 6, t_bot, sprintf('\\downarrow%d', r_low_dn), ...
    'FontSize', 9, 'Color', lbl_col, 'FontWeight', 'bold', ...
    'Interpreter', 'tex', 'HorizontalAlignment', 'right');
% High-irradiance pair  (6 → 5 transition)
text(THR_hi_up  + 6, t_top, sprintf('\\uparrow%d', r_hi_up), ...
    'FontSize', 9, 'Color', lbl_col, 'FontWeight', 'bold', ...
    'Interpreter', 'tex');
text(THR_hi_dn  - 6, t_bot, sprintf('\\downarrow%d', r_hi_dn), ...
    'FontSize', 9, 'Color', lbl_col, 'FontWeight', 'bold', ...
    'Interpreter', 'tex', 'HorizontalAlignment', 'right');
% Hysteresis-band annotation (centred inside each grey band)
for bd = {[THR_low_dn, THR_low_up], [THR_hi_dn, THR_hi_up]}
    bd = bd{1};
    text(mean(bd), np_ylim_lo + 0.30, {'hysteresis', 'band'}, ...
        'FontSize', 7, 'Color', [0.4 0.4 0.4], ...
        'HorizontalAlignment', 'center', 'FontAngle', 'italic');
end
hold off;
xlabel('Solar Irradiance  G  (W m^{-2})');
ylabel('Active Parallel Strings  N_p');
xlim([NIGHT_THR, xmax_irr14]);
yticks(Np_unique);
yticklabels(G_labels);
ylim([np_ylim_lo, np_ylim_hi]);
% Legend inside the plot, lower-left — well clear of the data clusters
lgd14 = legend('Location', 'southwest', 'FontSize', 9, 'NumColumns', 1);
lgd14.Color = [1 1 1];   % solid white background (default, explicit for clarity)
grid on;  box on;
%title(tl14, sprintf('PV String Reconfiguration – %s', NM.G), ...
   % 'FontSize', 12, 'FontWeight', 'bold');
drawnow;
savefig_fn(fig14, 'C14_Np_Reconfiguration');
% =========================================================================
%  FIGURE C15 – PEM ELECTROCHEMICAL EFFICIENCY η_PEM
%  η_PEM = P_chemical / P_electrical = (n_H2 × LHV) / (V_op × I_op)
%  Reflects how much of the electrical input is converted to H2 chemical
%  energy vs wasted as ohmic heat.  Lower V_op (fewer strings, lower G)
%  → higher η_PEM.  Reconfigurable case maintains higher η_PEM at high G.
% =========================================================================
fprintf('Generating Fig C15: PEM Electrochemical Efficiency η_PEM...\n');
Irr_bins15  = 50:50:1050;
bm15 = @(eta, irr) arrayfun(@(g) mean(eta(irr>=g-25 & irr<g+25),'omitnan'), Irr_bins15);
trendPEM_A = bm15(etaPEM_A, IrrA);
trendPEM_D = bm15(etaPEM_D, IrrD);
trendPEM_G = bm15(etaPEM_G, IrrG);
vb15 = @(t) ~isnan(t) & isfinite(t);
fig15 = figure('Position', [150 150 1100 580]);
tl15  = tiledlayout(2,1,'TileSpacing','compact','Padding','compact');
% --- Top: time series ---
ax15a = nexttile;
plot(t_c, sm30(etaPEM_Ac), ls.A, 'Color', clr.A, 'LineWidth', lw, 'DisplayName', NM.A); hold on;
plot(t_c, sm30(etaPEM_Dc), ls.D, 'Color', clr.D, 'LineWidth', lw, 'DisplayName', NM.D);
plot(t_c, sm30(etaPEM_Gc), ls.G, 'Color', clr.G, 'LineWidth', lw, 'DisplayName', NM.G);
hold off;
ylabel('\eta_{PEM}  (%)');
etaPEM_all_ts = [etaPEM_Ac(~isnan(etaPEM_Ac)); etaPEM_Dc(~isnan(etaPEM_Dc)); etaPEM_Gc(~isnan(etaPEM_Gc))];
ylim([max(0,min(etaPEM_all_ts)*0.90), min(100,max(etaPEM_all_ts)*1.05)]);
xticks(ax15a, day_ticks); xlim(ax15a,[0 t_c(end)]); set(ax15a,'XTickLabel',[]);
legend('Location','southeast','FontSize',9);
%title('PEM Electrochemical Efficiency  \eta_{PEM} = P_{H_2} / P_{PEM}', ...
    %'FontSize',11,'FontWeight','bold');
% --- Bottom: scatter + binned mean vs G ---
ax15b = nexttile;
ss15A = find(maskA & etaPEM_A>1); ss15A = ss15A(round(linspace(1,end,min(end,2500))));
ss15D = find(maskD & etaPEM_D>1); ss15D = ss15D(round(linspace(1,end,min(end,2500))));
ss15G = find(maskG & etaPEM_G>1); ss15G = ss15G(round(linspace(1,end,min(end,2500))));
scatter(IrrA(ss15A), etaPEM_A(ss15A), 8, clr.A, 'filled', ...
    'MarkerFaceAlpha',0.15,'MarkerEdgeAlpha',0,'HandleVisibility','off'); hold on;
scatter(IrrD(ss15D), etaPEM_D(ss15D), 8, clr.D, 'filled', ...
    'MarkerFaceAlpha',0.15,'MarkerEdgeAlpha',0,'HandleVisibility','off');
scatter(IrrG(ss15G), etaPEM_G(ss15G), 8, clr.G, 'filled', ...
    'MarkerFaceAlpha',0.15,'MarkerEdgeAlpha',0,'HandleVisibility','off');
plot(Irr_bins15(vb15(trendPEM_A)), trendPEM_A(vb15(trendPEM_A)), ls.A, ...
    'Color',clr.A,'LineWidth',2.2,'DisplayName',[NM.A ' – mean']);
plot(Irr_bins15(vb15(trendPEM_D)), trendPEM_D(vb15(trendPEM_D)), ls.D, ...
    'Color',clr.D,'LineWidth',2.2,'DisplayName',[NM.D ' – mean']);
plot(Irr_bins15(vb15(trendPEM_G)), trendPEM_G(vb15(trendPEM_G)), ls.G, ...
    'Color',clr.G,'LineWidth',2.2,'DisplayName',[NM.G ' – mean']);
hold off;
xlabel('Solar Irradiance  G  (W m^{-2})');
ylabel('\eta_{PEM}  (%)');
xlim([NIGHT_THR, 1050]);
etaPEM_sc = [etaPEM_A(ss15A); etaPEM_D(ss15D); etaPEM_G(ss15G)];
ylim([max(0,quantile(etaPEM_sc,0.01)-2), min(100,quantile(etaPEM_sc,0.99)+3)]);
legend('Location','southwest','FontSize',9);
grid on; box on;
drawnow;
savefig_fn(fig15, 'C15_PEM_Efficiency');
% =========================================================================
%  FIGURE C16 – EFFICIENCY CHAIN BREAKDOWN
%  Shows where losses occur in each topology:
%    STH [%] = η_PV × η_coupling × η_PEM / 10000
%  η_coupling = P_PEM / P_PV  (direct ≈ 1; indirect includes converter loss)
% =========================================================================
fprintf('Generating Fig C16: Efficiency Chain Breakdown...\n');
% Mean coupling efficiency (= system eta already computed)
eta_coupl = [mean(etaA(maskA),'omitnan'), mean(etaD(maskD),'omitnan'), mean(etaG(maskG),'omitnan')];
chain_data = [kpi.mean_etaPV; eta_coupl; kpi.mean_etaPEM; kpi.mean_STH]';
% rows = cases [A;D;G], cols = [etaPV, etaCoupling, etaPEM, STH]
chain_labels = {'\eta_{PV}', '\eta_{coupling}', '\eta_{PEM}', '\eta_{STH}'};
chain_colors = [0.55 0.75 0.95;   % light blue
                0.95 0.75 0.45;   % amber
                0.60 0.90 0.60;   % light green
                0.85 0.50 0.85];  % violet
fig16 = figure('Position', [160 160 860 520]);
ax16  = axes;
b16   = bar(1:3, chain_data, 0.72, 'grouped');
for bi = 1:4
    b16(bi).FaceColor    = chain_colors(bi,:);
    b16(bi).EdgeColor    = chain_colors(bi,:) * 0.65;
    b16(bi).DisplayName  = chain_labels{bi};
end
% Value labels on each bar — bold, large, dark colour for readability
for g = 1:3
    for bi = 1:4
        v = chain_data(g, bi);
        if isfinite(v) && v > 0.5
            n_bars = 4;  bar_w = 0.72;
            x_off  = (bi - (n_bars+1)/2) * bar_w / n_bars;
            text(g + x_off, v + 2.5, sprintf('%.1f%%', v), ...
                'HorizontalAlignment','center','FontSize',11,'FontWeight','bold', ...
                'Color', [0.15 0.15 0.15]);
        end
    end
end
set(ax16,'XTick',1:3,'XTickLabel',{NM_SHORT.A, NM_SHORT.D, NM_SHORT.G},'FontSize',10);
xtickangle(ax16, 15);
ylabel('Mean Efficiency  (%)');
ylim([0, max(chain_data(:))*1.20]);
legend('Location','northeast','FontSize',10,'NumColumns',2);
%title('Efficiency Chain Breakdown by Topology', 'FontSize',12,'FontWeight','bold');
grid on; box on;
drawnow;
savefig_fn(fig16, 'C16_Efficiency_Chain');

% =========================================================================
%  FIGURE C17 – ELECTRICITY CURTAILMENT (MISMATCH ENERGY)
% =========================================================================
fprintf('Generating Fig C17: Electricity Curtailment / Mismatch Energy...\n');
fig17 = figure('Position', [170 170 600 500]);
ax17  = axes;
bar_vals = kpi.sum_err_Wh / 1000; % Convert Wh to kWh for readability

b17 = bar(1:3, bar_vals, 0.6);

% Match color to the 'Coupling Efficiency' (amber) from Fig 16
match_color = [0.95 0.75 0.45];
b17.FaceColor = 'flat';
for g = 1:3
    b17.CData(g,:) = match_color;
end
b17.EdgeColor = match_color * 0.65;

max_val = max(bar_vals, [], 'omitnan');
if isnan(max_val) || max_val <= 0
    max_val = 1;
end

hold on;
for g = 1:3
    if ~isnan(bar_vals(g))
        text(g, bar_vals(g) + max_val*0.03, sprintf('%.1f kWh', bar_vals(g)), ...
            'HorizontalAlignment', 'center', 'FontSize', 12, 'FontWeight', 'bold');
    end
end
hold off;

set(ax17, 'XTick', 1:3, 'XTickLabel', {NM.A, NM.D, NM.G}, 'FontSize', 11);
ylabel('Total Curtailed / Mismatch Energy (kWh)', 'FontWeight', 'bold');
ylim([0, max_val*1.2 + 0.1]);
title('Electricity Curtailment Comparison', 'FontSize', 13, 'FontWeight', 'bold');
grid on; box on;
drawnow;
savefig_fn(fig17, 'C17_Electricity_Curtailment');

% =========================================================================
%  FINAL SUMMARY
% =========================================================================
fprintf('\n=== All Figures Saved ===\n');
fprintf('  Output folder: %s\n', fullfile(pwd, OUTDIR));
fprintf('  Figures generated: C1–C17\n');
fprintf('  KPIs saved to: comparison_KPIs.mat\n\n');
fprintf('--- Performance Ranking (by Total H2 Yield) ---\n');
[~, rank_idx] = sort(kpi.total_H2, 'descend');
rank_names = {NM.A, NM.D, NM.G};
for r = 1:3
    idx = rank_idx(r);
    fprintf('  %d. %s\n', r, rank_names{idx});
    fprintf('     H2 = %.2f g  |  C = %.4f  |  STH = %.3f %%\n', ...
        kpi.total_H2(idx), kpi.mean_C(idx), kpi.mean_STH(idx));
    fprintf('     η_PV = %.2f %%  |  η_PEM = %.2f %%  |  Mismatch = %.1f Wh\n', ...
        kpi.mean_etaPV(idx), kpi.mean_etaPEM(idx), kpi.sum_err_Wh(idx));
end

% =========================================================================
%  LOCAL HELPER FUNCTIONS
% =========================================================================
function yq = si_safe(ts, ys, tq)
% Safe wrapper around interp1 that removes duplicate/non-monotonic time
% points before interpolating.  Simulink variable-step output can produce
% repeated timestamps at t=0 and at discrete-event boundaries (e.g. Np
% configuration switches), which griddedInterpolant rejects.
    [~, idx] = unique(ts, 'stable');   % keep first occurrence, preserve order
    yq = interp1(ts(idx), ys(idx), tq, 'linear', 'extrap');
end
