#!/usr/bin/env python
"""Butler-side checks for the GW-Primo calibrations: medium-band flats and sky frames.

Needs the LSST stack. Settings come from the environment common.sh's load_set
exports (REPO, SET, BANDS, FLAT_QUERY, SKY_QUERY, CALIB_COLLECTION,
CERT_BEGIN/END, FLAT_MIN_EXPOSURES, SKY_MIN_EXPOSURES), so every subcommand
sees the selection the pipetask runs used.

  inventory       read-only: dome flats and sky-frame science exposures per
                  physical filter and night, which have overscanRaw, and what
                  is certified in CALIB_COLLECTION
  check           flat gate before certification (exit 1 on failure): enough
                  dome flats per filter, a flat for every detector in --run, and
                  sanity statistics of the binned flats (warnings only)
  check-sky       the same for sky frames: enough science exposures per filter
                  and a sky frame for every detector in --run
  select-sky      write at most SKY_MAX_EXPOSURES science exposures per filter
                  (from SKY_BASE_QUERY) to --output, spread over nights and
                  pointings, for sets with more exposures than a sky frame needs
  verify-summary  cp_verify's pass/fail per filter and exposure in --run
                  (exit 1 if any filter failed)
  decertify       remove this set's flats (or sky frames, --dataset-type sky)
                  from CALIB_COLLECTION for [CERT_BEGIN, CERT_END); prints what
                  it would do unless --confirm is given
  relink-overscan put every RUN under OVERSCAN_COLLECTION/ that is missing
                  from that chain back at its front (--dry-run: only list
                  them). Every set's overscan writes to the one chain, and
                  pipetask rewrites a chain from what it read moments before,
                  so two runs starting together can drop each other's RUN.

Every subcommand prints what it found.
"""

import argparse
import math
import os
import statistics
import sys
from collections import defaultdict

# A combined, normalized dome flat has a median near 1 on every detector.
# These limits only flag detectors for a look; they do not fail the check.
FLAT_MEDIAN_RANGE = (0.5, 1.5)
MAX_NONFINITE_FRAC = 0.01


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
        sys.exit(f"ERROR: {name} is not set; run through the GW-Primo calib scripts (common.sh load_set)")
    return value


def get_butler(writeable=False):
    from lsst.daf.butler import Butler

    return Butler(env("REPO"), writeable=writeable)


def band_map(registry):
    return {r.name: r.band for r in registry.queryDimensionRecords("physical_filter", instrument="DECam")}


def raw_exposures(registry, query_var="FLAT_QUERY"):
    """{physical_filter: {exposure: set(detectors)}} of the raws a set query selects.

    FLAT_QUERY selects the dome flats, SKY_QUERY the science exposures the sky
    frames are built from.
    """
    where = env(query_var)
    records = {r.id: r for r in registry.queryDimensionRecords("exposure", where=where)}
    found = defaultdict(lambda: defaultdict(set))
    for ref in registry.queryDatasets("raw", collections="DECam/raw/all", where=where):
        exposure = ref.dataId["exposure"]
        found[records[exposure].physical_filter][exposure].add(ref.dataId["detector"])
    return found, records


def dome_flats(registry):
    return raw_exposures(registry, "FLAT_QUERY")


def print_exposure_table(rep, title, exposures, records):
    rep.out(title)
    rep.out(f"  {'physical filter':34s} {'exposures':>9s} {'detectors':>9s}  nights  exptime  programs")
    for pf in sorted(exposures):
        exps = exposures[pf]
        recs = [records[e] for e in exps]
        nights = sorted({r.day_obs for r in recs})
        exptimes = sorted({r.exposure_time for r in recs})
        programs = sorted({r.science_program for r in recs})
        detectors = set().union(*exps.values())
        rep.out(f"  {pf:34s} {len(exps):9d} {len(detectors):9d}  {','.join(map(str, nights))}  "
                f"{','.join(f'{t:g}' for t in exptimes)}  {','.join(programs)}")


def require_run(rep, registry, run):
    from lsst.daf.butler import MissingCollectionError

    if not run:
        rep.error("no RUN given (has the step that writes it run yet?)")
        return False
    try:
        registry.getCollectionType(run)
    except MissingCollectionError:
        rep.error(f"collection {run} does not exist")
        return False
    return True


# ---------------------------------------------------------------------------

def cmd_inventory(args):
    rep = Report()
    registry = get_butler().registry
    bands = env("BANDS").split()
    bmap = band_map(registry)
    for kind, query_var in (("dome flats", "FLAT_QUERY"), ("sky-frame science exposures", "SKY_QUERY")):
        exposures, records = raw_exposures(registry, query_var)
        print_exposure_table(rep, f"set {env('SET')}: {kind} selected by {query_var}", exposures, records)
        for band in bands:
            if not any(bmap.get(pf) == band for pf in exposures):
                rep.warn(f"band {band}: no {kind} in this set's nights")
        have = set()
        try:
            have = {ref.dataId["exposure"] for ref in registry.queryDatasets(
                "overscanRaw", collections=env("OVERSCAN_COLLECTION"), where=env(query_var))}
        except Exception:  # the collection does not exist yet
            pass
        n_exp = sum(len(v) for v in exposures.values())
        rep.out(f"  overscanRaw in {env('OVERSCAN_COLLECTION')}: {len(have)}/{n_exp} exposures")

    calib = env("CALIB_COLLECTION")
    for dataset_type in ("flat", "sky"):
        try:
            assocs = list(registry.queryDatasetAssociations(dataset_type, collections=calib,
                                                            flattenChains=False))
        except Exception:  # the collection does not exist yet
            assocs = []
        if not assocs:
            rep.out(f"{calib}: no certified {dataset_type} yet")
            continue
        spans = defaultdict(set)
        for a in assocs:
            spans[(a.ref.dataId["physical_filter"], str(a.timespan))].add(a.ref.dataId["detector"])
        rep.out(f"{dataset_type} certified in {calib}:")
        for (pf, span), dets in sorted(spans.items()):
            rep.out(f"  {pf:34s} {span}  {len(dets)} detectors")
    return rep.finish(args.summary_file)


def binned_stats(butler, ref):
    """(median, fraction of non-finite pixels) of a binned flat."""
    import numpy as np

    array = butler.get(ref).image.array
    finite = np.isfinite(array)
    frac_bad = 1.0 - finite.mean() if array.size else 1.0
    median = float(np.median(array[finite])) if finite.any() else math.nan
    return median, frac_bad


def cmd_check(args):
    rep = Report()
    butler = get_butler()
    registry = butler.registry
    rep.out(f"flat set {env('SET')}: check of {args.run or '(no RUN)'}")
    flats_in, _ = dome_flats(registry)
    bmap = band_map(registry)
    min_exp = int(env("FLAT_MIN_EXPOSURES"))
    for band in env("BANDS").split():
        if not any(bmap.get(pf) == band for pf in flats_in):
            rep.error(f"band {band}: no dome flats selected; nothing to build")
    if not require_run(rep, registry, args.run):
        return rep.finish(args.summary_file)

    made = defaultdict(set)
    for ref in registry.queryDatasets("flat", collections=args.run):
        made[ref.dataId["physical_filter"]].add(ref.dataId["detector"])
    rep.out(f"  {'physical filter':34s} {'exposures':>9s} {'flats':>6s} {'expected':>8s}")
    for pf in sorted(flats_in):
        exps = flats_in[pf]
        expected = set().union(*exps.values())
        rep.out(f"  {pf:34s} {len(exps):9d} {len(made.get(pf, ())):6d} {len(expected):8d}")
        if len(exps) < min_exp:
            rep.error(f"{pf}: only {len(exps)} dome flats (< FLAT_MIN_EXPOSURES={min_exp})")
        missing = sorted(expected - made.get(pf, set()))
        if missing:
            rep.error(f"{pf}: no flat for detectors {missing}; certifying would leave ISR without one")

    # Sanity of the binned flats.
    stats = defaultdict(dict)
    for ref in registry.queryDatasets("flatBin64", collections=args.run):
        try:
            stats[ref.dataId["physical_filter"]][ref.dataId["detector"]] = binned_stats(butler, ref)
        except Exception as exc:
            rep.warn(f"cannot read flatBin64 {ref.dataId}: {exc}")
    if not stats:
        rep.warn("no flatBin64 in the RUN; skipped the flat statistics")
    lo, hi = FLAT_MEDIAN_RANGE
    rep.out(f"binned-flat medians per filter (detectors flagged outside [{lo}, {hi}] "
            f"or with > {MAX_NONFINITE_FRAC:.0%} non-finite pixels):")
    for pf in sorted(stats):
        medians = [m for m, _ in stats[pf].values() if m == m]
        flagged = sorted(d for d, (m, bad) in stats[pf].items()
                         if not (lo <= m <= hi) or bad > MAX_NONFINITE_FRAC)
        if medians:
            rep.out(f"  {pf:34s} median {statistics.median(medians):.3f}  "
                    f"range {min(medians):.3f}-{max(medians):.3f}  flagged {flagged or 'none'}")
        if flagged:
            rep.warn(f"{pf}: look at detectors {flagged} (flatMosaic64 shows the whole focal plane)")
    return rep.finish(args.summary_file)


def cmd_check_sky(args):
    import numpy as np

    rep = Report()
    butler = get_butler()
    registry = butler.registry
    rep.out(f"set {env('SET')}: sky-frame check of {args.run or '(no RUN)'}")
    science, _ = raw_exposures(registry, "SKY_QUERY")
    bmap = band_map(registry)
    min_exp = int(env("SKY_MIN_EXPOSURES"))
    for band in env("BANDS").split():
        if not any(bmap.get(pf) == band for pf in science):
            # e.g. M517 in the June set: dome flats but no science that run.
            rep.warn(f"band {band}: no science exposures in this set's nights; no sky frame for it")
    if not science:
        rep.error("no science exposures selected; nothing to build")
    if not require_run(rep, registry, args.run):
        return rep.finish(args.summary_file)

    made = defaultdict(dict)
    for ref in registry.queryDatasets("sky", collections=args.run):
        made[ref.dataId["physical_filter"]][ref.dataId["detector"]] = ref
    rep.out(f"  {'physical filter':34s} {'exposures':>9s} {'sky':>5s} {'expected':>8s}  "
            f"{'median':>9s} {'stdev':>9s}  non-finite detectors")
    for pf in sorted(science):
        exps = science[pf]
        expected = set().union(*exps.values())
        if len(exps) < min_exp:
            rep.error(f"{pf}: only {len(exps)} science exposures (< SKY_MIN_EXPOSURES={min_exp})")
        missing = sorted(expected - set(made.get(pf, {})))
        if missing:
            rep.error(f"{pf}: no sky frame for detectors {missing}; doSky would fail for them")
        medians, stdevs, bad = [], [], []
        for detector, ref in sorted(made.get(pf, {}).items()):
            array = butler.get(ref).image.array
            finite = np.isfinite(array)
            if finite.mean() < 1 - MAX_NONFINITE_FRAC:
                bad.append(detector)
            if finite.any():
                medians.append(float(np.median(array[finite])))
                stdevs.append(float(np.std(array[finite])))
        med = f"{statistics.median(medians):9.4g}" if medians else f"{'-':>9s}"
        std = f"{statistics.median(stdevs):9.4g}" if stdevs else f"{'-':>9s}"
        rep.out(f"  {pf:34s} {len(exps):9d} {len(made.get(pf, {})):5d} {len(expected):8d}  "
                f"{med} {std}  {bad or 'none'}")
        if bad:
            rep.warn(f"{pf}: sky frames of detectors {bad} have > {MAX_NONFINITE_FRAC:.0%} non-finite pixels")
    return rep.finish(args.summary_file)


def cmd_select_sky(args):
    """Pick at most SKY_MAX_EXPOSURES exposures per physical filter, spread out.

    Exposures are grouped by (night, 0.5-deg pointing cell); the longest one of
    each group is a candidate, and candidates are taken round-robin over the
    nights, so the list covers as many nights and pointings as the cap allows.
    The same Butler content always gives the same list.
    """
    rep = Report()
    registry = get_butler().registry
    cap = int(env("SKY_MAX_EXPOSURES"))
    # Keyed by id: the query's detector clause must not repeat an exposure.
    records = {r.id: r for r in registry.queryDimensionRecords("exposure", where=env("SKY_BASE_QUERY"))}.values()
    by_filter = defaultdict(lambda: defaultdict(list))
    for r in records:
        dec = r.tracking_dec
        ra_step = 0.5 / max(math.cos(math.radians(dec)), 0.05)
        cell = (round(r.tracking_ra / ra_step), round(dec / 0.5))
        by_filter[r.physical_filter][(r.day_obs, cell)].append(r)
    chosen = []
    rep.out(f"set {env('SET')}: at most {cap} sky-frame exposures per physical filter")
    rep.out(f"  {'physical filter':34s} {'available':>9s} {'chosen':>6s} {'nights':>6s} {'cells':>5s}")
    for pf in sorted(by_filter):
        groups = by_filter[pf]
        # The longest exposure of each (night, cell), then round-robin over nights.
        best = {key: max(recs, key=lambda r: (r.exposure_time, -r.id)) for key, recs in groups.items()}
        by_night = defaultdict(list)
        for (night, cell), r in sorted(best.items()):
            by_night[night].append(r)
        picked = []
        while len(picked) < cap and any(by_night.values()):
            for night in sorted(by_night):
                if by_night[night] and len(picked) < cap:
                    picked.append(by_night[night].pop(0))
        n_avail = sum(len(v) for v in groups.values())
        rep.out(f"  {pf:34s} {n_avail:9d} {len(picked):6d} {len({r.day_obs for r in picked}):6d} "
                f"{len({k[1] for k, v in best.items() if v in picked}):5d}")
        chosen.extend(picked)
    if not chosen:
        rep.error("the query selects no exposures")
        return rep.finish()
    with open(args.output, "w") as f:
        f.write(f"# sky-frame exposures of set {env('SET')}, written by gwprimo_flats.py select-sky\n")
        f.write(f"# from: {env('SKY_BASE_QUERY')}\n")
        f.write(f"# at most {cap} per physical filter; one exposure id per line\n")
        for r in sorted(chosen, key=lambda r: r.id):
            f.write(f"{r.id}\n")
    rep.out(f"wrote {len(chosen)} exposures to {args.output}")
    return rep.finish()


def success_of(stats):
    """cp_verify's SUCCESS flag of a stats dict (None if absent)."""
    for key in ("SUCCESS", "success"):
        if key in stats:
            return bool(stats[key])
    return None


def cmd_verify_summary(args):
    rep = Report()
    butler = get_butler()
    registry = butler.registry
    rep.out(f"flat set {env('SET')}: cp_verify results in {args.run or '(no RUN)'}")
    if not require_run(rep, registry, args.run):
        return rep.finish(args.summary_file)

    per_exp = defaultdict(lambda: [0, 0])
    for ref in registry.queryDatasets("verifyFlatExpStats", collections=args.run):
        ok = success_of(butler.get(ref))
        pf = registry.expandDataId(ref.dataId).records["exposure"].physical_filter
        per_exp[pf][0 if ok else 1] += 1
    runs = list(registry.queryDatasets("verifyFlatStats", collections=args.run))
    if not runs:
        rep.error("no verifyFlatStats: cp_verify did not finish")
    for ref in runs:
        pf = ref.dataId["physical_filter"]
        stats = butler.get(ref)
        ok = success_of(stats)
        passed, failed = per_exp.get(pf, [0, 0])
        rep.out(f"  {pf:34s} {'PASS' if ok else 'FAIL'}   exposures passing {passed}/{passed + failed}")
        if not ok:
            failures = stats.get("FAILURES") or stats.get("failures") or []
            for line in list(failures)[:10]:
                rep.out(f"      {line}")
            rep.error(f"{pf}: cp_verify failed")
    return rep.finish(args.summary_file)


def cmd_decertify(args):
    from lsst.daf.butler import MissingCollectionError, Timespan
    from astropy.time import Time

    rep = Report()
    butler = get_butler(writeable=args.confirm)
    registry = butler.registry
    calib = env("CALIB_COLLECTION")
    try:
        registry.getCollectionType(calib)
    except MissingCollectionError:
        rep.out(f"{calib} does not exist: nothing is certified")
        return rep.finish()
    begin, end = env("CERT_BEGIN"), env("CERT_END")
    timespan = Timespan(Time(begin, scale="tai"), Time(end, scale="tai"))
    bmap = band_map(registry)
    bands = set(env("BANDS").split())
    kind = args.dataset_type
    data_ids = [a.ref.dataId for a in registry.queryDatasetAssociations(kind, collections=calib,
                                                                       flattenChains=False)
                if bmap.get(a.ref.dataId["physical_filter"]) in bands and a.timespan.overlaps(timespan)]
    rep.out(f"{len(data_ids)} certified {kind} of bands {sorted(bands)} overlap [{begin}, {end}) in {calib}")
    if not data_ids:
        return rep.finish()
    if not args.confirm:
        rep.out("dry run: rerun with --confirm to decertify them")
        return rep.finish()
    registry.decertify(calib, kind, timespan, dataIds=data_ids)
    rep.out(f"decertified {len(data_ids)} {kind} for [{begin}, {end})")
    return rep.finish()


def cmd_relink_overscan(args):
    from lsst.daf.butler import CollectionType, MissingCollectionError

    rep = Report()
    butler = get_butler(writeable=not args.dry_run)
    chain = env("OVERSCAN_COLLECTION")
    try:
        linked = set(butler.collections.query(chain, flatten_chains=True))
    except MissingCollectionError:
        rep.out(f"{chain} does not exist: nothing to relink")
        return rep.finish()
    runs = butler.collections.query(f"{chain}/*", collection_types={CollectionType.RUN})
    # Newest first, as pipetask orders the chain.
    missing = sorted((r for r in runs if r not in linked), reverse=True)
    rep.out(f"{len(runs)} RUNs under {chain}/, {len(missing)} missing from the chain")
    for run in missing:
        rep.out(f"  {run}")
    if missing and args.dry_run:
        rep.out("dry run: rerun without --dry-run to prepend them")
    elif missing:
        # prepend_chain locks the chain row; pipetask's own update does not.
        butler.collections.prepend_chain(chain, missing)
        rep.out(f"prepended {len(missing)} RUNs to {chain}")
    return rep.finish()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("inventory", help="read-only state of the set")
    p.add_argument("--summary-file")
    p.set_defaults(func=cmd_inventory)

    p = sub.add_parser("check", help="gate before certification")
    p.add_argument("--run", required=True, help="the cpFlat RUN to check")
    p.add_argument("--summary-file")
    p.set_defaults(func=cmd_check)

    p = sub.add_parser("check-sky", help="sky-frame gate before certification")
    p.add_argument("--run", required=True, help="the cpSky RUN to check")
    p.add_argument("--summary-file")
    p.set_defaults(func=cmd_check_sky)

    p = sub.add_parser("select-sky", help="choose the sky-frame exposures of a capped set")
    p.add_argument("--output", required=True, help="exposure list to write")
    p.set_defaults(func=cmd_select_sky)

    p = sub.add_parser("verify-summary", help="cp_verify pass/fail")
    p.add_argument("--run", required=True, help="the cp_verify RUN to read")
    p.add_argument("--summary-file")
    p.set_defaults(func=cmd_verify_summary)

    p = sub.add_parser("decertify", help="undo this set's certification")
    p.add_argument("--dataset-type", choices=["flat", "sky"], default="flat")
    p.add_argument("--confirm", action="store_true")
    p.set_defaults(func=cmd_decertify)

    p = sub.add_parser("relink-overscan", help="put orphaned overscanRaw RUNs back in their chain")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_relink_overscan)

    args = parser.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
