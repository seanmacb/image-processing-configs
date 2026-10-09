#!/usr/bin/env python
"""Report or reclaim the storage used by the datasets of a butler collection.

With --dry-run: nothing is changed; prints, per dataset type, how many datasets the
collection holds and how much disk they use, marking which types would be kept.

Without --dry-run: permanently deletes (files AND registry entries) every dataset
whose type is not in the keep list. The keep list defaults to template_coadd only;
give --keep one or more times to replace it. You are asked to retype the collection
name before anything is deleted unless --yes is given.

Scope: only RUN collections the named collection owns. For a RUN that is the
collection itself. For a CHAINED collection (e.g. DECam/templates/S250830bp) it is
the child RUNs whose names start with "<collection>/" -- the layout pipetask -o
creates. The shared inputs a chain also lists (DECam/raw/all, DECam/calib/...,
skymaps, refcats/...) are never touched; they are reported as out of scope.

Needs the LSST stack set up, and write access to the repo for deletion.
"""

import argparse
import os
import sys
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

from lsst.daf.butler import Butler, CollectionType
from lsst.resources import ResourcePath

DEFAULT_KEEP = ["template_coadd"]
PRUNE_CHUNK = 2000


def parse_args():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("collection", help="RUN or CHAINED collection, e.g. DECam/templates/S250830bp")
    p.add_argument("--repo", default=os.environ.get("REPO"), help="Butler repo (default: $REPO)")
    p.add_argument("--keep", action="append", metavar="DATASET_TYPE",
                   help=f"dataset type to preserve; repeatable (default: {', '.join(DEFAULT_KEEP)})")
    p.add_argument("--dry-run", action="store_true",
                   help="report sizes only; delete nothing")
    p.add_argument("--yes", action="store_true",
                   help="skip the confirmation prompt (needed for batch jobs)")
    p.add_argument("--threads", type=int, default=16, help="threads used to stat files")
    args = p.parse_args()
    if not args.repo:
        p.error("--repo not given and $REPO is not set")
    args.keep = args.keep or list(DEFAULT_KEEP)
    return args


def owned_runs(butler, collection):
    """(runs to operate on, runs listed but out of scope)."""
    info = butler.collections.get_info(collection)
    if info.type == CollectionType.RUN:
        return [collection], []
    if info.type != CollectionType.CHAINED:
        sys.exit(f"{collection} is a {info.type.name} collection; need RUN or CHAINED.")
    children = butler.collections.query(collection, flatten_chains=True,
                                        collection_types={CollectionType.RUN})
    prefix = collection.rstrip("/") + "/"
    mine = sorted(c for c in children if c.startswith(prefix))
    other = sorted(c for c in children if not c.startswith(prefix))
    return mine, other


def file_size(uri):
    try:
        return uri.size()
    except Exception:
        return None


def ref_bytes(butler, refs, pool):
    """Total on-disk bytes for refs, and how many files couldn't be found."""
    total, missing = 0, 0
    for i in range(0, len(refs), 5000):
        uris = butler.get_many_uris(refs[i:i + 5000], allow_missing=True)
        paths = []
        for ref_uris in uris.values():
            if ref_uris.primaryURI is not None:
                paths.append(ref_uris.primaryURI)
            paths.extend(ref_uris.componentURIs.values())
        for size in pool.map(file_size, paths):
            if size is None:
                missing += 1
            else:
                total += size
    return total, missing


def human(n):
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or unit == "TiB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024


def main():
    args = parse_args()
    butler = Butler(args.repo, writeable=not args.dry_run)

    runs, out_of_scope = owned_runs(butler, args.collection)
    if not runs:
        sys.exit(f"No RUN collections owned by {args.collection}.")
    print(f"Collection: {args.collection}")
    print(f"In scope ({len(runs)} RUN collections):")
    for r in runs:
        print(f"  {r}")
    if out_of_scope:
        print(f"Out of scope, never touched ({len(out_of_scope)} shared RUN collections in the chain):")
        for r in out_of_scope:
            print(f"  {r}")

    by_type = defaultdict(list)
    for dt in sorted(butler.registry.queryDatasetTypes("*"), key=lambda d: d.name):
        refs = butler.query_datasets(dt, collections=runs, find_first=False,
                                     limit=None, explain=False)
        if refs:
            by_type[dt.name] = refs

    keep = set(args.keep)
    absent = sorted(keep - set(by_type))
    if absent:
        print(f"WARNING: preserved types with no datasets in scope: {', '.join(absent)}")

    rows = []
    with ThreadPoolExecutor(args.threads) as pool:
        for name, refs in by_type.items():
            size, missing = ref_bytes(butler, refs, pool)
            rows.append((name, len(refs), size, missing, name in keep))

    rows.sort(key=lambda r: -r[2])
    width = max([len(r[0]) for r in rows] + [12])
    print(f"\n{'dataset type':<{width}}  {'datasets':>9}  {'size':>10}  action")
    for name, n, size, missing, kept in rows:
        note = f"  ({missing} files not found)" if missing else ""
        print(f"{name:<{width}}  {n:>9}  {human(size):>10}  {'KEEP' if kept else 'delete'}{note}")
    keep_bytes = sum(r[2] for r in rows if r[4])
    del_bytes = sum(r[2] for r in rows if not r[4])
    del_types = [r for r in rows if not r[4]]
    print(f"\nkeep:   {human(keep_bytes)} in {sum(r[1] for r in rows if r[4])} datasets")
    print(f"delete: {human(del_bytes)} in {sum(r[1] for r in del_types)} datasets "
          f"across {len(del_types)} dataset types")

    if args.dry_run:
        print("\nDry run: nothing deleted.")
        return
    if not (keep & set(by_type)):
        sys.exit("Refusing to delete: none of the preserved dataset types exist in scope "
                 "(typo in --keep?). Run with --dry-run to inspect.")
    if not del_types:
        print("Nothing to delete.")
        return

    if not args.yes:
        print(f"\nThis PERMANENTLY deletes {human(del_bytes)} of files and their registry entries.")
        if input(f"Retype the collection name ({args.collection}) to proceed: ").strip() != args.collection:
            sys.exit("Aborted.")

    for name, n, *_ in del_types:
        refs = by_type[name]
        for i in range(0, len(refs), PRUNE_CHUNK):
            butler.pruneDatasets(refs[i:i + PRUNE_CHUNK], disassociate=True,
                                 unstore=True, purge=True)
        print(f"deleted {n:>9} {name}", flush=True)
    print(f"Done. Freed about {human(del_bytes)}.")


if __name__ == "__main__":
    main()
