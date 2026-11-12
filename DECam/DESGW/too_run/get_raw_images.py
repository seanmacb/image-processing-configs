#!/usr/bin/env python
"""Download raw DECam exposures from the NOIRLab Astro Data Archive.

Two ways to say what to fetch:

  --exposure-list CSV     a list of exposures (columns expnum, nite; the output
                          of select_template_exposures.py). One archive query is
                          made per night, not per exposure.
  --propid P --night N    every raw object exposure of program P on night N
                          (YYYYMMDD).

The archive search is anonymous; no credentials are used. Files are saved as
DECam_<expnum:08d>.fits.fz in --outdir, which is the name the rest of
/shares/.../fitsFiles/desgw already uses. Each file is downloaded to a .part
file, checked against the archive's size and md5, then renamed, so an
interrupted run never leaves a truncated file behind and a re-run only fetches
what is missing.

A manifest.csv (one row per exposure that should be in the Butler for this
run) is written to --outdir. Its `status` column is one of

  downloaded           fetched by this run
  present              already in --outdir, size matches the archive
  skipped_ingested     expnum listed in --skip-expnums (already in the Butler)
  skipped_elsewhere    DECam_<expnum>.fits.fz exists in a --skip-dir
  not_found            not returned by the archive search
  failed               download or checksum error (see `note`)

Standard library only. Exit status is 1 if any download failed.
"""

import argparse
import csv
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta

ARCHIVE = "https://astroarchive.noirlab.edu/api"
OUTFIELDS = ["md5sum", "archive_filename", "url", "filesize", "EXPNUM", "caldat",
             "proposal", "ifilter", "obs_type", "proc_type", "instrument"]
MANIFEST_COLUMNS = ["expnum", "filename", "md5sum", "filesize", "band", "propid",
                    "caldat", "status", "note"]
SEARCH_LIMIT = 5000
CHUNK = 1 << 20


def log(msg):
    print(f"[{time.strftime('%F %T')}] {msg}", flush=True)


def iso(night):
    """YYYYMMDD (str or int) -> YYYY-MM-DD."""
    n = str(night)
    return f"{n[:4]}-{n[4:6]}-{n[6:]}"


def shift_night(night, days):
    d = datetime.strptime(str(night), "%Y%m%d") + timedelta(days=days)
    return d.strftime("%Y%m%d")


def _request(req, retries, timeout):
    delay = 5
    for attempt in range(retries + 1):
        try:
            return urllib.request.urlopen(req, timeout=timeout)
        except urllib.error.HTTPError as e:
            # 4xx other than 429 will not get better by retrying.
            if e.code < 500 and e.code != 429:
                raise
            err = e
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            err = e
        if attempt == retries:
            raise err
        time.sleep(delay)
        delay = min(delay * 2, 120)


def search(night_from, night_to, propid=None, retries=4):
    """Raw DECam object exposures with caldat in [night_from, night_to]."""
    criteria = [
        ["instrument", "decam"],
        ["proc_type", "raw"],
        ["obs_type", "object"],
        ["caldat", iso(night_from), iso(night_to)],
    ]
    if propid:
        criteria.append(["proposal", propid])
    payload = json.dumps({"outfields": OUTFIELDS, "search": criteria}).encode()
    req = urllib.request.Request(
        f"{ARCHIVE}/adv_search/find/?rectype=file&limit={SEARCH_LIMIT}",
        data=payload, headers={"Content-Type": "application/json"})
    with _request(req, retries, timeout=120) as resp:
        data = json.load(resp)
    rows = data[1:]  # first element is the response header
    if len(rows) >= SEARCH_LIMIT:
        log(f"WARNING: search returned {len(rows)} rows (the limit); results may be truncated")
    hits = {}
    for r in rows:
        try:
            hits.setdefault(int(r["EXPNUM"]), r)
        except (KeyError, TypeError, ValueError):
            continue
    return hits


def entry_from_hit(hit):
    return dict(
        expnum=int(hit["EXPNUM"]), filename="", md5sum=hit.get("md5sum", ""),
        filesize=hit.get("filesize", ""), band=str(hit.get("ifilter", "")).split(" ")[0],
        propid=hit.get("proposal", ""), caldat=hit.get("caldat", ""), status="", note="")


def download(hit, dest, retries=3):
    """Fetch hit['url'] to dest via dest.part, checking size and md5. Returns note."""
    part = dest + ".part"
    last = ""
    for attempt in range(retries + 1):
        try:
            md5 = hashlib.md5()
            size = 0
            with _request(urllib.request.Request(hit["url"]), 3, timeout=300) as resp, \
                    open(part, "wb") as out:
                while True:
                    block = resp.read(CHUNK)
                    if not block:
                        break
                    out.write(block)
                    md5.update(block)
                    size += len(block)
            if hit.get("filesize") and size != int(hit["filesize"]):
                raise OSError(f"size {size} != archive size {hit['filesize']}")
            if hit.get("md5sum") and md5.hexdigest() != hit["md5sum"]:
                raise OSError(f"md5 {md5.hexdigest()} != archive md5 {hit['md5sum']}")
            os.replace(part, dest)
            return ""
        except urllib.error.HTTPError as e:
            last = f"HTTP {e.code} {e.reason}" + (" (proprietary data?)" if e.code in (401, 403) else "")
            if e.code < 500 and e.code != 429:
                break
        except (OSError, urllib.error.URLError) as e:
            last = str(e)
        time.sleep(10 * (attempt + 1))
    if os.path.exists(part):
        os.remove(part)
    return last


def read_exposure_list(path):
    wanted = {}
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            wanted[int(row["expnum"])] = str(row["nite"])
    return wanted


def read_expnum_file(path):
    if not path or not os.path.exists(path):
        return set()
    with open(path) as f:
        return {int(line.split(",")[0]) for line in f
                if line.strip() and line.split(",")[0].strip().isdigit()}


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--outdir", required=True)
    p.add_argument("--exposure-list", help="CSV with expnum and nite columns")
    p.add_argument("--propid")
    p.add_argument("--night", help="YYYYMMDD; with --propid")
    p.add_argument("--skip-expnums", help="file of expnums already in the Butler, one per line")
    p.add_argument("--skip-dir", action="append", default=[],
                   help="directory holding DECam_<expnum>.fits.fz files to reuse (repeatable)")
    p.add_argument("--workers", type=int, default=4)
    p.add_argument("--dry-run", action="store_true",
                   help="search and write the manifest, but download nothing")
    args = p.parse_args()

    if bool(args.exposure_list) == bool(args.propid):
        p.error("give either --exposure-list, or --propid with --night")
    if args.propid and not args.night:
        p.error("--propid needs --night")
    os.makedirs(args.outdir, exist_ok=True)
    skip_expnums = read_expnum_file(args.skip_expnums)

    # Work out which exposures we want and which night to look for each in.
    if args.exposure_list:
        wanted = read_exposure_list(args.exposure_list)
    else:
        wanted = None
    entries = {}
    to_fetch = {}

    def classify(expnum, hit):
        """Fill entries[expnum] and decide whether it needs downloading."""
        e = entry_from_hit(hit) if hit else dict(
            expnum=expnum, filename="", md5sum="", filesize="", band="", propid="",
            caldat="", status="", note="")
        entries[expnum] = e
        if expnum in skip_expnums:
            e["status"] = "skipped_ingested"
            return
        name = f"DECam_{expnum:08d}.fits.fz"
        for d in args.skip_dir:
            if os.path.exists(os.path.join(d, name)):
                e["status"], e["note"] = "skipped_elsewhere", d
                return
        if hit is None:
            e["status"] = "not_found"
            return
        e["filename"] = name
        dest = os.path.join(args.outdir, name)
        if os.path.exists(dest) and os.path.getsize(dest) == int(hit["filesize"]):
            e["status"] = "present"
        else:
            to_fetch[expnum] = (hit, dest)

    if wanted is None:
        log(f"searching archive: propid {args.propid}, night {args.night}")
        hits = search(args.night, args.night, propid=args.propid)
        log(f"{len(hits)} raw exposures found")
        for expnum, hit in sorted(hits.items()):
            classify(expnum, hit)
    else:
        by_night = defaultdict(list)
        for expnum, nite in wanted.items():
            by_night[nite].append(expnum)
        log(f"{len(wanted)} exposures requested over {len(by_night)} nights")
        unmatched = {}
        for i, (nite, expnums) in enumerate(sorted(by_night.items()), 1):
            if expnums and all(e in skip_expnums for e in expnums):
                for e in expnums:
                    classify(e, None)
                continue
            hits = search(nite, nite)
            for e in expnums:
                if e in hits:
                    classify(e, hits[e])
                else:
                    unmatched[e] = nite
            if i % 20 == 0:
                log(f"queried {i}/{len(by_night)} nights")
        # The CSV night and the archive's caldat can differ by a day for exposures
        # taken near the date change; look at the neighbouring nights once.
        if unmatched:
            log(f"{len(unmatched)} exposures not found on their night; trying +/-1 day")
            by_night = defaultdict(list)
            for e, nite in unmatched.items():
                by_night[nite].append(e)
            for nite, expnums in sorted(by_night.items()):
                hits = search(shift_night(nite, -1), shift_night(nite, 1))
                for e in expnums:
                    classify(e, hits.get(e))

    n = defaultdict(int)
    for e in entries.values():
        if e["status"]:
            n[e["status"]] += 1
    n["to_download"] = len(to_fetch)
    log("plan: " + ", ".join(f"{k}={v}" for k, v in sorted(n.items())))

    n_failed = 0
    if to_fetch and not args.dry_run:
        total = len(to_fetch)
        log(f"downloading {total} files with {args.workers} workers")
        with ThreadPoolExecutor(max_workers=args.workers) as pool:
            futures = {pool.submit(download, hit, dest): expnum
                       for expnum, (hit, dest) in sorted(to_fetch.items())}
            for done, fut in enumerate(as_completed(futures), 1):
                expnum = futures[fut]
                note = fut.result()
                if note:
                    entries[expnum]["status"], entries[expnum]["note"] = "failed", note
                    n_failed += 1
                    log(f"FAILED {expnum}: {note}")
                else:
                    entries[expnum]["status"] = "downloaded"
                if done % 10 == 0 or done == total:
                    log(f"{done}/{total} done ({n_failed} failed)")
    elif to_fetch:
        for expnum in to_fetch:
            entries[expnum]["status"] = "dry_run"

    manifest = os.path.join(args.outdir, "manifest.csv")
    with open(manifest, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=MANIFEST_COLUMNS)
        w.writeheader()
        for expnum in sorted(entries):
            w.writerow({k: entries[expnum].get(k, "") for k in MANIFEST_COLUMNS})
    counts = defaultdict(int)
    for e in entries.values():
        counts[e["status"]] += 1
    log(f"manifest {manifest}: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    return 1 if n_failed else 0


if __name__ == "__main__":
    sys.exit(main())
