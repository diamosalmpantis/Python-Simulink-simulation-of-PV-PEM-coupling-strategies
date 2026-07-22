# Python–Simulink Simulation of DC-Coupled PV–PEM Electrolyzer Systems under Minute-Level Solar Variability

This repository contains the simulation code accompanying the manuscript of the same title. It implements a Python–MATLAB/Simulink co-simulation framework that evaluates seven DC-coupled PV–PEM electrolyzer architectures (three battery-less, four battery-integrated) under minute-resolution, downscaled meteorological data, together with the irradiance and temperature downscaling algorithms used to generate that input data and the electrochemical model validation against experimental measurements.

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

Each case folder contains one MATLAB driver script (`.m`) and its Simulink model (`.slx`), sharing the same base name. The driver script loads the `.slx` model listed above, applies parameter overrides, runs the simulation, and exports the results to Excel. **The model file itself never changes** — the "Applying Model Patches" step you'll see printed at the start of each run loads this base model, saves an in-memory working copy internally (MATLAB handles this automatically; there is no separate file to look for), and applies the patches to that copy. You do not need to do anything beyond running the `.m` script.

### MATLAB/Simulink version note

All models **except Case 7's** are saved in and verified to load in **MATLAB/Simulink R2025b**. Case 7's model (`PV_PEM_reconfigurable_battery.slx`) was saved in **R2026a** and cannot be safely downgraded: MATLAB's own "Export to Previous Version" tool explicitly does not support the Simscape Electrical blocks this model uses, and a forced conversion produces a model MATLAB itself flags as only "partially successful" with possible behavioural changes. Rather than ship an unverified conversion, Case 7 is provided as-is; running it requires MATLAB R2026a (or later, once you've confirmed compatibility yourself). All other cases and the PEM validation models were load-tested and confirmed working in R2025b.

**A `private_data/` subfolder appears inside `01_PEM_Validation/` and `02_Downscaling_Algorithms/`.** These hold the experimental/measurement files the scripts expect at those exact relative paths, but the data itself is not intended for public redistribution (see [Data availability](#data-availability) below) and should be excluded before pushing to a public remote, e.g. via `.gitignore`:
```
**/private_data/
```

## Requirements

**MATLAB/Simulink**
R2025b, with Simscape and Simscape Electrical, for every case except Case 7 (see the version note above), which requires R2026a.

**Python** (downscaling algorithms and the reconfiguration controller)
Python ≥ 3.10, with:
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

**1. PEM validation** — run `Sim_vs_meas_static.m` (steady-state) and `Sim_vs_meas_dynamic.m` (dynamic) in MATLAB; each calls its companion Simulink model and reports RMSE/MAE/R² against the experimental data expected at `private_data/PEM_recorded_data.xlsx` and `private_data/PEM_dyn_wind_data_short.xlsx` (see [Data availability](#data-availability)).

**2. Downscaling algorithms** — run `ghi_downscaling_v5_KNN.py` and `Final_Temperature_Downscaling.py` directly with Python. Both expect the reference 1-minute record at `private_data/henrik_davidsson_weather_data (1).csv`, run all three candidate algorithms for their respective variable, and report NRMSE/NMBE/R² (GHI) or RMSE/MAE/R² (temperature).

**3. No-battery cases** — run the `.m` driver script in each `CaseN_*` folder from MATLAB (it loads the co-located `.slx` model itself; you don't open the model separately). Case 3 (Reconfigurable) additionally requires the scripts in `Reconfiguration_Controller/`: the Python side (`optimal_np_finder.py` / `realtime_np_controller.py` / `np_controller_step.py`) pre-computes the optimal string-count sequence, which the Simulink side (`sfunc_np_controller.m` / `np_controller_block.m`) reads via a `From Workspace` block. `PV_PEM_reconfigurable.m` calls `pyenv` to locate a Python interpreter; if MATLAB doesn't auto-detect one, set the path explicitly as instructed in the script's comment. Run `compare_cases.m` afterwards to reproduce the comparative figures and KPIs.

**4. Battery cases** — same pattern as above for Cases 4–7 (Case 7's reconfiguration sequence is pre-computed offline beforehand, so it does not call `pyenv` directly). Run `compare_batt_cases.m` afterwards for the comparative figures and KPIs. Note that `compare_batt_cases.m`, and the driver scripts for Case 7, default to variable names/output files with a `_CNR` suffix from the authors' own cross-location workflow; to reproduce the primary Lyngby results reported in the manuscript, drop that suffix from the relevant `WEATHER_FILE` / `EXCEL_OUT` / `FILES{...}` variables before running (see comments at the top of each script).

## Data availability

The raw measurement files are not distributed in this public repository. Each script expects its input file at the `private_data/` path noted above; obtain the corresponding dataset and place it there under the exact filename the script expects, or contact the corresponding author.

- The Lyngby 1-minute meteorological reference record (`henrik_davidsson_weather_data (1).csv`) was curated by co-author Henrik Davidsson and is available from the corresponding author on reasonable request.
- The PEM validation dataset (`PEM_recorded_data.xlsx`, `PEM_dyn_wind_data_short.xlsx`) was obtained from Pape et al. (2025), *International Journal of Hydrogen Energy*, 127, 51–63 ([doi.org/10.1016/j.ijhydene.2025.03.387](https://doi.org/10.1016/j.ijhydene.2025.03.387)); consult that publication for original data access terms.
- The cross-location (CNR, Navarra, Spain) results reported in the manuscript use the same models in this repository re-run against the openly available BSRN station record: Olano, X. (2024). *Basic measurements of radiation at station CNER (2023)*, PANGAEA ([doi.org/10.1594/PANGAEA.931893](https://doi.org/10.1594/PANGAEA.931893)). The CNR-specific driver scripts are not included here to keep the repository focused on the primary Lyngby case study; they follow the identical structure of the scripts provided and are available from the corresponding author on request.

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

*Update the citation above with the final journal, volume, page numbers and DOI once the manuscript is accepted, and update the `url` field with this repository's actual address.*

## License

This repository is released under the [MIT License](LICENSE). The accompanying manuscript text and figures are copyright of the publishing journal upon acceptance and are not covered by this license.

## Contact

Diamantis Almpantis — diamantis.almpantis@energy.lth.se
Department of Energy Sciences, Lund University
