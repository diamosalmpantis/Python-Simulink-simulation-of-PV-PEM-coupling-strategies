# Python–Simulink Simulation of DC-Coupled PV–PEM Electrolyzer Systems under Minute-Level Solar Variability

This repository contains the simulation code accompanying the manuscript of the same title. It implements a Python–MATLAB/Simulink co-simulation framework that evaluates seven DC-coupled PV–PEM electrolyzer architectures (three battery-less, four battery-integrated) under minute-resolution, downscaled meteorological data, together with the irradiance and temperature downscaling algorithms used to generate that input data and the electrochemical model validation against experimental measurements.

## Repository structure

```
01_PEM_Validation/             PEM equivalent-electrical-circuit (EEC) model validation
                               against experimental data (static and dynamic cases)
02_Downscaling_Algorithms/     Hourly-to-1-minute downscaling for GHI (White Noise,
                               Markov+AR(1), Hybrid KNN) and ambient temperature
                               (Linear, PCHIP, Hybrid KNN)
03_No_Battery_Cases/           Case 1 (Indirect), Case 2 (Static Direct),
                               Case 3 (Reconfigurable Direct) + reconfiguration
                               controller + post-processing
04_Battery_Cases/              Case 4 (Indirect + EMS), Case 5 (Direct + Passive
                               Battery), Case 6 (Direct + Active Battery),
                               Case 7 (Reconfigurable + Active Battery)
                               + post-processing
```

Each case folder contains a MATLAB driver script (`.m`) and its corresponding Simulink model (`.slx`). The driver script configures parameters, runs the Simulink model, and exports the results.

## Requirements

**MATLAB/Simulink**
Developed and tested in MATLAB/Simulink R2025b. The models use only standard Simulink/Simscape Electrical blocks and should be compatible with recent prior releases (R2021b or later); if you encounter a version-compatibility prompt on opening a `.slx` file, allow MATLAB to update it.

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

**1. PEM validation** — run `Sim_vs_meas_static.m` (steady-state) and `Sim_vs_meas_dynamic.m` (dynamic) in MATLAB; each calls its companion Simulink model and reports RMSE/MAE/R² against the experimental data in `PEM_recorded_data.xlsx` and `PEM_dyn_wind_data_short.xlsx`.

**2. Downscaling algorithms** — run `ghi_downscaling_v5_KNN.py` and `Final_Temperature_Downscaling.py` directly with Python. Both read the reference 1-minute record from `Data/henrik_davidsson_weather_data (1).csv`, run all three candidate algorithms for their respective variable, and report NRMSE/NMBE/R² (GHI) or RMSE/MAE/R² (temperature).

**3. No-battery cases** — open and run the `.slx` model in each `CaseN_*` folder via its driver `.m` script. Case 3 (Reconfigurable) additionally requires the scripts in `Reconfiguration_Controller/`: the Python side (`optimal_np_finder.py` / `realtime_np_controller.py` / `np_controller_step.py`) pre-computes the optimal string-count sequence, which the Simulink side (`sfunc_np_controller.m` / `np_controller_block.m`) reads via a `From Workspace` block. Run `compare_cases.m` afterwards to reproduce the comparative figures and KPIs.

**4. Battery cases** — same pattern as above for Cases 4–7; run `compare_batt_cases.m` afterwards for the comparative figures and KPIs.

## Data availability

- The Lyngby 1-minute meteorological reference record (`henrik_davidsson_weather_data (1).csv`) was curated by co-author Henrik Davidsson and is included in full.
- The PEM validation dataset was obtained from Pape et al. (2025), *International Journal of Hydrogen Energy*, 127, 51–63 ([doi.org/10.1016/j.ijhydene.2025.03.387](https://doi.org/10.1016/j.ijhydene.2025.03.387)).
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
