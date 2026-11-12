#!/usr/bin/env python
"""Select template exposures from the DELVE exposure table.

Reads DECam/data/delve_dr3qr_combo_v10.csv (one row per exposure; columns used:
expnum, nite, ra, dec, band, exptime, t_eff, psf_fwhm, propid) and keeps the
exposures inside a sky box and a night window, optionally cut on band, t_eff and
seeing. Writes a CSV with one row per selected exposure, which get_raw_images.py
--exposure-list then downloads.

Standard library only, so it also runs outside the LSST stack.

RA_MIN > RA_MAX means the box wraps through RA = 0.
"""

import argparse
import csv
import sys
from collections import Counter, defaultdict

OUT_COLUMNS = ["expnum", "nite", "band", "ra", "dec", "exptime", "t_eff", "psf_fwhm", "propid"]


def _float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def in_ra_range(ra, ra_min, ra_max):
    if ra_min <= ra_max:
        return ra_min < ra < ra_max
    return ra > ra_min or ra < ra_max


def select(args):
    exclude = set(args.exclude_propid)
    bands = set(args.bands)
    selected = {}
    n_rows = 0
    with open(args.csv, newline="") as f:
        for row in csv.DictReader(f):
            n_rows += 1
            ra, dec = _float(row["ra"]), _float(row["dec"])
            if ra is None or dec is None:
                continue
            if not (in_ra_range(ra, args.ra_min, args.ra_max) and args.dec_min < dec < args.dec_max):
                continue
            nite = int(row["nite"])
            if not (args.start <= nite <= args.end):
                continue
            if row["band"] not in bands:
                continue
            if row["propid"] in exclude:
                continue
            t_eff, fwhm = _float(row["t_eff"]), _float(row["psf_fwhm"])
            if args.teff_min is not None and (t_eff is None or t_eff < args.teff_min):
                continue
            if args.fwhm_max is not None and (fwhm is None or fwhm > args.fwhm_max):
                continue
            expnum = int(row["expnum"])
            selected[expnum] = dict(
                expnum=expnum, nite=nite, band=row["band"], ra=ra, dec=dec,
                exptime=row["exptime"], t_eff=row["t_eff"], psf_fwhm=row["psf_fwhm"],
                propid=row["propid"])
    rows = sorted(selected.values(), key=lambda r: (r["band"], r["nite"], r["expnum"]))
    if args.max_per_band:
        per_band = defaultdict(list)
        for r in rows:
            per_band[r["band"]].append(r)
        rows = []
        for band_rows in per_band.values():
            band_rows.sort(key=lambda r: -(_float(r["t_eff"]) or 0.0))
            rows.extend(band_rows[:args.max_per_band])
        rows.sort(key=lambda r: (r["band"], r["nite"], r["expnum"]))
    return rows, n_rows


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--csv", required=True, help="DELVE exposure table")
    p.add_argument("--ra-min", type=float, required=True)
    p.add_argument("--ra-max", type=float, required=True)
    p.add_argument("--dec-min", type=float, required=True)
    p.add_argument("--dec-max", type=float, required=True)
    p.add_argument("--start", type=int, default=0, help="first night, YYYYMMDD (inclusive)")
    p.add_argument("--end", type=int, required=True, help="last night, YYYYMMDD (inclusive)")
    p.add_argument("--bands", nargs="+", default=["g", "r", "i", "z"])
    p.add_argument("--teff-min", type=float, default=None)
    p.add_argument("--fwhm-max", type=float, default=None, help="psf_fwhm cut (arcsec)")
    p.add_argument("--max-per-band", type=int, default=None, help="keep the best t_eff first")
    p.add_argument("--exclude-propid", nargs="*", default=[])
    p.add_argument("--out", required=True)
    args = p.parse_args()

    rows, n_rows = select(args)
    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=OUT_COLUMNS)
        w.writeheader()
        w.writerows(rows)

    per_band = Counter(r["band"] for r in rows)
    nights = {r["nite"] for r in rows}
    print(f"{n_rows} exposures in {args.csv}")
    print(f"{len(rows)} selected -> {args.out} "
          f"(RA {args.ra_min}-{args.ra_max}, Dec {args.dec_min}-{args.dec_max}, "
          f"nights {args.start}-{args.end}, {len(nights)} distinct nights)")
    for band in sorted(per_band):
        print(f"  {band}: {per_band[band]}")
    if not rows:
        print("ERROR: no exposures selected", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
