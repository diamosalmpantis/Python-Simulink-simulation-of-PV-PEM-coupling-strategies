% --- Setup Model ---
N = 1; %Number of cells

Vint	= 1.475841;    		% V  
Rint 	= 0.008673;    		% ohm 
Ra   	= 0.00177;    		% ohm 
Rc   	= 0.0005;     	% ohm 
% try to keep kinda a ratio of Ra:Rc = %:1 based on what I found in papers. Started with Ra = 0.005 and Rc = 0.001 
ratio_tau 	= 10; 			% ratio of tau_a to tau_c
tau_a 			= 0.4 ; 	% [s] Time constant anode
tau_c 			= tau_a/ratio_tau ; % [s] Time constant cathode
Ca   	= tau_a/Ra;   		% F  
Cc   	= tau_c/Rc;   		% F  "SIim
Active_Area 	= 17.64;  	% cm²



% --- Read experimental data from first sheet of Data ---
filename = fullfile(fileparts(mfilename('fullpath')), "private_data", "PEM_recorded_data.xlsx");
T = readtable(filename,"Sheet",1);   

measTime = T{:,5};    % seconds 0-9295 s
measI    = T{:,27};   % current - average actual current over 4 cells
measV    = T{:,29};   % voltage - average actual voltage over 4 cells
Input_Time = T{:,5};                     
Input_Voltage = T{:,28}; % Target voltage - average target voltage over 4 cells
%Input_Current    = T{:,27}; % Target current

% --- run model ---
sim('PEM_cell_validate_static');  % run model

% If your To Workspace blocks output timeseries objects, convert them:
if exist('simI','var') && isa(simI,'timeseries')
    simI_ts = simI;
    simTime = simI_ts.Time;
    simI   = simI_ts.Data;
end
if exist('simV','var') && isa(simV,'timeseries')
    simV_ts = simV;
    simV = simV_ts.Data;
end

% --- 3) Interpolate measured data to simulation time base ---
% Choose target timebase. We'll use simTime as x for plotting.
% If simTime does not exist, use measTime (swap roles).
if exist('simTime','var') && ~isempty(simTime)
    t = simTime;
    measI_on_sim = interp1(measTime, measI, t, 'linear', 'extrap');
    measV_on_sim = interp1(measTime, measV, t, 'linear', 'extrap');
else
    t = measTime;
    simI = interp1(simTime, simI, t, 'linear', 'extrap');  % if simTime exists
    simV = interp1(simTime, simV, t, 'linear', 'extrap');
    measI_on_sim = measI;
    measV_on_sim = measV;
end

% --- 4) Compute errors ---
errI = simI - measI_on_sim;
errV = simV - measV_on_sim;

% --- 5) Plot results: one figure with both signals, one with error ---

% Thicker default lines and larger default fonts
set(groot, 'defaultLineLineWidth', 1.5, 'defaultAxesFontSize', 12);

% Colourblind-safe palette (Wong 2011), reused from the other result figures
% in the paper so the same colour always means the same signal:
%   blue = measured current, orange = simulated current (same hue family as
%   the "simulated" trace elsewhere in the paper), teal = measured voltage,
%   violet = simulated voltage. Reviewer comment (Henrik #26): the previous
%   red/magenta pair for "Simulated I" and "Simulated V" was hard to tell
%   apart; blue/orange/teal/violet are pairwise distinguishable, including
%   for the two common types of colour-vision deficiency.
cMeasI = [0.00, 0.45, 0.70];   % blue
cSimI  = [0.85, 0.33, 0.10];   % orange
cMeasV = [0.00, 0.53, 0.55];   % teal
cSimV  = [0.49, 0.18, 0.56];   % violet

fig_err = figure('Units','pixels','Position',[100 100 1369 888]);
subplot(2,1,1);
plot(t, measI_on_sim, '-',  'Color',cMeasI, 'DisplayName','Measured I'); hold on;
plot(t, simI,         '--', 'Color',cSimI,  'DisplayName','Simulated I');
yyaxis right;
ax = gca; ax.YColor = cMeasV;
plot(t, measV_on_sim, '-',  'Color',cMeasV, 'DisplayName','Measured V');
plot(t, simV,         '--', 'Color',cSimV,  'DisplayName','Simulated V');
hold off;
xlabel('Time (s)');
%title('Current and Voltage: Measured vs Simulated');
title('(a)', 'FontSize', 15);
legend('show');
%text(0.02, 0.95, 'a)', 'Units','normalized', 'FontWeight','bold', 'FontSize',12);



subplot(2,1,2);
plot(t, errI, '-', 'Color',cSimI, 'DisplayName','I_{sim}-I_{meas}'); hold on;
plot(t, errV, '-', 'Color',cSimV, 'DisplayName','V_{sim}-V_{meas}');
xlabel('Time (s)');
ylabel('Error');
%title('Error (Simulated - Measured)');
title('(b)', 'FontSize', 15);
legend('show');
%text(0.02, 0.95, 'b)', 'Units','normalized', 'FontWeight','bold', 'FontSize',12);

exportgraphics(fig_err, 'Error_sim_meas.png', 'Resolution', 200);

grid on;

%Option B — two figures (one for currents, one for voltages)
figure;
subplot(2,1,1);
plot(t, measI_on_sim,'-b',t,simI,'--r'); xlabel('Time (s)'); ylabel('I (A)');
legend('Measured','Simulated'); title('(a)', 'FontSize', 15); grid on;
subplot(2,1,2);
plot(t, errI,'-m'); xlabel('Time (s)'); ylabel('Error (A)'); title('(b)', 'FontSize', 15); grid on;

figure;
subplot(2,1,1);
plot(t, measV_on_sim,'-b',t,simV,'--r'); xlabel('Time (s)'); ylabel('V (V)');
legend('Measured','Simulated'); title('(a)', 'FontSize', 15); grid on;
subplot(2,1,2);
plot(t, errV,'-m'); xlabel('Time (s)'); ylabel('Error (V)'); title('(b)', 'FontSize', 15); grid on;


% --- Summary error metrics (use names from this script) ---
% Ensure column vectors
simI = simI(:); 
simV = simV(:);
measI = measI_on_sim(:); 
measV = measV_on_sim(:);

% Mask finite samples and equal length
n = min([numel(simI), numel(measI), numel(simV), numel(measV)]);
simI = simI(1:n); measI = measI(1:n);
simV = simV(1:n); measV = measV(1:n);
okI = isfinite(simI) & isfinite(measI);
okV = isfinite(simV) & isfinite(measV);

% Error vectors
eI = simI(okI) - measI(okI);
eV = simV(okV) - measV(okV);

% Metrics
RMSE_I  = sqrt(mean(eI.^2));
NRMSE_I = RMSE_I / (max(measI(okI)) - min(measI(okI))); % normalized by range
%RelRMSE_I = RMSE_I / mean(abs(measI(okI)));            % relative to mean
%PctBias_I = 100 * mean(eI) / mean(abs(measI(okI)));    % percent bias

RMSE_V  = sqrt(mean(eV.^2));
NRMSE_V = RMSE_V / (max(measV(okV)) - min(measV(okV)));
%RelRMSE_V = RMSE_V / mean(abs(measV(okV)));
%PctBias_V = 100 * mean(eV) / mean(abs(measV(okV)));

% Print
fprintf('Current:  RMSE=%.4g A, NRMSE=%.4g%\n', ...
    RMSE_I, NRMSE_I);
fprintf('Voltage:  RMSE=%.4g V, NRMSE=%.4g%\n', ...
    RMSE_V, NRMSE_V);

%Polarisation Curve

% Fit linear models V = R * I + V0 for measured and simulated
p_meas = polyfit(measI, measV, 1);   % [R_meas, V0_meas]
p_sim  = polyfit(simI,        simV,        1);     % [R_sim,  V0_sim]

% Compute R²
Vmeas_pred = polyval(p_meas, measI);
Vsim_pred  = polyval(p_sim,  simI);
R2_meas = 1 - sum((measV - Vmeas_pred).^2) / sum((measV - mean(measV)).^2);
R2_sim  = 1 - sum((simV - Vsim_pred).^2) / sum((simV - mean(simV)).^2);

% Fit lines for plotting
Imin = min([measI; simI]); Imax = max([measI; simI]);
I_fit = linspace(Imin, Imax, 200);
Vfit_meas = polyval(p_meas, I_fit);
Vfit_sim  = polyval(p_sim,  I_fit);

% Plot
%figure('Color','w','Position',[100 100 900 600]);
figure;
plot(measI, measV, 'o', 'Color',[0 0.4470 0.7410], 'MarkerFaceColor',[0 0.4470 0.7410], 'MarkerSize',2); hold on;
plot(simI, simV, 's', 'Color',[0.8500 0.3250 0.0980], 'MarkerFaceColor',[0.8500 0.3250 0.0980], 'MarkerSize',3);

plot(I_fit, Vfit_meas, '--m', 'LineWidth',2.2);
plot(I_fit, Vfit_sim,  '--g', 'LineWidth',2.2);

xlabel('Current I (A)', 'FontSize',13);
ylabel('Voltage V (V)', 'FontSize',13);
%title('Polarization Curve: Measured vs Simulated', 'FontSize',15);
legend('Measured data','Simulated data','Measured fit','Simulated fit', 'Location','best');
grid on; box on; set(gca,'FontSize',11);

% Display fit equations and R^2 in a legend-like text box
eq_meas = sprintf('Measured: V = %.6f \\cdot I + %.6f,  R^2 = %.4f', p_meas(1), p_meas(2), R2_meas);
eq_sim  = sprintf('Simulated: V = %.6f \\cdot I + %.6f,  R^2 = %.4f', p_sim(1), p_sim(2), R2_sim);

% Place text in upper-left of axes (normalized coordinates)
xpos = 0.02; ypos = 0.98;
text(xpos, ypos, {eq_meas, eq_sim}, 'Units','normalized', 'VerticalAlignment','top', ...
     'BackgroundColor','white', 'EdgeColor','black', 'FontSize',11, 'Interpreter','tex');



% --- 6) Save combined data to new Excel file ---
outT = table(t(:), measI_on_sim(:), measV_on_sim(:), simI(:), simV(:), errI(:), errV(:), ...
    'VariableNames',{'Time','MeasCurrent','MeasVoltage','SimCurrent','SimVoltage','ErrCurrent','ErrVoltage'});
summaryT = table(RMSE_I,NRMSE_I,RMSE_V,NRMSE_V, ...
    'VariableNames',{'RMSE_I','NRMSE_I','RMSE_V','NRMSE_V'});
fitT = table(p_meas(1), p_meas(2), R2_meas, p_sim(1), p_sim(2), R2_sim, ...
    'VariableNames', {'Meas_slope','Meas_intercept','Meas_R2','Sim_slope','Sim_intercept','Sim_R2'});

writetable(outT, "comparison_results_static.xlsx", "Sheet", 1);
writetable(summaryT, "comparison_results_static.xlsx", "Sheet", 2);
writetable(fitT, "comparison_results_static.xlsx", "Sheet", 3);%, 'WriteRowNames', false);
