#!/usr/bin/env bash
#
# Step 2 of the source_injection workflow: generate the DESGW pilot injection
# catalogs on disk, one per band.
#   https://pipelines.lsst.io/modules/lsst.source.injection/index.html
#
# Wraps generate_injection_catalog. Parameters come from
# desgw_injection_catalog.yaml; command-line options override the file.
# One catalog is written per band, so magnitudes (and hence colors) can vary
# band to band -- a single catalog ingested against several bands would give
# every band identical fluxes.
#
# Writes <outdir>/injection_catalog_<band>.ecsv plus a manifest.txt that
# ingest_injection_catalog.sh reads.
#
# Example:
#
#   ./make_injection_catalog.sh --outdir ./injection_catalogs
#   ./ingest_injection_catalog.sh --repo $REPO \
#       --output-collection u/${USER}/desgw/pilot/injection_catalog
#
# or in one go:
#
#   ./make_injection_catalog.sh --outdir ./injection_catalogs \
#       --ingest --repo $REPO \
#       --output-collection u/${USER}/desgw/pilot/injection_catalog
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'USAGE_EOF'
Generate DESGW injection catalogs with generate_injection_catalog.

Options:
  --config PATH            Catalog definition YAML.
                           Default: desgw_injection_catalog.yaml beside this script.
  --outdir PATH            Directory for the generated catalogs.
                           Default: ./injection_catalogs
  --bands BAND [BAND ...]  Only generate these bands (must appear in the YAML).
  --ra-lim MIN MAX         Override the RA limits, in degrees.
  --dec-lim MIN MAX        Override the Dec limits, in degrees.
  --mag-lim MIN MAX        Override the magnitude limits for every band.
  --density N              Override sources per square degree.
  --seed N                 Override the Halton sequence seed.
  --format FMT             Output file format. Default: inferred from .ecsv
  --overwrite              Overwrite existing catalog files.

  --ingest                 Run ingest_injection_catalog.sh afterwards.
  --repo PATH              Butler repo (required with --ingest).
  --output-collection COLL Output collection (required with --ingest).

  -n, --dry-run            Print commands instead of running them.
  -h, --help               Show this message.
USAGE_EOF
}

CONFIG="${HERE}/desgw_injection_catalog.yaml"
OUTDIR="./injection_catalogs"
BANDS=()
RA_LIM=()
DEC_LIM=()
MAG_LIM=()
DENSITY=""
SEED=""
FORMAT=""
OVERWRITE=0
DO_INGEST=0
REPO=""
OUTPUT_COLLECTION=""
DRY_RUN=0

# Collect the values following a multi-valued option into the named array.
collect() {
    local -n _target=$1
    shift
    _target=()
    while [[ $# -gt 0 && $1 != -* ]]; do
        _target+=("$1")
        shift
    done
    CONSUMED=${#_target[@]}
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG="$2"; shift 2 ;;
        --outdir) OUTDIR="$2"; shift 2 ;;
        --bands) shift; collect BANDS "$@"; shift "$CONSUMED" ;;
        --ra-lim) shift; collect RA_LIM "$@"; shift "$CONSUMED" ;;
        --dec-lim) shift; collect DEC_LIM "$@"; shift "$CONSUMED" ;;
        --mag-lim) shift; collect MAG_LIM "$@"; shift "$CONSUMED" ;;
        --density) DENSITY="$2"; shift 2 ;;
        --seed) SEED="$2"; shift 2 ;;
        --format) FORMAT="$2"; shift 2 ;;
        --overwrite) OVERWRITE=1; shift ;;
        --ingest) DO_INGEST=1; shift ;;
        --repo) REPO="$2"; shift 2 ;;
        --output-collection) OUTPUT_COLLECTION="$2"; shift 2 ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 2; }

[[ -f "$CONFIG" ]] || die "config not found: $CONFIG"
command -v generate_injection_catalog >/dev/null \
    || die "generate_injection_catalog not on PATH; set up lsst_distrib first"
if [[ $DO_INGEST -eq 1 ]]; then
    [[ -n "$REPO" ]] || die "--repo is required with --ingest"
    [[ -n "$OUTPUT_COLLECTION" ]] || die "--output-collection is required with --ingest"
fi
[[ ${#RA_LIM[@]} -eq 0 || ${#RA_LIM[@]} -eq 2 ]] || die "--ra-lim needs exactly two values"
[[ ${#DEC_LIM[@]} -eq 0 || ${#DEC_LIM[@]} -eq 2 ]] || die "--dec-lim needs exactly two values"
[[ ${#MAG_LIM[@]} -eq 0 || ${#MAG_LIM[@]} -eq 2 ]] || die "--mag-lim needs exactly two values"

# Turn the YAML into one shlex-quoted generate_injection_catalog argument list
# per band, prefixed by the band name and the output filename.
PLAN_FILE="$(mktemp)"
trap 'rm -f "$PLAN_FILE"' EXIT

if ! CFG="$CONFIG" OUTDIR="$OUTDIR" FORMAT="$FORMAT" \
     ONLY_BANDS="${BANDS[*]-}" RA_LIM="${RA_LIM[*]-}" DEC_LIM="${DEC_LIM[*]-}" \
     MAG_LIM="${MAG_LIM[*]-}" DENSITY="$DENSITY" SEED="$SEED" \
     python3 - > "$PLAN_FILE" <<'PY_EOF'
import os
import shlex
import sys

import yaml

cfg = yaml.safe_load(open(os.environ["CFG"]))
if not isinstance(cfg, dict):
    sys.exit(f"error: {os.environ['CFG']} is not a YAML mapping")
outdir = os.environ["OUTDIR"]


def env_list(name):
    raw = os.environ.get(name, "").strip()
    return raw.split() if raw else None


sky = cfg.get("sky") or {}
ra_lim = env_list("RA_LIM") or sky.get("ra_lim")
dec_lim = env_list("DEC_LIM") or sky.get("dec_lim")
if not ra_lim or not dec_lim:
    sys.exit("error: sky.ra_lim and sky.dec_lim must be set in the config or on the command line")

mag_override = env_list("MAG_LIM")
density = os.environ.get("DENSITY") or cfg.get("density")
if not density:
    sys.exit("error: density must be set in the config or via --density")
seed = os.environ.get("SEED") or cfg.get("seed")

defaults = cfg.get("defaults") or {}
bands = cfg.get("bands") or {}
if not bands:
    sys.exit("error: no bands defined in the config")

only = env_list("ONLY_BANDS")
if only:
    missing = [b for b in only if b not in bands]
    if missing:
        sys.exit(f"error: band(s) not in config: {', '.join(missing)}")
    bands = {b: bands[b] for b in only}

fmt = os.environ.get("FORMAT", "").strip()
ext = "ecsv"

for band, spec in bands.items():
    spec = spec or {}
    mag_lim = mag_override or spec.get("mag_lim") or defaults.get("mag_lim")
    if not mag_lim:
        sys.exit(f"error: no mag_lim for band {band} (set it on the band or in defaults)")

    filename = os.path.join(outdir, f"injection_catalog_{band}.{ext}")

    args = [
        "-a", str(ra_lim[0]), str(ra_lim[1]),
        "-d", str(dec_lim[0]), str(dec_lim[1]),
        "-m", str(mag_lim[0]), str(mag_lim[1]),
        "-s", str(density),
    ]

    # Profile parameters: band entry wins over defaults, key by key.
    params = dict(defaults.get("parameters") or {})
    params.update(spec.get("parameters") or {})
    for key, values in params.items():
        if not isinstance(values, list):
            values = [values]
        args += ["-p", str(key)] + [str(v) for v in values]

    if seed is not None:
        args += ["--seed", str(seed)]
    args += ["-f", filename]
    if fmt:
        args += ["--format", fmt]

    print(f"{band}\t{filename}\t{shlex.join(args)}")
PY_EOF
then
    die "could not build a generation plan from $CONFIG"
fi

readarray -t PLAN < "$PLAN_FILE"
[[ ${#PLAN[@]} -gt 0 ]] || die "config produced no bands to generate"

run() {
    printf '+'; printf ' %q' "$@"; printf '\n'
    [[ $DRY_RUN -eq 1 ]] || "$@"
}

if [[ $DRY_RUN -eq 0 ]]; then
    mkdir -p "$OUTDIR"
fi

MANIFEST="${OUTDIR}/manifest.txt"
manifest_lines=()

for line in "${PLAN[@]}"; do
    band="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    filename="${rest%%$'\t'*}"
    argstr="${rest#*$'\t'}"

    if [[ -e "$filename" && $OVERWRITE -eq 0 && $DRY_RUN -eq 0 ]]; then
        die "$filename already exists; pass --overwrite to replace it"
    fi

    eval "args=($argstr)"
    [[ $OVERWRITE -eq 1 ]] && args+=(--overwrite)

    run generate_injection_catalog "${args[@]}"
    manifest_lines+=("${filename}"$'\t'"${band}")
done

if [[ $DRY_RUN -eq 1 ]]; then
    echo
    echo "(dry run) manifest would be written to: ${MANIFEST}"
    printf '%s\n' "${manifest_lines[@]}"
    exit 0
fi

printf '%s\n' "${manifest_lines[@]}" > "$MANIFEST"
echo
echo "Wrote ${#manifest_lines[@]} catalog(s) and manifest: ${MANIFEST}"

if [[ $DO_INGEST -eq 1 ]]; then
    echo
    "${HERE}/ingest_injection_catalog.sh" \
        --repo "$REPO" \
        --output-collection "$OUTPUT_COLLECTION" \
        --manifest "$MANIFEST"
else
    cat <<EOF_MSG

Next, ingest into the butler:

  ${HERE}/ingest_injection_catalog.sh \\
    --repo \$REPO \\
    --output-collection u/\$USER/desgw/pilot/injection_catalog \\
    --manifest ${MANIFEST}
EOF_MSG
fi
