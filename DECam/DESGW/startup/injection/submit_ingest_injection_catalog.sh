#!/usr/bin/bash -l
#SBATCH --job-name=desgw_ingest_inj
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=128GB
#SBATCH --time=48:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/ButlerProjects/desgw_postgres/logs/ingest_injection_catalog-%A.out
#SBATCH -e /shares/soares-santos.physik.uzh/ButlerProjects/desgw_postgres/logs/ingest_injection_catalog-%A.err
#
# Ingest the DESGW pilot injection catalogs into the desgw_postgres butler,
# one band at a time.
#
# Submit with:
#   sbatch $IMAGE_PROC_CONFIG_DIR/DECam/DESGW/submit/submit_ingest_injection_catalog.sh
#
# Sizing notes -- these catalogs are full-sky (ra_lim [0,360], dec_lim [-90,90]
# at 2000 deg^-2), so each band is ~82.5M sources in a 6.5 GB ECSV file:
#
#   Memory. astropy reads the whole ECSV into memory before anything else
#   happens. The four numeric columns are ~2.6 GB and the source_type column
#   lands as numpy 'U13' (52 bytes/row, ~4.3 GB), so the Table alone is ~7 GB
#   on top of the 6.5 GB text buffer held during parsing. 128 GB leaves
#   comfortable headroom for the parse peak.
#
#   Time. ingest_injection_catalog loops over every unique HTM7 trixel and
#   rebuilds a full-length boolean mask each iteration. Full sky is 8*4^6 =
#   32768 trixels, and a measured mask+index pass over 82.5M rows is ~0.15 s,
#   so the masking alone is ~1.4 h per band before the 32768 butler.put calls
#   against postgres. Budget several hours per band; 48 h covers all four.
#
# Resuming. Each put lands in the same RUN collection, so re-running a band
# that already completed (or partially completed) will fail with
# ConflictingDefinitionError. To resume, set BANDS below to only the bands
# still outstanding; if a band died midway, ingest it into a fresh collection
# rather than re-running it into this one.

REPO="/shares/soares-santos.physik.uzh/ButlerProjects/desgw_postgres"
CATALOG_DIR="${REPO}/injection_catalogs"
COLLECTION="u/smacbr/desgw/pilot/injection_catalog"
DATASET_TYPE="injection_catalog"

# Bands to ingest, in order. Trim this to resume a partial run.
BANDS="g r i z"

source /shares/soares-santos.physik.uzh/envs/lsst_stack/loadLSST.bash
setup lsst_distrib

echo "Repo:       ${REPO}"
echo "Collection: ${COLLECTION}"
echo "Bands:      ${BANDS}"
echo "Started:    $(date)"
echo

for BAND in ${BANDS}; do
    CATALOG="${CATALOG_DIR}/injection_catalog_${BAND}.ecsv"

    if [[ ! -f "${CATALOG}" ]]; then
        echo "ERROR: catalog not found: ${CATALOG}" >&2
        exit 1
    fi

    echo "=================================================================="
    echo "Ingesting ${BAND} band from ${CATALOG}"
    echo "Start: $(date)"
    echo "=================================================================="

    ingest_injection_catalog \
        -b "${REPO}" \
        -o "${COLLECTION}" \
        -t "${DATASET_TYPE}" \
        -i "${CATALOG}" "${BAND}"
    status=$?

    if [[ ${status} -ne 0 ]]; then
        echo "ERROR: ${BAND}-band ingestion failed with status ${status}" >&2
        echo "Bands completed before the failure: any listed above this line." >&2
        exit ${status}
    fi

    echo "Finished ${BAND} band: $(date)"
    echo
done

echo "=================================================================="
echo "Finished all bands (${BANDS}), exiting."
echo "Ended: $(date)"
echo
echo "Verify with:"
echo "  butler query-datasets ${REPO} ${DATASET_TYPE} --collections ${COLLECTION}"
