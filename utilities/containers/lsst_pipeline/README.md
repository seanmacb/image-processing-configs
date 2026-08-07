# lsst_pipeline Apptainer image (DRAFT)

Apptainer/Singularity packaging of the LSST Science Pipelines stack + UZH
custom-filter patches, as an alternative to installing `lsst_distrib` as
loose files on shared storage (see `utilities/ansible/roles/lsst_pipeline`
/ `lsst_custom_filters` for the current, non-containerized approach). The
physik cluster's ansible-managed install is 156GB, but 128GB of that is
`demo_data` (tutorial data, not software) - actual software is 28GB
(`lsst_stack/`). Built `.sif` here: 2.9GB.

Motivation: S3IT's docs recommend containerizing over a bare conda/mamba
env on their storage (`docs.s3it.uzh.ch/general/conda/`); S3IT's shared
storage is CephFS, which like Lustre/GPFS has a metadata-server tier that
many-small-files access loads down.

**Status:** local build works, not yet run on S3IT, not wired into
`utilities/ansible/`. See `TODO.md`.

## Layout

```
lsst_pipeline.def       build definition (the actual image recipe)
build.args               default --build-arg-file values
build.sh                  builds the .sif locally, see "Build" below
TODO.md                   planned follow-up work
custom/                   UZH-specific patches, not upstream LSST code
    filters.yaml              custom DECam filter band definitions
    apply_custom_filters.py   applies them to obs_decam/skymap during the build
utilities/                helper scripts that aren't part of the build itself
    ship_to_s3it.sh           rsyncs a built .sif to the cluster
```

## Building on top of the upstream image

`lsst_pipeline.def` bootstraps `FROM ghcr.io/lsst/scipipe:al9-{{
LSST_VERSION }}_x86` - LSST's own official prebuilt image - rather than
reinstalling `lsst_distrib` from scratch via `lsstinstall`/`eups distrib
install` on every build. Confirmed to exist for weekly tags (not just
numbered releases), e.g.
[al9-w_2026_30_x86](https://github.com/orgs/lsst/packages/container/scipipe/1059405985?tag=al9-w_2026_30_x86).
Only `obs_decam`/`skymap` (small, local patches) are actually built here -
see `%post` in `lsst_pipeline.def`. This is a real change from an earlier
draft of this file, which built everything from a bare `almalinux:9` base;
keeping that history out of the file itself since git already has it.

## Why build locally, not on the cluster

Building an Apptainer image needs either root or `--fakeroot` (Linux user
namespaces). Personal machines generally have this; shared HPC login nodes
often don't (or restrict it) - so the workflow here is: build the `.sif`
locally, ship the finished file to the cluster, run it there. The cluster
never needs build privileges at all. (This mattered more when every build
meant a from-scratch, multi-hour `eups distrib install`; now that the
build starts from LSST's prebuilt image, the local build is mostly
pulling/caching that image plus two quick `scons` builds - still no
reason to do it on a shared login node instead of your own machine.)

## What's in the image vs. what stays outside it

**Baked into the `.sif` at build time:**
- LSST's official `lsst_distrib` install for the pinned `LSST_VERSION`,
  via the upstream `ghcr.io/lsst/scipipe` base image (see above)
- `obs_decam` and `skymap`, cloned, patched with the custom DECam filter
  bands (`filters.yaml`), built, and set up as LOCAL eups packages -
  mirrors what `utilities/ansible/roles/lsst_custom_filters` currently
  does at deploy time against a live host
- An `%environment` that auto-activates everything (equivalent to sourcing
  `setup_env.sh` today) - no `source setup_env.sh` step needed, just
  `apptainer exec image.sif <command>`

**Stays outside the image, unchanged:**
- The butler repo itself (Postgres registry + data files) - this is
  per-deployment state, not software, and must never be baked into an
  image. Bind-mount it at run time (see below). Still managed by
  `utilities/ansible/roles/lsst_butler_repo`.
- Anything host-specific (Slurm partition config, shared group/permissions
  setup) - still ansible's job on the target host.

## Build

```bash
./build.sh                    # uses build.args
# or:
./build.sh path/to/other.args
```

Produces `lsst_pipeline_<LSST_VERSION>.sif` next to this README - 2.9GB in
practice. `build.sh`'s `MIN_FREE_GB=100` scratch-space check is more
conservative than that, to cover the pulled image layers and unpacked
working tree, not just the final squashfs size. `build.sh` warns if the
tmp/cache dirs it'll use look short on space.

Edit `build.args` (or pass a different `--build-arg-file`) to change
`LSST_VERSION` / the `obs_decam`/`skymap` git refs - mirrors
`group_vars/all.yml`'s `lsst_version` and
`lsst_custom_filters_obs_decam_ref`/`lsst_custom_filters_skymap_ref`.

To change the custom filter bands themselves, edit `custom/filters.yaml` -
**it is a manually-kept copy** of
`utilities/ansible/roles/lsst_custom_filters/defaults/main.yml`'s
`lsst_custom_filters` list, not templated from it (Apptainer def-file
templating is flat variable substitution, not Jinja2 loops). Keep the two
in sync by hand for now.

## Ship to S3IT

```bash
SIF=lsst_pipeline_w_2026_30.sif DEST_HOST=<your-s3it-alias> ./utilities/ship_to_s3it.sh
```

Thin `rsync --partial` wrapper (resumable, so a dropped connection doesn't
restart the transfer from zero) - see the script header for env vars
(`DEST_DIR` etc.).

## Run it

```bash
apptainer exec --bind /path/to/butler:/butler \
    lsst_pipeline_w_2026_30.sif \
    pipetask run -b /butler ...
```

No `module load`/`source setup_env.sh` needed - the image's
`%environment` does that automatically on every `apptainer exec`/`run`.

## Building locally, running on different hardware

Safe as long as both machines are **x86_64 Linux** - the image's OS
userland (AlmaLinux 9, from the `ghcr.io/lsst/scipipe` base) is fully
self-contained in the `.sif`, so only CPU architecture/instruction set
need to match, not your host distro/glibc/kernel. `build.sh` and
`lsst_pipeline.def` guard the known risks:

- Wrong architecture (e.g. arm64 Mac): `build.sh` hard-fails on `uname -m`
  and passes `apptainer build --arch amd64`.
- CPU instruction-set mismatch on `obs_decam`/`skymap` (the only things
  actually compiled locally - `lsst_distrib` is prebuilt): pinned to
  `-march=x86-64-v3 -mtune=generic` via `ARCHFLAGS`/`CFLAGS`/`CXXFLAGS`,
  chosen from real `sinfo -o "%N %c %f"` output on S3IT (every partition
  has AVX-512 except `u24-chaiam0-*`, which still has AVX2/BMI2/FMA - v3
  is the highest baseline safe everywhere). See `lsst_pipeline.def`'s
  comments for why `ARCHFLAGS` specifically, not raw `scons CCFLAGS=...`
  (the latter isn't a real scons `Variable` in `sconsUtils` and failed a
  real build - full postmortem in git history).
- `--fakeroot`/disk-space/NFS issues: `build.sh` checks `/etc/subuid`/
  `/etc/subgid`, free space, and whether tmp/cache dirs are on NFS, all as
  warnings since none of this is verifiable without your machine.

## Known gaps / things to verify on the first real build

- `apply_custom_filters.py`'s edits reproduce the same anchors/logic as
  the ansible `blockinfile` tasks - verified against real `w.2026.30`
  clones of both repos (patches apply, all three edited files parse as
  valid Python, `SUPPORTED_FILTERS` contains the new bands at runtime),
  but the `skymap` anchor regex already broke once against upstream
  content drift (fixed - see git history) and could break again on a
  future ref bump. See `TODO.md` for a more robust alternative.

See `TODO.md` for planned follow-up work.
