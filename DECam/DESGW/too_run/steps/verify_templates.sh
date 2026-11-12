#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=116GB
#SBATCH --time=04:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_verify_templates_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_verify_templates_%j.err

# Check the output of build_templates.sh.
#
#  1. Coverage: a goodSeeing template_coadd exists, per band, for at least
#     $TEMPLATE_MIN_COVERAGE of the (tract, patch) cells the template exposures
#     overlap. Edge patches legitimately lack coverage, hence a fraction.
#  2. PSF (when TEMPLATE_PSF_CHECK=1): runs verify/measure_template_psf.py and
#     warns, without failing, if a band's median template FWHM exceeds
#     $TEMPLATE_FWHM_WARN arcsec. Plots: verify/evaluate_template_psf_quality.ipynb.
#
# On success it writes $TEMPLATES_OK_MARKER, which the search phase requires.
#
#   verify_templates.sh templates

TOO_RUN_DIR=${TOO_RUN_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$TOO_RUN_DIR/common.sh"
load_conf
init_step "${1:-}" verify_templates

status_file=$LOGDIR/too_run_${EVENT}_${TAG}_templates.status
[[ -r $status_file ]] && log "pipetask exit status: $(cat "$status_file")" | tee -a "$LOGFILE"
rm -f "$TEMPLATES_OK_MARKER"
run_logged python "$TOO_RUN_DIR/verify_butler.py" check-templates \
    --expnums-file "$EXPOSURE_LIST" --collection "$TEMPLATE_COLLECTION" \
    --skymap-collection "$SKYMAP_COLLECTION" --min-coverage "$TEMPLATE_MIN_COVERAGE"
rc=$?

if [[ $rc -eq 0 && $TEMPLATE_PSF_CHECK == 1 ]]; then
    psf_dir=$LOGDIR/templatePsf/$EVENT
    mkdir -p "$psf_dir"
    if run_logged python "$IMAGE_PROC_CONFIG_DIR/verify/measure_template_psf.py" \
            --repo "$REPO" --collection "$TEMPLATE_COLLECTION" \
            --output-dir "$psf_dir" --workers "$NPROC"; then
        run_logged python -I - "$psf_dir/template_psf_per_patch.csv" "$TEMPLATE_FWHM_WARN" <<'PY'
import csv, statistics, sys
from collections import defaultdict
path, limit = sys.argv[1], float(sys.argv[2])
fwhm = defaultdict(list)
for row in csv.DictReader(open(path)):
    try:
        fwhm[row["band"]].append(float(row["template_psf_fwhm_median"]))
    except ValueError:
        pass
for band in sorted(fwhm):
    med = statistics.median(fwhm[band])
    flag = f"  WARNING: above {limit} arcsec" if med > limit else ""
    print(f"template PSF FWHM band {band}: median {med:.2f} arcsec over {len(fwhm[band])} patches{flag}")
PY
    else
        log "WARNING: PSF measurement failed; coverage check result stands" | tee -a "$LOGFILE"
    fi
fi

if [[ $rc -eq 0 ]]; then
    date > "$TEMPLATES_OK_MARKER"
    log "wrote $TEMPLATES_OK_MARKER" | tee -a "$LOGFILE"
fi
finish_step
exit $rc
