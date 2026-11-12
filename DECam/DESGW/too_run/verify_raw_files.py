#!/usr/bin/env python
"""Check the output of get_raw_images.py: manifest, files on disk, FITS headers.

Fails (exit 1) if

  * the manifest is missing or has no exposures to process,
  * any exposure has status failed or dry_run,
  * a downloaded/present file is missing, has the wrong size, or does not open
    as a multi-extension FITS file whose EXPNUM header matches the manifest,
  * for --propid: a file's PROPID header differs from it,
  * for --exposure-list: an exposure of the list is absent from the manifest, or
    more than --max-not-found-frac of them were not found in the archive.

md5 was already checked against the archive when each file was downloaded; add
--full-md5 to recompute it (slow: reads every byte).

Needs astropy (part of the LSST stack).
"""

import argparse
import csv
import hashlib
import os
import sys
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor

GOOD = {"downloaded", "present"}
ACCOUNTED = GOOD | {"skipped_ingested", "skipped_elsewhere"}


def check_file(path, expnum, size, propid, full_md5, md5sum):
    from astropy.io import fits

    problems = []
    if not os.path.exists(path):
        return [f"{expnum}: file missing: {path}"]
    if size and os.path.getsize(path) != int(size):
        problems.append(f"{expnum}: size {os.path.getsize(path)} != manifest {size}")
    try:
        with fits.open(path) as hdul:
            if len(hdul) < 2:
                problems.append(f"{expnum}: only {len(hdul)} HDU(s)")
            for hdu in hdul:  # touching .header reads every HDU header
                hdu.header
            primary = hdul[0].header
            if int(primary.get("EXPNUM", -1)) != int(expnum):
                problems.append(f"{expnum}: EXPNUM header is {primary.get('EXPNUM')}")
            if propid and str(primary.get("PROPID", "")).strip() != propid:
                problems.append(f"{expnum}: PROPID header is {primary.get('PROPID')}, expected {propid}")
    except Exception as e:  # noqa: BLE001 - any read error is a failed check
        problems.append(f"{expnum}: cannot read FITS file: {e}")
    if full_md5 and md5sum:
        h = hashlib.md5()
        with open(path, "rb") as f:
            for block in iter(lambda: f.read(1 << 20), b""):
                h.update(block)
        if h.hexdigest() != md5sum:
            problems.append(f"{expnum}: md5 mismatch")
    return problems


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--outdir", required=True)
    p.add_argument("--propid")
    p.add_argument("--exposure-list")
    p.add_argument("--max-not-found-frac", type=float, default=0.05)
    p.add_argument("--full-md5", action="store_true")
    p.add_argument("--workers", type=int, default=8)
    args = p.parse_args()

    manifest = os.path.join(args.outdir, "manifest.csv")
    if not os.path.exists(manifest):
        print(f"FAIL: no manifest at {manifest}")
        return 1
    with open(manifest, newline="") as f:
        rows = list(csv.DictReader(f))
    errors, warnings = [], []
    status = Counter(r["status"] for r in rows)
    print("manifest status: " + ", ".join(f"{k}={v}" for k, v in sorted(status.items())))
    if not rows:
        errors.append("manifest is empty: the search matched no exposures")

    for bad in ("failed", "dry_run"):
        for r in rows:
            if r["status"] == bad:
                errors.append(f"{r['expnum']}: status {bad} {r['note']}")

    leftovers = [n for n in os.listdir(args.outdir) if n.endswith(".part")]
    if leftovers:
        errors.append(f"partial downloads left in {args.outdir}: {', '.join(leftovers[:5])}")

    good = [r for r in rows if r["status"] in GOOD]
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        results = pool.map(lambda r: check_file(
            os.path.join(args.outdir, r["filename"]), r["expnum"], r["filesize"],
            args.propid, args.full_md5, r["md5sum"]), good)
        for problems in results:
            errors.extend(problems)
    print(f"checked {len(good)} files on disk")

    not_found = [r["expnum"] for r in rows if r["status"] == "not_found"]
    if args.exposure_list:
        with open(args.exposure_list, newline="") as f:
            wanted = [r["expnum"] for r in csv.DictReader(f)]
        in_manifest = {r["expnum"] for r in rows}
        missing = [e for e in wanted if e not in in_manifest]
        if missing:
            errors.append(f"{len(missing)} listed exposures absent from the manifest, e.g. {missing[:5]}")
        accounted = sum(1 for r in rows if r["status"] in ACCOUNTED)
        print(f"{accounted}/{len(wanted)} listed exposures accounted for "
              f"(downloaded, on disk, or already ingested)")
        if wanted and len(not_found) / len(wanted) > args.max_not_found_frac:
            errors.append(f"{len(not_found)}/{len(wanted)} listed exposures not found in the archive")
    if not_found:
        warnings.append(f"{len(not_found)} not found in the archive: {', '.join(not_found[:10])}"
                        + (" ..." if len(not_found) > 10 else ""))

    by_band = defaultdict(Counter)
    for r in rows:
        by_band[r["band"] or "?"][r["status"]] += 1
    print("band  " + "  ".join(f"{s}" for s in sorted(status)))
    for band in sorted(by_band):
        print(f"{band:4}  " + "  ".join(f"{by_band[band][s]:>{len(s)}}" for s in sorted(status)))

    for w in warnings:
        print(f"WARNING: {w}")
    for e in errors[:50]:
        print(f"ERROR: {e}")
    if len(errors) > 50:
        print(f"... and {len(errors) - 50} more errors")
    print("PASS" if not errors else "FAIL")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
