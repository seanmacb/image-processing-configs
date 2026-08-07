#!/usr/bin/env python3
"""
apply_custom_filters.py

Container-build-time equivalent of the text edits made by
utilities/ansible/roles/lsst_custom_filters/tasks/obs_decam.yml and
skymap.yml (ansible's blockinfile tasks), for use from lsst_pipeline.def's
%post. Run once per fresh git clone during the image build - not meant to
be idempotent/re-runnable against an already-patched checkout.

USAGE:
    apply_custom_filters.py obs_decam --filters-file filters.yaml --repo-dir /opt/repos/obs_decam
    apply_custom_filters.py skymap    --filters-file filters.yaml --repo-dir /opt/repos/skymap
"""
import argparse
import pathlib
import re
import sys

import yaml

MARKER_START = "# BEGIN - lsst_custom_filters (apply_custom_filters.py)"
MARKER_END = "# END - lsst_custom_filters (apply_custom_filters.py)"


def load_filters(path):
    with open(path) as fh:
        return yaml.safe_load(fh)


def patch_obs_decam(repo_dir, filters):
    repo_dir = pathlib.Path(repo_dir)

    # decamFilters.py: no fixed anchor to insert into (DECAM_FILTER_DEFINITIONS
    # is a literal tuple expression) - instead append a module-level
    # reassignment at EOF that rebuilds it from the existing value, same
    # trick the ansible blockinfile task (no insertafter/insertbefore, so it
    # defaults to appending at end of file) relies on.
    decam_filters_path = repo_dir / "python/lsst/obs/decam/decamFilters.py"
    entries = "\n".join(
        f'    FilterDefinition(physical_filter="{f["physical_filter"]}", band="{f["band"]}"),'
        for f in filters
    )
    block = (
        f"\n{MARKER_START}\n"
        "DECAM_FILTER_DEFINITIONS = FilterDefinitionCollection(\n"
        "    *DECAM_FILTER_DEFINITIONS,\n"
        f"{entries}\n"
        ")\n"
        f"{MARKER_END}\n"
    )
    with open(decam_filters_path, "a") as fh:
        fh.write(block)

    # filterMap.py: insert right after "config.filterMap = {".
    filter_map_path = repo_dir / "config/filterMap.py"
    anchor = "config.filterMap = {"
    text = filter_map_path.read_text()
    if anchor not in text:
        sys.exit(f"ERROR: {filter_map_path} is missing expected anchor '{anchor}'")
    entries = "\n".join(
        f'    "{f["band"]}": "{f["filter_map_target"]}",' for f in filters
    )
    insertion = f"{MARKER_START}\n{entries}\n{MARKER_END}\n"
    text = text.replace(anchor, f"{anchor}\n{insertion}", 1)
    filter_map_path.write_text(text)

    print(f"obs_decam: patched {decam_filters_path} and {filter_map_path}")


def patch_skymap(repo_dir, filters):
    repo_dir = pathlib.Path(repo_dir)
    packers_path = repo_dir / "python/lsst/skymap/packers.py"

    # No trailing $ - the real line has a "# DECam narrow-bands" comment
    # after the closing bracket (confirmed against the actual w.2026.30
    # source), same as why the ansible version of this check (skymap.yml)
    # doesn't anchor its grep -qE pattern at the end of the line either.
    anchor_re = re.compile(r'^\s*\+ \[f"N\{d\}" for d in \(419, 540, 708, 964\)\]', re.MULTILINE)
    text = packers_path.read_text()
    match = anchor_re.search(text)
    if not match:
        sys.exit(f"ERROR: {packers_path} is missing expected SUPPORTED_FILTERS anchor line")

    bands = ", ".join(f'"{f["band"]}"' for f in filters)
    insertion = f"\n    {MARKER_START}\n    + [{bands}]\n    {MARKER_END}"
    insert_at = match.end()
    text = text[:insert_at] + insertion + text[insert_at:]
    packers_path.write_text(text)

    print(f"skymap: patched {packers_path}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("target", choices=["obs_decam", "skymap"])
    parser.add_argument("--filters-file", required=True)
    parser.add_argument("--repo-dir", required=True)
    args = parser.parse_args()

    filters = load_filters(args.filters_file)

    if args.target == "obs_decam":
        patch_obs_decam(args.repo_dir, filters)
    else:
        patch_skymap(args.repo_dir, filters)


if __name__ == "__main__":
    main()
