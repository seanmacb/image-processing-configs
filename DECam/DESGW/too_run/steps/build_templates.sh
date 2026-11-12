#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=116GB
#SBATCH --time=48:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_templates_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_templates_%j.err

# Build the good-seeing template coadds for the event's sky box, from every
# archive science exposure in the box before the event (QuickTemplate.yaml).
# Same call as pilot/build-template-S250830bp.sh; the data query comes from the
# conf (sky box, night window, bands, excluded programs).
#
#   build_templates.sh templates

TOO_RUN_DIR=${TOO_RUN_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$TOO_RUN_DIR/common.sh"
load_conf
init_step "${1:-templates}" templates
[[ $PHASE == templates ]] || die "build_templates.sh only runs in the templates phase"

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
    --skip-existing-in "$TEMPLATE_COLLECTION" \
    -b "$REPO" --instrument lsst.obs.decam.DarkEnergyCamera \
    -i "$CALIB_INPUTS,$OVERSCAN_COLLECTION,$SKYMAP_COLLECTION,refcats/gen3" \
    -o "$TEMPLATE_COLLECTION" \
    -p "$IMAGE_PROC_CONFIG_DIR/configs/QuickTemplate.yaml" \
    -d "$TEMPLATE_QUERY AND $DET_EXCL"
record_pipetask_status $? "pipetask (templates)"
finish_step
exit 0
