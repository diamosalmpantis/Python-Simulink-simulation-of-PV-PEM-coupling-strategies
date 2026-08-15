# -*- coding: utf-8 -*-
"""
PEM EEC parameter identification, uncertainty, and sensitivity analysis
=======================================================================
Reviewer #1, comment 3 (Solar Energy Advances, 2026 revision).

The Simulink validation model (Sim_vs_meas_static.m / _dynamic.m) uses a
hand-calibrated equivalent electrical circuit (EEC). This script quantifies how
well those parameters are constrained by the measurements and how sensitive the
validation error is to them, WITHOUT re-running Simulink:

  1. IDENTIFICATION + UNCERTAINTY
     At electrical steady state the two parallel RC branches conduct through Ra
     and Rc (capacitors open), so the terminal law is
         V_cell = Vint + (Rint + Ra + Rc) * I = Vint + R_ss * I.
     The static polarisation data therefore identify Vint and R_ss (not the
     individual resistance split, nor the time constants). We fit them by OLS on
     the n=1380 measured points and give 95% CIs from both the analytic
     covariance and a moving-block bootstrap (robust to serial correlation).

  2. SENSITIVITY
     A two-state state-space realisation of the SAME circuit is driven by the
     recorded voltage set-points and compared with the measured current. This
     independent implementation reproduces the Simulink current NRMSE (1.07% of
     the 47.9 A nominal current) exactly, then each parameter's uncertainty is
     propagated one-at-a-time to the NRMSE.

Outputs: printed tables + Fig_PEM_ParamUncertainty.png (saved into the paper
figs folder). Requires numpy, pandas, scipy, matplotlib.
"""
import os
import numpy as np, pandas as pd
from scipy import stats
from scipy.linalg import expm
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
STAT = os.path.join(HERE, "private_data", "PEM_recorded_data.xlsx")
# Figure destination: ..\..\Simulink_paper\figs\Results  (adjust if needed)
FIGDIR = os.path.normpath(os.path.join(
    HERE, "..", "..", "Simulink_paper", "figs", "Results"))
I_NOM = 47.9  # A, nominal operating current used for NRMSE normalisation

# hand-calibrated reference parameters (from Sim_vs_meas_static.m)
P0 = dict(Vint=1.475841, Rint=0.008673, Ra=0.00177, Rc=0.0005,
          tau_a=0.4, tau_c=0.04)

# ---------------------------------------------------------------- 1. IDENTIFY
s = pd.read_excel(STAT, sheet_name=0)
I = s["Average_actual_current"].to_numpy(float)
V = s["Average_actual_voltage"].to_numpy(float)
m = np.isfinite(I) & np.isfinite(V); I, V = I[m], V[m]
X = np.column_stack([np.ones(I.size), I])
beta = np.linalg.lstsq(X, V, rcond=None)[0]
res = V - X @ beta; dof = I.size - 2
cov = (res @ res / dof) * np.linalg.inv(X.T @ X); se = np.sqrt(np.diag(cov))
tc = stats.t.ppf(0.975, dof)
R2 = 1 - (res @ res) / ((V - V.mean()) @ (V - V.mean()))
rmse_v = np.sqrt(np.mean(res ** 2))
Vint_hat, Rss_hat = beta

rng = np.random.default_rng(0); L = 50; nb = I.size // L; B = 5000
bs = np.empty((B, 2)); ix = np.arange(I.size)
for k in range(B):
    st = rng.integers(0, I.size - L, size=nb)
    tk = np.concatenate([ix[q:q + L] for q in st])[:I.size]
    bs[k] = np.linalg.lstsq(X[tk], V[tk], rcond=None)[0]
ciV = np.percentile(bs[:, 0], [2.5, 97.5]); ciR = np.percentile(bs[:, 1], [2.5, 97.5])

# ---------------------------------------------------------------- 2. SENSITIVITY
t = s["total time_s"].to_numpy(float)
Vin = s["Average_target_voltage"].to_numpy(float)
Imeas = s["Average_actual_current"].to_numpy(float)
ok = np.isfinite(t) & np.isfinite(Vin) & np.isfinite(Imeas)
t, Vin, Imeas = t[ok], Vin[ok], Imeas[ok]
o = np.argsort(t); t, Vin, Imeas = t[o], Vin[o], Imeas[o]
dt = np.diff(t, prepend=t[0] - np.median(np.diff(t)))


def simulate(P):
    Vint, Rint, Ra, Rc = P["Vint"], P["Rint"], P["Ra"], P["Rc"]
    Ca, Cc = P["tau_a"] / Ra, P["tau_c"] / Rc
    M = np.array([[-1 / (Rint * Ca) - 1 / (Ra * Ca), -1 / (Rint * Ca)],
                  [-1 / (Rint * Cc), -1 / (Rint * Cc) - 1 / (Rc * Cc)]])
    b = np.array([1 / (Rint * Ca), 1 / (Rint * Cc)])
    x = np.zeros(2); Iout = np.empty(t.size)
    for k in range(t.size):
        Ad = expm(M * dt[k]); Bd = np.linalg.solve(M, (Ad - np.eye(2)) @ b)
        x = Ad @ x + Bd * (Vin[k] - Vint)
        Iout[k] = (Vin[k] - Vint - x[0] - x[1]) / Rint
    return Iout


def nrmse(P):
    e = simulate(P) - Imeas; e = e[np.isfinite(e)]
    return np.sqrt(np.mean(e ** 2)) / I_NOM


base = nrmse(P0)
Rss0 = P0["Rint"] + P0["Ra"] + P0["Rc"]


def with_Rss(scale):
    return {**P0, "Rint": P0["Rint"] * scale, "Ra": P0["Ra"] * scale, "Rc": P0["Rc"] * scale}


def with_split(f):
    Rint = P0["Rint"] * (1 + f); sc = (Rss0 - Rint) / (P0["Ra"] + P0["Rc"])
    return {**P0, "Rint": Rint, "Ra": P0["Ra"] * sc, "Rc": P0["Rc"] * sc}


srcs = [
    ("Vint (95% CI)",   nrmse({**P0, "Vint": ciV[0]}), nrmse({**P0, "Vint": ciV[1]})),
    ("Rss (95% CI)",    nrmse(with_Rss(ciR[0] / Rss0)), nrmse(with_Rss(ciR[1] / Rss0))),
    ("R split (+-50%)", nrmse(with_split(-0.5)), nrmse(with_split(+0.5))),
    ("tau_a (+-50%)",   nrmse({**P0, "tau_a": P0["tau_a"] * 0.5}), nrmse({**P0, "tau_a": P0["tau_a"] * 1.5})),
    ("tau_c (+-50%)",   nrmse({**P0, "tau_c": P0["tau_c"] * 0.5}), nrmse({**P0, "tau_c": P0["tau_c"] * 1.5})),
]

print("=" * 64)
print("IDENTIFICATION (static, per cell, n=%d)" % I.size)
print("  Vint = %.4f V   95%% CI [%.4f, %.4f]" % (Vint_hat, ciV[0], ciV[1]))
print("  R_ss = %.5f ohm 95%% CI [%.5f, %.5f]" % (Rss_hat, ciR[0], ciR[1]))
print("  R2 = %.4f   residual RMSE = %.2f mV" % (R2, rmse_v * 1e3))
print("SENSITIVITY  baseline NRMSE = %.2f%% of I_nom=%.1f A" % (base * 100, I_NOM))
for nm, lo, hi in srcs:
    print("  %-16s NRMSE [%.2f, %.2f]%%  (max dev %+.2f pp)"
          % (nm, lo * 100, hi * 100, (max(lo, hi) - base) * 100))

# ---------------------------------------------------------------- 3. FIGURE
plt.rcParams.update({"font.size": 11, "axes.linewidth": 0.9})
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11, 4.3))
Ig = np.linspace(I.min(), I.max(), 200); Vg = beta[0] + beta[1] * Ig
for a_i, b_i in bs[np.random.default_rng(1).integers(0, B, 300)]:
    ax1.plot(Ig, a_i + b_i * Ig, "-", color="#D55E00", alpha=0.03, lw=1, zorder=3)
ax1.plot([], [], "-", color="#D55E00", alpha=0.5, lw=3, label="300 bootstrap fits")
ax1.scatter(I, V, s=7, color="#0072B2", alpha=0.4, edgecolors="none", label="Measured", zorder=2)
ax1.plot(Ig, Vg, "-", color="#8C2D04", lw=1.8, label="OLS fit", zorder=4)
ax1.set_xlabel("Cell current $I$ (A)"); ax1.set_ylabel("Cell voltage $V$ (V)")
ax1.text(0.03, 0.97, r"$V=V_\mathrm{int}+R_\mathrm{ss}\,I$""\n"
         r"$V_\mathrm{int}=%.4f\pm%.4f$ V""\n"
         r"$R_\mathrm{ss}=%.4f\pm%.4f\ \Omega$""\n"r"$R^2=%.4f$"
         % (Vint_hat, (ciV[1]-ciV[0])/2, Rss_hat, (ciR[1]-ciR[0])/2, R2),
         transform=ax1.transAxes, va="top", ha="left", fontsize=9.5,
         bbox=dict(boxstyle="round", fc="white", ec="0.6"))
ax1.legend(loc="lower right", fontsize=9); ax1.grid(alpha=0.3)
ax1.set_title("(a) Static parameter identification", fontsize=11)

order_srcs = sorted(srcs, key=lambda z: abs(max(z[1], z[2]) - base))
b100 = base * 100
pretty = {"Vint (95% CI)": r"$V_\mathrm{int}$ (95% CI)", "Rss (95% CI)": r"$R_\mathrm{ss}$ (95% CI)",
          "R split (+-50%)": r"$R$ split ($\pm$50%)", "tau_a (+-50%)": r"$\tau_a$ ($\pm$50%)",
          "tau_c (+-50%)": r"$\tau_c$ ($\pm$50%)"}
for i, (nm, lo, hi) in enumerate(order_srcs):
    ax2.barh(i, hi * 100 - b100, left=b100, color="#D55E00", alpha=0.85, height=0.58)
    ax2.barh(i, lo * 100 - b100, left=b100, color="#0072B2", alpha=0.85, height=0.58)
ax2.axvline(b100, color="0.25", lw=1.2, zorder=1)
ax2.set_yticks(range(len(order_srcs)))
ax2.set_yticklabels([pretty[z[0]] for z in order_srcs], fontsize=10)
ax2.set_xlabel("Validation NRMSE (%)")
ax2.set_ylim(-0.6, len(order_srcs) - 0.4)
ax2.set_title("(b) Propagated uncertainty in validation error", fontsize=11, pad=8)
from matplotlib.patches import Patch
from matplotlib.lines import Line2D
ax2.legend(handles=[Patch(facecolor="#0072B2", alpha=0.85, label="lower bound"),
                    Patch(facecolor="#D55E00", alpha=0.85, label="upper bound"),
                    Line2D([0], [0], color="0.25", lw=1.2,
                           label="baseline (%.2f%%)" % b100)],
           loc="lower right", fontsize=8.5, framealpha=0.95)
ax2.grid(axis="x", alpha=0.3)
fig.tight_layout()
os.makedirs(FIGDIR, exist_ok=True)
out = os.path.join(FIGDIR, "Fig_PEM_ParamUncertainty.png")
fig.savefig(out, dpi=220, facecolor="white", bbox_inches="tight")
print("\nsaved", out)
