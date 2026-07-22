# Python–Simulink Simulation of DC-Coupled PV–PEM Electrolyzer Systems under Minute-Level Solar Variability

This repository contains the simulation code accompanying the manuscript of the same title. It implements a Python–MATLAB/Simulink co-simulation framework that evaluates seven DC-coupled PV–PEM electrolyzer architectures under minute-resolution, downscaled meteorological data. Three architectures are battery-less and four are battery-integrated. The repository also includes the irradiance and temperature downscaling algorithms used to generate the input data, and the electrochemical model validation against experimental measurements.

## Repository structure

```
01_PEM_Validation/
    Sim_vs_meas_static.m              + PEM_cell_validate_static.slx
    Sim_vs_meas_dynamic.m             + PEM_cell_validate_dynamic.slx

02_Downscaling_Algorithms/
    ghi_downscaling_v5_KNN.py             (GHI: White Noise, Markov+AR(1), Hybrid KNN)
    Final_Temperature_Downscaling.py      (Temp: Linear, PCHIP, Hybrid KNN)

03_No_Battery_Cases/
    Case1_Indirect/            PV_PEM_indirect.m              + PV_PEM_indirect.slx
    Case2_Direct/              PV_PEM_direct.m                + PV_PEM_direct.slx
    Case3_Reconfigurable/      PV_PEM_reconfigurable.m        + PV_PEM_reconfigurable.slx
                               Reconfiguration_Controller/     (Python + Simulink S-function)
    compare_cases.m            (post-processing / comparative figures)

04_Battery_Cases/
    Case4_Indirect_EMS/            PV_PEM_indirect_battery.m           + PV_PEM_indirect_battery.slx
    Case5_Direct_Passive/          PV_PEM_direct_battery_passive.m     + PV_PEM_direct_battery_passive.slx
    Case6_Direct_Active/           PV_PEM_direct_battery_active.m      + PV_PEM_direct_battery_active.slx
    Case7_Reconfigurable_Active/   PV_PEM_reconfigurable_battery.m     + PV_PEM_reconfigurable_battery.slx
    compare_batt_cases.m       (post-processing / comparative figures)
```

Each case folder contains one MATLAB driver script (`.m`) and its Simulink model (`.slx`), sharing the same base name. The driver script loads the model, applies parameter overrides, runs the simulation, and exports the results to Excel. You do not need to open the model separately.

The "Applying Model Patches" message printed at the start of each run is expected. The script loads the base model and creates a working copy internally. MATLAB handles this automatically. There is no separate file to look for.

The scripts in `01_PEM_Validation/` and `02_Downscaling_Algorithms/` expect their experimental and measurement input files inside a `private_data/` subfolder at each script's location. This data is not distributed in this repository. See [Data availability](#data-availability) below for how to obtain it.

## Requirements

**MATLAB/Simulink**
All models in this repository were built and verified in **MATLAB/Simulink R2026a**, with Simscape and Simscape Electrical installed. Use R2026a to avoid compatibility issues, particularly for the Simscape Electrical blocks used throughout.

**Python** (downscaling algorithms and the reconfiguration controller)
Python 3.10 or later, with:
```
numpy
pandas
matplotlib
scipy
scikit-learn
pvlib
openpyxl
```
Install with:
```
pip install numpy pandas matplotlib scipy scikit-learn pvlib openpyxl
```

## How to run

**1. PEM validation.** Run `Sim_vs_meas_static.m` (steady-state) and `Sim_vs_meas_dynamic.m` (dynamic) in MATLAB. Each script calls its companion Simulink model and reports RMSE, MAE, and R² against the experimental measurement data (see [Data availability](#data-availability) for how to obtain it).

**2. Downscaling algorithms.** Run `ghi_downscaling_v5_KNN.py` and `Final_Temperature_Downscaling.py` directly with Python. Both expect the reference 1-minute meteorological record described in [Data availability](#data-availability). Each script runs all three candidate algorithms for its variable and reports NRMSE, NMBE, and R² for GHI, or RMSE, MAE, and R² for temperature.

**3. No-battery cases.** Run the `.m` driver script in each `CaseN_*` folder from MATLAB. It loads the co-located `.slx` model itself. Case 3 (Reconfigurable) additionally requires the scripts in `Reconfiguration_Controller/`. The Python side (`optimal_np_finder.py`, `realtime_np_controller.py`, `np_controller_step.py`) pre-computes the optimal string-count sequence. The Simulink side (`sfunc_np_controller.m`, `np_controller_block.m`) reads that sequence through a `From Workspace` block. `PV_PEM_reconfigurable.m` also calls `pyenv` to locate a Python interpreter. If MATLAB doesn't auto-detect one, set the path explicitly as instructed in the script's comment. Run `compare_cases.m` afterwards to reproduce the comparative figures and KPIs.

**4. Battery cases.** Follow the same pattern for Cases 4 to 7. Case 7's reconfiguration sequence is pre-computed offline beforehand, so it does not call `pyenv` directly. Run `compare_batt_cases.m` afterwards for the comparative figures and KPIs.

`compare_batt_cases.m`, and the driver scripts for Case 7, default to variable names and output files with a `_CNR` suffix, left over from the authors' own cross-location workflow. To reproduce the primary Lyngby results reported in the manuscript, drop that suffix from the relevant `WEATHER_FILE`, `EXCEL_OUT`, and `FILES{...}` variables before running. See the comments at the top of each script.

## Data availability

The raw measurement and reference data used by the scripts in this repository are not distributed here. If you would like access to this data, please contact the corresponding author.

For context, the PEM electrochemical validation data originates from Pape et al. (2025), *International Journal of Hydrogen Energy*, 127, 51–63 ([doi.org/10.1016/j.ijhydene.2025.03.387](https://doi.org/10.1016/j.ijhydene.2025.03.387)), and the cross-location (CNR, Navarra, Spain) results reported in the manuscript use the same models in this repository, re-run against the openly available BSRN station record of Olano, X. (2024), *Basic measurements of radiation at station CNER (2023)*, PANGAEA ([doi.org/10.1594/PANGAEA.931893](https://doi.org/10.1594/PANGAEA.931893)). The CNR-specific driver scripts are not included here, to keep the repository focused on the primary Lyngby case study, but are available from the corresponding author on request.

## Citation

If you use this code, please cite the accompanying paper:

> D. Almpantis, H. Wöhlert, M.H. Fouladfar, H. Davidsson, M. Andersson. "Python–Simulink Simulation of DC-Coupled PV–PEM Electrolyzer Systems under Minute-Level Solar Variability." *Manuscript submitted for publication*, 2026.

```bibtex
@misc{Almpantis2026PVPEMSimulink,
  author = {Almpantis, Diamantis and W{\"o}hlert, Hanna and Fouladfar, Mohammad Hossein and Davidsson, Henrik and Andersson, Martin},
  title  = {Python--Simulink Simulation of DC-Coupled PV--PEM Electrolyzer Systems under Minute-Level Solar Variability},
  year   = {2026},
  note   = {Manuscript submitted for publication},
  url    = {https://github.com/USERNAME/REPOSITORY}
}
```

Update the citation above with the final journal, volume, page numbers, and DOI once the manuscript is accepted. Update the `url` field with this repository's actual address.

## License

This repository is released under the [MIT License](LICENSE). The accompanying manuscript text and figures are copyright of the publishing journal upon acceptance and are not covered by this license.

## Contact

Diamantis Almpantis — diamantis.almpantis@energy.lth.se
Department of Energy Sciences, Lund University
