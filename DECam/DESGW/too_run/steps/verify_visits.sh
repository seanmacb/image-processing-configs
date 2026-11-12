#!/usr/bin/bash -l
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16GB
#SBATCH --time=02:00:00
#SBATCH -o /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_verify_visits_%j.out
#SBATCH -e /shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/too_run_verify_visits_%j.err

# Check the output of define_visits.sh: every science exposure of the manifest has
# a visit with a region and per-detector regions. In the search phase it also
# checks that the exposures are of the event's target ($TARGET_NAME), which
# catches a wrong propid or night.
#
#   verify_visits.sh <templates|search>

TOO_RUN_DIR=${TOO_RUN_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
source "$TOO_RUN_DIR/common.sh"
load_conf
init_step "${1:-}" verify_visits

args=(--manifest "$MANIFEST")
[[ $PHASE == search ]] && args+=(--target-name "$TARGET_NAME")
run_logged python "$TOO_RUN_DIR/verify_butler.py" check-visits "${args[@]}"
rc=$?
finish_step
exit $rc
