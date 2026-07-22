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

filename = fullfile(fileparts(mfilename('fullpath')), "private_data", "PEM_dyn_wind_data_short.xlsx");
T = readtable(filename,"Sheet",1);   % assume columns: Time, Current, Voltage

measTime = T{:,5};   % seconds
measI    = T{:,14};   % current - actual current
measV    = T{:,17};   % voltage - actual voltage
Input_Time = T{:,5};                     
Input_Voltage = T{:,16}; % Target voltage
Input_Current    = T{:,14}; % Target current

% --- 2) Run Simulink model (assumes model configured to save outputs to workspace) ---
% Example: model name is "myModel". Configure To Workspace blocks to save as simTime, simI, simV
sim('PEM_cell_validate_dynamic');  % uncomment to run the model from script

% For this example we assume you already have simTime, simI, simV in workspace.
% If your To Workspace blocks output timeseries objects, convert them:
if exist('simI','var') && isa(simI,'timeseries')
    simI_ts = simI;
    simTime = simI_ts.Time;
    simI   = simI_ts.Data;
end
if exist('simV','var') && isa(simV,'timeseries')
    simV_ts = simV;
    simV = simV_ts.Data;
    % ensure simTime matches simV.Time if needed
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
figure;
subplot(2,1,1);
plot(t, measI_on_sim, '-b', 'DisplayName','Measured I'); hold on;
plot(t, simI,        '--r', 'DisplayName','Simulated I');
yyaxis right;
plot(t, measV_on_sim, '-c', 'DisplayName','Measured V');
plot(t, simV,         '--m', 'DisplayName','Simulated V');
hold off;
xlabel('Time (s)');
title('Current and Voltage: Measured vs Simulated');
legend('show');

subplot(2,1,2);
plot(t, errI, '-r', 'DisplayName','I_{sim}-I_{meas}'); hold on;
plot(t, errV, '-m', 'DisplayName','V_{sim}-V_{meas}');
xlabel('Time (s)');
ylabel('Error');
title('Error (Simulated - Measured)');
legend('show');
grid on;

% --- 6) Save combined data to new Excel file ---
outT = table(t(:), measI_on_sim(:), measV_on_sim(:), simI(:), simV(:), errI(:), errV(:), ...
    'VariableNames',{'Time','MeasCurrent','MeasVoltage','SimCurrent','SimVoltage','ErrCurrent','ErrVoltage'});

% assume t, measI_on_sim, measV_on_sim, simI, simV exist and are same length
% compute errors
errI = simI - measI_on_sim;
errV = simV - measV_on_sim;

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
legend('Measured','Simulated'); title('Voltage'); grid on;
subplot(2,1,2);
plot(t, errV,'-m'); xlabel('Time (s)'); ylabel('Error (V)'); title('Voltage Error'); grid on;





writetable(outT,"comparison_results.xlsx","Sheet",1);

% --- Summary error metrics (use names from this script) ---
% Ensure column vectors
simI = simI(:); simV = simV(:);
measI = measI_on_sim(:); measV = measV_on_sim(:);

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
RelRMSE_I = RMSE_I / mean(abs(measI(okI)));            % relative to mean
PctBias_I = 100 * mean(eI) / mean(abs(measI(okI)));    % percent bias

RMSE_V  = sqrt(mean(eV.^2));
NRMSE_V = RMSE_V / (max(measV(okV)) - min(measV(okV)));
RelRMSE_V = RMSE_V / mean(abs(measV(okV)));
PctBias_V = 100 * mean(eV) / mean(abs(measV(okV)));

% Print
fprintf('Current:  RMSE=%.4g A, NRMSE=%.4g, RelRMSE=%.4g, PctBias=%.3g%%\n', ...
    RMSE_I, NRMSE_I, RelRMSE_I, PctBias_I);
fprintf('Voltage:  RMSE=%.4g V, NRMSE=%.4g, RelRMSE=%.4g, PctBias=%.3g%%\n', ...
    RMSE_V, NRMSE_V, RelRMSE_V, PctBias_V);

% Optional: use built-in rmse if available
% RMSE_I = rmse(simI(okI), measI(okI));
% RMSE_V = rmse(simV(okV), measV(okV));

% Save summary to table and add to Excel
%summaryT = table(RMSE_I, MAE_I, MAX_I, NRMSE_I, RelRMSE_I, PctBias_I, ...
%                 RMSE_V, MAE_V, MAX_V, NRMSE_V, RelRMSE_V, PctBias_V, ...
%                 'VariableNames',{'RMSE_I','MAE_I','MAX_I','NRMSE_I','RelRMSE_I','PctBias_I', ...
%                                  'RMSE_V','MAE_V','MAX_V','NRMSE_V','RelRMSE_V','PctBias_V'});

%writetable(summaryT,"comparison_results.xlsx","Sheet",2);
