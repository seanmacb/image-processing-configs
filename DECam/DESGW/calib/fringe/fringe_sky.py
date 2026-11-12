#!/usr/bin/env python
"""z-band fringe frames from on-sky science exposures, by observing epoch.

Epochs
------
Fringe epochs follow the DES observing epochs (SVE1 ... Y11, by exposure
number, from the DES season table) and the DECam filter-position log
(DECam-FILTER-POSITIONS-2024.xlsx): z sat in SLOT2-East (cassette3) until
2018-03-26 and in SLOT1-East (cassette1) from then on, apart from 2019-06-05 to
2019-06-20 when it was in SLOT3-East. The 2018 move falls between Y5E2 and Y6,
so it is already an epoch boundary; the 2019 excursion has no z science
exposures in the repo.

DES epochs with too few usable z science exposures in the repo are merged into
a neighbour within the same filter slot, never across the 2018-03-26 move
(SVE1-Y2E1 have none at all; Y4E1 6, Y5E1 5, Y6 10):

  epoch   DES epochs        exposure range       validity
  Y1-Y3   SVE1 .. Y3        133757 - 516846      2012-09-11 -> 2016-08-13
  Y4      Y4E1, Y4E2        563912 - 622099      2016-08-13 -> 2017-08-03
  Y5      Y5E1, Y5E2        664648 - 724479      2017-08-03 -> 2018-09-08
  Y6-Y11  Y6, Y11           770843 - (open)      2018-09-08 -> (open)

A merged epoch takes every exposure from its first DES epoch's MINEXPNUM to its
last one's MAXEXPNUM, so non-DES exposures between two merged DES epochs count
too. Validity is contiguous: each epoch is certified from its first night up to
the next epoch's first night, so exposures between DES seasons get the
preceding epoch's fringe. Night boundaries are 12:00 UTC (Chilean daytime): a
00:00 UTC boundary would cut the previous night in two.

Subcommands
-----------
  select         choose each epoch's exposures, write <epoch>.exposures
  query          print the data query for an epoch (from its .exposures file)
  overscan-gaps  raws of the epoch's exposures with no overscanRaw in
                 --collection; --where-out writes a clause leaving them out
  check          gate before certification: a fringe for every detector in
                 the latest RUN of the epoch's output collection
  certify        decertify every z fringe in DECam/calib over the span the
                 epochs cover, then certify each epoch's RUN for its window;
                 dry run unless --confirm

Selection, per epoch
--------------------
  * observation_type 'science', band z, raw in DECam/raw/all, exposure number in
    the epoch's range, exposure_time >= --min-exptime (the fringe amplitude is a
    fixed fraction of the sky, so short frames add mostly read noise);
  * at most --per-cell exposures per 0.5-deg pointing cell, from different
    nights and 1-arcmin dither positions first. The combine rejects each frame's
    DETECTED pixels, so a field observed hundreds of times at one position
    (OMLApex in Y11: ~600 exposures at 4 positions) would leave its stars
    masked in most inputs and dominate any unmasked halo light;
  * at most --max-exposures in all, round-robin over nights.
The same Butler content always gives the same lists.
"""

import argparse
import math
import os
import sys
from collections import defaultdict

REPO = os.environ.get("REPO", "/shares/soares-santos.physik.uzh/ButlerProjects/desgw_postgres")
RAW_COLLECTION = "DECam/raw/all"
CALIB_COLLECTION = "DECam/calib"
OUTPUT_PREFIX = "DECam/calib/fringe/sky"
HERE = os.path.dirname(os.path.abspath(__file__))
MIN_EXPOSURES = 20
N_DETECTORS = 62
PHYSICAL_FILTER = "z DECam SDSS c0004 9260.0 1520.0"

# name, DES epochs merged, first exposure, last exposure (None: open), first night
EPOCHS = [
    ("Y1-Y3", "SVE1 SVE2 Y1E1 Y1E2 Y2E1 Y2E2 Y3", 133757, 516846, 20120911),
    ("Y4", "Y4E1 Y4E2", 563912, 622099, 20160813),
    ("Y5", "Y5E1 Y5E2", 664648, 724479, 20170803),
    ("Y6-Y11", "Y6 Y11", 770843, None, 20180908),
]
NAMES = [e[0] for e in EPOCHS]


def epoch(name):
    return next(e for e in EPOCHS if e[0] == name)


def night_iso(night):
    s = str(night)
    return f"{s[:4]}-{s[4:6]}-{s[6:]}T12:00:00"


def window(name):
    """(begin, end) ISO strings in TAI; end is None for the open last epoch."""
    i = NAMES.index(name)
    begin = night_iso(EPOCHS[i][4])
    end = night_iso(EPOCHS[i + 1][4]) if i + 1 < len(EPOCHS) else None
    return begin, end


def butler(writeable=False):
    from lsst.daf.butler import Butler

    return Butler(REPO, writeable=writeable)


def list_path(name, outdir=HERE):
    return os.path.join(outdir, f"{name}.exposures")


def read_list(name):
    path = list_path(name)
    if not os.path.exists(path):
        sys.exit(f"{path} does not exist: run `fringe_sky.py select --epochs {name}` first")
    with open(path) as f:
        ids = [int(line) for line in f if line.strip() and not line.startswith("#")]
    if not ids:
        sys.exit(f"{path} lists no exposures")
    return ids


def epoch_query(name):
    ids = ",".join(map(str, read_list(name)))
    return f"instrument='DECam' AND band='z' AND exposure IN ({ids})"


def cell_of(r, size_deg):
    dec = r.tracking_dec
    ra_step = size_deg / max(math.cos(math.radians(dec)), 0.05)
    return (round(r.tracking_ra / ra_step), round(dec / size_deg))


def pick(records, per_cell, cap):
    """Per-cell cap (spread over nights and dithers), then a total cap over nights."""
    by_cell = defaultdict(list)
    for r in records:
        by_cell[cell_of(r, 0.5)].append(r)
    kept = []
    for cell in sorted(by_cell):
        recs = sorted(by_cell[cell], key=lambda r: (-r.exposure_time, r.id))
        chosen, nights, dithers = [], set(), set()
        # First pass: one per night and dither position; second: fill up to the cap.
        for strict in (True, False):
            for r in recs:
                if len(chosen) >= per_cell:
                    break
                if r in chosen:
                    continue
                d = cell_of(r, 1 / 60)
                if strict and (r.day_obs in nights or d in dithers):
                    continue
                chosen.append(r)
                nights.add(r.day_obs)
                dithers.add(d)
        kept.extend(chosen)
    by_night = defaultdict(list)
    for r in sorted(kept, key=lambda r: (r.day_obs, -r.exposure_time, r.id)):
        by_night[r.day_obs].append(r)
    picked = []
    while len(picked) < cap and any(by_night.values()):
        for night in sorted(by_night):
            if by_night[night] and len(picked) < cap:
                picked.append(by_night[night].pop(0))
    return sorted(picked, key=lambda r: r.id), len(by_cell)


def cmd_select(args):
    registry = butler().registry
    status = 0
    print(f"{'epoch':7s} {'available':>9s} {'usable':>6s} {'chosen':>6s} {'nights':>6s} {'cells':>5s}  file")
    for name, des, lo, hi, _ in EPOCHS:
        if args.epochs and name not in args.epochs:
            continue
        where = (f"instrument='DECam' AND band='z' AND exposure.observation_type='science' "
                 f"AND exposure >= {lo}" + (f" AND exposure <= {hi}" if hi else ""))
        recs = list({r.id: r for r in registry.queryDimensionRecords(
            "exposure", where=where, datasets="raw", collections=RAW_COLLECTION)}.values())
        usable = [r for r in recs if r.exposure_time >= args.min_exptime]
        chosen, n_cells = pick(usable, args.per_cell, args.max_exposures)
        path = list_path(name, args.outdir)
        flag = "" if len(chosen) >= MIN_EXPOSURES else f"  WARNING: fewer than {MIN_EXPOSURES}"
        print(f"{name:7s} {len(recs):9d} {len(usable):6d} {len(chosen):6d} "
              f"{len({r.day_obs for r in chosen}):6d} {n_cells:5d}  "
              f"{'(dry run)' if args.dry_run else path}{flag}")
        if not chosen:
            status = 1
            continue
        if args.dry_run:
            continue
        with open(path, "w") as f:
            f.write(f"# z-band fringe exposures of epoch {name} ({des}), written by fringe_sky.py select\n")
            f.write(f"# from: {where}, raw in {RAW_COLLECTION}\n")
            f.write(f"# exposure_time >= {args.min_exptime:g}, at most {args.per_cell} per 0.5-deg cell, "
                    f"at most {args.max_exposures} in all; one exposure id per line\n")
            for r in chosen:
                f.write(f"{r.id}\n")
    return status


def cmd_query(args):
    print(epoch_query(args.epoch))
    return 0


def cmd_overscan_gaps(args):
    from lsst.daf.butler import MissingCollectionError

    registry = butler().registry
    where = epoch_query(args.epoch)
    raws = {(d["exposure"], d["detector"]) for d in registry.queryDataIds(
        ["exposure", "detector"], datasets="raw", collections=RAW_COLLECTION, where=where)}
    try:
        done = {(d["exposure"], d["detector"]) for d in registry.queryDataIds(
            ["exposure", "detector"], datasets="overscanRaw", collections=args.collection.split(","),
            where=where)}
    except MissingCollectionError:
        done = set()
    missing = sorted(raws - done)
    print(f"epoch {args.epoch}: {len(missing)} of {len(raws)} raws have no overscanRaw in {args.collection}")
    by_exp = defaultdict(list)
    for exposure, detector in missing:
        by_exp[exposure].append(detector)
    for exposure in sorted(by_exp)[:30]:
        print(f"  exposure {exposure}: detectors {by_exp[exposure]}")
    limit = math.ceil(args.max_missing_frac * len(raws))
    if not raws:
        print("ERROR: the epoch's exposures have no raws")
        return 1
    if len(missing) > limit:
        print(f"ERROR: more than {args.max_missing_frac} of the raws ({limit}) lack overscanRaw: "
              "has the overscan step finished?")
        return 1
    if args.where_out:
        with open(args.where_out, "w") as f:
            # CNF on purpose: NOT((exposure=X AND detector=Y) OR ...) makes the butler
            # predicate normalizer expand De Morgan combinatorially (MemoryError).
            f.write(" AND ".join(f"(exposure != {e} OR detector NOT IN ({', '.join(map(str, d))}))"
                                 for e, d in sorted(by_exp.items())))
    return 0


def latest_run(registry, name):
    from lsst.daf.butler import CollectionType, MissingCollectionError

    chain = f"{OUTPUT_PREFIX}/{name}"
    try:
        runs = [c for c in registry.getCollectionChain(chain)
                if registry.getCollectionType(c) == CollectionType.RUN and c.startswith(chain + "/")]
    except MissingCollectionError:
        return None
    return runs[0] if runs else None


def fringe_detectors(registry, run):
    return {ref.dataId["detector"] for ref in registry.queryDatasets(
        "fringe", collections=run, where=f"instrument='DECam' AND physical_filter='{PHYSICAL_FILTER}'")}


def check_epoch(registry, name):
    run = latest_run(registry, name)
    if run is None:
        print(f"{name:7s} no RUN in {OUTPUT_PREFIX}/{name}")
        return None
    dets = fringe_detectors(registry, run)
    missing = sorted(set(range(1, N_DETECTORS + 1)) - dets)
    print(f"{name:7s} {run}: fringe for {len(dets)}/{N_DETECTORS} detectors"
          + (f", missing {missing}" if missing else ""))
    return run if not missing else None


def cmd_check(args):
    registry = butler().registry
    bad = [n for n in (args.epochs or NAMES) if check_epoch(registry, n) is None]
    return 1 if bad else 0


def cmd_certify(args):
    from astropy.time import Time
    from lsst.daf.butler import Timespan

    b = butler(writeable=args.confirm)
    registry = b.registry
    runs = {}
    for name in NAMES:
        runs[name] = check_epoch(registry, name)
    if None in runs.values():
        print("ERROR: every epoch needs a complete RUN before the set is certified "
              "(certifying a partial set leaves ISR without a fringe for the missing ones)")
        return 1

    def tai(s):
        return Time(s, scale="tai") if s else None

    span = Timespan(tai(window(NAMES[0])[0]), None)
    old = [a for a in registry.queryDatasetAssociations("fringe", collections=CALIB_COLLECTION,
                                                         flattenChains=False)
           if a.ref.dataId["physical_filter"] == PHYSICAL_FILTER and a.timespan.overlaps(span)]
    print(f"\n{len(old)} certified z fringes in {CALIB_COLLECTION} overlap [{window(NAMES[0])[0]}, open):")
    for (r, b_, e_), n in sorted(_group(old).items(), key=lambda kv: str(kv[0][1])):
        print(f"  {r}  [{b_}, {e_})  {n}")
    print("\nto certify:")
    for name in NAMES:
        begin, end = window(name)
        print(f"  {name:7s} {runs[name]}  [{begin}, {end or 'open'})")
    if not args.confirm:
        print("\ndry run: rerun with --confirm to decertify the above and certify the new set")
        return 0
    if old:
        registry.decertify(CALIB_COLLECTION, "fringe", span, dataIds=[a.ref.dataId for a in old])
        print(f"decertified {len(old)} z fringes from {window(NAMES[0])[0]} on")
    for name in NAMES:
        begin, end = window(name)
        refs = list(registry.queryDatasets("fringe", collections=runs[name], findFirst=True,
                                           where=f"instrument='DECam' AND physical_filter='{PHYSICAL_FILTER}'"))
        registry.certify(CALIB_COLLECTION, refs, Timespan(tai(begin), tai(end)))
        print(f"certified {len(refs)} fringes of {name} for [{begin}, {end or 'open'})")
    return 0


def _group(assocs):
    out = defaultdict(int)
    for a in assocs:
        t = a.timespan
        out[(a.ref.run, t.begin.isot if t.begin else None, t.end.isot if t.end else None)] += 1
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("select", help="write <epoch>.exposures")
    s.add_argument("--epochs", nargs="+", choices=NAMES)
    s.add_argument("--min-exptime", type=float, default=60.0)
    s.add_argument("--per-cell", type=int, default=3)
    s.add_argument("--max-exposures", type=int, default=300)
    s.add_argument("--outdir", default=HERE)
    s.add_argument("--dry-run", action="store_true", help="print the summary, write nothing")
    s.set_defaults(func=cmd_select)

    s = sub.add_parser("query", help="data query of an epoch")
    s.add_argument("epoch", choices=NAMES)
    s.set_defaults(func=cmd_query)

    s = sub.add_parser("overscan-gaps", help="raws without overscanRaw")
    s.add_argument("epoch", choices=NAMES)
    s.add_argument("--collection", required=True, help="comma-separated collections to look in")
    s.add_argument("--max-missing-frac", type=float, default=0.005)
    s.add_argument("--where-out")
    s.set_defaults(func=cmd_overscan_gaps)

    s = sub.add_parser("check", help="all detectors present in the latest RUN")
    s.add_argument("--epochs", nargs="+", choices=NAMES)
    s.set_defaults(func=cmd_check)

    s = sub.add_parser("certify", help="replace the certified z fringes with the new set")
    s.add_argument("--confirm", action="store_true")
    s.set_defaults(func=cmd_certify)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
