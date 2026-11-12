#!/usr/bin/env python
"""Butler-side checks for the too_run pipeline. Read-only.

Needs the LSST stack. Every subcommand prints what it found and exits 1 if the
check fails, so the verify_*.sh wrappers can be chained with Slurm afterok.

  ingested-expnums    print the expnums (read from a file) that already have an
                      `exposure` record; used to skip downloads
  check-collections   collections (and optionally a refcat) exist in the repo
  check-ingest        every exposure of a manifest is in the Butler with raws
  check-visits        every science exposure of a manifest has a defined visit
  check-datasets      a per-(exposure, detector) dataset type (overscanRaw) exists
                      for the exposures a data query selects
  check-templates     template_coadd exists where the given visits need it
  check-ap            ap_pipe outputs exist for the exposures a data query selects

Expnum sources (--manifest from get_raw_images.py, or --expnums-file holding a
CSV with an `expnum` column or one expnum per line) are interchangeable.
"""

import argparse
import csv
import fnmatch
import os
import re
import sys
from collections import Counter, defaultdict

CHUNK = 400


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


def chunks(items, n=CHUNK):
    items = list(items)
    for i in range(0, len(items), n):
        yield items[i:i + n]


def in_list(name, values):
    return f"{name} IN ({','.join(str(v) for v in values)})"


def get_butler(repo, collections=None):
    from lsst.daf.butler import Butler

    return Butler(repo, collections=collections)


def read_expnums(args, include=None):
    """Expnums from --manifest (rows whose status is in `include`) or --expnums-file."""
    expnums = []
    if getattr(args, "manifest", None):
        with open(args.manifest, newline="") as f:
            for row in csv.DictReader(f):
                if include is None or row["status"] in include:
                    expnums.append(int(row["expnum"]))
    elif getattr(args, "expnums_file", None):
        with open(args.expnums_file) as f:
            text = f.read().splitlines()
        if text and "expnum" in text[0].split(","):
            expnums = [int(r["expnum"]) for r in csv.DictReader(text)]
        else:
            expnums = [int(t.split(",")[0]) for t in text if t.strip()[:1].isdigit()]
    return sorted(set(expnums))


# Statuses of manifest rows that must be in the Butler by the time ingest is done.
WANTED = {"downloaded", "present", "skipped_ingested", "skipped_elsewhere"}


def exposure_records(registry, expnums):
    records = {}
    for chunk in chunks(expnums):
        for rec in registry.queryDimensionRecords(
                "exposure", where=f"instrument='DECam' AND {in_list('exposure', chunk)}"):
            records[rec.id] = rec
    return records


def band_map(registry):
    return {r.name: r.band for r in registry.queryDimensionRecords("physical_filter", instrument="DECam")}


def expected_exposure_detectors(registry, raw_collection, where):
    """Set of (exposure, detector) of the raws a data query selects."""
    pairs = set()
    for ref in registry.queryDatasets("raw", collections=raw_collection, where=where):
        pairs.add((ref.dataId["exposure"], ref.dataId["detector"]))
    return pairs


# ---------------------------------------------------------------------------
# subcommands
# ---------------------------------------------------------------------------

def cmd_ingested_expnums(args):
    butler = get_butler(args.repo)
    found = exposure_records(butler.registry, read_expnums(args))
    for e in sorted(found):
        print(e)
    return 0


def cmd_check_collections(args):
    rep = Report()
    butler = get_butler(args.repo)
    registry = butler.registry
    for name in args.collections:
        try:
            kind = registry.getCollectionType(name).name
            rep.out(f"ok       {name} ({kind})")
        except Exception:  # noqa: BLE001 - MissingCollectionError and friends
            rep.error(f"collection not found: {name}")
    if args.refcat:
        try:
            n = sum(1 for _ in registry.queryDatasets(args.refcat, collections=args.refcat_collection).limit(1))
        except Exception:  # noqa: BLE001
            n = 0
        if n:
            rep.out(f"ok       reference catalog {args.refcat} in {args.refcat_collection}")
        else:
            rep.error(f"reference catalog {args.refcat} not found in {args.refcat_collection}")
    return rep.finish()


def cmd_check_ingest(args):
    rep = Report()
    butler = get_butler(args.repo)
    registry = butler.registry
    expnums = read_expnums(args, include=WANTED)
    rep.out(f"checking {len(expnums)} exposures against {args.raw_collection}")
    if not expnums:
        rep.error("no exposures to check")
        return rep.finish()
    records = exposure_records(registry, expnums)
    missing = [e for e in expnums if e not in records]
    if missing:
        rep.error(f"{len(missing)} exposures have no exposure record, e.g. {missing[:10]}")

    n_raw = Counter()
    for chunk in chunks([e for e in expnums if e in records]):
        for ref in registry.queryDatasets(
                "raw", collections=args.raw_collection,
                where=f"instrument='DECam' AND {in_list('exposure', chunk)}"):
            n_raw[ref.dataId["exposure"]] += 1
    short = {e: n_raw[e] for e in records if n_raw[e] < args.min_raw}
    if short:
        sample = dict(list(short.items())[:10])
        rep.error(f"{len(short)} exposures have fewer than {args.min_raw} raw datasets: {sample}")
    if n_raw:
        counts = sorted(n_raw.values())
        rep.out(f"raw datasets per exposure: min {counts[0]}, median {counts[len(counts)//2]}, max {counts[-1]}")
    types = Counter(r.observation_type for r in records.values())
    rep.out("observation types: " + ", ".join(f"{k}={v}" for k, v in sorted(types.items())))
    return rep.finish()


def cmd_check_visits(args):
    rep = Report()
    butler = get_butler(args.repo)
    registry = butler.registry
    expnums = read_expnums(args, include=WANTED)
    rep.out(f"checking visits for {len(expnums)} exposures")
    if not expnums:
        rep.error("no exposures to check")
        return rep.finish()
    exposures = exposure_records(registry, expnums)
    science = sorted(e for e, r in exposures.items() if r.observation_type == "science")
    other = len(exposures) - len(science)
    if other:
        rep.out(f"{other} exposures are not 'science' and get no visit (expected)")
    if not science:
        rep.error("none of the exposures is a science exposure")
        return rep.finish()

    visits, n_det = {}, Counter()
    for chunk in chunks(science):
        where = f"instrument='DECam' AND {in_list('visit', chunk)}"
        for rec in registry.queryDimensionRecords("visit", where=where):
            visits[rec.id] = rec
        for rec in registry.queryDimensionRecords("visit_detector_region", where=where):
            n_det[rec.visit] += 1
    missing = [e for e in science if e not in visits]
    if missing:
        rep.error(f"{len(missing)} science exposures have no visit defined, e.g. {missing[:10]}")
    no_region = [v for v, r in visits.items() if r.region is None]
    if no_region:
        rep.error(f"{len(no_region)} visits have no region, e.g. {no_region[:10]}")
    no_det = [v for v in visits if n_det[v] == 0]
    if no_det:
        rep.error(f"{len(no_det)} visits have no visit_detector_region rows, e.g. {no_det[:10]}")
    if n_det:
        counts = sorted(n_det[v] for v in visits)
        rep.out(f"detector regions per visit: min {counts[0]}, max {counts[-1]}")

    bands = band_map(registry)
    table = Counter(bands.get(r.physical_filter, r.physical_filter) for r in visits.values())
    rep.out("visits per band: " + ", ".join(f"{k}={v}" for k, v in sorted(table.items())))
    if args.target_name:
        names = Counter(exposures[e].target_name for e in science)
        rep.out("target names: " + ", ".join(f"{k}={v}" for k, v in names.most_common(8)))
        if names[args.target_name] == 0:
            rep.error(f"no science exposure has target_name {args.target_name}: wrong propid or night?")
        elif names[args.target_name] < len(science):
            rep.warn(f"{len(science) - names[args.target_name]} science exposures have another target_name")
    return rep.finish()


def cmd_check_datasets(args):
    rep = Report()
    butler = get_butler(args.repo)
    registry = butler.registry
    expected = expected_exposure_detectors(registry, args.raw_collection, args.where)
    rep.out(f"{len(expected)} (exposure, detector) pairs selected by the query "
            f"over {len({e for e, _ in expected})} exposures")
    if not expected:
        rep.error("the data query selects no raw datasets (nothing ingested, or wrong query)")
        return rep.finish()
    found = set()
    for ref in registry.queryDatasets(args.dataset_type, collections=args.collections, where=args.where,
                                      findFirst=True):
        found.add((ref.dataId["exposure"], ref.dataId["detector"]))
    missing = expected - found
    frac = len(missing) / len(expected)
    rep.out(f"{args.dataset_type}: {len(expected) - len(missing)}/{len(expected)} present "
            f"({frac:.1%} missing, limit {args.max_missing_frac:.1%})")
    if missing:
        by_exp = Counter(e for e, _ in missing)
        rep.out("most affected exposures: " + ", ".join(f"{e}({n})" for e, n in by_exp.most_common(8)))
    if frac > args.max_missing_frac:
        rep.error(f"too many missing {args.dataset_type} datasets")
    return rep.finish()


def to_spherepoint(vertex):
    import lsst.geom as geom
    import lsst.sphgeom as sphgeom

    ll = sphgeom.LonLat(vertex)
    return geom.SpherePoint(ll.getLon().asRadians(), ll.getLat().asRadians(), geom.radians)


def load_skymap(butler, collection):
    registry = butler.registry
    names = [r.name for r in registry.queryDimensionRecords("skymap")]
    if not names:
        raise RuntimeError("no skymap registered in the repo")
    name = "decam_rings_v1" if "decam_rings_v1" in names else names[0]
    return name, butler.get("skyMap", skymap=name, collections=collection)


def needed_patches(registry, skymap, expnums):
    """{band: {(tract, patch)}} covered by the regions of the visits `expnums`."""
    bands = band_map(registry)
    needed = defaultdict(set)
    cache = {}
    for chunk in chunks(expnums):
        for rec in registry.queryDimensionRecords(
                "visit", where=f"instrument='DECam' AND {in_list('visit', chunk)}"):
            if rec.region is None:
                continue
            if rec.id not in cache:
                points = [to_spherepoint(v) for v in rec.region.getVertices()]
                cache[rec.id] = [(t.getId(), t.getSequentialPatchIndex(p))
                                 for t, plist in skymap.findTractPatchList(points) for p in plist]
            needed[bands.get(rec.physical_filter, rec.physical_filter)].update(cache[rec.id])
    return needed


def cmd_check_templates(args):
    rep = Report()
    butler = get_butler(args.repo)
    registry = butler.registry
    expnums = read_expnums(args, include=WANTED)
    rep.out(f"template coverage in {args.collection} for {len(expnums)} exposures (min {args.min_coverage:.0%})")
    if not expnums:
        rep.error("no exposures to check")
        return rep.finish()
    skymap_name, skymap = load_skymap(butler, args.skymap_collection)
    needed = needed_patches(registry, skymap, expnums)
    if not needed:
        rep.error("none of the exposures has a visit region")
        return rep.finish()
    have = defaultdict(set)
    for ref in registry.queryDatasets("template_coadd", collections=args.collection,
                                      where=f"skymap='{skymap_name}'", findFirst=True):
        have[ref.dataId["band"]].add((ref.dataId["tract"], ref.dataId["patch"]))
    rep.out(f"skymap {skymap_name}")
    rep.out("band  needed  present  coverage")
    for band in sorted(needed):
        n_need = len(needed[band])
        n_have = len(needed[band] & have[band])
        cov = n_have / n_need if n_need else 1.0
        rep.out(f"{band:4}  {n_need:6}  {n_have:7}  {cov:7.1%}")
        if cov < args.min_coverage:
            uncovered = sorted(needed[band] - have[band])
            rep.error(f"band {band}: coverage {cov:.1%} below {args.min_coverage:.0%}; "
                      f"e.g. (tract, patch) {uncovered[:5]}")
    return rep.finish()


AP_DATASETS = [
    # (dataset type, name used in the report, argument holding the minimum fraction)
    ("preliminary_visit_image", "calibrated image", "min_isr_frac"),
    ("difference_image", "difference image", "min_diff_frac"),
    ("dia_source_unfiltered", "DIA sources (unfiltered)", None),
    ("dia_source_apdb", "DIA sources (associated)", None),
    ("fakes_goodSeeingDiff_matchDiaSrc", "injected-fake matches", None),
]
AP_METRIC_PATTERNS = ["assocDiaFakesVisitMagBins*", "assocDiaFakesDetectorVisitMagBins*"]


def parse_pipetask_log(path):
    """Last 'Executed N quanta successfully, M failed and K remain out of total T quanta'."""
    if not path or not os.path.exists(path):
        return None
    pattern = re.compile(r"Executed (\d+) quanta successfully, (\d+) failed and (\d+) remain out of total (\d+)")
    last = None
    with open(path, errors="replace") as f:
        for line in f:
            m = pattern.search(line)
            if m:
                last = tuple(int(g) for g in m.groups())
    return last


def cmd_check_ap(args):
    rep = Report()
    butler = get_butler(args.repo)
    registry = butler.registry
    expected = expected_exposure_detectors(registry, args.raw_collection, args.where)
    visits = sorted({e for e, _ in expected})
    rep.out(f"{len(expected)} (visit, detector) pairs selected over {len(visits)} visits; "
            f"outputs read from {args.collection}")
    if not expected:
        rep.error("the data query selects no raw datasets")
        return rep.finish(args.summary_file)

    if args.status_file and os.path.exists(args.status_file):
        with open(args.status_file) as f:
            rep.out(f"pipetask exit status: {f.read().strip()}")
    quanta = parse_pipetask_log(args.log)
    if quanta:
        ok, failed, remain, total = quanta
        rep.out(f"pipetask: {ok} quanta succeeded, {failed} failed, {remain} not run, of {total}")
        if remain:
            rep.error(f"{remain} quanta did not run")

    lo, hi = visits[0], visits[-1]
    for dataset_type, label, frac_arg in AP_DATASETS:
        found = set()
        try:
            for ref in registry.queryDatasets(
                    dataset_type, collections=args.collection, findFirst=True,
                    where=f"instrument='DECam' AND visit >= {lo} AND visit <= {hi}"):
                found.add((ref.dataId["visit"], ref.dataId["detector"]))
        except Exception as e:  # noqa: BLE001 - dataset type not registered (nothing ran)
            rep.out(f"{dataset_type}: cannot query ({type(e).__name__})")
        n = len(found & expected)
        frac = n / len(expected)
        rep.out(f"{label:28} {dataset_type:36} {n:6}/{len(expected)}  {frac:6.1%}")
        minimum = getattr(args, frac_arg) if frac_arg else None
        if minimum is not None and frac < minimum:
            rep.error(f"{dataset_type}: {frac:.1%} of visit-detectors, minimum {minimum:.0%}")
        elif minimum is None and n == 0:
            rep.error(f"no {dataset_type} datasets for these visits")

    all_types = [dt.name for dt in registry.queryDatasetTypes()]
    metric_types = [n for pat in AP_METRIC_PATTERNS for n in fnmatch.filter(all_types, pat)]
    n_metric = 0
    for name in metric_types:
        for ref in registry.queryDatasets(name, collections=args.collection, findFirst=True,
                                          where=f"instrument='DECam' AND visit >= {lo} AND visit <= {hi}"):
            n_metric += 1
    if n_metric == 0:
        rep.warn("no fake-recovery 1-mag-bin metric datasets found")
    else:
        rep.out(f"fake-recovery 1-mag-bin analysis datasets: {n_metric}")
    return rep.finish(args.summary_file)


# ---------------------------------------------------------------------------

def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--repo", default=os.environ.get("REPO"), help="Butler repo (default $REPO)")
    sub = p.add_subparsers(dest="cmd", required=True)

    def add_expnums(sp):
        g = sp.add_mutually_exclusive_group(required=True)
        g.add_argument("--manifest")
        g.add_argument("--expnums-file")

    sp = sub.add_parser("ingested-expnums")
    sp.add_argument("--expnums-file", required=True)
    sp.set_defaults(func=cmd_ingested_expnums)

    sp = sub.add_parser("check-collections")
    sp.add_argument("--collections", nargs="+", required=True)
    sp.add_argument("--refcat", help="reference catalog dataset type that must exist")
    sp.add_argument("--refcat-collection", default="refcats/gen3")
    sp.set_defaults(func=cmd_check_collections)

    sp = sub.add_parser("check-ingest")
    add_expnums(sp)
    sp.add_argument("--raw-collection", default="DECam/raw/all")
    sp.add_argument("--min-raw", type=int, default=50, help="minimum raw datasets per exposure")
    sp.set_defaults(func=cmd_check_ingest)

    sp = sub.add_parser("check-visits")
    add_expnums(sp)
    sp.add_argument("--target-name")
    sp.set_defaults(func=cmd_check_visits)

    sp = sub.add_parser("check-datasets")
    sp.add_argument("--dataset-type", required=True)
    sp.add_argument("--collections", required=True)
    sp.add_argument("--raw-collection", default="DECam/raw/all")
    sp.add_argument("--where", required=True)
    sp.add_argument("--max-missing-frac", type=float, default=0.05)
    sp.set_defaults(func=cmd_check_datasets)

    sp = sub.add_parser("check-templates")
    add_expnums(sp)
    sp.add_argument("--collection", required=True, help="template collection")
    sp.add_argument("--skymap-collection", default="skymaps")
    sp.add_argument("--min-coverage", type=float, default=0.5)
    sp.set_defaults(func=cmd_check_templates)

    sp = sub.add_parser("check-ap")
    sp.add_argument("--collection", required=True, help="ap_pipe output collection")
    sp.add_argument("--raw-collection", default="DECam/raw/all")
    sp.add_argument("--where", required=True)
    sp.add_argument("--min-isr-frac", type=float, default=0.8)
    sp.add_argument("--min-diff-frac", type=float, default=0.7)
    sp.add_argument("--log", help="pipetask log to scan for failed-quantum counts")
    sp.add_argument("--status-file", help="file holding pipetask's exit status")
    sp.add_argument("--summary-file")
    sp.set_defaults(func=cmd_check_ap)

    args = p.parse_args()
    if not args.repo:
        p.error("--repo or $REPO is required")
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
