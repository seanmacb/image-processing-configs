# DECam / GW-Primo

DRP-style processing of DECam broad-band (g r i z) and medium/narrow-band
(N395, M411, M438, M464, M490, M517, N540) images of one sky region, from raws
to multiband object tables, with `analysis_tools` metrics after each step. The
object tables (GAaP, PSF, CModel, Kron and MultiProFit fluxes in every band, one
schema across patches) are the input to the photo-z work, which happens
elsewhere. See the [top-level README](../../README.md) for the environment
(`$REPO`, `$LOGDIR`) every script relies on.

The pipeline follows drp_pipe's DECam DRP
([`DRP-Merian.yaml`](https://tigress-web.princeton.edu/~lkelvin/pipelines/current/drp_pipe/DECam/DRP-Merian/),
the DECam medium-band survey pipeline): step 1 single-frame processing, step 2
recalibration with jointcal (DECam has no FGCM or gbdes configuration), step 3
coaddition and multiband measurement. The metric tasks come from the
[`analysis_tools`](https://tigress-web.princeton.edu/~lkelvin/pipelines/current/analysis_tools/)
pipelines written for these (v1) dataset names, as in HSC's DRP.

## Layout

| Path | Purpose |
|---|---|
| `configs/gwprimo_drp.yaml` | The pipeline: steps `step1`, `step2a`/`2b`/`2d`/`2e`, `step3`, and a `stepN-metrics` subset after each. Its header and comments explain every override. |
| `fields/<FIELD>/field.conf` | Per-field settings: sky region, bands, visit filters, extra calibration collections, thresholds. The only thing that changes between fields. |
| `run/field.conf.template` | Documents every conf variable; `run/new_field.sh <FIELD>` copies it. |
| `run/common.sh` | Stack setup, conf defaults, the data queries, `pipetask` and `sbatch` helpers. |
| `run/00_preflight.sh` | Read-only prerequisite check (run it first; `run_drp.sh` runs it too). |
| `run/run_drp.sh` | Driver: submits the steps and their check jobs, chained with `afterok`. Supports `--dry-run`. |
| `run/steps/step{0,1,2,3}.sh` | One Slurm job per step. |
| `run/steps/metrics.sh <N>` | The check job after step N: metrics subset, completeness check, metric summary. |
| `run/gwprimo_butler.py` | The Butler-side checks (`preflight`, `check`, `summarize`). Read-only. |
| `calib/` | Medium-band flats and sky frames: `run_calib.sh` builds, checks, certifies (and for flats verifies) one calibration set (`calib/sets/<SET>.conf`) into `DECam/calib/GW-Primo`. See [Medium-band flats](#medium-band-flats) and [Sky frames](#sky-frames). |

## Quick start

```bash
cd DECam/GW-Primo/run
./new_field.sh MYFIELD                       # or edit fields/S250830bp/field.conf
$EDITOR ../fields/MYFIELD/field.conf         # FIELD, REGION, BANDS, CALIB_COLLECTIONS
./00_preflight.sh ../fields/MYFIELD/field.conf
./run_drp.sh ../fields/MYFIELD/field.conf --steps 0,1 --dry-run     # look first
./run_drp.sh ../fields/MYFIELD/field.conf --steps 0,1
# inspect $LOGDIR/gwprimo/MYFIELD/step1_*, then
./run_drp.sh ../fields/MYFIELD/field.conf --steps 2
./run_drp.sh ../fields/MYFIELD/field.conf --steps 3
```

`--steps all` chains everything. A failed check stops the chain; fix the
problem and resubmit from that step, since every step uses `pipetask
--skip-existing`. A step's script can also be run directly, without Slurm:
`GWP_CONF=<conf> bash steps/step1.sh`.

## Selecting a region

`REGION` uses the butler's ADQL-style literals (degrees):
`CIRCLE(ra, dec, radius)`, `BOX(ra, dec, width, height)` (an RA/Dec rectangle
around the centre) or `POLYGON(ra1, dec1, ra2, dec2, ...)`. Together with
`BANDS` and the optional `DAY_OBS_MIN`/`MAX`, `PROGRAMS`, `EXCLUDE_PROGRAMS` and
`EXTRA_WHERE`, it gives three data queries (built in `common.sh`):

| Step | Query | Why |
|---|---|---|
| 0, 1 | `visit.region OVERLAPS <REGION>` plus science exposures and the DESGW detector exclusions | Whole visits: step 2 (skyCorr, visit summaries, jointcal) needs full focal planes, so steps 1 and 2 are never constrained by tract or patch. |
| 2 | `visit.region OVERLAPS <REGION> AND skymap=...` | The same visits. |
| 3 | `patch.region OVERLAPS <REGION> AND skymap=...` | Coadds only where you asked for them. Tract-level outputs (`objectTable_tract`, tract metrics) then cover those patches only. |

DECam visits are ~2.2 deg across, so steps 1 and 2 process sky well beyond the
region. `fields/S250830bp` is the 2026A-271131 medium-band follow-up
(target `GWPRIMO_S250830bp`, RA ~326, Dec ~-77.6), plus the archival g r i z of
the same sky that DESGW ingested for its templates.

## The steps

| Step | Tasks | Output | Check job |
|---|---|---|---|
| 0 | cp_pipe `RunIsrForCrosstalkSources.yaml`: `overscanRaw` for every raw step 1 reads. Raws that already have it in `DECam/template/overscanRaw` (the DESGW templates) are skipped. | `DECam/GW-Primo/<FIELD>/overscanRaw` | `overscanRaw` for `STEP0_MIN_FRAC` of the raws, per band. |
| 1 | `isr`, `calibrateImage` (astrometry and photometry against `the_monster_20250219`), `transformPreSourceTable` | `DECam/GW-Primo/<FIELD>/drp` | `step1-metrics`, then a calexp for `STEP1_MIN_FRAC` of the raws per band; visits lost entirely are listed. |
| 2 | `step2a` consolidation, `skyCorr`, `isolatedStarAssociation`; `step2b` `jointcal`; `step2d` `finalizeCharacterization`, recalibrated source tables, `updateVisitSummary`; `step2e` visit tables. Four `pipetask run`s in one job. | same chain | `step2-metrics`, then `finalVisitSummary` and `sourceTable_visit` for `STEP2_MIN_FRAC` of the step 1 visits, a jointcal fit for every band, the visit tables. |
| 3 | Warps, `deepCoadd`, cell coadds, property maps, detection, scarlet deblending, measurement, forced photometry, MultiProFit, object tables | same chain | `step3-metrics`, then a `deepCoadd` for `STEP3_MIN_FRAC` of the region patches per band, and `objectTable_tract` for every tract with coadds. |

Step 0 is not part of `gwprimo_drp.yaml` because `overscanRaw` is a
prerequisite input of `isr`, and one pipeline graph cannot both make and need
it. `DRP-Merian.yaml` excludes it for the same reason.

## Metrics after each step

Each `metrics.sh` job runs the step's metric subset into the same output chain,
then writes to `$LOGDIR/gwprimo/<FIELD>/`:

- `stepN_check.txt`: the completeness check (PASS/FAIL, which decides the
  job's exit status);
- `stepN_metrics.csv`: every measurement of every metric bundle the step's
  tasks wrote (dataset type, data ID, band, tool, metric, value, unit);
- `stepN_summary.txt`: median and 5-95% range per metric and band;
- `stepN_plots/`: the step's `analysis_tools` plots, at most 50 per plot type
  (`EXPORT_PLOTS=0` turns this off). All of them stay in the Butler.

| Subset | `analysis_tools` tasks | What to look at |
|---|---|---|
| `step1-metrics` | `analyzeAmpOffsetMetadata`, `analyzeCalibrateImageMetadata`, `calexpSummary` | Per band: PSF star counts, astrometry/photometry match counts, astrometric offset to the refcat, mask fractions and sky level (calibrateImage metadata); PSF size, zero point, limiting magnitude, sky (calexp summary stats). Narrow bands with few PSF or photometry stars show up here first. |
| `step2-metrics` | `analyzePreSourceTableCore`, `analyzeSourceTableCore`, `catalogMatchVisit` + `astrometricRefCatSourceVisit`, `photometricMatchVisit` + `photometricRefCatSourceVisit`, `analyzeMatchedPreVisitCore`, `analyzeMatchedVisitCore` | Per-visit source quality before and after recalibration; astrometric and photometric residuals against `the_monster` per visit (every band; see the colour-term caveat below); per-tract repeatability of isolated stars before (preSource) and after (source) jointcal, i.e. what step 2 bought. |
| `step3-metrics` | `analyzeObjectTableCore`, `analyzeObjectParentTableCore`, `validateObjectTableCore`, `catalogMatchTract` + `refCatObjectTract`, `photometricCatalogMatch` + `photometricRefCatObjectTract`, `plotPropertyMapTract`, binned whole-tract `deepCoadd` and N-image mosaics, `aggregateDeepCoaddMaskFractions` | Object table: PSF-CModel, stellar-locus widths, sizes and shapes, sky objects, input counts; deblender metrics; valid PSF/CModel flux fractions per band; astrometric (all bands) and photometric (g r i z only) residuals against the refcat; per-tract depth (`psf_maglim`), PSF size and exposure-time maps per band; mosaics for a visual check. |

## Medium-band flats

`DECam/calib` only has g r i z flats; the DESGW flat builds
(`DESGW/startup/calib/build-flat-*.sh`) select those bands only. The raw dome
flats of the medium bands are all in `DECam/raw/all` already, taken in the two
2026A observing runs:

| Set conf | Nights (day_obs) | Filters (dome flats) | Certified for |
|---|---|---|---|
| `calib/sets/2026-06.conf` | 20260620-21 | M438 (44), M464 (44), M490 (44), M517 (41) | [2026-06-01, 2026-07-01) |
| `calib/sets/2026-07.conf` | 20260710-11 | M411 (22), M517 (22), N395 (22), N540 (22) | [2026-07-01, 2026-11-01) |

One set per observing run, so a flat is only used for the run its dome flats
come from; the two windows do not overlap (M517 is in both). The end date
matches the 2025-26 bias in `DECam/calib`, which these flats are built with.

`calib/run_calib.sh <set conf> --steps <list> [--dry-run]` chains up to nine
Slurm jobs with `afterok`, the flats first and then the sky frames (next
section):

| Step | What it does |
|---|---|
| `overscan` | cp_pipe `RunIsrForCrosstalkSources.yaml` on the set's dome flats, into `DECam/calib/GW-Primo/overscanRaw` (shared by every set). Afterwards `gwprimo_flats.py relink-overscan` puts back any RUN of that chain that a concurrent set's pipetask dropped from it (pipetask rewrites the chain from what it read a moment earlier). |
| `flat` | cp_pipe DECam `cpFlat.yaml`, one combined flat per (physical filter, detector), into `DECam/calib/GW-Primo/flat/<SET>`. Detectors 61 and 31 are skipped, as in the science queries. Always a complete new RUN (no `--skip-existing`), because the later steps read only the newest RUN. |
| `check` | The gate before certifying: at least `FLAT_MIN_EXPOSURES` (5) dome flats per filter and a flat for every detector they cover. Prints per-filter medians of the binned flats (`flatBin64`) and flags detectors outside 0.5-1.5 (warnings). Writes `$LOGDIR/gwprimo_calib_<SET>_flat_check.txt`. |
| `certify` | `butler certify-calibrations` of that RUN into the CALIBRATION collection `DECam/calib/GW-Primo` (created on first use) for the set's window. The shared `DECam/calib` is not touched. |
| `verify` | cp_verify with DESGW's `desgw_verify_flat.yaml` (the DECam MJD fix), then a pass/fail per filter and exposure in `$LOGDIR/gwprimo_calib_<SET>_flat_verify.txt`. |

```bash
cd DECam/GW-Primo/calib
./run_calib.sh sets/2026-06.conf --steps overscan,flat,check --dry-run
./run_calib.sh sets/2026-06.conf --steps overscan,flat,check
# read $LOGDIR/gwprimo_calib_2026-06_flat_check.txt and look at flatMosaic64, then
./run_calib.sh sets/2026-06.conf --steps certify,verify
# the same for sets/2026-07.conf (the two sets can run side by side)
```

`gwprimo_flats.py inventory` shows a set's state without changing anything
(dome flats and sky-frame science exposures per filter and night, overscanRaw
coverage, what is certified), and `gwprimo_flats.py decertify [--dataset-type
sky]` undoes a set's certification (dry run unless `--confirm`). Both read the
set conf through `common.sh`:

```bash
GWP_SET_CONF=sets/2026-07.conf bash -lc 'source common.sh; load_set; python gwprimo_flats.py inventory'
```

These are dome flats only. Star flats or illumination corrections for the
medium bands do not exist yet, so large-scale flat-field errors end up in the
zero points, where jointcal's per-detector fit absorbs part of them.

## Sky frames

A sky frame is the static background pattern (scattered light, pupil ghost,
residual illumination) left in flat-fielded science images; `skyCorr` subtracts
it, scaled per visit, when `doSky` is on. It is built from the science
exposures themselves, with sources masked, so it needs the set's flats
certified first. The same set conf drives it: the science exposures of its
bands and nights (all programs; with these nights that is only 2026A-271131),
certified for the same window as the flats.

| Step | What it does |
|---|---|
| `sky_select` | Only for sets with `SKY_MAX_EXPOSURES`: `gwprimo_flats.py select-sky` picks at most that many exposures per filter (the longest of each night and 0.5-deg pointing cell, round-robin over nights) into `sets/<SET>.sky_exposures`, and the later sky steps use exactly that list. A no-op for the medium-band sets, which use every exposure. |
| `sky_overscan` | `overscanRaw` for those science exposures, into the same `DECam/calib/GW-Primo/overscanRaw`, with the same relink afterwards. |
| `sky` | `calib/configs/gwprimo_cpSky.yaml`: cp_pipe DECam `cpSky.yaml` with its ISR set like the science ISR. The cp_pipe file leaves `cpSkyIsr` looking for crosstalk sources under IsrTask's default name, which this repo never writes, and its amp-offset override is mis-indented and never applied. One `sky` per (physical filter, detector), into `DECam/calib/GW-Primo/sky/<SET>`, a complete new RUN each time. |
| `sky_check` | The gate: at least `SKY_MIN_EXPOSURES` (20) science exposures per filter and a sky frame for every detector; per-filter median and spread of the sky frames, and detectors with non-finite pixels. Filters with no science that run (M517 in June) only warn. Writes `$LOGDIR/gwprimo_calib_<SET>_sky_check.txt`. |
| `sky_certify` | `butler certify-calibrations ... sky` into `DECam/calib/GW-Primo` for the set's window. |

```bash
# after certify,verify of the same set:
./run_calib.sh sets/2026-07.conf --steps sky_select,sky_overscan,sky,sky_check
./run_calib.sh sets/2026-07.conf --steps sky_certify
```

**Broad-band sky sets.** `skyCorr` needs a sky frame for every band of a
visit list, so the archival g r i z visits of `fields/S250830bp` need them too.
`calib/sets/sky-<era>.conf` are sky-only sets (`SKY_ONLY=1`; the flats are
DESGW's, already in `DECam/calib`), one per flat era of `DECam/calib`, so each
sky frame is certified for exactly the window of the flat it was built with:

| Set | Window | Bands (the field's visits in that era) |
|---|---|---|
| `sky-15-16` | 2015-01-01 to 2016-12-31 | g r |
| `sky-17-18` | 2017-01-01 to 2018-12-31 | g r |
| `sky-19-20` | 2019-01-01 to 2020-12-31 | g r i z |
| `sky-21-22` | 2021-01-01 to 2022-12-31 | g r i |
| `sky-23-24` | 2023-01-01 to 2024-12-31 | g i z |
| `sky-25-26` | 2025-01-01 to 2026-11-01 | g r i z |

They draw on every science exposure of at least 60 s in `DECam/raw/all` for
the era (69 to 722 per band and era), capped at 150 per filter by
`sky_select`. That keeps each set to roughly one step 1 of 150 visits per band.
One exposure per night and pointing cell leaves 32 to 150 per filter (229 to
516 per set). In 2023-26 most of those exposures come from a few repeatedly
observed fields (2025-26 z: 32 exposures in 8 cells), so check `sky_check`'s
statistics there. For these sets `all` means the five
sky steps; the flat steps are refused.

```bash
for era in 15-16 17-18 19-20 21-22 23-24 25-26; do
    ./run_calib.sh sets/sky-$era.conf --steps sky_select,sky_overscan,sky,sky_check
done
# read each $LOGDIR/gwprimo_calib_sky-<era>_sky_check.txt, then
for era in 15-16 17-18 19-20 21-22 23-24 25-26; do
    ./run_calib.sh sets/sky-$era.conf --steps sky_certify
done
```

With these six and the two medium-band sets certified, every (filter, night)
of `fields/S250830bp` has a sky frame, and `SKY_FRAMES=auto` turns `doSky` on.
`sky_select` rewrites `sets/<SET>.sky_exposures` each time it runs. Commit the
list with the sky frames it produced, and rerun it only to rebuild them.

The medium-band science is thin for this (one field, 32 to 96 exposures per
filter, dithered over ~0.9 deg). Expect noisier sky frames for the ~32-exposure
filters (M411, N540) than for N395.

**Switching skyCorr to sky frames.** `gwprimo_drp.yaml` keeps
`skyCorr.doSky: false`. Before step 2a, `run/steps/step2.sh` decides from
`SKY_FRAMES` in the field conf:

- `auto` (default): `-c skyCorr:doSky=True` if `gwprimo_butler.py sky-ready`
  finds a certified sky frame for every physical filter and night of the
  field's visits, otherwise without.
- `on`: with sky frames, and step 2 fails if any is missing.
- `off`: never.

One `skyCorr` config serves every band, so `auto` stays off for
`fields/S250830bp` until the broad-band sets above are certified as well.
Decide before step 2 first runs: if `skyCorr` already ran in
`OUTPUT_COLLECTION` with the other setting, step 2 stops, because
`--skip-existing` would keep the old outputs. Use a new `OUTPUT_COLLECTION`,
or set `SKY_FRAMES` to the old behaviour. `00_preflight.sh` reports which way
step 2 will go.

## Prerequisites and known blockers

`00_preflight.sh` checks all of these. As of 2026-10-23 two of them fail for
`fields/S250830bp`:

1. **Medium-band flats are not certified.** `DECam/calib` has flats for g r i z
   only. The raw dome flats for all seven filters are already ingested; build
   and certify them with `calib/` ([Medium-band flats](#medium-band-flats)).
   `fields/S250830bp` already points `CALIB_COLLECTIONS` at the result,
   `DECam/calib/GW-Primo`, which does not exist until the first certify. Until
   then preflight fails and step 1 cannot run. Step 0 does not need the flats:
   `run_drp.sh <conf> --steps 0 --skip-preflight`.
2. **The obs_decam fork's working copy breaks step 3.** Uncommitted lines in
   `$OBSDECAM/config/measureCoaddSources.py` load `filterMap.py` into
   `MeasureMergedCoaddSourcesConfig`, which has no `filterMap` (nor
   `refObjLoader`), and import `lsst.obs.decam.filterMap`, which does not exist.
   Any pipeline with the coadd `measure` task fails to build with `AttributeError`.
   Coadd measurement no longer matches to a refcat, so the four lines can simply
   go. The preflight `pipetask build` shows the error until then.

Also needed and checked: visits defined for every raw (`butler define-visits`),
`the_monster_20250219` in `refcats/gen3` over the region, and the
`decam_rings_v1` skymap.

## Gotchas

- **No colour terms for the medium bands.** obs_decam's `filterMap.py` ties
  M411-M517 and N540 to the_monster's DES g flux, and N395 to SDSS u. Neither
  calibrateImage nor jointcal applies colour terms (obs_decam's `colorterms.py`
  has no the_monster entries; with them on, jointcal raises). So each medium
  band's zero point carries a colour-dependent offset relative to its true
  system. The step 2 visit-level photometric residuals show it. The photo-z
  calibration (zero-point offsets fit on spectroscopic or stellar-locus data)
  has to absorb it, unless colour terms are derived for these filters.
- **Tract-level photometric metrics are g r i z only** (`refcat_bands`).
  analysis_tools turns a `monster_*` column back into a band by its last
  character (DM-46728), so a medium band would silently be compared as g.
- **The band list lives in `configs/gwprimo_drp.yaml`** (`parameters.bands`)
  and drives isolated-star matching, merge priorities, object-table columns,
  extendedness, MultiProFit and the `bands` of every analysis task. Each of
  those silently drops a band it does not list. `BANDS` in a conf must be a subset of it
  (preflight checks). A command-line `-c parameters:bands=...` does not work:
  the value arrives as a string.
- **Pipeline `python:` blocks are exec'd with separate locals**, so a
  comprehension inside one cannot see names the block defined (`NameError`).
  The blocks use plain loops for this reason.
- **No sky frames yet.** `DECam/calib` has no `sky` calibration for any
  filter, so `skyCorr` runs with `doSky: false` until every filter and night of
  a field has one ([Sky frames](#sky-frames)). It still fits the
  full-focal-plane background, but not the static sky pattern.
- **`the_monster_20250219` everywhere.** The drp_pipe, jointcal and
  analysis_tools default refcats (`gaia_dr3_20230707`, `ps1_pv3_3pi_20170110`,
  `gaia_dr2_20200414`) are not in this repo, and PS1 does not reach Dec -77.
- **`--no-raise-on-partial-outputs`** on every step, for the reason in the DESGW
  README: one failed detector must not fail its whole visit downstream. The
  step jobs therefore always exit 0 and record the pipetask status in
  `$LOGDIR/gwprimo_<FIELD>_stepN.status`; the check job decides from what was
  produced.
- **Retire a calib `overscanRaw` RUN with `butler remove-runs`**, not by taking
  it out of the `DECam/calib/GW-Primo/overscanRaw` chain: every `overscan` and
  `sky_overscan` job relinks the RUNs under that name that are missing from
  the chain.
- **Keep the `-i` list fixed** for one `OUTPUT_COLLECTION`: pipetask refuses an
  existing output chain whose inputs differ. Adding `CALIB_COLLECTIONS` after
  step 1 has run means a new `OUTPUT_COLLECTION`.
- **Step 3 is memory heavy.** The multiband deblender and MultiProFit hold all
  eleven bands of a patch. It runs with `NPROC_STEP3=15` workers on a 116 GB
  node. MultiProFit fits every band, with `allow_missing_bands` so patches
  without medium-band coverage are still fit. It is the slowest task; drop
  `fitDeblendedObjectsExp`/`Sersic` from `step3` if you only need
  GAaP/PSF/CModel/Kron fluxes, together with the Sersic and exponential
  atools of `analyzeObjectTableCore`, which read their columns.
- **Logs**: `$LOGDIR/gwprimo_<FIELD>_<step>.log`, Slurm output in
  `/shares/soares-santos.physik.uzh/fitsFiles/calibs/logs/gwprimo_<FIELD>_*`.
