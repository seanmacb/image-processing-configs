#!/usr/bin/env python
"""Download each config event's GraceDB Bilby skymap to <skymap_dir>/<label>.fits.

plot_template_psf.py draws the event's 50% and 90% credible contours from these files.
Run it once on a node with internet access (a login node); the plotting job itself
needs no network. Plain standard library, so any Python 3 will do.

The low-latency Bilby.multiorder.fits is preferred; an event that only has offline
reruns gets the highest-numbered Bilby.offline<N>.multiorder.fits, and says so.
Existing files are kept unless --force is given.

    python fetch_event_skymaps.py --config template_psf_events.yaml [--events A,B] [--force]
"""

import argparse
import json
import os
import re
import sys
import urllib.request

import yaml

API = "https://gracedb.ligo.org/api/superevents/{}/files/"


def pick_skymap(files):
    """(name, url) of the preferred Bilby multi-order skymap among a GraceDB file listing."""
    if "Bilby.multiorder.fits" in files:                 # unversioned name = latest version
        return "Bilby.multiorder.fits", files["Bilby.multiorder.fits"]
    offline = {int(m.group(1)): k for k in files
               if (m := re.fullmatch(r"Bilby\.offline(\d+)\.multiorder\.fits", k))}
    if not offline:
        return None, None
    name = offline[max(offline)]
    return name, files[name]


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--config", required=True)
    p.add_argument("--events", default=None, help="comma-separated labels (default: all)")
    p.add_argument("--force", action="store_true", help="re-download existing files")
    args = p.parse_args()

    with open(args.config) as f:
        cfg = yaml.safe_load(f)
    skymap_dir = os.path.expandvars(cfg["skymap_dir"])
    os.makedirs(skymap_dir, exist_ok=True)
    labels = [e["label"] for e in cfg["events"]]
    if args.events:
        wanted = [e.strip() for e in args.events.split(",") if e.strip()]
        unknown = set(wanted) - set(labels)
        if unknown:
            sys.exit(f"events not in {args.config}: {sorted(unknown)}")
        labels = wanted

    failed = []
    for label in labels:
        dest = os.path.join(skymap_dir, f"{label}.fits")
        if os.path.exists(dest) and not args.force:
            print(f"{label}: have {dest}")
            continue
        try:
            with urllib.request.urlopen(API.format(label), timeout=60) as r:
                name, url = pick_skymap(json.load(r))
            if name is None:
                raise RuntimeError("no Bilby multiorder skymap on GraceDB")
            with urllib.request.urlopen(url, timeout=120) as r, open(dest + ".part", "wb") as out:
                out.write(r.read())
            os.replace(dest + ".part", dest)
        except Exception as exc:
            print(f"{label}: FAILED ({type(exc).__name__}: {exc})")
            failed.append(label)
            continue
        note = "" if name == "Bilby.multiorder.fits" else "  (offline rerun; no low-latency Bilby map)"
        print(f"{label}: {name} -> {dest}{note}")
    if failed:
        sys.exit(f"failed: {failed}")


if __name__ == "__main__":
    main()
