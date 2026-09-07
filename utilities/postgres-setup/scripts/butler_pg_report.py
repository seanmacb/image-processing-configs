#!/usr/bin/env python3
"""
butler_pg_report.py

Summarise a butler_pg_monitor.sh run: worst-case saturation gauges and
per-database counter deltas over a chosen window. Read-only; it only reads the
CSV files the sampler wrote.

USAGE
    python butler_pg_report.py RUN_DIR [window] [--plot FILE.png]

RUN_DIR is a run directory (e.g. pgmon/run_20260907T101500Z) or the
pgmon/latest symlink.

WINDOW (default: the whole run)
    --label TEXT           from the marker whose label contains TEXT to the
                           next marker (or the end of the run)
    --since 30min          last <pandas offset> of the run
    --from ISO --to ISO    explicit UTC bounds (either may be omitted)
"""

import argparse
import pathlib
import sys

import pandas as pd


def _read_csvs(files):
    # concat, skipping empty files (interrupted header write / stale rollover);
    # ts_utc is forced to UTC-aware so window bounds always compare cleanly.
    frames = []
    for f in files:
        try:
            frames.append(pd.read_csv(f))
        except (pd.errors.EmptyDataError, FileNotFoundError):
            continue
    if not frames:
        return pd.DataFrame()
    df = pd.concat(frames, ignore_index=True)
    if "ts_utc" in df:
        df["ts_utc"] = pd.to_datetime(df["ts_utc"], utc=True, errors="coerce")
        df = df.sort_values("ts_utc")
    return df


def load_run(run_dir):
    inst = _read_csvs(sorted(run_dir.glob("instance_*.csv")))
    if inst.empty:
        sys.exit(f"no readable instance_*.csv under {run_dir}")
    if "pg_status" not in inst:   # CSVs from before pg_status existed
        inst["pg_status"] = inst["pg_up"].map(lambda v: "ok" if v == 1 else "unreachable")
    db = _read_csvs(sorted(run_dir.glob("database_*.csv")))
    markers = _read_csvs([run_dir / "markers.csv"])
    if markers.empty:
        markers = pd.DataFrame(columns=["ts_utc", "label"])
    return inst, db, markers


def pick_window(args, inst, markers):
    t_lo, t_hi = inst["ts_utc"].min(), inst["ts_utc"].max()
    if args.label:
        hit = markers[markers["label"].str.contains(args.label, case=False, na=False, regex=False)]
        if hit.empty:
            sys.exit(f"no marker matching {args.label!r} (have: {list(markers['label'])})")
        start = hit["ts_utc"].iloc[0]
        later = markers[markers["ts_utc"] > start]
        end = later["ts_utc"].iloc[0] if not later.empty else t_hi
        return start, end
    if args.since:
        return t_hi - pd.Timedelta(args.since), t_hi
    lo = pd.to_datetime(args.from_, utc=True) if args.from_ else t_lo
    hi = pd.to_datetime(args.to, utc=True) if args.to else t_hi
    return lo, hi


def human_kb(kb):
    try:
        v = float(kb) * 1024
    except (TypeError, ValueError):
        return "n/a"
    if pd.isna(v):
        return "n/a"
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(v) < 1024 or unit == "TiB":
            return f"{v:.1f} {unit}"
        v /= 1024


def delta(series):
    s = series.dropna()
    return s.iloc[-1] - s.iloc[0] if len(s) >= 2 else float("nan")


def counter_delta(series):
    # NaN if the counter decreased -> pg_stat was reset inside the window
    s = series.dropna()
    if len(s) < 2 or s.diff().min() < 0:
        return float("nan")
    return s.iloc[-1] - s.iloc[0]


def show(v):
    return "n/a" if (isinstance(v, float) and pd.isna(v)) else v


def report(inst, db, t0, t1):
    win = inst[(inst["ts_utc"] >= t0) & (inst["ts_utc"] <= t1)]
    print("=" * 70)
    print(" BUTLER PG LOAD REPORT")
    print("=" * 70)
    print(f" window : {t0}  ->  {t1}")
    print(f" span   : {t1 - t0}")
    print(f" samples: {len(win)}")
    if len(win) < 2:
        print("\n WARNING: < 2 samples in this window; deltas are unavailable.")
        return

    ok = win[win["pg_status"] == "ok"]
    n_ceiling = int((win["pg_status"] == "too_many_clients").sum())
    n_timeout = int((win["pg_status"] == "timeout").sum())
    n_unreach = int(win["pg_status"].isin(["unreachable", "error"]).sum())

    def peak(col, fn="max"):
        if col not in win or win[col].dropna().empty:
            return float("nan")
        return getattr(win[col].dropna(), fn)()

    cores = peak("ncpu")
    load1 = peak("load1")
    print("\n--- Saturation (worst case over window) " + "-" * 30)
    print(f" cores                     : {show(cores)}")
    print(f" peak load1                : {show(load1)}")
    if pd.notna(load1) and pd.notna(cores) and float(cores) != 0:
        print(f" peak load1 / core         : {float(load1) / float(cores):.2f}")
    print(f" peak CPU busy %           : {show(peak('cpu_util_pct'))}")
    print(f" peak PSI cpu/mem/io some  : {show(peak('psi_cpu_some_avg10'))} / "
          f"{show(peak('psi_mem_some_avg10'))} / {show(peak('psi_io_some_avg10'))}")
    print(f" min available RAM         : {human_kb(peak('mem_avail_kb', 'min'))}")
    swap_used = (win["swap_total_kb"] - win["swap_free_kb"]).max()
    print(f" max swap used             : {human_kb(swap_used)}")
    print(f" peak disk read / write    : {show(peak('disk_read_kbps'))} / {show(peak('disk_write_kbps'))} KB/s")
    print(f" peak disk busy %          : {show(peak('disk_util_pct'))}")
    print(f" peak data-volume used %   : {show(peak('disk_used_pct'))}")
    print(f" data-volume growth        : {human_kb(delta(win['disk_used_kb']))}")
    print(f" WAL written over window   : {human_kb(delta(win['wal_bytes']) / 1024)}")
    if not ok.empty:
        print(f" peak connections          : {ok['total_conn'].max()} / {ok['max_connections'].max()} "
              f"({100 * ok['total_conn'].max() / max(ok['max_connections'].max(), 1):.0f}%)")
        print(f" peak active backends      : {ok['active_conn'].max()}")
        print(f" peak blocked on lock      : {ok['waiting_on_lock'].max()}")
        print(f" peak idle in transaction  : {ok['idle_in_xact_conn'].max()}")
        print(f" longest query / xact  (s) : {ok['longest_query_secs'].max()} / {ok['oldest_xact_secs'].max()}")
        print(f" longest idle-in-xact  (s) : {ok['longest_idle_xact_secs'].max()}")
        print(f" peak autovacuum workers   : {ok['autovac_workers'].max()}")
        print(f" max datfrozenxid age      : {ok['max_datfrozenxid_age'].max()}")
    if n_ceiling:
        print(f" samples that hit the connection ceiling : {n_ceiling}  (server up)")
    if n_timeout:
        print(f" samples where the sample query timed out : {n_timeout}  (server up)")
    if n_unreach:
        print(f" samples with Postgres unreachable        : {n_unreach}")

    if db.empty:
        return
    dwin = db[(db["ts_utc"] >= t0) & (db["ts_utc"] <= t1)]
    if dwin.empty:
        return
    print("\n--- Per-database counter deltas over window " + "-" * 26)
    counters = ("xact_commit", "xact_rollback", "blks_hit", "blks_read",
                "tup_inserted", "tup_updated", "tup_deleted",
                "temp_files", "temp_bytes", "deadlocks")
    rows, reset_dbs = [], []
    for name, g in dwin.groupby("datname"):
        g = g.sort_values("ts_utc")
        if len(g) < 2:
            continue
        d = {c: counter_delta(g[c]) for c in counters}
        if any(pd.isna(v) for v in d.values()):   # counter went backwards -> reset
            reset_dbs.append(name)
            continue
        hit, rd = d["blks_hit"], d["blks_read"]
        rows.append({
            "datname": name,
            "commits": int(d["xact_commit"]),
            "rollbacks": int(d["xact_rollback"]),
            "cache_hit_%": round(100 * hit / (hit + rd), 3) if (hit + rd) else float("nan"),
            "blks_read": int(rd),
            "tup_ins": int(d["tup_inserted"]),
            "tup_upd": int(d["tup_updated"]),
            "tup_del": int(d["tup_deleted"]),
            "temp_files": int(d["temp_files"]),
            "temp_spill": human_kb(d["temp_bytes"] / 1024),
            "deadlocks": int(d["deadlocks"]),
        })
    if rows:
        out = pd.DataFrame(rows).sort_values("commits", ascending=False)
        print(out.to_string(index=False))
    if reset_dbs:
        print(f"\n  NOTE: pg_stat counters reset inside the window for: {', '.join(reset_dbs)}")
        print("        (crash recovery or pg_stat_reset zeroes them; deltas omitted)")


def make_plot(inst, t0, t1, path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    win = inst[(inst["ts_utc"] >= t0) & (inst["ts_utc"] <= t1)]
    panels = [
        ("load1", "cpu_util_pct"),
        ("total_conn", "active_conn", "waiting_on_lock"),
        ("disk_read_kbps", "disk_write_kbps"),
        ("mem_avail_kb",),
    ]
    fig, axes = plt.subplots(len(panels), 1, figsize=(11, 2.4 * len(panels)), sharex=True)
    for ax, cols in zip(axes, panels):
        for c in cols:
            if c in win:
                ax.plot(win["ts_utc"], win[c], label=c, linewidth=1)
        ax.legend(loc="upper left", fontsize=8)
        ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(path, dpi=110)
    print(f"\nplot written: {path}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("run_dir", type=pathlib.Path)
    p.add_argument("--label")
    p.add_argument("--since")
    p.add_argument("--from", dest="from_")
    p.add_argument("--to")
    p.add_argument("--plot", type=pathlib.Path)
    args = p.parse_args()

    run_dir = args.run_dir.resolve()
    if not run_dir.is_dir():
        sys.exit(f"not a directory: {run_dir}")
    inst, db, markers = load_run(run_dir)
    t0, t1 = pick_window(args, inst, markers)
    report(inst, db, t0, t1)
    if not markers.empty:
        mk = markers[(markers["ts_utc"] >= t0) & (markers["ts_utc"] <= t1)]
        if not mk.empty:
            print("\n--- Markers in window " + "-" * 48)
            for _, m in mk.iterrows():
                print(f" {m['ts_utc']}  {m['label']}")
    if args.plot:
        make_plot(inst, t0, t1, args.plot)


if __name__ == "__main__":
    main()
