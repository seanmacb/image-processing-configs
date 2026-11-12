#!/usr/bin/env python
"""Template PSF figures for one or more sky areas (e.g. GW events), from a config file.

Batch counterpart of the plotting cells in evaluate_template_psf_quality.ipynb. For each
event in the config it keeps the patches of template_psf_per_patch.csv (written by
measure_template_psf.py) whose centre lies in the event's RA/Dec box, and writes the
notebook's three key figures into <output_root>/<label>/:

  PSF_across_Templates.pdf          per-tract spread of the patch-level template PSF
  PSF_across_Templates_spatial.pdf  sky map (true RA/Dec) of the template PSF FWHM, with
                                    the event's 50% and 90% credible contours
  PSF_across_Templates_corr.pdf     template vs. input-weighted PSF FWHM

See template_psf_events.yaml for the config format. Patch centres come from the skymap,
so this needs the LSST stack (see run-plot-template-psf.sh); they are cached in
<output_root>/patch_centers.csv so later runs only touch the Butler for new patches.

The contours come from each event's GraceDB multi-order skymap, read from
<skymap_dir>/<label>.fits (fetch_event_skymaps.py puts them there); an event without
one is plotted without contours.
"""

import argparse
import glob
import os
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import yaml
from matplotlib.lines import Line2D
from matplotlib.ticker import FuncFormatter

BOX_KEYS = ("ra_min", "ra_max", "dec_min", "dec_max")
CONTOUR_FRACTIONS = (0.9, 0.5)      # credible levels drawn on the spatial plot
SKYMAP_NSIDE = 1024                 # resolution the multi-order skymap is flattened to (0.06 deg)


def load_config(path):
    with open(path) as f:
        cfg = yaml.safe_load(f)
    if not cfg.get("events"):
        sys.exit(f"{path}: no events listed")
    return cfg


def event_box(event):
    """(ra_min, ra_max, dec_min, dec_max) in degrees, or None if the event has no box yet."""
    values = [event.get(k) for k in BOX_KEYS]
    if any(v is None for v in values):
        return None
    return tuple(float(v) for v in values)


def read_csvs(spec):
    """Concatenate the per-patch CSVs matched by a path/glob or a list of them."""
    patterns = [spec] if isinstance(spec, str) else list(spec)
    paths = sorted({p for pattern in patterns for p in glob.glob(os.path.expandvars(pattern))})
    if not paths:
        raise FileNotFoundError(f"no CSV matches {patterns}")
    df = pd.concat((pd.read_csv(p) for p in paths), ignore_index=True)
    return df.drop_duplicates(subset=["band", "tract", "patch"], keep="last")


def patch_centers(keys, cache_path, repo, skymap_name, skymap_collection):
    """DataFrame (tract, patch, ra, dec) for every (tract, patch) in `keys`."""
    cached = pd.read_csv(cache_path) if os.path.exists(cache_path) else pd.DataFrame(
        columns=["tract", "patch", "ra", "dec"])
    have = set(zip(cached["tract"], cached["patch"]))
    missing = [k for k in keys if k not in have]
    if missing:
        import lsst.geom as geom
        from lsst.daf.butler import Butler

        skymap = Butler(repo, collections=[skymap_collection]).get("skyMap", skymap=skymap_name)
        rows = []
        for tract, patch in missing:
            tract_info = skymap[tract]
            center_pix = geom.Box2D(tract_info[patch].getInnerBBox()).getCenter()
            center = tract_info.getWcs().pixelToSky(center_pix)
            rows.append(dict(tract=tract, patch=patch,
                             ra=center.getRa().asDegrees(), dec=center.getDec().asDegrees()))
        cached = pd.concat([cached, pd.DataFrame(rows)], ignore_index=True)
        os.makedirs(os.path.dirname(os.path.abspath(cache_path)), exist_ok=True)
        cached.to_csv(cache_path, index=False)
        print(f"Computed {len(missing)} new patch centres; cache now {len(cached)} -> {cache_path}")
    return cached


def in_sky_box(ra, dec, box):
    """Vectorised box test; ra_min > ra_max means the box wraps through RA = 0."""
    ra_min, ra_max, dec_min, dec_max = box
    in_ra = (ra - ra_min) % 360.0 <= (ra_max - ra_min) % 360.0
    return in_ra & (dec >= dec_min) & (dec <= dec_max)


class Skymap:
    """A GraceDB multi-order skymap, flattened so credible levels can be drawn as contours."""

    def __init__(self, path):
        import healpy as hp
        from astropy.table import Table

        self._hp = hp
        table = Table.read(path)
        uniq = np.asarray(table["UNIQ"], dtype=np.int64)
        dens = np.asarray(table["PROBDENSITY"], dtype=float)
        level = np.floor(np.log2(uniq / 4) / 2).astype(int)
        ipix = uniq - 4 * 4 ** level.astype(np.int64)
        top = int(np.log2(SKYMAP_NSIDE))

        flat = np.zeros(hp.nside2npix(SKYMAP_NSIDE))          # density per NESTED pixel
        for lv in np.unique(level):
            sel = level == lv
            if lv <= top:
                k = 4 ** (top - lv)
                for start, d in zip(ipix[sel] * k, dens[sel]):
                    flat[start:start + k] = d
            else:                                              # finer than the flat map: area-average
                np.add.at(flat, ipix[sel] >> (2 * (lv - top)), dens[sel] / 4 ** (lv - top))
        self._flat = flat

        order = np.argsort(flat)[::-1]
        cum = np.cumsum(flat[order])
        cum /= cum[-1]                                         # all flat pixels have equal area
        self.levels = {f: float(flat[order[min(np.searchsorted(cum, f), order.size - 1)]])
                       for f in CONTOUR_FRACTIONS}             # density at the f credible contour
        self.peak = tuple(float(v) for v in hp.pix2ang(SKYMAP_NSIDE, order[0], nest=True, lonlat=True))
        region = order[: np.searchsorted(cum, max(CONTOUR_FRACTIONS)) + 1]
        self.region_ra, self.region_dec = hp.pix2ang(SKYMAP_NSIDE, region, nest=True, lonlat=True)

    def density_at(self, ra, dec):
        return self._flat[self._hp.ang2pix(SKYMAP_NSIDE, ra % 360.0, np.clip(dec, -90, 90),
                                           nest=True, lonlat=True)]


def load_event_skymap(event, cfg):
    """The event's Skymap, or None (with a message) if it is missing or unreadable."""
    path = event.get("skymap")
    if path is None and cfg.get("skymap_dir"):
        path = os.path.join(cfg["skymap_dir"], f"{event['label']}.fits")
    if path is None:
        print(f"{event['label']}: no skymap configured; plotting without contours")
        return None
    path = os.path.expandvars(path)
    if not os.path.exists(path):
        print(f"{event['label']}: WARNING no skymap at {path} (run fetch_event_skymaps.py); "
              "plotting without contours")
        return None
    try:
        return Skymap(path)
    except Exception as exc:
        print(f"{event['label']}: WARNING could not read {path} ({type(exc).__name__}: {exc}); "
              "plotting without contours")
        return None


def plot_per_tract(df, label, path):
    bands = sorted(df["band"].dropna().unique())
    n_tracts = df["tract"].nunique()
    fig, axes = plt.subplots(len(bands), 1,
                             figsize=(max(8, min(0.4 * n_tracts, 40)), 3 * len(bands)),
                             squeeze=False)
    for ax, band in zip(axes[:, 0], bands):
        sub = df[df["band"] == band]
        tracts = sorted(sub["tract"].unique())
        data = [sub.loc[sub["tract"] == t, "template_psf_fwhm_median"].dropna() for t in tracts]
        ax.boxplot(data, tick_labels=[str(t) for t in tracts], showfliers=False)
        ax.set_title(f"band = {band}")
    axes[-1, 0].set_xlabel("tract")
    fig.supylabel("template PSF FWHM (arcsec)")
    fig.suptitle(f"{label}: per-tract spread of patch-level template PSF")
    fig.tight_layout()
    fig.savefig(path, dpi=300)
    plt.close(fig)


def plot_spatial(df, label, box, path, skymap=None):
    """Patch centres at their true RA/Dec (RA increasing to the left, as on the sky),
    coloured by template PSF FWHM, with the event's 50% and 90% credible contours."""
    bands = sorted(df["band"].dropna().unique())
    # RA is unwrapped around the event so a region straddling RA = 0 stays contiguous.
    ra_ref = skymap.peak[0] if skymap else (box[0] + ((box[1] - box[0]) % 360.0) / 2.0) % 360.0
    unwrap = lambda ra: ra_ref + ((np.asarray(ra) - ra_ref + 180.0) % 360.0 - 180.0)
    x, y = unwrap(df["ra"]), df["dec"].to_numpy()

    xs, ys = [x], [y]                                       # the view covers patches and region
    if skymap:
        xs.append(unwrap(skymap.region_ra)); ys.append(skymap.region_dec)
    xmin, xmax = min(a.min() for a in xs), max(a.max() for a in xs)
    ymin, ymax = min(a.min() for a in ys), max(a.max() for a in ys)
    pad = 0.03 * max(xmax - xmin, ymax - ymin, 1.0)
    xmin, xmax, ymin, ymax = xmin - pad, xmax + pad, max(ymin - pad, -90.0), min(ymax + pad, 90.0)
    dec_mid = 0.5 * (ymin + ymax)

    fig, axes = plt.subplots(1, len(bands), figsize=(5 * len(bands), 5),
                             squeeze=False, sharex=True, sharey=True)
    vmin, vmax = df["template_psf_fwhm_median"].quantile([0.02, 0.98])
    if skymap:
        step = max(0.05, max(xmax - xmin, ymax - ymin) / 800.0)
        gx, gy = np.meshgrid(np.arange(xmin, xmax, step), np.arange(ymin, ymax, step))
        density = skymap.density_at(gx, gy)
    sc = None
    for ax, band in zip(axes[0], bands):
        sel = (df["band"] == band).to_numpy()
        sc = ax.scatter(x[sel], y[sel], c=df.loc[sel, "template_psf_fwhm_median"],
                        cmap="viridis", vmin=vmin, vmax=vmax, s=40)
        if skymap:
            # the 90% contour is the lower density level, so it comes first (dashed)
            ax.contour(gx, gy, density, levels=[skymap.levels[0.9], skymap.levels[0.5]],
                       colors="red", linewidths=1.5, linestyles=["--", "-"])
            ax.plot(*[[v] for v in (unwrap(skymap.peak[0]), skymap.peak[1])], "r+", ms=12, mew=2)
        ax.set_title(f"band = {band}")
        ax.set_xlabel("RA (deg)")
        ax.set_xlim(xmax, xmin)                                          # east to the left
        ax.set_ylim(ymin, ymax)
        ax.set_aspect(1.0 / np.cos(np.radians(dec_mid)))                 # equal on-sky scale
        ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v % 360:g}"))
    axes[0, 0].set_ylabel("Dec (deg)")
    if skymap:
        axes[0, 0].legend(handles=[
            Line2D([], [], color="red", ls="-", label="50% credible"),
            Line2D([], [], color="red", ls="--", label="90% credible"),
            Line2D([], [], color="red", marker="+", ls="", ms=10, mew=2, label="skymap peak")],
            loc="best", fontsize=8)
    fig.colorbar(sc, ax=axes, label="template PSF FWHM (arcsec)", shrink=0.8)
    fig.suptitle(f"{label}: template PSF across the sky")
    fig.savefig(path, dpi=300)
    plt.close(fig)


def plot_template_vs_input(df, label, path):
    valid = df.dropna(subset=["template_psf_fwhm_median", "input_psf_fwhm_weighted_median"])
    if valid.empty:
        print(f"  {label}: no patches with both template and input FWHM; skipping corr figure")
        return False
    fig, ax = plt.subplots(figsize=(6, 6))
    sc = ax.scatter(valid["input_psf_fwhm_weighted_median"], valid["template_psf_fwhm_median"],
                    c=valid["n_inputs"], cmap="plasma", s=30)
    cols = ["input_psf_fwhm_weighted_median", "template_psf_fwhm_median"]
    lims = [valid[cols].min().min(), valid[cols].max().max()]
    ax.plot(lims, lims, "k--", lw=1, label="1:1")
    ax.set_xlabel("input-weighted median FWHM (arcsec)")
    ax.set_ylabel("template (coadd) PSF FWHM (arcsec)")
    ax.set_title(label)
    ax.legend()
    fig.colorbar(sc, ax=ax, label="n inputs")
    fig.tight_layout()
    fig.savefig(path, dpi=300)
    plt.close(fig)
    return True


def parse_args():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--config", required=True, help="YAML config (see template_psf_events.yaml)")
    p.add_argument("--events", default=None,
                   help="comma-separated event labels to process (default: all in the config)")
    return p.parse_args()


def main():
    args = parse_args()
    cfg = load_config(args.config)
    events = cfg["events"]
    if args.events:
        wanted = [e.strip() for e in args.events.split(",") if e.strip()]
        unknown = set(wanted) - {e["label"] for e in events}
        if unknown:
            sys.exit(f"events not in {args.config}: {sorted(unknown)}")
        events = [e for e in events if e["label"] in wanted]

    output_root = os.path.expandvars(cfg["output_root"])
    default_csv = cfg.get("csv")

    # Read each distinct CSV spec once; events usually share one.
    tables = {}
    for event in events:
        spec = event.get("csv", default_csv)
        if spec is None:
            sys.exit(f"{event['label']}: no csv given and no top-level default csv")
        key = repr(spec)
        if key not in tables and event_box(event) is not None:
            tables[key] = read_csvs(spec)
            print(f"Read {len(tables[key])} patch rows for csv {spec}")

    keys = sorted({(int(t), int(p)) for df in tables.values()
                   for t, p in zip(df["tract"], df["patch"])})
    centers = patch_centers(
        keys, os.path.join(output_root, "patch_centers.csv"),
        os.path.expandvars(cfg["repo"]), cfg.get("skymap", "decam_rings_v1"),
        cfg.get("skymap_collection", "skymaps")) if keys else None

    made = []
    for event in events:
        label = event["label"]
        box = event_box(event)
        if box is None:
            print(f"{label}: SKIPPED, ra_min/ra_max/dec_min/dec_max not set in {args.config}")
            continue
        df = tables[repr(event.get("csv", default_csv))].merge(centers, on=["tract", "patch"])
        df = df[in_sky_box(df["ra"], df["dec"], box)]
        if df.empty:
            print(f"{label}: SKIPPED, no template patches inside RA {box[0]:g}-{box[1]:g}, "
                  f"Dec {box[2]:g} to {box[3]:g}")
            continue
        if df["template_psf_fwhm_median"].notna().sum() == 0:
            print(f"{label}: SKIPPED, {len(df)} patches in the box but none has a PSF measurement")
            continue

        skymap = load_event_skymap(event, cfg)
        outdir = os.path.join(output_root, label)
        os.makedirs(outdir, exist_ok=True)
        plot_per_tract(df, label, os.path.join(outdir, "PSF_across_Templates.pdf"))
        plot_spatial(df, label, box, os.path.join(outdir, "PSF_across_Templates_spatial.pdf"), skymap)
        plot_template_vs_input(df, label, os.path.join(outdir, "PSF_across_Templates_corr.pdf"))
        per_band = df.groupby("band")["template_psf_fwhm_median"].agg(["count", "median"])
        summary = ", ".join(f"{b}: {int(r['count'])} patches, median {r['median']:.2f}\""
                            for b, r in per_band.iterrows())
        print(f"{label}: {len(df)} patches in {df['tract'].nunique()} tracts ({summary}) -> {outdir}")
        made.append(label)

    print(f"Done: figures for {len(made)}/{len(events)} events")
    if not made:
        sys.exit(1)


if __name__ == "__main__":
    main()
