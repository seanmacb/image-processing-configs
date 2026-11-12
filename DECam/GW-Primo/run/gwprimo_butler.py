#!/usr/bin/env python
"""Butler-side checks for the GW-Primo DRP scripts. Read-only.

Needs the LSST stack. Settings come from the environment that common.sh's
load_conf exports (REPO, FIELD, BANDS, REGION, the step queries, the
collections and the STEPn_MIN_FRAC thresholds), so every subcommand sees
exactly the selection the pipetask runs used.

  preflight   everything a run needs is in place: the conf's bands are in the
              pipeline, collections, skymap and refcat exist, the region has
              visits and raws per band, and every band finds a bias, a flat and
              the other ISR calibrations for every night
  check       completeness of one step's outputs, per band (exit 1 below the
              conf's threshold, so the Slurm chain stops)
  summarize   every metric the step's analysis_tools tasks wrote, to a CSV and a
              per-band median table; optionally copies the step's plots
  sky-ready   whether a certified `sky` frame exists for every physical filter
              and night of the field's visits (exit 0 if so); step2.sh turns
              skyCorr's doSky on only then
  skycorr-dosky
              the doSky an earlier step2 recorded in OUTPUT_COLLECTION
              (prints True, False or none)

Every subcommand prints what it found and exits 1 if the check fails.
"""

import argparse
import csv
import os
import re
import statistics
import sys
from collections import Counter, defaultdict

# Representative detector for the calibration lookups (S4, near the centre of
# the focal plane).
CALIB_DETECTOR = 28
CALIB_TYPES = ("bias", "flat", "crosstalk", "defects", "linearizer")


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

class Report:
    """Collects output lines (also printed) and errors/warnings."""

    def __init__(self):
        self.lines, self.errors, self.warnings = [], [], []

    def out(self, msg=""):
        print(msg, flush=True)
        self.lines.append(msg)

    def error(self, msg):
        self.errors.append(msg)
        self.out(f"ERROR: {msg}")

    def warn(self, msg):
        self.warnings.append(msg)
        self.out(f"WARNING: {msg}")

    def finish(self, summary_file=None):
        self.out("FAIL" if self.errors else "PASS")
        if summary_file:
            with open(summary_file, "w") as f:
                f.write("\n".join(self.lines) + "\n")
        return 1 if self.errors else 0


def env(name, default=None):
    value = os.environ.get(name, default)
    if value is None:
        sys.exit(f"ERROR: {name} is not set; run through the GW-Primo scripts (common.sh load_conf)")
    return value


def env_list(name, sep=None):
    return [v for v in re.split(sep or r"[,\s]+", env(name, "")) if v]


def get_butler():
    from lsst.daf.butler import Butler

    return Butler(env("REPO"))


def collection_exists(registry, name):
    from lsst.daf.butler import MissingCollectionError

    try:
        registry.getCollectionType(name)
        return True
    except MissingCollectionError:
        return False


def existing(registry, names):
    return [n for n in names if collection_exists(registry, n)]


def band_map(registry):
    return {r.name: r.band for r in registry.queryDimensionRecords("physical_filter", instrument="DECam")}


def band_lookup(registry):
    """{visit or exposure id: band} for the visits VISIT_QUERY selects.

    `band` is only an implied dimension of raw, calexp and the visit tables, so
    it is read from the visit records (one-to-one: visit id == exposure id).
    """
    bmap = band_map(registry)
    return {r.id: bmap.get(r.physical_filter, r.physical_filter)
            for r in registry.queryDimensionRecords("visit", where=env("VISIT_QUERY"))}


def band_of(data_id, lookup):
    if "band" in data_id.dimensions.required:
        return data_id["band"]
    for key in ("visit", "exposure"):
        if key in data_id.dimensions.required:
            return lookup.get(data_id[key])
    return None


def frac(n, d):
    return n / d if d else 0.0


def pipeline_bands(path):
    """`parameters.bands` of the pipeline YAML (no stack needed)."""
    import yaml

    with open(path) as f:
        doc = yaml.safe_load(f)
    return list(doc.get("parameters", {}).get("bands", []))


def per_band_table(rep, title, expected, found, threshold):
    """Print found/expected per band and flag bands below threshold."""
    rep.out(title)
    rep.out(f"  {'band':6s} {'found':>8s} {'expected':>9s} {'frac':>6s}")
    for band in sorted(expected, key=lambda b: (len(b), b)):
        n, d = found.get(band, 0), expected[band]
        f = frac(n, d)
        flag = "" if f >= threshold else f"   below {threshold:.2f}"
        rep.out(f"  {band:6s} {n:8d} {d:9d} {f:6.2f}{flag}")
        if f < threshold:
            rep.error(f"{title.strip(':')}: band {band} has {n}/{d} ({f:.2f} < {threshold})")


def parse_region(text):
    """sphgeom region of a REGION string, with the butler's semantics."""
    import lsst.sphgeom as sg

    m = re.fullmatch(r"\s*(CIRCLE|BOX|POLYGON)\s*\(([^)]*)\)\s*", text)
    if not m:
        raise ValueError(f"cannot parse REGION {text!r}")
    kind, args = m.group(1), [float(a) for a in m.group(2).split(",")]
    if kind == "CIRCLE":
        ra, dec, r = args
        return sg.Circle(sg.UnitVector3d(sg.LonLat.fromDegrees(ra, dec)), sg.Angle.fromDegrees(r))
    if kind == "BOX":
        ra, dec, w, h = args
        return sg.Box(sg.LonLat.fromDegrees(ra, dec), sg.Angle.fromDegrees(w / 2), sg.Angle.fromDegrees(h / 2))
    return sg.ConvexPolygon([sg.UnitVector3d(sg.LonLat.fromDegrees(args[i], args[i + 1]))
                             for i in range(0, len(args), 2)])


# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------

def cmd_preflight(args):
    rep = Report()
    butler = get_butler()
    registry = butler.registry
    bands = env_list("BANDS")

    # Bands: everything the conf selects must be configured in the pipeline,
    # or isolatedStarAssociation, the merge tasks and the metrics drop it.
    pipe_bands = pipeline_bands(env("PIPELINE"))
    missing = [b for b in bands if b not in pipe_bands]
    if missing:
        rep.error(f"BANDS {missing} are not in parameters.bands of {env('PIPELINE')} ({pipe_bands})")
    else:
        rep.out(f"ok       bands {bands} are all in the pipeline's parameters.bands")

    # Collections.
    inputs = env_list("DRP_INPUTS", ",")
    overscan = env("OVERSCAN_COLLECTION")
    needed = [n for n in inputs if n != overscan] + [env("RAW_COLLECTION"), env("REFCAT_COLLECTION"), "skymaps"]
    skip_in = env("OVERSCAN_SKIP_EXISTING_IN", "")
    if skip_in:
        needed.append(skip_in)
    for name in dict.fromkeys(needed):
        if collection_exists(registry, name):
            rep.out(f"ok       collection {name} ({registry.getCollectionType(name).name})")
        else:
            rep.error(f"collection {name} does not exist")
    rep.out(f"info     {overscan} {'exists' if collection_exists(registry, overscan) else 'will be created by step0'}")
    output = env("OUTPUT_COLLECTION")
    if collection_exists(registry, output):
        runs = list(registry.getCollectionChain(output)) if registry.getCollectionType(output).name == "CHAINED" else []
        rep.out(f"info     {output} exists with {len(runs)} children; reruns add RUNs and skip finished quanta")
    else:
        rep.out(f"info     {output} will be created by step1")

    # Skymap and reference catalog over the region.
    skymap = env("SKYMAP")
    if list(registry.queryDatasets("skyMap", collections="skymaps", where=f"skymap='{skymap}'")):
        rep.out(f"ok       skymap {skymap}")
    else:
        rep.error(f"skymap {skymap} not found in 'skymaps'")
    refcat = env("REFCAT")
    try:
        from lsst.sphgeom import HtmPixelization

        region = parse_region(env("REGION"))
        dt = registry.getDatasetType(refcat)
        htm = next(n for n in dt.dimensions.names if n.startswith("htm"))
        shards = [i for lo, hi in HtmPixelization(int(htm[3:])).envelope(region) for i in range(lo, hi)]
        found = {ref.dataId[htm] for ref in registry.queryDatasets(
            refcat, collections=env("REFCAT_COLLECTION"),
            where=f"{htm} IN ({','.join(str(s) for s in shards)})")}
        if found:
            rep.out(f"ok       {refcat}: {len(found)}/{len(shards)} {htm} shards over the region")
        else:
            rep.error(f"{refcat} has no shards over the region in {env('REFCAT_COLLECTION')}")
    except Exception as exc:  # report, do not crash the remaining checks
        rep.error(f"reference catalog check failed: {exc}")

    # Visits and raws per band.
    visits = defaultdict(list)
    for rec in registry.queryDimensionRecords("visit", where=env("VISIT_QUERY")):
        visits[rec.physical_filter].append(rec)
    bmap = band_map(registry)
    lookup = band_lookup(registry)
    raws = Counter()
    for ref in registry.queryDatasets("raw", collections=env("RAW_COLLECTION"), where=env("STEP1_QUERY")):
        raws[band_of(ref.dataId, lookup)] += 1
    rep.out("visits touching the region, per physical filter:")
    rep.out(f"  {'physical filter':34s} {'band':5s} {'visits':>6s} {'raws':>7s}  nights         programs")
    by_band_visits = Counter()
    for pf in sorted(visits, key=lambda p: bmap.get(p, p)):
        recs = visits[pf]
        band = bmap.get(pf, "?")
        by_band_visits[band] += len(recs)
        nights = sorted({r.day_obs for r in recs})
        programs = sorted({r.science_program for r in recs})
        rep.out(f"  {pf:34s} {band:5s} {len(recs):6d} {raws.get(band, 0):7d}  "
                f"{nights[0]}-{nights[-1]}  {','.join(programs[:4])}{' ...' if len(programs) > 4 else ''}")
    if not visits:
        rep.error("no visits touch the region with this selection (are visits defined?)")
    for band in bands:
        if not by_band_visits.get(band):
            rep.warn(f"band {band}: no visits touch the region")
        elif not raws.get(band):
            rep.error(f"band {band}: visits but no raws in {env('RAW_COLLECTION')}")

    # Calibrations: for each physical filter, one visit of every night (the
    # certified windows of DECam/calib are per era, so a gap in the middle of
    # a filter's nights would be missed by checking only its ends).
    calib_collections = [n for n in inputs if collection_exists(registry, n)]
    rep.out(f"calibrations (detector {CALIB_DETECTOR}) searched in {calib_collections}:")
    for pf in sorted(visits, key=lambda p: bmap.get(p, p)):
        band = bmap.get(pf, "?")
        types = CALIB_TYPES + (("fringe",) if band in ("z", "y") else ())
        per_night = {}
        for rec in sorted(visits[pf], key=lambda r: r.id):
            per_night.setdefault(rec.day_obs, rec)
        bad = 0
        for night, rec in sorted(per_night.items()):
            missing = []
            for calib in types:
                data_id = {"instrument": "DECam", "detector": CALIB_DETECTOR}
                if calib in ("flat", "fringe"):
                    data_id["physical_filter"] = pf
                try:
                    ref = registry.findDataset(calib, data_id, collections=calib_collections,
                                               timespan=rec.timespan)
                except Exception:
                    ref = None
                if ref is None:
                    missing.append(calib)
            if missing:
                bad += 1
                rep.error(f"{pf} visit {rec.id} (night {night}): no {', '.join(missing)}")
        if not bad:
            rep.out(f"  ok     {pf}: {', '.join(types)} on all {len(per_night)} nights")

    # overscanRaw that step0 still has to build.
    have = existing(registry, [overscan, skip_in] if skip_in else [overscan])
    n_os = 0
    if have:
        n_os = sum(1 for _ in registry.queryDatasets("overscanRaw", collections=have, where=env("STEP1_QUERY"),
                                                     findFirst=True))
    n_raw = sum(raws.values())
    rep.out(f"info     overscanRaw exists for {n_os}/{n_raw} raws; step0 builds the rest")

    return rep.finish(args.summary_file)


# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------

def count_by_band(registry, dataset_type, collections, where, key, lookup):
    """{band: number of distinct key(dataId)} of a dataset type, and the keys."""
    seen = defaultdict(set)
    for ref in registry.queryDatasets(dataset_type, collections=collections, where=where, findFirst=True):
        seen[band_of(ref.dataId, lookup)].add(key(ref.dataId))
    return {band: len(v) for band, v in seen.items()}, seen


def check_step0(rep, registry, lookup):
    where = env("STEP1_QUERY")
    pair = lambda d: (d["exposure"], d["detector"])  # noqa: E731
    expected, _ = count_by_band(registry, "raw", env("RAW_COLLECTION"), where, pair, lookup)
    skip_in = env("OVERSCAN_SKIP_EXISTING_IN", "")
    colls = existing(registry, [env("OVERSCAN_COLLECTION")] + ([skip_in] if skip_in else []))
    found = {}
    if colls:
        found, _ = count_by_band(registry, "overscanRaw", colls, where, pair, lookup)
    per_band_table(rep, "raws with overscanRaw:", expected, found, float(env("STEP0_MIN_FRAC")))


def check_step1(rep, registry, output, lookup):
    where = env("STEP1_QUERY")
    expected, raw_pairs = count_by_band(registry, "raw", env("RAW_COLLECTION"), where,
                                        lambda d: (d["exposure"], d["detector"]), lookup)
    found, seen = count_by_band(registry, "calexp", output, where, lambda d: (d["visit"], d["detector"]),
                                lookup)
    per_band_table(rep, "raws (exposure, detector) with a calexp:", expected, found,
                   float(env("STEP1_MIN_FRAC")))
    # Whole visits lost (every detector failed) are worth a look on their own.
    visits_all = {band: len({e for e, _ in pairs}) for band, pairs in raw_pairs.items()}
    visits_done = {band: len({v for v, _ in pairs}) for band, pairs in seen.items()}
    for band, n in sorted(visits_all.items()):
        if visits_done.get(band, 0) < n:
            rep.warn(f"band {band}: {n - visits_done.get(band, 0)} of {n} visits have no calexp at all")
    for name in ("preSourceTable",):
        n = sum(1 for _ in registry.queryDatasets(name, collections=output, where=where, findFirst=True))
        rep.out(f"info     {name}: {n} datasets")


def check_step2(rep, registry, output, lookup):
    where = env("STEP2_QUERY")
    visit_key = lambda d: d["visit"]  # noqa: E731
    expected, _ = count_by_band(registry, "calexp", output, env("VISIT_QUERY"), visit_key, lookup)
    threshold = float(env("STEP2_MIN_FRAC"))
    for name in ("finalVisitSummary", "sourceTable_visit"):
        found, _ = count_by_band(registry, name, output, env("VISIT_QUERY"), visit_key, lookup)
        per_band_table(rep, f"step1 visits with {name}:", expected, found, threshold)
    # jointcal is per (tract, physical filter); a filter with no fit at all is
    # the usual sign of too few reference stars for a medium band.
    bmap = band_map(registry)
    fits = Counter()
    for ref in registry.queryDatasets("jointcalPhotoCalibCatalog", collections=output, where=where, findFirst=True):
        fits[bmap.get(ref.dataId["physical_filter"])] += 1
    rep.out("jointcal photometric fits (tract x physical filter) per band:")
    for band in sorted(expected, key=lambda b: (len(b), b)):
        rep.out(f"  {band:6s} {fits.get(band, 0):4d}")
        if not fits.get(band):
            rep.error(f"band {band}: no jointcal photometric fit")
    for name in ("visitTable", "ccdVisitTable"):
        if any(True for _ in registry.queryDatasets(name, collections=output, findFirst=True)):
            rep.out(f"ok       {name}")
        else:
            rep.error(f"{name} missing (step2e)")


def check_step3(rep, registry, output, lookup):
    where = env("STEP3_QUERY")
    skymap, region = env("SKYMAP"), env("REGION")
    patches = {(d["tract"], d["patch"]) for d in registry.queryDataIds(
        ["tract", "patch"], where=f"skymap='{skymap}' AND patch.region OVERLAPS {region}")}
    bands = env_list("BANDS")
    expected = {band: len(patches) for band in bands}
    found, seen = count_by_band(registry, "deepCoadd", output, where, lambda d: (d["tract"], d["patch"]),
                                lookup)
    per_band_table(rep, f"region patches ({len(patches)}) with a deepCoadd:", expected, found,
                   float(env("STEP3_MIN_FRAC")))
    tracts = {t for pairs in seen.values() for t, _ in pairs}
    have = {ref.dataId["tract"] for ref in registry.queryDatasets(
        "objectTable_tract", collections=output, where=f"skymap='{skymap}'", findFirst=True)}
    for tract in sorted(tracts):
        if tract in have:
            rep.out(f"ok       objectTable_tract tract {tract}")
        else:
            rep.error(f"objectTable_tract missing for tract {tract}")


def cmd_check(args):
    rep = Report()
    registry = get_butler().registry
    output = env("OUTPUT_COLLECTION")
    rep.out(f"check step{args.step} for field {env('FIELD')} in {output}")
    if args.step != 0 and not collection_exists(registry, output):
        rep.error(f"{output} does not exist")
        return rep.finish(args.summary_file)
    lookup = band_lookup(registry)
    {0: lambda: check_step0(rep, registry, lookup),
     1: lambda: check_step1(rep, registry, output, lookup),
     2: lambda: check_step2(rep, registry, output, lookup),
     3: lambda: check_step3(rep, registry, output, lookup)}[args.step]()
    return rep.finish(args.summary_file)


# ---------------------------------------------------------------------------
# summarize
# ---------------------------------------------------------------------------

def metric_outputs(step):
    """(metric bundle, plot) dataset type names written by stepN-metrics."""
    from lsst.pipe.base import Pipeline

    graph = Pipeline.from_uri(f"{env('PIPELINE')}#step{step}-metrics").to_graph()
    metrics, plots = set(), set()
    for task in graph.tasks.values():
        for edge in task.outputs.values():
            sc = edge.storage_class_name
            if sc == "MetricMeasurementBundle":
                metrics.add(edge.parent_dataset_type_name)
            elif sc == "Plot":
                plots.add(edge.parent_dataset_type_name)
    return sorted(metrics), sorted(plots)


def bundle_rows(dataset_type, ref, bundle, bands, lookup):
    data_id = {k: ref.dataId[k] for k in ref.dataId.dimensions.required}
    id_band = band_of(ref.dataId, lookup)
    for atool, measurements in bundle.items():
        for m in measurements:
            name = str(getattr(m, "metric_name", "") or "")
            name = name.split(".")[-1]
            # Tract-level bundles carry the band in the metric name instead.
            band = id_band or next((b for b in bands if name.startswith(f"{b}_")), "")
            q = m.quantity
            yield {
                "dataset_type": dataset_type,
                "data_id": ";".join(f"{k}={v}" for k, v in data_id.items()),
                "band": band,
                "atool": atool,
                "metric": name,
                "value": float(getattr(q, "value", q)),
                "unit": str(getattr(q, "unit", "")),
            }


def cmd_summarize(args):
    butler = get_butler()
    registry = butler.registry
    output = env("OUTPUT_COLLECTION")
    bands = env_list("BANDS")
    os.makedirs(args.out_dir, exist_ok=True)
    metrics, plots = metric_outputs(args.step)
    print(f"step{args.step}-metrics writes {len(metrics)} metric bundle and {len(plots)} plot dataset types")

    known = {dt.name for dt in registry.queryDatasetTypes()}
    lookup = band_lookup(registry)
    rows = []
    for dataset_type in metrics:
        if dataset_type not in known:
            print(f"  {dataset_type}: not registered (task never ran)")
            continue
        refs = list(registry.queryDatasets(dataset_type, collections=output, findFirst=True))
        print(f"  {dataset_type}: {len(refs)} bundles")
        for ref in refs:
            try:
                rows.extend(bundle_rows(dataset_type, ref, butler.get(ref), bands, lookup))
            except Exception as exc:
                print(f"    could not read {ref.dataId}: {exc}")

    csv_path = os.path.join(args.out_dir, f"step{args.step}_metrics.csv")
    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["dataset_type", "data_id", "band", "atool", "metric", "value",
                                               "unit"])
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {len(rows)} measurements to {csv_path}")

    # Median (and 5-95% range) per metric and band, over visits/detectors/tracts.
    groups = defaultdict(list)
    units = {}
    for r in rows:
        key = (r["dataset_type"], r["atool"], r["metric"], r["band"])
        if r["value"] == r["value"]:  # drop NaN
            groups[key].append(r["value"])
        units[key] = r["unit"]
    band_order = {b: i for i, b in enumerate(bands)}
    lines = [f"{'dataset type':40s} {'atool':32s} {'metric':40s} {'band':5s} {'n':>6s} {'median':>12s}"
             f" {'p05':>12s} {'p95':>12s} unit"]
    for key in sorted(groups, key=lambda k: (k[0], k[1], k[2], band_order.get(k[3], 99), k[3])):
        v = sorted(groups[key])
        p = lambda q: v[min(len(v) - 1, int(q * (len(v) - 1) + 0.5))]  # noqa: E731
        lines.append(f"{key[0]:40s} {key[1]:32s} {key[2]:40s} {key[3]:5s} {len(v):6d} "
                     f"{statistics.median(v):12.5g} {p(0.05):12.5g} {p(0.95):12.5g} {units[key]}")
    summary_path = os.path.join(args.out_dir, f"step{args.step}_summary.txt")
    with open(summary_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines))
    print(f"wrote {summary_path}")

    if args.plots_dir:
        os.makedirs(args.plots_dir, exist_ok=True)
        n = 0
        for dataset_type in plots:
            if dataset_type not in known:
                continue
            refs = list(registry.queryDatasets(dataset_type, collections=output, findFirst=True))
            refs = refs[:args.max_plots_per_type]
            if refs:
                butler.retrieveArtifacts(refs, args.plots_dir, preserve_path=False, overwrite=True)
                n += len(refs)
        print(f"copied {n} plots to {args.plots_dir} (at most {args.max_plots_per_type} per plot type)")
    return 0


# ---------------------------------------------------------------------------
# sky frames
# ---------------------------------------------------------------------------

def cmd_sky_ready(args):
    """Exit 0 if every (physical filter, night) of the visits finds a sky frame."""
    rep = Report()
    registry = get_butler().registry
    collections = existing(registry, env_list("DRP_INPUTS", ","))
    # One visit per (physical filter, night): sky frames are certified per
    # observing run, so checking each night covers every validity window.
    samples = {}
    for rec in registry.queryDimensionRecords("visit", where=env("VISIT_QUERY")):
        samples.setdefault((rec.physical_filter, rec.day_obs), rec)
    by_filter = defaultdict(lambda: [0, 0])
    missing = defaultdict(list)
    for (pf, night), rec in sorted(samples.items()):
        data_id = {"instrument": "DECam", "detector": CALIB_DETECTOR, "physical_filter": pf}
        try:
            ref = registry.findDataset("sky", data_id, collections=collections, timespan=rec.timespan)
        except Exception:
            ref = None
        by_filter[pf][0 if ref is not None else 1] += 1
        if ref is None:
            missing[pf].append(night)
    rep.out(f"sky frames (detector {CALIB_DETECTOR}) per physical filter, nights with / without, "
            f"searched in {collections}:")
    for pf in sorted(by_filter):
        have, lack = by_filter[pf]
        nights = missing.get(pf, [])
        rep.out(f"  {pf:34s} {have:4d} / {lack:4d}"
                + (f"   missing e.g. {nights[:3]}{' ...' if len(nights) > 3 else ''}" if nights else ""))
    if not samples:
        rep.error("no visits selected")
    for pf, nights in sorted(missing.items()):
        rep.error(f"{pf}: no sky frame for {len(nights)} of its nights")
    return rep.finish(args.summary_file)


def cmd_skycorr_dosky(args):
    butler = get_butler()
    registry = butler.registry
    output = env("OUTPUT_COLLECTION")
    if not collection_exists(registry, output):
        print("none")
        return 0
    try:
        ref = registry.findDataset("skyCorr_config", {}, collections=output)
    except Exception:  # dataset type not registered: step2 never ran anywhere
        ref = None
    print("none" if ref is None else str(bool(butler.get(ref).doSky)))
    return 0


# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("preflight", help="read-only prerequisite check")
    p.add_argument("--summary-file")
    p.set_defaults(func=cmd_preflight)

    p = sub.add_parser("check", help="completeness of one step's outputs")
    p.add_argument("--step", type=int, choices=[0, 1, 2, 3], required=True)
    p.add_argument("--summary-file")
    p.set_defaults(func=cmd_check)

    p = sub.add_parser("summarize", help="tabulate one step's analysis_tools metrics")
    p.add_argument("--step", type=int, choices=[1, 2, 3], required=True)
    p.add_argument("--out-dir", required=True)
    p.add_argument("--plots-dir", help="copy the step's plots here")
    p.add_argument("--max-plots-per-type", type=int, default=50)
    p.set_defaults(func=cmd_summarize)

    p = sub.add_parser("sky-ready", help="sky frames exist for every filter and night")
    p.add_argument("--summary-file")
    p.set_defaults(func=cmd_sky_ready)

    p = sub.add_parser("skycorr-dosky", help="doSky of the skyCorr already in OUTPUT_COLLECTION")
    p.set_defaults(func=cmd_skycorr_dosky)

    args = parser.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
