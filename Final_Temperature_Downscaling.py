# -*- coding: utf-8 -*-
"""
Created on Mon May 11 09:54:44 2026

@author: Diamantis
"""

import os
import warnings
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from scipy.interpolate import PchipInterpolator
from sklearn.metrics import r2_score, mean_absolute_error, mean_squared_error
from sklearn.preprocessing import StandardScaler

warnings.filterwarnings("ignore")

# ==============================================================================
# CONFIGURATION
# ==============================================================================

REAL_1MIN_PATH  = os.path.join(os.path.dirname(os.path.abspath(__file__)), "private_data", "henrik_davidsson_weather_data (1).csv")

OUTPUT_DIR      = "output_temp_validation"
EXAMPLE_PLOTS_DIR = os.path.join(OUTPUT_DIR, "Example_Plots")

TIMEZONE  = "Europe/Copenhagen"
MINS_PER_DAY = 1440

# Test period: Full Year
TEST_MONTHS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]

# ==============================================================================
# DATA LOADING
# ==============================================================================

def load_1min_temp_data(path):
    print(f"Loading historical 1-min temperature library from {path}...")
    # Load 'air_temperature' instead of GHI
    df = pd.read_csv(path, usecols=["Time(utc)", "air_temperature"], parse_dates=["Time(utc)"], encoding="latin1")
    df = df.rename(columns={"Time(utc)": "time", "air_temperature": "temp"})
    df["time"] = pd.to_datetime(df["time"], utc=True).dt.tz_convert(TIMEZONE)
    
    # Forward fill any small gaps (NaNs) in temperature
    df["temp"] = df["temp"].ffill().bfill()
    
    return df.set_index("time").sort_index()

def resample_to_hourly(df_1min):
    df_h = df_1min["temp"].resample("h").mean().to_frame()
    df_h.columns = ["temp"]
    df_h["date"] = df_h.index.normalize().date
    df_h["hour"] = df_h.index.hour
    return df_h.dropna()

def extract_1min_profile(df_1min, target_date):
    day_1min = df_1min[df_1min.index.date == target_date]["temp"].values
    if len(day_1min) < MINS_PER_DAY:
        day_1min = np.pad(day_1min, (0, MINS_PER_DAY - len(day_1min)), mode='edge')
    else:
        day_1min = day_1min[:MINS_PER_DAY]
    return day_1min

# ==============================================================================
# TEMPERATURE SYNTHESIS ALGORITHMS
# ==============================================================================

def synthesise_temp_linear(temp_h):
    """Algorithm 1: Standard Linear Interpolation"""
    t_h = np.arange(24, dtype=float)
    t_m = np.linspace(0, 23, MINS_PER_DAY)
    return np.interp(t_m, t_h, temp_h)

def synthesise_temp_pchip(temp_h):
    """Algorithm 2: PCHIP Interpolation (Smooth, physically realistic thermal inertia)"""
    # Place hourly averages at the center of the hour (0.5, 1.5, etc.)
    x_hours = np.arange(0.5, 24.5, 1.0)
    
    # Pad boundaries to ensure the curve connects properly at midnight
    x_pad = np.array([0.0] + list(x_hours) + [24.0])
    y_pad = np.array([temp_h[0]] + list(temp_h) + [temp_h[-1]])
    
    interp = PchipInterpolator(x_pad, y_pad)
    x_min = np.linspace(0, 24, MINS_PER_DAY)
    return interp(x_min)

def synthesise_temp_knn(temp_h, nn_1min, nn_temp_h):
    """
    Algorithm 3: Hybrid KNN
    Extracts the high-frequency micro-variations from a similar historical day
    and superimposes them onto the target day's smooth PCHIP baseline.
    """
    target_pchip = synthesise_temp_pchip(temp_h)
    nn_pchip = synthesise_temp_pchip(nn_temp_h)
    
    # Additive residual noise (since temp can be <= 0, multiplicative ratios fail)
    residual_noise = nn_1min - nn_pchip
    
    f_synth = target_pchip + residual_noise
    
    # Mean Preservation: Shift each hour so its exact hourly average matches the input
    for h in range(24):
        st, en = h * 60, (h + 1) * 60
        diff = temp_h[h] - f_synth[st:en].mean()
        f_synth[st:en] += diff
        
    return f_synth

# ==============================================================================
# VALIDATION METRICS
# ==============================================================================

def compute_metrics(synthetic, measured):
    """For temperature, Absolute Errors (MAE, RMSE) are much better than percentages"""
    if len(measured) == 0 or np.isnan(measured).all():
        return {"MBE": np.nan, "RMSE": np.nan, "MAE": np.nan, "R2": np.nan}
        
    mbe  = np.mean(synthetic - measured)
    rmse = np.sqrt(mean_squared_error(measured, synthetic))
    mae  = mean_absolute_error(measured, synthetic)
    r2   = r2_score(measured, synthetic)
    
    return {"MBE": mbe, "RMSE": rmse, "MAE": mae, "R2": r2}

# ==============================================================================
# PLOTTING FUNCTIONS
# ==============================================================================

def plot_day_triple_temp(date_str, measured, f_lin, f_pch, f_knn, m_lin, m_pch, m_knn, out_dir):
    """
    Generates a 3-row plot comparing the downscaling methods for Temperature.
    """
    fig, axes = plt.subplots(3, 1, figsize=(14, 12), sharex=True)
    t_min = np.arange(MINS_PER_DAY)

    plot_real = lambda ax: ax.plot(t_min, measured, lw=3.0, color="#9E9E9E", alpha=0.6, label="Measured 1-Min Truth", zorder=1)
    month_name = pd.Timestamp(date_str).strftime('%B')

    # --- ROW 1: Linear Interpolation (Purple) ---
    plot_real(axes[0])
    axes[0].plot(t_min, f_lin, lw=1.5, color="#9C27B0", alpha=0.9, label="Linear Interpolation", zorder=2)
    axes[0].set_ylabel("Temp (°C)")
    axes[0].set_title(f"Linear Interpolation: {date_str} ({month_name}) | RMSE={m_lin['RMSE']:.2f}°C, R²={m_lin['R2']:.3f}", fontweight="bold")
    axes[0].legend(fontsize=10, loc="upper right")
    axes[0].grid(alpha=0.3)

    # --- ROW 2: PCHIP Interpolation (Pink/Red) ---
    plot_real(axes[1])
    axes[1].plot(t_min, f_pch, lw=1.5, color="#E91E63", alpha=0.9, label="PCHIP Interpolation", zorder=2)
    axes[1].set_ylabel("Temp (°C)")
    axes[1].set_title(f"PCHIP Smooth Curve: {date_str} ({month_name}) | RMSE={m_pch['RMSE']:.2f}°C, R²={m_pch['R2']:.3f}", fontweight="bold")
    axes[1].legend(fontsize=10, loc="upper right")
    axes[1].grid(alpha=0.3)

    # --- ROW 3: Hybrid KNN (Blue) ---
    plot_real(axes[2])
    axes[2].plot(t_min, f_knn, lw=1.5, color="#2196F3", alpha=0.9, label="Hybrid KNN", zorder=2)
    axes[2].set_xlabel("Time (minutes from midnight)")
    axes[2].set_ylabel("Temp (°C)")
    axes[2].set_title(f"Hybrid KNN (Data-Driven Variance): {date_str} ({month_name}) | RMSE={m_knn['RMSE']:.2f}°C, R²={m_knn['R2']:.3f}", fontweight="bold")
    axes[2].legend(fontsize=10, loc="upper right")
    axes[2].grid(alpha=0.3)
    
    axes[2].set_xlim(0, 1440)
    axes[2].xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))

    fig.tight_layout()
    os.makedirs(EXAMPLE_PLOTS_DIR, exist_ok=True)
    out_path = os.path.join(EXAMPLE_PLOTS_DIR, f"temp_downscale_{date_str}.png")
    fig.savefig(out_path, dpi=120)
    plt.close(fig)

def plot_statistical_comparison_temp(hourly_temp, min1_lin, min1_pch, min1_knn, out_dir, real_1min):
    fig, axes = plt.subplots(3, 2, figsize=(14, 15))

    def build_row(row_idx, synth_data, color, label_title):
        # Histogram (PDF)
        axes[row_idx, 0].hist(real_1min, bins=80, density=True, alpha=0.5, color="#9E9E9E", label="Real 1-Minute Truth", zorder=1)
        axes[row_idx, 0].hist(synth_data, bins=80, density=True, alpha=0.6, color=color, label=f"Synthetic: {label_title}", zorder=2)
        axes[row_idx, 0].set_ylabel("Density", fontsize=11)
        if row_idx == 2: axes[row_idx, 0].set_xlabel("Temperature (°C)", fontsize=11)
        axes[row_idx, 0].legend(fontsize=10)
        axes[row_idx, 0].grid(alpha=0.3)

        # CDF
        axes[row_idx, 1].plot(np.sort(real_1min), np.linspace(0, 1, len(real_1min)), lw=3.0, color="#9E9E9E", label="Real 1-Minute Truth", zorder=1)
        axes[row_idx, 1].plot(np.sort(synth_data), np.linspace(0, 1, len(synth_data)), lw=2.0, color=color, label=f"Synthetic: {label_title}", zorder=2)
        axes[row_idx, 1].set_ylabel("Cumulative Probability", fontsize=11)
        if row_idx == 2: axes[row_idx, 1].set_xlabel("Temperature (°C)", fontsize=11)
        axes[row_idx, 1].legend(fontsize=10)
        axes[row_idx, 1].grid(alpha=0.3)

    build_row(0, min1_lin, "#9C27B0", "Linear Interpolation")
    build_row(1, min1_pch, "#E91E63", "PCHIP Interpolation")
    build_row(2, min1_knn, "#2196F3", "Hybrid KNN")

    fig.tight_layout()
    out_path = os.path.join(out_dir, "temp_statistical_sanity_check.png")
    fig.savefig(out_path, dpi=120)
    plt.close(fig)

def plot_version_comparison_temp(df_m, out_dir):
    versions = ["Linear", "PCHIP", "Hybrid KNN"]
    
    rmse_vals = [df_m["RMSE_LIN"].mean(), df_m["RMSE_PCH"].mean(), df_m["RMSE_KNN"].mean()]
    mae_vals  = [df_m["MAE_LIN"].mean(), df_m["MAE_PCH"].mean(), df_m["MAE_KNN"].mean()]
    r2_vals   = [df_m["R2_LIN"].mean(), df_m["R2_PCH"].mean(), df_m["R2_KNN"].mean()]

    fig, axes = plt.subplots(1, 3, figsize=(14, 5))
    
    # New Colors to avoid confusion with GHI
    colours = ["#9C27B0", "#E91E63", "#2196F3"]

    for ax, vals, label, fmt in zip(axes, [rmse_vals, mae_vals, r2_vals],
                                    ["Mean RMSE (°C)", "Mean MAE (°C)", "Mean R²"],
                                    ["{:.3f}°C", "{:.3f}°C", "{:.4f}"]):
        bars = ax.bar(range(3), vals, color=colours, alpha=0.85)
        ax.set_xticks(range(3))
        ax.set_xticklabels(versions, fontsize=10)
        ax.set_ylabel(label, fontsize=12)
        ax.grid(axis="y", alpha=0.3)
        
        y_max, y_min = max(vals), min(vals)
        ax.set_ylim(0 if y_min >= 0 else y_min * 1.2, y_max * 1.2)
        
        rng_span = max(abs(v) for v in vals) * 0.08 if vals else 0.1
        for bar, v in zip(bars, vals):
            ax.text(bar.get_x() + bar.get_width() / 2, v + (rng_span if v >= 0 else -rng_span * 2.5),
                    fmt.format(v), ha="center", fontsize=10, fontweight="bold")

    fig.tight_layout()
    out = os.path.join(out_dir, "temp_version_comparison.png")
    fig.savefig(out, dpi=120)
    plt.close(fig)

# ==============================================================================
# MAIN
# ==============================================================================

def main():
    print("=" * 70)
    print("TEMPERATURE Downscaling Validation (Linear vs PCHIP vs KNN)")
    print("=" * 70)

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    os.makedirs(EXAMPLE_PLOTS_DIR, exist_ok=True)

    print("\nLoading temperature data ...")
    df_1min   = load_1min_temp_data(REAL_1MIN_PATH)
    df_hourly = resample_to_hourly(df_1min)

    all_dates  = sorted({d for d in df_hourly["date"].unique() if pd.Timestamp(d).month in TEST_MONTHS})
    print(f"  1-min rows        : {len(df_1min):,}")
    print(f"  Candidate days    : {all_dates[0]} -> {all_dates[-1]} ({len(all_dates)} total)")

    print("\nBuilding feature database for KNN...", end=" ", flush=True)
    db_records = []
    
    for date_obj in all_dates:
        day_h = (df_hourly[df_hourly["date"] == date_obj].groupby("hour")["temp"]
                 .mean().reindex(range(24)).values.astype(float))
        
        if np.isnan(day_h).any(): continue

        t_mean = day_h.mean()
        t_max  = day_h.max()
        t_min  = day_h.min()
        t_std  = day_h.std()
        
        doy = pd.Timestamp(date_obj).dayofyear
        sin_doy = np.sin(2 * np.pi * doy / 365.25)
        cos_doy = np.cos(2 * np.pi * doy / 365.25)

        db_records.append({
            "Date": date_obj, "DateStr": str(date_obj), "day_h": day_h,
            "T_mean": t_mean, "T_max": t_max, "T_min": t_min, "T_std": t_std,
            "Sin_DOY": sin_doy, "Cos_DOY": cos_doy
        })
        
    df_db = pd.DataFrame(db_records)
    
    scaler = StandardScaler()
    features = ['T_mean', 'T_max', 'T_min', 'T_std', 'Sin_DOY', 'Cos_DOY']
    X_scaled = scaler.fit_transform(df_db[features])
    X_scaled[:, 4] *= 2.0; X_scaled[:, 5] *= 2.0  # Emphasize Seasonality

    print("done.")

    print("\nStarting Temperature Downscaling Validation...")
    all_metrics = []

    final_1min_timestamps = []
    final_1min_lin = []
    final_1min_pch = []
    final_1min_knn = []
    final_1min_truth = []
    
    plotted_months = set()

    for i, target_row in df_db.iterrows():
        target_date = target_row["Date"]
        ds          = target_row["DateStr"]
        day_h       = target_row["day_h"]

        # --- ALGORITHM 1: LINEAR ---
        f_lin = synthesise_temp_linear(day_h)

        # --- ALGORITHM 2: PCHIP ---
        f_pch = synthesise_temp_pchip(day_h)

        # --- ALGORITHM 3: HYBRID KNN ---
        dist = np.linalg.norm(X_scaled - X_scaled[i], axis=1)
        dist[i] = np.inf  # Don't match with itself
              
        nn_idx = np.argmin(dist)
        nn_date = df_db.iloc[nn_idx]["Date"]
        nn_temp_h = df_db.iloc[nn_idx]["day_h"]
        
        nn_1min_meas = extract_1min_profile(df_1min, nn_date)

        f_knn = synthesise_temp_knn(day_h, nn_1min_meas, nn_temp_h)

        # --- VALIDATION METRICS ---
        day_1min = extract_1min_profile(df_1min, target_date)

        m_lin = compute_metrics(f_lin, day_1min)
        m_pch = compute_metrics(f_pch, day_1min)
        m_knn = compute_metrics(f_knn, day_1min)

        row = {
            "Date": ds, "NN_Date": str(nn_date),
            "RMSE_LIN": m_lin["RMSE"], "MAE_LIN": m_lin["MAE"], "R2_LIN": m_lin["R2"],
            "RMSE_PCH": m_pch["RMSE"], "MAE_PCH": m_pch["MAE"], "R2_PCH": m_pch["R2"],
            "RMSE_KNN": m_knn["RMSE"], "MAE_KNN": m_knn["MAE"], "R2_KNN": m_knn["R2"]
        }
        all_metrics.append(row)

        t_index = pd.date_range(f"{ds} 00:00", periods=MINS_PER_DAY, freq="1min", tz=TIMEZONE)
        final_1min_truth.extend(day_1min)
        final_1min_timestamps.extend(t_index)
        final_1min_lin.extend(f_lin)
        final_1min_pch.extend(f_pch)
        final_1min_knn.extend(f_knn)

        current_month = pd.Timestamp(ds).month
        if current_month not in plotted_months:
            print(f"  {ds} | Lin R2: {m_lin['R2']:.3f} | PCHIP R2: {m_pch['R2']:.3f} | KNN R2: {m_knn['R2']:.3f}")
            plot_day_triple_temp(ds, day_1min, f_lin, f_pch, f_knn, m_lin, m_pch, m_knn, OUTPUT_DIR)
            plotted_months.add(current_month)

    df_m = pd.DataFrame(all_metrics)

    print("\nPerforming final Macro-Statistical plotting...")
    synth_lin_array = np.array(final_1min_lin)
    synth_pch_array = np.array(final_1min_pch)
    synth_knn_array = np.array(final_1min_knn)
    truth_array     = np.array(final_1min_truth)
    
    target_hourly_array = df_hourly["temp"].values
    
    plot_statistical_comparison_temp(target_hourly_array, synth_lin_array, synth_pch_array, synth_knn_array, OUTPUT_DIR, real_1min=truth_array)

    print("\n" + "=" * 70)
    print("OVERALL METRICS -- TEMPERATURE DOWNSCALING")
    print("=" * 70)
    print(f"  Mean R2    | Linear: {df_m['R2_LIN'].mean():.4f}  | PCHIP: {df_m['R2_PCH'].mean():.4f}  | KNN: {df_m['R2_KNN'].mean():.4f}")
    print(f"  Mean RMSE  | Linear: {df_m['RMSE_LIN'].mean():.3f}°C | PCHIP: {df_m['RMSE_PCH'].mean():.3f}°C | KNN: {df_m['RMSE_KNN'].mean():.3f}°C")
    
    plot_version_comparison_temp(df_m, OUTPUT_DIR)

    # Export Hourly Data - FIXED timezone issue
    hourly_xlsx_path = os.path.join(OUTPUT_DIR, "hourly_temperature_input.xlsx")
    df_hourly_export = df_hourly.copy()
    if isinstance(df_hourly_export.index, pd.DatetimeIndex):
        df_hourly_export.index = df_hourly_export.index.tz_localize(None)
    df_hourly_export.to_excel(hourly_xlsx_path, sheet_name="Hourly_Temp")

    # Export massive combined CSV
    print(f"\nSaving final Temperature dataset...")
    output_df = pd.DataFrame({
        "time": final_1min_timestamps,
        "Temp_1min_Linear": np.round(final_1min_lin, 2),
        "Temp_1min_PCHIP": np.round(final_1min_pch, 2),
        "Temp_1min_KNN": np.round(final_1min_knn, 2)
    })
    out_csv = os.path.join(OUTPUT_DIR, "Lyngby_downscaled_temp_1min.csv")
    output_df.to_csv(out_csv, index=False)

    print(f"\n[OK] Data CSV saved       : {out_csv}")
    print(f"[OK] Hourly Excel saved   : {hourly_xlsx_path}")
    print(f"[OK] Plots saved in       : {OUTPUT_DIR}")

if __name__ == "__main__":
    main()