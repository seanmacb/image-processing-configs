# lsst_pipeline Apptainer image (DRAFT)

Experimental Apptainer/Singularity packaging of the LSST Science Pipelines
stack + UZH custom-filter patches, as an alternative to installing
`lsst_distrib` as loose files onto a cluster's shared filesystem (see
`utilities/ansible/roles/lsst_pipeline` / `lsst_custom_filters` for the
current, working, non-containerized approach). The physik cluster's
equivalent ansible-managed install (same `w_2026_30`) is **429,989 files /
156GB** (`find w_2026_30/ -type f | wc -l`, `du -sh w_2026_30/`) - a real
measurement, not an estimate.

Motivation is two-fold: S3IT's own docs explicitly recommend containerizing
(Apptainer) over a bare conda/mamba env for exactly this reason -
`docs.s3it.uzh.ch/general/conda/` warns of "crucially relevant
implications when using Conda/Mamba on distributed filesystems"; and
S3IT's shared storage is confirmed CephFS (`df -T` on
`/shares/soares-santos.physik.uzh/...` - Ceph, not NFS), which like
Lustre/GPFS has a dedicated metadata-server tier that heavy small-file
access loads down.

**Status: draft/testing, not validated against a real build yet, and
deliberately not wired into `utilities/ansible/`.** Treat every command
below as "should work" rather than "known to work" until it's actually
been run once.

## Layout

```
lsst_pipeline.def       build definition (the actual image recipe)
build.args               default --build-arg-file values
build.sh                  builds the .sif locally, see "Build" below
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

Produces `lsst_pipeline_<LSST_VERSION>.sif` next to this README. Even
though the build no longer compiles `lsst_distrib` itself (see "Building
on top of the upstream image" above), the upstream image it pulls already
contains the full stack, so **250GB+ free scratch space** on the build
machine is still the right expectation - the physik cluster's equivalent
install is 156GB uncompressed, and a fakeroot build needs room for the
pulled image layers, the unpacked working tree, and the final squashfs
`.sif` at the same time. `build.sh` warns if the tmp/cache dirs it'll use
look short on space.

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

Thin `rsync --partial` wrapper (resumable - the 156GB physik-cluster
figure above means the `.sif` will likely be large enough that a dropped
connection restarting from zero is a real annoyance, not a hypothetical)
- see the script header for env vars (`DEST_DIR` etc.).

## Run it

```bash
apptainer exec --bind /path/to/butler:/butler \
    lsst_pipeline_w_2026_30.sif \
    pipetask run -b /butler ...
```

No `module load`/`source setup_env.sh` needed - the image's
`%environment` does that automatically on every `apptainer exec`/`run`.

## Building locally, running on different hardware

Building on your own machine and running the result on S3IT is safe
**as long as both are x86_64 Linux** - the image's OS userland (AlmaLinux
9, inherited from the `ghcr.io/lsst/scipipe` base image) is entirely
self-contained inside the `.sif`, so your host distro/glibc/kernel version
don't leak into it.
The only things that actually need to match are CPU architecture and,
more subtly, CPU instruction set for anything compiled locally during the
build. `build.sh` and `lsst_pipeline.def` guard the known risks:

- **Wrong architecture entirely** (e.g. an Apple Silicon Mac, arm64
  Linux): `build.sh` hard-fails via a `uname -m` check before attempting
  anything, and passes `apptainer build --arch amd64` so a mismatch can't
  silently produce a QEMU-emulated or broken image.
- **CPU instruction-set mismatch** on the two packages actually compiled
  during the build (`obs_decam`, `skymap` - `lsst_distrib` itself is
  prebuilt binaries fetched from LSST's server, not compiled locally):
  `lsst_pipeline.def` pins `CFLAGS`/`CXXFLAGS` to `-march=x86-64-v3
  -mtune=generic` instead of letting gcc default to `-march=native` (i.e.
  your specific laptop CPU), which could otherwise bake in an instruction
  your laptop has and an S3IT node doesn't, and crash with `SIGILL` there
  instead of failing at build time. `x86-64-v3` was picked from real data,
  not a guess: `sinfo -o "%N %c %f"` on S3IT shows every partition has
  `AVX512` **except** `u24-chaiam0-*` (AMD EPYC 7402, Zen 2), which still
  has AVX2/BMI2/FMA (v3) - so v3 is the highest baseline safe on every
  listed partition, v4 would `SIGILL` on chaiam0. If you know jobs using
  this image will never land on chaiam0 (e.g. via a Slurm `--constraint`),
  v4 would be a safe bump there. **UNVERIFIED** whether `sconsUtils`
  actually honours `CCFLAGS`/`CXXFLAGS` this way (passed both as env vars
  and scons command-line vars as a hedge); worth confirming after the
  first build, e.g. by checking the compiled `.so` files don't reference
  AVX-512 (`objdump -d foo.so | grep -m1 -i zmm` should find nothing) or
  just running the shipped `.sif` on S3IT once and watching for `SIGILL`.
- **`--fakeroot`/build-privilege issues, tmp/cache disk space, TMPDIR on
  NFS**: `build.sh` checks `/etc/subuid`/`/etc/subgid`, free space in the
  tmp/cache dirs apptainer will actually use, and whether they're on NFS
  (fakeroot's overlay mount doesn't work there) - all as warnings, since
  none of these are things I can verify without your machine, but they're
  the most common reasons a fakeroot build fails partway through.

## Known gaps / things to verify on the first real build

- The `dnf install` package list in `lsst_pipeline.def`'s `%post` (now
  just `git git-lfs patch rsync findutils`, trimmed down since the base
  image should already carry LSST's own compiler toolchain/Java/etc. for
  `scons`) is **not verified against a real build** - the base image's
  actual contents haven't been inspected, so this could still be missing
  something `obs_decam`/`skymap`'s build needs.
- `apply_custom_filters.py`'s edits reproduce the same anchors/logic as
  the ansible `blockinfile` tasks, but haven't been diffed byte-for-byte
  against a real ansible-patched checkout.
- Apptainer is confirmed available on S3IT (`module load apptainer` gets
  1.5.0 on a login node) - running a shipped `.sif` there needs no further
  setup on S3IT's side.
- Not yet checked whether S3IT's compute nodes (not just the login node)
  have outbound internet access, network policy for pulling anything at
  run time, or any per-user/project storage quota that 150GB+ `.sif`
  files would need to fit inside.
