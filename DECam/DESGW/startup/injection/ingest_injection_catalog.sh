#!/usr/bin/env bash
#
# Step 3 of the source_injection workflow: ingest the DESGW pilot injection
# catalogs into the butler.
#   https://pipelines.lsst.io/modules/lsst.source.injection/index.html
#
# Wraps ingest_injection_catalog, which shards each catalog by depth-7 HTM
# trixel (~0.315 deg^2 each) and does one butler.put per (htm7, band). It also
# registers the 'injection_catalog' dataset type -- dimensions htm7 + band,
# storage class ArrowAstropy -- and creates the output RUN collection, so no
# `butler register-dataset-type` or `butler create` step is needed first.
#
# Input comes from the manifest written by make_injection_catalog.sh, or from
# explicit --catalog options.
#
# The repo must already know the band values, which arrive with the instrument:
# run `butler register-instrument $REPO lsst.obs.decam.DarkEnergyCamera` on a
# fresh repo first, or ingestion fails with
#   DataIdValueError: Could not fetch record for dimension band
#
# The resulting collection must appear in the AP pipeline's -i list:
# injectVisit declares injection_catalogs as a *prerequisite* input, which is
# resolved when the QuantumGraph is built, so the catalog has to exist before
# desgw_ap_pipe.yaml runs at all -- well before injectedMatchDiaSrc.
#
# Examples:
#
#   ./ingest_injection_catalog.sh --repo $REPO \
#       --output-collection u/${USER}/desgw/pilot/injection_catalog
#
#   ./ingest_injection_catalog.sh --repo $REPO \
#       --output-collection u/${USER}/desgw/pilot/injection_catalog \
#       --catalog /path/to/fakes.ecsv g r i z
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'USAGE_EOF'
Ingest DESGW injection catalogs into the butler with ingest_injection_catalog.

Options:
  --repo PATH               Butler repository (required).
  --output-collection COLL  RUN collection to ingest into (required).

  --manifest PATH           Manifest written by make_injection_catalog.sh.
                            Default: <outdir>/manifest.txt
  --outdir PATH             Directory holding the manifest.
                            Default: ./injection_catalogs
  --catalog FILE BAND [BAND ...]
                            Ingest this file against these bands. Repeatable.
                            Overrides the manifest entirely. Use several bands
                            on one file only when the fakes are meant to have
                            identical fluxes in each.

  --dataset-type NAME       Output dataset type. Default: injection_catalog
  -n, --dry-run             Print commands instead of running them.
  -h, --help                Show this message.
USAGE_EOF
}

REPO=""
OUTPUT_COLLECTION=""
MANIFEST=""
OUTDIR="./injection_catalogs"
DATASET_TYPE="injection_catalog"
DRY_RUN=0
# Each entry is one "-i" group: "file<TAB>band band band".
CATALOGS=()

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
        --repo) REPO="$2"; shift 2 ;;
        --output-collection) OUTPUT_COLLECTION="$2"; shift 2 ;;
        --manifest) MANIFEST="$2"; shift 2 ;;
        --outdir) OUTDIR="$2"; shift 2 ;;
        --catalog)
            shift
            collect _group "$@"
            shift "$CONSUMED"
            [[ ${#_group[@]} -ge 2 ]] || { echo "error: --catalog needs a file and at least one band" >&2; exit 2; }
            CATALOGS+=("${_group[0]}"$'\t'"${_group[*]:1}")
            ;;
        --dataset-type) DATASET_TYPE="$2"; shift 2 ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 2; }

[[ -n "$REPO" ]] || die "--repo is required"
[[ -n "$OUTPUT_COLLECTION" ]] || die "--output-collection is required"
command -v ingest_injection_catalog >/dev/null \
    || die "ingest_injection_catalog not on PATH; set up lsst_distrib first"

# Fall back to the manifest when no --catalog was given.
if [[ ${#CATALOGS[@]} -eq 0 ]]; then
    [[ -n "$MANIFEST" ]] || MANIFEST="${OUTDIR}/manifest.txt"
    [[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST (run make_injection_catalog.sh first, or pass --catalog)"
    while IFS=$'\t' read -r file band; do
        [[ -n "${file:-}" ]] || continue
        CATALOGS+=("${file}"$'\t'"${band}")
    done < "$MANIFEST"
    [[ ${#CATALOGS[@]} -gt 0 ]] || die "manifest is empty: $MANIFEST"
fi

# ingest_injection_catalog takes repeated -i groups, so one call covers
# every band; each group is put into the same RUN collection.
cmd=(ingest_injection_catalog -b "$REPO" -o "$OUTPUT_COLLECTION" -t "$DATASET_TYPE")
for entry in "${CATALOGS[@]}"; do
    file="${entry%%$'\t'*}"
    bands="${entry#*$'\t'}"
    [[ -f "$file" ]] || die "catalog file not found: $file"
    # shellcheck disable=SC2206  # deliberate word splitting on the band list
    band_array=($bands)
    cmd+=(-i "$file" "${band_array[@]}")
done

printf '+'; printf ' %q' "${cmd[@]}"; printf '\n'
if [[ $DRY_RUN -eq 1 ]]; then
    exit 0
fi
if ! "${cmd[@]}"; then
    cat >&2 <<'HINT_EOF'

hint: if this failed with "Could not fetch record for dimension band", the repo
      has no band values yet. Register the instrument, then retry:

        butler register-instrument $REPO lsst.obs.decam.DarkEnergyCamera
HINT_EOF
    exit 1
fi

cat <<EOF_MSG

Ingested into collection: ${OUTPUT_COLLECTION}

Check it with:

  butler query-datasets ${REPO} ${DATASET_TYPE} --collections ${OUTPUT_COLLECTION}

Then include the collection in the AP pipeline's inputs:

  pipetask run -b ${REPO} \\
    -p ${HERE}/desgw_ap_pipe.yaml#apPipe \\
    -i <your inputs>,${OUTPUT_COLLECTION} \\
    -o <output collection> \\
    -c 'parameters:apdb_config=/path/to/apdb_config.yaml'
EOF_MSG
