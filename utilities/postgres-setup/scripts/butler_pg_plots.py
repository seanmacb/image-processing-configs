#!/usr/bin/env python3
"""
butler_pg_plots.py

Time-series plots of a butler_pg_monitor.sh run. Local analysis only -- do NOT
copy this to the server (use butler_pg_report.py there).

USAGE
    python butler_pg_plots.py RUN_DIR [window] [--freq 1h] [--only a,b] [--save [DIR]]

SAVING
    no --save        show the figures interactively
    --save           write PNGs to <postgres-setup>/_figures/<run dir name>/
    --save DIR       write PNGs to DIR
    (put RUN_DIR first: `--save RUN_DIR` would take RUN_DIR as DIR)

WINDOW (default: the whole run; same options as butler_pg_report.py)
    --label TEXT | --since 14D | --from ISO --to ISO

FIGURES (--only, comma separated; default all)
    growth       disk used vs. volume capacity, growth per day
    cpu          load per core, CPU busy, PSI
    disk         disk throughput and busy
    memory       available RAM, swap
    connections  connection counts vs. max, query and transaction ages
    vacuum       autovacuum workers, datfrozenxid age
    db           per-database commits, rollbacks, inserts, cache hit, temp spill
"""

import argparse
import pathlib
import sys
import types

import matplotlib.dates as mdates
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

import butler_pg_report as report

SURF, INK, INK2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
C = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100"]   # categorical slots 1-4
DB_COLOR = {"butler_main": C[0], "butler_testing": C[1], "postgres": C[2]}
FIGS_ROOT = pathlib.Path(__file__).resolve().parent.parent / "_figures"
DB_COUNTERS = ["xact_commit", "xact_rollback", "blks_hit", "blks_read",
               "tup_inserted", "tup_updated", "tup_deleted", "temp_bytes"]

plt.rcParams.update({
    "figure.facecolor": SURF, "axes.facecolor": SURF, "savefig.facecolor": SURF,
    "text.color": INK, "axes.labelcolor": INK2, "xtick.color": INK2, "ytick.color": INK2,
    "axes.edgecolor": GRID, "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.6, "axes.axisbelow": True,
    "font.size": 9, "legend.frameon": False, "legend.fontsize": 8,
})

FIGURES = {}


def figure(fn):
    FIGURES[fn.__name__.removeprefix("fig_")] = fn
    return fn


def auto_freq(span):
    # aim for <= ~1500 points per line
    target = span.total_seconds() / 1500
    for f, s in (("15s", 15), ("1min", 60), ("5min", 300), ("15min", 900),
                 ("1h", 3600), ("3h", 10800), ("6h", 21600)):
        if target <= s:
            return f
    return "1D"


def derive(d):
    d = d.copy()
    gib = 2 ** 20   # kB -> GiB
    d["disk_used_gib"] = d["disk_used_kb"] / gib
    d["mem_avail_gib"] = d["mem_avail_kb"] / gib
    d["swap_used_gib"] = (d["swap_total_kb"] - d["swap_free_kb"]) / gib
    d["load1_core"] = d["load1"] / d["ncpu"]
    d["disk_read_mbps"] = d["disk_read_kbps"] / 1024
    d["disk_write_mbps"] = d["disk_write_kbps"] / 1024
    return d


def db_deltas(db):
    # per-sample counter deltas; NaN where a counter went backwards (pg_stat reset)
    db = db.sort_values(["datname", "ts_utc"])
    d = db.groupby("datname")[DB_COUNTERS].diff()
    d[d < 0] = np.nan
    d["ts_utc"], d["datname"] = db["ts_utc"], db["datname"]
    return d


def db_binned(deltas, freq):
    # -> {metric: DataFrame(index=time, columns=datname)}, rates per second
    s = deltas.set_index("ts_utc").groupby("datname")[DB_COUNTERS].resample(freq).sum(min_count=1)
    secs = pd.Timedelta(freq).total_seconds()
    col = lambda c: s[c].unstack("datname")
    hit, rd = col("blks_hit"), col("blks_read")
    return {
        "commits": col("xact_commit") / secs,
        "rollbacks": col("xact_rollback") / secs,
        "tup_ins": col("tup_inserted") / secs,
        "cache_hit": 100 * hit / (hit + rd).where((hit + rd) > 0),
        "temp_mbps": col("temp_bytes") / secs / 2 ** 20,
    }


def finish(ctx, fig, axes, title, subtitle):
    fig.suptitle(title, x=0.01, ha="left", fontsize=12, fontweight="bold")
    axes[0].set_title(subtitle, loc="left", fontsize=8, color=INK2)
    for ax in axes:
        for ts, label in ctx.markers:
            ax.axvline(ts, color=INK2, lw=0.8, ls=":", alpha=0.7)
    if 0 < len(ctx.markers) <= 12:
        for ts, label in ctx.markers:
            axes[0].text(ts, 1.0, label, rotation=90, va="top", ha="right", fontsize=7,
                         color=INK2, transform=axes[0].get_xaxis_transform())
    loc = mdates.AutoDateLocator()
    axes[-1].xaxis.set_major_locator(loc)
    axes[-1].xaxis.set_major_formatter(mdates.ConciseDateFormatter(loc))
    axes[-1].set_xlim(ctx.t0, ctx.t1)


def sub(ctx, extra=""):
    return f"{ctx.t0:%Y-%m-%d %H:%M} -> {ctx.t1:%Y-%m-%d %H:%M} UTC  |  bin {ctx.freq}{extra}"


def stacked(ctx, title, panels):
    """panels: dicts with ylabel, series=[(col, label)], how=both|max|mean, hline, scale, zero."""
    cols = sorted({c for p in panels for c, _ in p["series"]})
    r = ctx.inst.set_index("ts_utc")[cols].resample(ctx.freq)
    mean, mx = r.mean(), r.max()
    fig, axes = plt.subplots(len(panels), 1, figsize=(12, 2.5 * len(panels) + 0.6),
                             sharex=True, squeeze=False, layout="constrained")
    axes = axes[:, 0]
    for ax, p in zip(axes, panels):
        how = p.get("how", "both")
        for (col, label), color in zip(p["series"], C):
            if how in ("both", "mean"):
                ax.plot(mean.index, mean[col], color=color, lw=1.4, label=label)
            if how in ("both", "max"):
                solid = how == "max"
                ax.plot(mx.index, mx[col], color=color, lw=1.4 if solid else 0.7,
                        alpha=1 if solid else 0.4, label=label if solid else None)
        if "hline" in p:
            v, text = p["hline"]
            ax.axhline(v, color=INK2, lw=0.8, ls="--")
            ax.text(0.995, v, text, transform=ax.get_yaxis_transform(), ha="right",
                    va="bottom", fontsize=7, color=INK2)
        ax.set_ylabel(p["ylabel"])
        if "scale" in p:
            ax.set_yscale(p["scale"])
        else:
            ax.set_ylim(bottom=0)
        if len(p["series"]) > 1:
            ax.legend(loc="upper left", ncol=len(p["series"]))
    finish(ctx, fig, axes, title, sub(ctx, "  |  solid = mean, faint = max per bin"))
    return fig


@figure
def fig_growth(ctx):
    d = ctx.inst.set_index("ts_utc")
    r = d["disk_used_gib"].resample(ctx.freq).last()
    total = d["disk_total_kb"].iloc[-1] / 2 ** 20
    fig, axes = plt.subplots(2, 1, figsize=(12, 6), sharex=True, layout="constrained")
    axes[0].plot(r.index, r, color=C[0], lw=1.6)
    axes[0].axhline(total, color=INK2, lw=0.8, ls="--")
    axes[0].text(0.005, total, f"volume capacity {total:.0f} GiB", transform=axes[0].get_yaxis_transform(),
                 ha="left", va="bottom", fontsize=7, color=INK2)
    axes[0].set_ylabel("Disk used (GiB)")
    axes[0].set_ylim(0, total * 1.08)

    # rate normalised by the real time between each bin's last samples, so partial bins are not skewed
    bin_ = "1D" if ctx.t1 - ctx.t0 >= pd.Timedelta("4D") else "1h"
    edge = d["disk_used_gib"].resample(bin_).last()
    last_ts = d.index.to_series().resample(bin_).last()
    rate = edge.diff() / (last_ts.diff().dt.total_seconds() / 86400)
    x = mdates.date2num(rate.index.to_pydatetime() + pd.Timedelta(bin_) / 2)
    axes[1].bar(x, rate, width=pd.Timedelta(bin_) / pd.Timedelta("1D") * 0.8, color=C[0])
    axes[1].axhline(0, color=INK2, lw=0.8)
    axes[1].set_ylabel("Growth rate (GiB/day)")
    finish(ctx, fig, axes, "Disk usage", sub(ctx, f"  |  growth rate per {bin_} bin"))
    return fig


@figure
def fig_cpu(ctx):
    return stacked(ctx, "CPU and pressure", [
        dict(ylabel="load1 per core", series=[("load1_core", "load1 / core")], hline=(1, "1 per core")),
        dict(ylabel="CPU busy (%)", series=[("cpu_util_pct", "CPU busy")]),
        dict(ylabel="PSI some, avg10 (%)", series=[("psi_cpu_some_avg10", "cpu"),
                                                   ("psi_mem_some_avg10", "memory"),
                                                   ("psi_io_some_avg10", "io")]),
    ])


@figure
def fig_disk(ctx):
    return stacked(ctx, "Disk I/O", [
        dict(ylabel="Disk throughput (MB/s)", series=[("disk_read_mbps", "read"), ("disk_write_mbps", "write")]),
        dict(ylabel="Disk busy (%)", series=[("disk_util_pct", "disk busy")]),
    ])


@figure
def fig_memory(ctx):
    return stacked(ctx, "Memory", [
        dict(ylabel="Available RAM (GiB)", series=[("mem_avail_gib", "available RAM")]),
        dict(ylabel="Swap used (GiB)", series=[("swap_used_gib", "swap used")]),
    ])


@figure
def fig_connections(ctx):
    maxc = ctx.inst["max_connections"].max()
    return stacked(ctx, "Connections and long-running work", [
        dict(ylabel="Connections (max per bin)", how="max", hline=(maxc, f"max_connections {maxc:.0f}"),
             series=[("total_conn", "total"), ("active_conn", "active"),
                     ("idle_in_xact_conn", "idle in xact"), ("waiting_on_lock", "waiting on lock")]),
        dict(ylabel="Age (s, max per bin)", how="max", scale="symlog",
             series=[("longest_query_secs", "longest query"), ("oldest_xact_secs", "oldest xact"),
                     ("longest_idle_xact_secs", "longest idle-in-xact")]),
    ])


@figure
def fig_vacuum(ctx):
    return stacked(ctx, "Autovacuum and transaction ID age", [
        dict(ylabel="Autovacuum workers (max)", how="max", series=[("autovac_workers", "workers")]),
        dict(ylabel="max datfrozenxid age", how="max", series=[("max_datfrozenxid_age", "xid age")]),
    ])


@figure
def fig_db(ctx):
    if ctx.deltas.empty:
        return None
    b = db_binned(ctx.deltas, ctx.freq)
    panels = [("commits", "Commits / s"), ("rollbacks", "Rollbacks / s"),
              ("tup_ins", "Tuples inserted / s"), ("cache_hit", "Cache hit (%)"),
              ("temp_mbps", "Temp spill (MB/s)")]
    fig, axes = plt.subplots(len(panels), 1, figsize=(12, 2.5 * len(panels) + 0.6),
                             sharex=True, layout="constrained")
    for ax, (key, ylabel) in zip(axes, panels):
        for name in b[key].columns:
            ax.plot(b[key].index, b[key][name], color=DB_COLOR.get(name, INK2), lw=1.4, label=name)
        ax.set_ylabel(ylabel)
        if key != "cache_hit":
            ax.set_ylim(bottom=0)
    axes[0].legend(loc="upper left", ncol=3)
    finish(ctx, fig, axes, "Per-database activity", sub(ctx, "  |  counters reset by pg_stat_reset leave gaps"))
    return fig


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("run_dir", type=pathlib.Path)
    p.add_argument("--label")
    p.add_argument("--since")
    p.add_argument("--from", dest="from_")
    p.add_argument("--to")
    p.add_argument("--freq", help="resample bin, e.g. 15min, 1h, 1D (default: automatic)")
    p.add_argument("--only", help=f"comma separated subset of: {', '.join(FIGURES)}")
    p.add_argument("--save", nargs="?", const="", default=None)
    args = p.parse_args()

    run_dir = args.run_dir.resolve()
    if not run_dir.is_dir():
        sys.exit(f"not a directory: {run_dir}")
    names = args.only.split(",") if args.only else list(FIGURES)
    if bad := [n for n in names if n not in FIGURES]:
        sys.exit(f"unknown figure(s) {bad}; choose from {list(FIGURES)}")

    inst, db, markers = report.load_run(run_dir)
    t0, t1 = report.pick_window(args, inst, markers)
    win = inst[(inst["ts_utc"] >= t0) & (inst["ts_utc"] <= t1)]
    if len(win) < 2:
        sys.exit("< 2 samples in the chosen window")
    deltas = db_deltas(db) if not db.empty else pd.DataFrame()
    if not deltas.empty:
        deltas = deltas[(deltas["ts_utc"] >= t0) & (deltas["ts_utc"] <= t1)]
    mk = markers[(markers["ts_utc"] >= t0) & (markers["ts_utc"] <= t1)]
    ctx = types.SimpleNamespace(
        inst=derive(win), deltas=deltas, t0=win["ts_utc"].min(), t1=win["ts_utc"].max(),
        markers=list(zip(mk["ts_utc"], mk["label"])),
        freq=args.freq or auto_freq(win["ts_utc"].max() - win["ts_utc"].min()))

    out = None
    if args.save is not None:
        out = pathlib.Path(args.save) if args.save else FIGS_ROOT / run_dir.name
        out.mkdir(parents=True, exist_ok=True)
        plt.switch_backend("Agg")

    for name in names:
        fig = FIGURES[name](ctx)
        if fig is None:
            continue
        if out:
            path = out / f"{name}.png"
            fig.savefig(path, dpi=130)
            plt.close(fig)
            print(f"wrote {path}")
    if not out:
        plt.show()


if __name__ == "__main__":
    main()
