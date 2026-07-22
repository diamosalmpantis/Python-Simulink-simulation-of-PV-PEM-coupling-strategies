% generate_mpp_data_Ns60.m
%
% Generates mpp_data_Ns60_NpX.mat files for Np = 5, 6, 7.
%
% Uses a single-diode PV model to sweep irradiance levels and extract the
% true MPP (V_mpp, I_mpp, P_mpp) for each case.  Fits 2nd-order polynomials
% and saves in the same format as the existing mpp_data_Ns45_*.mat files.
%
% Saves to TWO locations so the simulation scripts find the file regardless
% of which directory MATLAB is running from:
%   1.  <this script's folder>   (Final_Batt_Comparison)
%   2.  One level up  ../        (Hanna Thesis_Laptop)
%
% Run this once before re-running Direct_hourly.m / Indirect_hourly.m /
% Rec_hourly.m so those scripts use accurate MPP references.
% =========================================================================
clear; clc;
fprintf('=== MPP data generator  Ns=60, Np=5/6/7 ===\n\n');

% ── PV cell parameters (Amerisolar 320W class) ───────────────────────────
Vm_cell  = 0.55;    % [V]   MPP voltage per cell at STC
Im_cell  = 9.59;    % [A]   MPP current per cell at STC
Voc_cell = 0.67;    % [V]   open-circuit voltage per cell at STC
Isc_cell = 10.14;   % [A]   short-circuit current per cell at STC
Ns_cell  = 60;      % cells in series per string
T_cell   = 25;      % [°C]  cell temperature (STC)

% Irradiance sweep
G_list = (50 : 25 : 1200)';   % W/m²  (49 levels, covers operating range)

% ── Single-diode model parameters ────────────────────────────────────────
% Derived from STC datasheet values using the standard 5-parameter method.
% Thermal voltage per cell:
q  = 1.602e-19;   % C
k  = 1.381e-23;   % J/K
T_K = T_cell + 273.15;
n_ideal = 1.3;    % ideality factor (typical for polycrystalline Si)
Vt = n_ideal * k * T_K / q;           % thermal voltage (single cell)
Vt_stack = Vt * Ns_cell;              % thermal voltage (full string)

% Saturation current I0 from Voc at STC
Voc_stc  = Voc_cell * Ns_cell;        % string Voc at STC
Isc_stc  = Isc_cell;                  % string Isc (parallel strings don't change Isc per string)
I0 = Isc_stc * exp(-Voc_stc / Vt_stack);

% Series resistance from slope at Voc (approximation)
Rs = 0.002 * Ns_cell;   % [Ohm]  ~2 mOhm/cell * Ns

% ── MPP solver ───────────────────────────────────────────────────────────
function [Vmpp, Impp, Pmpp] = find_mpp(Iph, I0, Vt, Rs, Voc)
    % Sweep voltage, compute current via Lambert-W or Newton iteration
    V_sweep = linspace(0, Voc * 0.999, 2000)';
    % I(V) implicit equation: I = Iph - I0*(exp((V+I*Rs)/Vt) - 1)
    % Solved iteratively:
    I_sweep = zeros(size(V_sweep));
    I_est   = Iph * ones(size(V_sweep));   % initial guess
    for iter = 1:80
        f  = I_est - Iph + I0 * (exp((V_sweep + I_est .* Rs) / Vt) - 1);
        df = 1 + I0 .* Rs ./ Vt .* exp((V_sweep + I_est .* Rs) / Vt);
        I_new = I_est - f ./ df;
        if max(abs(I_new - I_est)) < 1e-9, break; end
        I_est = max(0, I_new);
    end
    I_sweep = max(0, I_est);
    P_sweep = V_sweep .* I_sweep;
    [Pmpp, idx] = max(P_sweep);
    Vmpp = V_sweep(idx);
    Impp = I_sweep(idx);
end

% ── Loop over Np values ──────────────────────────────────────────────────
Np_list = [5, 6, 7];

for np_idx = 1:length(Np_list)
    Np_cell = Np_list(np_idx);
    fprintf('Computing Ns=%d, Np=%d ...\n', Ns_cell, Np_cell);

    % String parameters
    Iph_stc = Isc_cell * Np_cell;     % photocurrent scales with Np
    Voc_str  = Voc_stc;               % Voc unchanged (series cells only)

    V_mpp = zeros(size(G_list));
    I_mpp = zeros(size(G_list));
    P_mpp = zeros(size(G_list));

    for gi = 1:length(G_list)
        G  = G_list(gi);
        Iph = Iph_stc * (G / 1000);   % photocurrent scales linearly with G

        % Approximate Voc shift with irradiance (log dependence)
        Voc_G = Voc_str + Vt_stack * log(G / 1000 + 1e-6);
        Voc_G = max(Voc_G, 0);

        [Vmpp_g, Impp_g, Pmpp_g] = find_mpp(Iph, I0, Vt_stack, Rs, Voc_G);
        V_mpp(gi) = Vmpp_g;
        I_mpp(gi) = Impp_g;
        P_mpp(gi) = Pmpp_g;
    end

    irr_unique = G_list;

    % Polynomial fits (degree 2, matching existing format)
    pP = polyfit(irr_unique, P_mpp, 2);
    pV = polyfit(irr_unique, V_mpp, 2);
    pI = polyfit(irr_unique, I_mpp, 2);

    % Quick sanity check at STC (G=1000)
    G_stc = 1000;
    fprintf('  STC check (G=1000):  Vmpp=%.2f V  Impp=%.2f A  Pmpp=%.0f W\n', ...
        polyval(pV, G_stc), polyval(pI, G_stc), polyval(pP, G_stc));
    fprintf('  Expected:            Vmpp=%.2f V  Impp=%.2f A  Pmpp=%.0f W\n\n', ...
        Vm_cell * Ns_cell, Im_cell * Np_cell, Vm_cell * Ns_cell * Im_cell * Np_cell);

    % ── Save .mat in both locations ──────────────────────────────────────
    fname = sprintf('mpp_data_Ns%d_Np%d.mat', Ns_cell, Np_cell);

    % Location 1: same folder as this script (Final_Batt_Comparison)
    here_path = fullfile(fileparts(mfilename('fullpath')), fname);
    save(here_path, 'pP', 'pV', 'pI', 'irr_unique', 'P_mpp', 'V_mpp', 'I_mpp', 'Ns_cell', 'Np_cell');
    fprintf('  Saved → %s\n', here_path);

    % Location 2: one level up (../), where simulation scripts look
    up_path = fullfile(fileparts(mfilename('fullpath')), '..', fname);
    save(up_path, 'pP', 'pV', 'pI', 'irr_unique', 'P_mpp', 'V_mpp', 'I_mpp', 'Ns_cell', 'Np_cell');
    fprintf('  Saved → %s\n\n', up_path);
end

fprintf('=== Done. Re-run your simulation scripts now. ===\n');

% ── Quick plot to verify ─────────────────────────────────────────────────
G_plot = linspace(100, 1100, 200)';
figure('Name', 'MPP locus verification Ns=60', 'Color', 'w', 'Position', [100 100 900 380]);
tiledlayout(1, 2, 'TileSpacing', 'loose', 'Padding', 'compact');
colors = {[0.85 0.33 0.10], [0.13 0.47 0.71], [0.47 0.67 0.19]};

ax1 = nexttile;
for np_idx = 1:3
    Np_cell = Np_list(np_idx);
    fname   = fullfile(fileparts(mfilename('fullpath')), ...
                       sprintf('mpp_data_Ns%d_Np%d.mat', Ns_cell, Np_cell));
    s = load(fname, 'pV', 'pI');
    plot(polyval(s.pV, G_plot), polyval(s.pI, G_plot), '-', ...
        'Color', colors{np_idx}, 'LineWidth', 2, ...
        'DisplayName', sprintf('Np=%d', Np_cell));
    hold on;
end
xlabel('V_{MPP}  (V)');  ylabel('I_{MPP}  (A)');
title('MPP locus  (I vs V)');
legend('Location', 'northwest');  grid on; box on;

ax2 = nexttile;
for np_idx = 1:3
    Np_cell = Np_list(np_idx);
    fname   = fullfile(fileparts(mfilename('fullpath')), ...
                       sprintf('mpp_data_Ns%d_Np%d.mat', Ns_cell, Np_cell));
    s = load(fname, 'pP');
    plot(G_plot, polyval(s.pP, G_plot), '-', ...
        'Color', colors{np_idx}, 'LineWidth', 2, ...
        'DisplayName', sprintf('Np=%d', Np_cell));
    hold on;
end
xlabel('Irradiance  G  (W m^{-2})');  ylabel('P_{MPP}  (W)');
title('Peak power vs irradiance');
legend('Location', 'northwest');  grid on; box on;
drawnow;
