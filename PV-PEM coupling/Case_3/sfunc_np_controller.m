function sfunc_np_controller(block)
%SFUNC_NP_CONTROLLER  Level-2 MATLAB S-Function: Python-Simulink co-simulation.
%
%  This block is the bridge between Simulink and the Python real-time Np
%  controller (np_controller_step.py).  At every sample instant it:
%    1. Reads G (irradiance) and T (temperature) from Simulink input ports.
%    2. Calls py.np_controller_step.step(G, T) — the Python controller.
%    3. Writes the returned Np (5, 6, or 7) to the Simulink output port.
%
%  Python maintains the controller state (current Np) as a module-level
%  global variable, which MATLAB's Python engine keeps alive for the entire
%  simulation.  This is genuine step-by-step co-simulation: Python code
%  executes at every Simulink timestep, not pre-computed beforehand.
%
%  HOW TO ADD TO SIMULINK
%  ----------------------
%  1. Open PV_PEM_reconfigurable → Recon_sw subsystem.
%  2. Add an S-Function block (Simulink > User-Defined Functions > S-Function).
%  3. Set "S-Function name" → sfunc_np_controller
%     Set "S-Function parameters" → (leave blank)
%  4. Connect:
%       Irradiance signal (G)     → input port 1
%       Temperature signal (T)    → input port 2
%       Output port 1 (Np)        → switch control logic
%         (replaces the THR_97_up / THR_75_up threshold comparator chain)
%  5. Sample time is inherited from Irr_stair_tsamp (= 60/scale_factor s).
%
%  REQUIREMENTS
%  ------------
%  • np_controller_step.py must be on the MATLAB/Python path.
%    The Start method adds the script folder automatically.
%  • pyenv must point to the correct Python interpreter before running.
%    G_direct_recon__no_batt_run.m calls pyenv in Section 4.
%
%  DIAGNOSTICS
%  -----------
%  The block prints a startup confirmation and the initial Np to the
%  MATLAB command window.  During simulation, decisions are silent (fast).
%  After simulation, read Np_current from workspace for logging.

setup(block);

end  % sfunc_np_controller


% =========================================================================
%  SETUP  — called once when the model is compiled
% =========================================================================
function setup(block)

% ── Ports ──────────────────────────────────────────────────────────────────
block.NumInputPorts  = 2;   % port 1: G [W/m²] | port 2: T [°C]
block.NumOutputPorts = 1;   % port 1: Np (5, 6, or 7)

block.SetPreCompInpPortInfoToDynamic;
block.SetPreCompOutPortInfoToDynamic;

block.InputPort(1).Dimensions  = 1;
block.InputPort(1).DirectFeedthrough = true;
block.InputPort(2).Dimensions  = 1;
block.InputPort(2).DirectFeedthrough = true;

block.OutputPort(1).Dimensions = 1;
block.OutputPort(1).DatatypeID = 0;   % double

% ── Sample time: inherited from driving signal ─────────────────────────────
% Use [Irr_stair_tsamp 0] if you prefer an explicit rate.
block.SampleTimes = [-1 0];   % -1 = inherited (matches Irr_stair_tsamp)

% ── Callbacks ─────────────────────────────────────────────────────────────
block.RegBlockMethod('Start',     @Start);
block.RegBlockMethod('Outputs',   @Outputs);
block.RegBlockMethod('Terminate', @Terminate);

end  % setup


% =========================================================================
%  START  — called once when the simulation begins
% =========================================================================
function Start(block)  %#ok<INUSD>

% Add the folder containing np_controller_step.py to Python's path.
script_dir = fileparts(which('sfunc_np_controller'));
if isempty(script_dir)
    script_dir = pwd;
end

py_path = py.sys.path;
if ~any(strcmp(cell(py_path), script_dir))
    py.sys.path().insert(int32(0), script_dir);
end

% (Re-)import the module so any edits since last run are picked up.
py.importlib.import_module('np_controller_step');
try
    py.importlib.reload(py.importlib.import_module('np_controller_step'));
catch
    % reload not critical — module already loaded
end

% Reset controller state to Np = 7 (maximum strings, safe start).
py.np_controller_step.reset();

fprintf('[sfunc_np_controller] Python co-simulation ACTIVE\n');
fprintf('  Module  : np_controller_step.py\n');
fprintf('  Initial : Np = 7 strings\n');
fprintf('  Weights : W_H2 = 1/6  |  W_eta = 5/6\n\n');

end  % Start


% =========================================================================
%  OUTPUTS  — called at every Simulink sample instant
% =========================================================================
function Outputs(block)

G = block.InputPort(1).Data;   % irradiance  [W/m²]
T = block.InputPort(2).Data;   % temperature [°C]

% Call Python step function — returns Python int (5, 6, or 7)
Np = double(py.np_controller_step.step(G, T));

block.OutputPort(1).Data = Np;

end  % Outputs


% =========================================================================
%  TERMINATE  — called once when the simulation ends
% =========================================================================
function Terminate(block)  %#ok<INUSD>

try
    Np_final = double(py.np_controller_step.get_current_np());
    fprintf('[sfunc_np_controller] Simulation ended.  Final Np = %d\n', Np_final);
catch
    fprintf('[sfunc_np_controller] Simulation ended.\n');
end

end  % Terminate
