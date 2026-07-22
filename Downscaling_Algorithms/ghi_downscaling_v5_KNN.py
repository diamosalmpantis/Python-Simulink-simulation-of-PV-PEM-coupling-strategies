# -*- coding: utf-8 -*-
"""
Created on Tue Apr 28 15:17:38 2026

@author: Diamantis
"""

"""
GHI Downscaling Algorithm -- Version 5: K-Nearest Neighbors (KNN)
============================================================================
Building on: Almpantis et al. (2024), Solar Energy Advances 4, 100076
Adapted from: Omoyele et al. (KNN-based downscaling, Milan 2017)

New in V5 over V4:
------------------
1. K-NEAREST NEIGHBORS (KNN) SYNTHESIS
   Stochastic processes (Box I, Markov Chains, AR(1)) are physically realistic 
   but fail to align synthetic cloud events with actual historical timestamps, 
   resulting in very poor R2 and NRMSE on "Broken" days.
   
   V5 resolves this by abandoning random noise. Instead, for each target day, 
   the algorithm searches the historical database for the 1-Nearest Neighbor (1-NN) 
   day based on standardized hourly characteristics:
       Features: [ k_bar (Mean), VI (Variability), Fm (Morning Fraction) ]
   
   The 1-minute clearness index (kt) profile of the nearest neighbor is extracted 
   and multiplied by the target day's clear-sky curve to generate the baseline.

2. SAME-CLASS FORCING
   The KNN search is strictly restricted to days belonging to the same Hofmann 
   classification (Cloudless, Broken, Overcast) to ensure physical consistency.

3. ENERGY CONSERVATION
   The inherited 1-minute profile is scaled using the V3/V4 energy conservation 
   step so that its daily sum perfectly matches the target day's hourly sum.

Test case : Full Year 2023, Lyngby, Denmark
Station   : DTU Lyngby Campus, 55.79064 N, 12.52505 E, 50 m AMSL
Data      : Self-resampled from henrik_davidsson_weather_data (1).csv

Dependencies: numpy, pandas, matplotlib, scipy, scikit-learn, pvlib, openpyxl
"""

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
GHI Downscaling Validation Tool -- DUAL ALGORITHM (V3 White Noise & V5 Hybrid KNN)
==================================================================================
This script perfectly evaluates the performance of both downscaling algorithms 
against real measured 1-minute data for the year 2023.

Improvements:
- Restored the V5 Hybrid Interpolated Baseline (Fixed R2 Drop).
- Restored Cyclical Seasonal Encoding (Sin_DOY, Cos_DOY).
- Generates 2-row comparative plots (Real vs V3, Real vs V5) with perfected z-ordering.
- Enforces an absolute safety cap of 1200 W/m2 for Simulink hardware safety.

Dependencies: numpy, pandas, scipy, scikit-learn, pvlib, matplotlib
"""

import os
import warnings
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from scipy.optimize import minimize_scalar
from scipy.stats import ks_2samp
from sklearn.metrics import r2_score
from sklearn.preprocessing import StandardScaler
import pvlib
from pvlib.location import Location

warnings.filterwarnings("ignore")

# ==============================================================================
# CONFIGURATION
# ==============================================================================

REAL_1MIN_PATH  = os.path.join(os.path.dirname(os.path.abspath(__file__)), "private_data", "henrik_davidsson_weather_data (1).csv")

# Output directory will be generated directly in the folder where the script is run
OUTPUT_DIR      = "output_triple_validation"
EXAMPLE_PLOTS_DIR = os.path.join(OUTPUT_DIR, "Example_Plots")

LAT       = 55.79064
LON       = 12.52505
ALTITUDE  = 50.0
TIMEZONE  = "Europe/Copenhagen"

MINS_PER_DAY = 1440

# Test period: Full Year
TEST_MONTHS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]

# Minimum daily energy (Wh m^-2)
MIN_DAILY_GHI = 100.0

SITE = Location(LAT, LON, TIMEZONE, ALTITUDE, "DTU Lyngby")

# --- V3 & V4 Specific Constants ---
GHI_THRESHOLD  = 35.0   
RR_THRESHOLD   = 0.25   
ELEV_THRESHOLD = 5.0    
ALPHA_A =  -4.171
ALPHA_B =   1.857
ALPHA_C =   1.288
ALPHA_E =   1.000
ALPHA_MIN = -0.50
ALPHA_MAX =  1.60

N_STATES = 10
RHO_DEFAULTS = {"Cloudless": 0.97, "Broken": 0.78, "Overcast": 0.92}

# --- Hardware Limits ---
ABSOLUTE_MAX_GHI = 1200.0  # W m^-2

# ==============================================================================
# DATA LOADING
# ==============================================================================

def load_1min_data(path):
    df = pd.read_csv(path, usecols=["Time(utc)", "GHI"], parse_dates=["Time(utc)"], encoding="latin1")
    df = df.rename(columns={"Time(utc)": "time", "GHI": "ghi"})
    df["time"] = pd.to_datetime(df["time"], utc=True).dt.tz_convert(TIMEZONE)
    df["ghi"]  = df["ghi"].clip(lower=0.0)
    return df.set_index("time").sort_index()

def resample_to_hourly(df_1min):
    df_h = df_1min["ghi"].resample("h").mean().to_frame()
    df_h.columns = ["ghi"]
    df_h["date"] = df_h.index.normalize().date
    df_h["hour"] = df_h.index.hour
    return df_h.dropna()

# ==============================================================================
# BULK pvlib PRECOMPUTATION
# ==============================================================================

def precompute_all(test_dates):
    print("  Bulk pvlib precomputation ...", end=" ", flush=True)

    h_stamps_per_day   = []
    min_stamps_per_day = []
    date_strs_checked  = []

    for d in test_dates:
        ds = str(d)
        try:
            th = pd.date_range(f"{ds} 00:30", f"{ds} 23:30", freq="1h", tz=TIMEZONE)
            tm = pd.date_range(f"{ds} 00:00", periods=MINS_PER_DAY, freq="1min", tz=TIMEZONE)
            if len(th) != 24: continue   # Skip DST transitions
            h_stamps_per_day.append(th)
            min_stamps_per_day.append(tm)
            date_strs_checked.append(ds)
        except Exception:
            continue

    if not date_strs_checked: return {}, []

    all_h   = h_stamps_per_day[0]
    all_min = min_stamps_per_day[0]
    for i in range(1, len(date_strs_checked)):
        all_h   = all_h.append(h_stamps_per_day[i])
        all_min = all_min.append(min_stamps_per_day[i])

    cs_h   = SITE.get_clearsky(all_h,   model="ineichen")["ghi"].clip(lower=0).values
    cs_min = SITE.get_clearsky(all_min, model="ineichen")["ghi"].clip(lower=0).values
    el_min = SITE.get_solarposition(all_min)["elevation"].values

    cache       = {}
    valid_dates = []
    for i, ds in enumerate(date_strs_checked):
        cache[ds] = {
            "ghi_cs_h":   cs_h[i * 24 : (i + 1) * 24],
            "ghi_cs_min": cs_min[i * MINS_PER_DAY : (i + 1) * MINS_PER_DAY],
            "elev_min":   el_min[i * MINS_PER_DAY : (i + 1) * MINS_PER_DAY]
        }
        valid_dates.append(pd.Timestamp(ds).date())

    print(f"done ({len(valid_dates)} days).")
    return cache, valid_dates

# ==============================================================================
# DAILY INDICATORS
# ==============================================================================

def compute_daily_metrics(day_h, ghi_cs_h):
    valid = ghi_cs_h > 50.0
    if not np.any(valid): return {"k_bar": 0.0, "k_tilde": 0.0}
    kt_valid = (day_h[valid] / ghi_cs_h[valid]).clip(0.0, 2.0)
    return {"k_bar": float(np.mean(kt_valid)), "k_tilde": float(np.std(kt_valid))}

def classify_day_hofmann(day_h, ghi_cs_h):
    m = compute_daily_metrics(day_h, ghi_cs_h)
    k_bar, k_tilde = m["k_bar"], m["k_tilde"]
    if k_bar == 0.0: return "Overcast"
    if k_tilde < (0.45 - k_bar): return "Overcast"
    if k_tilde <= (k_bar - 0.588): return "Cloudless"
    return "Broken"

def compute_variability_index(ghi_h, ghi_cs_h):
    dGm, dGcs = np.diff(ghi_h), np.diff(ghi_cs_h)
    num, den = np.sum(np.sqrt(dGm**2 + 1.0)), np.sum(np.sqrt(dGcs**2 + 1.0))
    return float(num / den) if den > 0 else 1.0

def compute_morning_fraction(ghi_h, date_str):
    times = pd.date_range(f"{date_str} 00:30", f"{date_str} 23:30", freq="1h", tz=TIMEZONE)
    sp = SITE.get_solarposition(times)
    noon_mask = sp["azimuth"].values < 180.0
    total = np.sum(ghi_h)
    return float(np.sum(ghi_h[noon_mask])) / total if total > 0 else 0.5

def compute_nvi(ghi_h, ghi_cs_h):
    ghi_sorted = np.sort(ghi_h)[::-1]
    vi_m = compute_variability_index(ghi_h,      ghi_cs_h)
    vi_s = compute_variability_index(ghi_sorted, ghi_cs_h)
    return float(vi_m / vi_s) if vi_s > 0 else 1.0

def compute_iccdf(ghi_h):
    diffs = np.diff(ghi_h)
    if len(diffs) == 0: return 0.0
    sd = np.sort(diffs)
    n = len(sd)
    ccdf = 1.0 - np.arange(1, n + 1) / n
    ic = np.trapz(ccdf, sd)
    dr = sd[-1] - sd[0]
    return float(ic / dr) if dr != 0 else 0.0

def hourly_to_minutely(hourly):
    t_h = np.arange(24, dtype=float)
    t_m = np.linspace(0, 23, MINS_PER_DAY)
    return np.interp(t_m, t_h, hourly).clip(min=0.0)

def extract_1min_profile(df_1min, target_date):
    day_1min = df_1min[df_1min.index.date == target_date]["ghi"].values
    if len(day_1min) < MINS_PER_DAY:
        day_1min = np.pad(day_1min, (0, MINS_PER_DAY - len(day_1min)))
    else:
        day_1min = day_1min[:MINS_PER_DAY]
    return day_1min

def get_season(date_obj):
    m = pd.Timestamp(date_obj).month
    if m in [12, 1, 2]: return "Winter"
    if m in [3, 4, 5]:  return "Spring"
    if m in [6, 7, 8]:  return "Summer"
    return "Autumn"

# ==============================================================================
# V3 SYNTHESIS (WHITE NOISE)
# ==============================================================================

def compute_ramp_rate(kt_h):
    rr = np.zeros_like(kt_h, dtype=float)
    for i in range(1, len(kt_h)):
        if kt_h[i] > 0: rr[i] = abs(kt_h[i] - kt_h[i - 1]) / kt_h[i]
    return rr

def adaptive_alpha(k_bar, vi, fm):
    alpha = ALPHA_A * k_bar + ALPHA_B * vi + ALPHA_C + ALPHA_E * abs(fm - 0.5)
    return float(np.clip(alpha, ALPHA_MIN, ALPHA_MAX))

def synthesise_ghi_v3(ghi_h, ghi_cs_h, ghi_cs_min, kt_h, rr_h, elev_min, alpha, seed=42):
    rng = np.random.default_rng(seed)
    L_t = hourly_to_minutely(ghi_h)
    G_clear_t = hourly_to_minutely(ghi_cs_h)
    r_t = np.repeat(rr_h, 60)
    
    box_mask  = ((np.abs(G_clear_t - L_t) > GHI_THRESHOLD) | (np.abs(r_t) > RR_THRESHOLD))
    elev_mask = elev_min > ELEV_THRESHOLD
    mask = box_mask & elev_mask

    f_t   = L_t.copy()
    noise = rng.uniform(-1.0, 1.0, size=MINS_PER_DAY)
    f_t[mask] = L_t[mask] * (1.0 + alpha * noise[mask])
    
    f_t = np.maximum(f_t, 0.0)
    f_t = np.minimum(f_t, ghi_cs_min * 1.20)
    return f_t

# ==============================================================================
# V4 SYNTHESIS (MARKOV + AR1)
# ==============================================================================

def _discretize(kt_val):
    if not np.isfinite(kt_val): return 0
    return int(min(max(kt_val * N_STATES, 0), N_STATES - 1))

def train_markov_and_ar1(df_1min, df_hourly, cache, valid_dates):
    print("  Training Markov matrices and AR(1) parameters ...", end=" ", flush=True)

    classes  = ["Cloudless", "Broken", "Overcast"]
    seasons  = ["Winter", "Spring", "Summer", "Autumn"]
    keys     = [(c, s) for c in classes for s in seasons]
    
    counts   = {k: np.full((N_STATES, N_STATES), 0.1) for k in keys}
    kt_seqs  = {k: [] for k in keys}

    for date_obj in valid_dates:
        ds = str(date_obj)
        if ds not in cache: continue

        ghi_cs_h   = cache[ds]["ghi_cs_h"]
        ghi_cs_min = cache[ds]["ghi_cs_min"]

        day_h = (df_hourly[df_hourly["date"] == date_obj].groupby("hour")["ghi"]
                 .mean().reindex(range(24), fill_value=0.0).values.astype(float))

        if day_h.sum() < MIN_DAILY_GHI: continue

        cls = classify_day_hofmann(day_h, ghi_cs_h)
        season = get_season(date_obj)
        key = (cls, season)

        day_1min = extract_1min_profile(df_1min, date_obj)

        with np.errstate(divide="ignore", invalid="ignore"):
            kt_min = np.where(ghi_cs_min > 0, day_1min / ghi_cs_min, 0.0)
        kt_min = np.nan_to_num(kt_min, nan=0.0, posinf=0.0).clip(0.0, 2.0)

        states = np.array([_discretize(k) for k in kt_min])
        for t in range(len(states) - 1):
            counts[key][states[t], states[t + 1]] += 1.0

        daylight = ghi_cs_min > 0
        if daylight.sum() > 10:
            kt_seqs[key].append(kt_min[daylight])

    T_matrices = {}
    for k in keys:
        row_sums = counts[k].sum(axis=1, keepdims=True)
        T_matrices[k] = counts[k] / np.maximum(row_sums, 1e-9)

    rho_params = {}
    for k in keys:
        c_class = k[0]
        if kt_seqs[k]:
            all_kt = np.concatenate(kt_seqs[k])
            all_kt = all_kt[np.isfinite(all_kt)]
            if len(all_kt) > 200 and all_kt.std() > 1e-4:
                mu    = all_kt.mean()
                dev   = all_kt - mu
                denom = np.dot(dev, dev)
                if denom > 1e-10:
                    rho = np.dot(dev[:-1], dev[1:]) / denom
                    rho_params[k] = float(np.clip(rho, 0.5, 0.995))
                else:
                    rho_params[k] = RHO_DEFAULTS[c_class]
            else:
                rho_params[k] = RHO_DEFAULTS[c_class]
        else:
            rho_params[k] = RHO_DEFAULTS[c_class]

    print("done.")
    return T_matrices, rho_params

def generate_markov_baseline(ghi_h, ghi_cs_h, ghi_cs_min, kt_h, T_matrix, rng):
    G_markov = np.zeros(MINS_PER_DAY)
    T_cum    = np.cumsum(T_matrix, axis=1)
    prev_s   = _discretize(kt_h[0])
    
    kt_min_interp = hourly_to_minutely(kt_h)
    L_t_target = kt_min_interp * ghi_cs_min

    for h in range(24):
        st  = h * 60
        end = st + 60

        s0 = _discretize(kt_h[h])
        current = s0 if (rng.random() < 0.70) else prev_s

        rand_vals = rng.random(60)
        states    = np.empty(60, dtype=int)
        for t in range(60):
            states[t] = current
            current   = int(np.searchsorted(T_cum[current], rand_vals[t]))
        prev_s = current

        kt60 = (states.astype(float) + 0.5) / N_STATES
        kt60_mean = kt60.mean()
        noise_ratio = kt60 / kt60_mean if kt60_mean > 0 else np.ones(60)

        G_markov[st:end] = L_t_target[st:end] * noise_ratio

    return G_markov

def generate_ar1_noise(n, rho, rng):
    eps   = rng.uniform(-1.0, 1.0, size=n)
    noise = np.empty(n)
    noise[0] = eps[0]
    scale = np.sqrt(max(1.0 - rho ** 2, 1e-6))
    for t in range(1, n):
        noise[t] = rho * noise[t - 1] + scale * eps[t]
    std = noise.std()
    if std > 1e-9:
        noise = noise / (std * 3.0)
    return noise.clip(-1.0, 1.0)

def synthesise_ghi_v4(ghi_h, ghi_cs_h, ghi_cs_min, kt_h, rr_h, elev_min, alpha, T_matrix, rho, seed=42):
    rng = np.random.default_rng(seed)
    G_markov = generate_markov_baseline(ghi_h, ghi_cs_h, ghi_cs_min, kt_h, T_matrix, rng)
    G_clear_t = hourly_to_minutely(ghi_cs_h)
    r_t       = np.repeat(rr_h, 60)
    
    box_mask  = ((np.abs(G_clear_t - G_markov) > GHI_THRESHOLD) | (np.abs(r_t) > RR_THRESHOLD))
    elev_mask = elev_min > ELEV_THRESHOLD
    mask      = box_mask & elev_mask

    noise = generate_ar1_noise(MINS_PER_DAY, rho, rng)
    f_t = G_markov.copy()
    f_t[mask] = G_markov[mask] * (1.0 + alpha * noise[mask])
    
    f_t = np.maximum(f_t, 0.0)
    f_t = np.minimum(f_t, ghi_cs_min * 1.20)
    return f_t

# ==============================================================================
# V5 SYNTHESIS (HYBRID KNN)
# ==============================================================================

def synthesise_ghi_v5_knn(target_cs_min, target_kt_h, nn_1min_measured, nn_cs_min, nn_kt_h):
    L_t_target = hourly_to_minutely(target_kt_h) * target_cs_min
    L_t_nn = hourly_to_minutely(nn_kt_h) * nn_cs_min
    
    with np.errstate(divide="ignore", invalid="ignore"):
        nn_noise_ratio = np.where(L_t_nn > 0, nn_1min_measured / L_t_nn, 1.0)
    nn_noise_ratio = np.nan_to_num(nn_noise_ratio, nan=1.0).clip(0.0, 5.0)
    
    f_raw = L_t_target * nn_noise_ratio
    f_raw = np.maximum(f_raw, 0.0)
    return np.minimum(f_raw, target_cs_min * 1.20)

def apply_energy_conservation(f_t, ghi_h):
    target = np.sum(ghi_h)
    f_sum  = np.sum(f_t) / 60.0
    if f_sum == 0 or target == 0: return f_t.copy(), 1.0
    res = minimize_scalar(lambda k: abs(target - k * f_sum), bounds=(0.1, 5.0), method="bounded")
    k_d = float(res.x)
    return (f_t * k_d).clip(min=0.0), k_d

# ==============================================================================
# VALIDATION METRICS
# ==============================================================================

def compute_metrics(synthetic, measured):
    mask = measured > 0
    if mask.sum() < 10: return {"NMBE": np.nan, "NRMSE": np.nan, "R2": np.nan}
    s, m = synthetic[mask], measured[mask]
    if not (np.isfinite(s).all() and np.isfinite(m).all()):
        return {"NMBE": np.nan, "NRMSE": np.nan, "R2": np.nan}
    n = len(m)
    nmbe  = float(np.sum(s - m) / np.sum(m) * 100.0)
    nrmse = float(np.sqrt(np.sum((s - m) ** 2) / n) / np.mean(m) * 100.0)
    r2    = float(r2_score(m, s))
    return {"NMBE": nmbe, "NRMSE": nrmse, "R2": r2}

def compute_ksi(synthetic, measured):
    daylight = measured > 0
    if daylight.sum() < 30: return np.nan
    s, m  = synthetic[daylight], measured[daylight]
    if not np.isfinite(s).all(): return np.nan
    ks, _ = ks_2samp(m, s)
    a_c   = 1.63 / np.sqrt(len(m)) * (m.max() - m.min())
    return float(ks / a_c * 100.0) if a_c > 0 else np.nan

# ==============================================================================
# PLOTTING FUNCTIONS (TRIPLE ROWS)
# ==============================================================================

def plot_day_triple(date_str, measured, f_ec_v3, f_ec_v4, f_ec_v5, nn_date, day_class, m_v3, m_v4, m_v5, out_dir):
    """
    Generates a 3-row plot for each day:
    Row 1: Real vs White Noise 
    Row 2: Real vs Markov
    Row 3: Real vs Hybrid KNN 
    """
    fig, axes = plt.subplots(3, 2, figsize=(16, 15))
    t_min = np.arange(MINS_PER_DAY)

    plot_real = lambda ax: ax.plot(t_min, measured, lw=2.5, color="#9E9E9E", alpha=0.6, label="Measured 1-Min", zorder=1)
    month_name = pd.Timestamp(date_str).strftime('%B')

    # --- ROW 1: WHITE NOISE ---
    ax_ts1, ax_cdf1 = axes[0, 0], axes[0, 1]
    plot_real(ax_ts1)
    ax_ts1.plot(t_min, f_ec_v3, lw=1.2, color="#4CAF50", alpha=0.9, label="White Noise \nwith Adaptive Alpha", zorder=2)
    ax_ts1.set_ylabel("GHI (W m⁻²)")
    ax_ts1.set_title(f"White Noise Validation: {date_str} ({month_name} - {day_class})", fontweight="bold")
    ax_ts1.legend(fontsize=9, loc="upper right")
    ax_ts1.grid(alpha=0.3)

    for data, label, c, lw, zo in zip([measured, f_ec_v3], ["Measured", "Synthetic White Noise"], ["#9E9E9E", "#4CAF50"], [3.0, 2.0], [1, 2]):
        d = data[data > 0]
        if len(d): ax_cdf1.plot(np.sort(d), np.linspace(0, 1, len(d)), lw=lw, label=label, color=c, zorder=zo)
    ax_cdf1.set_ylabel("Cumulative probability")
    ax_cdf1.set_title(f"White Noise Metrics: NRMSE={m_v3['NRMSE']:.1f}%  R²={m_v3['R2']:.3f}")
    ax_cdf1.legend(fontsize=9)
    ax_cdf1.grid(alpha=0.3)

    # --- ROW 2: MARKOV + AR1 ---
    ax_ts2, ax_cdf2 = axes[1, 0], axes[1, 1]
    plot_real(ax_ts2)
    ax_ts2.plot(t_min, f_ec_v4, lw=1.2, color="#FF9800", alpha=0.9, label="Markov + AR(1)", zorder=2)
    ax_ts2.set_ylabel("GHI (W m⁻²)")
    ax_ts2.set_title(f"Markov Validation: {date_str} ({month_name} - {day_class})", fontweight="bold")
    ax_ts2.legend(fontsize=9, loc="upper right")
    ax_ts2.grid(alpha=0.3)

    for data, label, c, lw, zo in zip([measured, f_ec_v4], ["Measured", "Synthetic Markov"], ["#9E9E9E", "#FF9800"], [3.0, 2.0], [1, 2]):
        d = data[data > 0]
        if len(d): ax_cdf2.plot(np.sort(d), np.linspace(0, 1, len(d)), lw=lw, label=label, color=c, zorder=zo)
    ax_cdf2.set_ylabel("Cumulative probability")
    ax_cdf2.set_title(f"Markov Metrics: NRMSE={m_v4['NRMSE']:.1f}%  R²={m_v4['R2']:.3f}")
    ax_cdf2.legend(fontsize=9)
    ax_cdf2.grid(alpha=0.3)

    # --- ROW 3: HYBRID KNN ---
    ax_ts3, ax_cdf3 = axes[2, 0], axes[2, 1]
    plot_real(ax_ts3)
    ax_ts3.plot(t_min, f_ec_v5, lw=1.2, color="#2196F3", alpha=0.9, label=f"Hybrid KNN (NN: {nn_date})", zorder=2)
    ax_ts3.set_xlabel("Time (minutes from midnight)")
    ax_ts3.set_ylabel("GHI (W m⁻²)")
    ax_ts3.set_title(f"Hybrid KNN Validation: {date_str} ({month_name} - {day_class})", fontweight="bold")
    ax_ts3.legend(fontsize=9, loc="upper right")
    ax_ts3.grid(alpha=0.3)

    for data, label, c, lw, zo in zip([measured, f_ec_v5], ["Measured", "Synthetic Hybrid KNN"], ["#9E9E9E", "#2196F3"], [3.0, 2.0], [1, 2]):
        d = data[data > 0]
        if len(d): ax_cdf3.plot(np.sort(d), np.linspace(0, 1, len(d)), lw=lw, label=label, color=c, zorder=zo)
    ax_cdf3.set_xlabel("GHI (W m⁻²)")
    ax_cdf3.set_ylabel("Cumulative probability")
    ax_cdf3.set_title(f"Hybrid KNN Metrics: NRMSE={m_v5['NRMSE']:.1f}%  R²={m_v5['R2']:.3f}")
    ax_cdf3.legend(fontsize=9)
    ax_cdf3.grid(alpha=0.3)

    fig.tight_layout()
    os.makedirs(EXAMPLE_PLOTS_DIR, exist_ok=True)
    out_path = os.path.join(EXAMPLE_PLOTS_DIR, f"downscale_example_{date_str}_{day_class}.png")
    fig.savefig(out_path, dpi=120)
    plt.close(fig)

def plot_statistical_comparison(hourly_ghi, min1_v3, min1_v4, min1_v5, out_dir, real_1min=None):
    """
    Generates a 3x2 Macro-Statistical validation grid.
    """
    if real_1min is not None:
        baseline_day = real_1min[real_1min > 10.0]
        baseline_label = "Real 1-Minute Truth"
    else:
        baseline_day = hourly_ghi[hourly_ghi > 10.0]
        baseline_label = "Real Hourly Input"

    v3_day = min1_v3[min1_v3 > 10.0]
    v4_day = min1_v4[min1_v4 > 10.0]
    v5_day = min1_v5[min1_v5 > 10.0]

    fig, axes = plt.subplots(3, 2, figsize=(14, 15))

    # Helper for repetitive plotting without redundant titles
    def build_row(row_idx, synth_data, color, label_title):
        # Histogram
        axes[row_idx, 0].hist(baseline_day, bins=60, density=True, alpha=0.5, color="#9E9E9E", label=baseline_label, zorder=1)
        axes[row_idx, 0].hist(synth_data, bins=60, density=True, alpha=0.6, color=color, label=f"Synthetic: {label_title}", zorder=2)
        axes[row_idx, 0].set_ylabel("Density", fontsize=11)
        if row_idx == 2: axes[row_idx, 0].set_xlabel("GHI (W m⁻²)", fontsize=11)
        axes[row_idx, 0].legend(fontsize=10)
        axes[row_idx, 0].grid(alpha=0.3)

        # CDF
        axes[row_idx, 1].plot(np.sort(baseline_day), np.linspace(0, 1, len(baseline_day)), lw=3.0, color="#9E9E9E", label=baseline_label, zorder=1)
        axes[row_idx, 1].plot(np.sort(synth_data), np.linspace(0, 1, len(synth_data)), lw=2.0, color=color, label=f"Synthetic: {label_title}", zorder=2)
        axes[row_idx, 1].set_ylabel("Cumulative Probability", fontsize=11)
        if row_idx == 2: axes[row_idx, 1].set_xlabel("GHI (W m⁻²)", fontsize=11)
        axes[row_idx, 1].legend(fontsize=10)
        axes[row_idx, 1].grid(alpha=0.3)

    build_row(0, v3_day, "#4CAF50", "White Noise \nwith Adaptive Alpha")
    build_row(1, v4_day, "#FF9800", "Markov + AR(1)")
    build_row(2, v5_day, "#2196F3", "Hybrid KNN")

    fig.tight_layout()
    out_path = os.path.join(out_dir, "statistical_sanity_check.png")
    fig.savefig(out_path, dpi=120)
    plt.close(fig)

def plot_full_year_continuous(df_target_h, min1_times, min1_v3, min1_v4, min1_v5, out_dir):
    """
    Generates a 3-row continuous plot of the entire year.
    Row 1: Real vs White Noise
    Row 2: Real vs Markov
    Row 3: Real vs Hybrid KNN
    """
    print("\nGenerating full-year continuous plot...")
    df_1min = pd.DataFrame({"time": min1_times, "v3": min1_v3, "v4": min1_v4, "v5": min1_v5}).set_index("time")
    df_target_h = df_target_h[df_target_h.index.notnull()]
    
    fig, axes = plt.subplots(3, 1, figsize=(24, 15), sharex=True)
    
    # Pre-calculate steps
    if not df_target_h.empty:
        last_time = df_target_h.index[-1] + pd.Timedelta(hours=1)
        step_times = list(df_target_h.index) + [last_time]
        step_vals = list(df_target_h["ghi"]) + [df_target_h["ghi"].iloc[-1]]
        for ax in axes:
            ax.step(step_times, step_vals, where='post', lw=1.5, color="#9E9E9E", label="Original 1-Hour Input", zorder=3)
            ax.set_ylim(bottom=0)
            ax.grid(alpha=0.3)
            ax.set_ylabel("GHI (W m⁻²)", fontsize=12)

    if not df_1min.empty:
        # V3
        axes[0].plot(df_1min.index, df_1min["v3"], lw=0.6, color="#4CAF50", alpha=0.7, label="Synthetic: White Noise \nwith Adaptive Alpha", zorder=2)
        axes[0].legend(loc="upper right", fontsize=11)
        
        # V4
        axes[1].plot(df_1min.index, df_1min["v4"], lw=0.6, color="#FF9800", alpha=0.7, label="Synthetic: Markov + AR(1)", zorder=2)
        axes[1].legend(loc="upper right", fontsize=11)

        # V5
        axes[2].plot(df_1min.index, df_1min["v5"], lw=0.6, color="#2196F3", alpha=0.7, label="Synthetic: Hybrid KNN", zorder=2)
        axes[2].legend(loc="upper right", fontsize=11)
        
    axes[2].set_xlim(df_target_h.index.min(), df_target_h.index.max())
    axes[2].xaxis.set_major_locator(mdates.MonthLocator())
    axes[2].xaxis.set_major_formatter(mdates.DateFormatter('%B'))
    
    fig.tight_layout()
    out_path = os.path.join(out_dir, "full_year_continuous.png")
    fig.savefig(out_path, dpi=150)
    plt.close(fig)

def plot_version_comparison(df_m, out_dir):
    versions = ["White Noise \nwith Adaptive Alpha", "Markov + AR(1)", "Hybrid KNN"]
    
    # We dynamically take the actual calculated averages from the dataframe
    nmbe_vals  = [df_m["NMBE_V3"].mean(), df_m["NMBE_V4"].mean(), df_m["NMBE_V5"].mean()]
    nrmse_vals = [df_m["NRMSE_V3"].mean(), df_m["NRMSE_V4"].mean(), df_m["NRMSE_V5"].mean()]
    r2_vals    = [df_m["R2_V3"].mean(), df_m["R2_V4"].mean(), df_m["R2_V5"].mean()]

    fig, axes = plt.subplots(1, 3, figsize=(14, 5))
    
    # Color palette: Green, Orange, Blue
    colours = ["#4CAF50", "#FF9800", "#2196F3"]

    for ax, vals, label, fmt in zip(axes, [nmbe_vals, nrmse_vals, r2_vals],
                                    ["Mean NMBE (%)", "Mean NRMSE (%)", "Mean R²"],
                                    ["{:.2f}%", "{:.1f}%", "{:.3f}"]):
        bars = ax.bar(range(3), vals, color=colours, alpha=0.85)
        ax.set_xticks(range(3))
        ax.set_xticklabels(versions, fontsize=10)
        ax.set_ylabel(label, fontsize=12)
        ax.axhline(0, ls="--", lw=0.6, c="k")
        ax.grid(axis="y", alpha=0.3)
        
        y_max, y_min = max(vals), min(vals)
        ax.set_ylim(y_min * 1.2 if y_min < 0 else 0, y_max * 1.2)
        
        rng_span = max(abs(v) for v in vals) * 0.08 if vals else 0.1
        for bar, v in zip(bars, vals):
            ax.text(bar.get_x() + bar.get_width() / 2, v + (rng_span if v >= 0 else -rng_span * 2.5),
                    fmt.format(v), ha="center", fontsize=10, fontweight="bold")

    fig.tight_layout()
    out = os.path.join(out_dir, "triple_version_comparison.png")
    fig.savefig(out, dpi=120)
    plt.close(fig)

# ==============================================================================
# MAIN
# ==============================================================================

def main():
    print("=" * 70)
    print("GHI Downscaling -- TRIPLE VALIDATION (V3 vs V4 vs V5)")
    print("=" * 70)

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    os.makedirs(EXAMPLE_PLOTS_DIR, exist_ok=True)

    print("\nLoading data ...")
    df_1min   = load_1min_data(REAL_1MIN_PATH)
    df_hourly = resample_to_hourly(df_1min)

    all_dates  = sorted({d for d in df_hourly["date"].unique() if pd.Timestamp(d).month in TEST_MONTHS})
    print(f"  1-min rows        : {len(df_1min):,}")
    print(f"  Candidate days    : {all_dates[0]} -> {all_dates[-1]} ({len(all_dates)} total)")

    print("\nPrecomputing clear-sky and solar position ...")
    cache, valid_dates = precompute_all(all_dates)
    print(f"  Valid dates after DST filter: {len(valid_dates)}")

    # Train V4 Markov Matrices
    T_matrices, rho_params = train_markov_and_ar1(df_1min, df_hourly, cache, valid_dates)

    print("\nBuilding feature database for KNN...", end=" ", flush=True)
    db_records = []
    
    for date_obj in valid_dates:
        ds = str(date_obj)
        if ds not in cache: continue

        day_h = (df_hourly[df_hourly["date"] == date_obj].groupby("hour")["ghi"]
                 .mean().reindex(range(24), fill_value=0.0).values.astype(float))

        if day_h.sum() < MIN_DAILY_GHI: continue

        ghi_cs_h = cache[ds]["ghi_cs_h"]
        with np.errstate(divide="ignore", invalid="ignore"):
            kt_h = np.where(ghi_cs_h > 0, day_h / ghi_cs_h, 0.0).clip(0.0, 2.0)
            
        m_d      = compute_daily_metrics(day_h, ghi_cs_h)
        vi       = compute_variability_index(day_h, ghi_cs_h)
        fm       = compute_morning_fraction(day_h, ds)
        nvi      = compute_nvi(day_h, ghi_cs_h)
        iccdf    = compute_iccdf(day_h)
        d_class  = classify_day_hofmann(day_h, ghi_cs_h)
        
        # Ensure DOY is calculated for seasonal matching
        doy = pd.Timestamp(date_obj).dayofyear
        sin_doy = np.sin(2 * np.pi * doy / 365.25)
        cos_doy = np.cos(2 * np.pi * doy / 365.25)

        db_records.append({
            "Date": date_obj, "DateStr": ds, "day_h": day_h, "kt_h": kt_h,
            "k_bar": m_d["k_bar"], "k_tilde": m_d["k_tilde"], "VI": vi, "Fm": fm,
            "NVI": nvi, "ICCDF": iccdf, "Sin_DOY": sin_doy, "Cos_DOY": cos_doy, "Class": d_class
        })
        
    df_db = pd.DataFrame(db_records)
    
    scaler = StandardScaler()
    features = ['k_bar', 'VI', 'Fm', 'Sin_DOY', 'Cos_DOY']
    X_scaled = scaler.fit_transform(df_db[features])
    X_scaled[:, 3] *= 0.5; X_scaled[:, 4] *= 0.5  

    print("done.")
    for cls in ["Cloudless", "Broken", "Overcast"]:
        print(f"    {cls:10s} : {len(df_db[df_db['Class'] == cls])} days available")

    print("\nStarting Triple Downscaling Process (V3, V4, and V5)...")
    all_metrics = []

    final_1min_timestamps = []
    final_1min_v3 = []
    final_1min_v4 = []
    final_1min_v5 = []
    final_1min_truth = []
    
    plotted_months = set()

    for i, target_row in df_db.iterrows():
        target_date = target_row["Date"]
        ds          = target_row["DateStr"]
        day_h       = target_row["day_h"]
        target_kt_h = target_row["kt_h"]
        day_class   = target_row["Class"]

        target_cs_h   = cache[ds]["ghi_cs_h"]
        target_cs_min = cache[ds]["ghi_cs_min"]
        elev_min      = cache[ds]["elev_min"]
        
        rr_h     = compute_ramp_rate(target_kt_h)
        alpha    = adaptive_alpha(target_row["k_bar"], target_row["VI"], target_row["Fm"])
        if day_class == "Overcast": alpha = min(alpha, 0.25)

        # ---------------- V3 SYNTHESIS ----------------
        f_raw_v3 = synthesise_ghi_v3(day_h, target_cs_h, target_cs_min, target_kt_h, rr_h, elev_min, alpha)
        f_ec_v3, kd_v3 = apply_energy_conservation(f_raw_v3, day_h)
        f_ec_v3 = np.minimum(f_ec_v3, ABSOLUTE_MAX_GHI)

        # ---------------- V4 SYNTHESIS ----------------
        season = get_season(target_date)
        k_key  = (day_class, season)
        rho   = rho_params[k_key]
        T_mat = T_matrices[k_key]
        f_raw_v4 = synthesise_ghi_v4(day_h, target_cs_h, target_cs_min, target_kt_h, rr_h, elev_min, alpha, T_mat, rho)
        f_ec_v4, kd_v4 = apply_energy_conservation(f_raw_v4, day_h)
        f_ec_v4 = np.minimum(f_ec_v4, ABSOLUTE_MAX_GHI)

        # ---------------- V5 SYNTHESIS ----------------
        dist = np.linalg.norm(X_scaled - X_scaled[i], axis=1)
        dist[i] = np.inf 
        
        class_mask = (df_db["Class"] == day_class).values
        dist[~class_mask] = np.inf
        
        if np.isinf(dist).all(): dist = np.linalg.norm(X_scaled - X_scaled[i], axis=1); dist[i] = np.inf
             
        nn_idx = np.argmin(dist)
        nn_date = df_db.iloc[nn_idx]["Date"]
        nn_date_str = df_db.iloc[nn_idx]["DateStr"]
        nn_kt_h = df_db.iloc[nn_idx]["kt_h"]
        
        nn_1min_meas = extract_1min_profile(df_1min, nn_date)
        nn_cs_min    = cache[nn_date_str]["ghi_cs_min"]

        f_raw_v5 = synthesise_ghi_v5_knn(target_cs_min, target_kt_h, nn_1min_meas, nn_cs_min, nn_kt_h)
        f_ec_v5, kd_v5 = apply_energy_conservation(f_raw_v5, day_h)
        f_ec_v5 = np.minimum(f_ec_v5, ABSOLUTE_MAX_GHI)

        # ---------------- VALIDATION METRICS ----------------
        day_1min = extract_1min_profile(df_1min, target_date)

        m_v3, ksi_v3 = compute_metrics(f_ec_v3, day_1min), compute_ksi(f_ec_v3, day_1min)
        m_v4, ksi_v4 = compute_metrics(f_ec_v4, day_1min), compute_ksi(f_ec_v4, day_1min)
        m_v5, ksi_v5 = compute_metrics(f_ec_v5, day_1min), compute_ksi(f_ec_v5, day_1min)

        row = {
            "Date": ds, "Class": day_class, "NN_Date": nn_date_str,
            "NMBE_V3": round(m_v3["NMBE"], 2), "NRMSE_V3": round(m_v3["NRMSE"], 2), "R2_V3": round(m_v3["R2"], 4), "KSI_V3": round(ksi_v3, 2),
            "NMBE_V4": round(m_v4["NMBE"], 2), "NRMSE_V4": round(m_v4["NRMSE"], 2), "R2_V4": round(m_v4["R2"], 4), "KSI_V4": round(ksi_v4, 2),
            "NMBE_V5": round(m_v5["NMBE"], 2), "NRMSE_V5": round(m_v5["NRMSE"], 2), "R2_V5": round(m_v5["R2"], 4), "KSI_V5": round(ksi_v5, 2)
        }
        all_metrics.append(row)

        t_index = pd.date_range(f"{ds} 00:00", periods=MINS_PER_DAY, freq="1min", tz=TIMEZONE)
        final_1min_truth.extend(day_1min)
        final_1min_timestamps.extend(t_index)
        final_1min_v3.extend(f_ec_v3)
        final_1min_v4.extend(f_ec_v4)
        final_1min_v5.extend(f_ec_v5)

        if len(all_metrics) % 15 == 1 or day_class == "Overcast":
            print(f"  {ds} {day_class:10s} | V3: R2={m_v3['R2']:.3f} | V4: R2={m_v4['R2']:.3f} | V5: R2={m_v5['R2']:.3f}")
            plot_day_triple(ds, day_1min, f_ec_v3, f_ec_v4, f_ec_v5, nn_date_str, day_class, m_v3, m_v4, m_v5, OUTPUT_DIR)

    if not all_metrics:
        print("\n[!] No valid days found.")
        return

    df_m = pd.DataFrame(all_metrics)

    # ---------------------------------------------------------
    # MACRO STATS & CONTINUOUS PLOT CALLS 
    # ---------------------------------------------------------
    print("\nPerforming final Macro-Statistical and Full-Year plotting...")
    synth_v3_array = np.array(final_1min_v3)
    synth_v4_array = np.array(final_1min_v4)
    synth_v5_array = np.array(final_1min_v5)
    
    df_target_h = resample_to_hourly(df_1min) 
    
    plot_statistical_comparison(None, synth_v3_array, synth_v4_array, synth_v5_array, OUTPUT_DIR, real_1min=np.array(final_1min_truth))
    plot_full_year_continuous(df_target_h, final_1min_timestamps, synth_v3_array, synth_v4_array, synth_v5_array, OUTPUT_DIR)

    print("\n" + "=" * 70)
    print("OVERALL METRICS -- Full Year 2023")
    print("=" * 70)
    print(f"  Days processed    : {len(df_m)}")
    print(f"  Mean NRMSE        | V3: {df_m['NRMSE_V3'].mean():.2f}%  | V4: {df_m['NRMSE_V4'].mean():.2f}%  | V5: {df_m['NRMSE_V5'].mean():.2f}%")
    print(f"  Mean R2           | V3: {df_m['R2_V3'].mean():.4f}  | V4: {df_m['R2_V4'].mean():.4f}  | V5: {df_m['R2_V5'].mean():.4f}")

    # Export
    xlsx_path = os.path.join(OUTPUT_DIR, "validation_metrics_triple.xlsx")
    with pd.ExcelWriter(xlsx_path, engine="openpyxl") as writer:
        df_m.to_excel(writer, sheet_name="Daily_Metrics", index=False)
        df_m.groupby("Class")[["NRMSE_V3", "R2_V3", "NRMSE_V4", "R2_V4", "NRMSE_V5", "R2_V5"]].mean().round(3).to_excel(writer, sheet_name="By_Class")

    plot_version_comparison(df_m, OUTPUT_DIR)
    
    # Export massive combined CSV
    print(f"\nSaving final TRIPLE 1-minute dataset...")
    output_df = pd.DataFrame({
        "time": final_1min_timestamps,
        "GHI_1min_V3": np.round(final_1min_v3, 2),
        "GHI_1min_V4": np.round(final_1min_v4, 2),
        "GHI_1min_V5": np.round(final_1min_v5, 2)
    })
    out_csv = os.path.join(OUTPUT_DIR, "Lyngby_downscaled_1min_TRIPLE.csv")
    output_df.to_csv(out_csv, index=False)

    print(f"\n[OK] Data CSV saved : {out_csv}")
    print(f"[OK] Excel saved    : {xlsx_path}")
    print(f"[OK] Plots saved in : {OUTPUT_DIR}")

if __name__ == "__main__":
    main()