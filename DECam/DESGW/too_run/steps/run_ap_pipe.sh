#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=116GB
#SBATCH --time=48:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_ap_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_ap_%j.err

# Run the DESGW AP pipeline (configs/desgw_ap_pipe.yaml: ApPipeWithFakes without
# solar-system association) on one night of the event, as in pilot/run-ap-pipe.sh.
#
# Every night of an event writes to the same output chain $SEARCH_COLLECTION; each
# run adds a new RUN to it. The data query is scoped to one night, and the -i list
# does not depend on the night (pipetask requires it to match an existing chain),
# so nights can be run one after another, or re-run, in any order. Nights share
# one APDB, so do not run two nights of an event at the same time.
#
# Prerequisites (checked here and by 00_preflight.sh): calibrations, templates
# that passed verify_templates.sh, overscanRaw, the APDB, the injection catalog
# and the RBTransiNet model package. See the header of configs/desgw_ap_pipe.yaml.
#
#   run_ap_pipe.sh search

TOO_RUN_DIR=${TOO_RUN_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$TOO_RUN_DIR/common.sh"
load_conf
init_step "${1:-search}" ap
[[ $PHASE == search ]] || die "run_ap_pipe.sh only runs in the search phase"
[[ -n $INJECTION_COLLECTION ]] || die "INJECTION_COLLECTION is not set in $TOO_RUN_CONF"
[[ -r $APDB_CONFIG ]] || die "APDB config not found: $APDB_CONFIG"

# Do not start a long run against missing or unverified templates.
[[ -e $TEMPLATES_OK_MARKER ]] || die "templates for $EVENT have not passed verify_templates.sh (no $TEMPLATES_OK_MARKER)"
run_logged python "$TOO_RUN_DIR/verify_butler.py" check-templates \
    --manifest "$MANIFEST" --collection "$TEMPLATE_COLLECTION" \
    --skymap-collection "$SKYMAP_COLLECTION" --min-coverage "$SEARCH_TEMPLATE_MIN_COVERAGE" \
    || die "templates do not cover the night's visits (see above)"

# --no-raise-on-partial-outputs: calibrateImage wraps AlgorithmError failures
# (aperture correction, PSF shapelets) in AnnotatedPartialOutputsError. By
# default that propagates as a hard failure, which marks every downstream
# quantum of the same VISIT as FAILED_DEP -- one bad detector out of 60 loses
# the whole visit's warps and coadds. With this flag the quantum is a qualified
# success instead, so nothing is blocked; the partial image itself is then
# de-selected by PsfWcsSelectImagesTask (no WCS/photoCalib) and never reaches
# the coadd. Verified on tract 308 / patch 10 z-band: the coadd built this way
# is bit-identical to one built by running calibrateImage and the coadd tasks
# as two separate pipetask invocations.
run_logged pipetask --long-log run --register-dataset-types -j "$NPROC" \
    --no-raise-on-partial-outputs \
    --skip-existing \
    -b "$REPO" --instrument lsst.obs.decam.DarkEnergyCamera \
    -i "$CALIB_INPUTS,$SKYMAP_COLLECTION,refcats/gen3,$OVERSCAN_COLLECTION,$INJECTION_COLLECTION,$TEMPLATE_COLLECTION,$MODEL_COLLECTION" \
    -o "$SEARCH_COLLECTION" \
    -p "$IMAGE_PROC_CONFIG_DIR/configs/desgw_ap_pipe.yaml" \
    -c "parameters:apdb_config=$APDB_CONFIG" \
    -d "$SEARCH_QUERY AND $DET_EXCL"
record_pipetask_status $? "pipetask (ap_pipe)"
finish_step
exit 0
