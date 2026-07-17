# LSST Pipeline install (Ansible)

Installs the LSST Science Pipelines into a shared, group-accessible directory
on a remote server, mirroring the manual steps recorded in `_previous.txt`.

## Setup

1. Copy the inventory template and fill in your host(s):

   ```
   cp inventory.example.ini inventory.ini
   ```

2. Adjust `group_vars/all.yml` if needed:
   - `lsst_install_dir` — target directory on the server (created if missing).
   - `lsst_shared_group` — Linux group that should own the install; the
     `ansible_user` for each host must already be a member of this group.
   - `lsst_version` — eups distrib / lsstinstall version tag.
   - `lsst_run_demo_check` — run the `pipelines_check` demo as a smoke test
     after install (default: true).
   - `lsst_run_rc2_subset_check` — clone the `rc2_subset` tutorial dataset
     and run a `butler` smoke test against it after install (default: true).
     Uses `git`/`git-lfs` from the sourced LSST stack environment.

## Run

```
ansible-playbook site.yml
```

Add `-v` to see the stdout/stderr of each command (e.g. `lsstinstall`, `eups
distrib install`, the demo run), which is hidden by default:

```
ansible-playbook site.yml -v
```

All steps are idempotent (guarded with `creates:`/marker files), so re-running
the playbook only performs work that hasn't happened yet, except the demo
smoke test, which always re-runs when enabled.

## Note: SSH on `linux.physik.uzh.ch` hosts

These hosts require a second, silent `keyboard-interactive` auth step after
the certificate, which Ansible disables by default. Run with a dummy
password to enable it (needs `sshpass` installed: `sudo apt install sshpass`):

```
ansible-playbook site.yml -e ansible_ssh_pass=x -v
```

## Troubleshooting

**`lsstinstall` fails with `line 374: /pkgroot: Permission denied` / `Unable to
write pkgroot file`**: this happens after an interrupted/killed previous run
(e.g. you Ctrl-C'd or killed a slow `ansible-playbook` mid-`lsstinstall`).
`lsstinstall`'s stdout will show `Using existing environment
lsst-scipipe-<version>` — it reuses the existing conda env instead of
creating a fresh one, but that env is left partially built, so `conda
activate` doesn't run the `eups` package's activation hook that sets
`EUPS_PATH`. With `EUPS_PATH` empty, the script tries to write to
`$EUPS_PATH/pkgroot`, which resolves to `/pkgroot` at the filesystem root.

Fix: remove the incomplete conda env so `lsstinstall` rebuilds it from
scratch, then re-run the playbook:

```
rm -rf <lsst_install_dir>/lsst_stack/conda/envs/lsst-scipipe-<version>
```

(check the exact env name first with `ls
<lsst_install_dir>/lsst_stack/conda/envs/`).

## What it does

- Creates `lsst_install_dir` and `lsst_install_dir/lsst_stack`, owned by
  `lsst_shared_group` with the setgid bit so new files inherit the group.
- Downloads and runs `lsstinstall -T <lsst_version>`.
- Sources `loadLSST.sh`, runs `eups distrib install`, applies `shebangtron`,
  and re-runs `setup lsst_distrib`.
- Optionally downloads `pipelines_check` and runs `./bin/run_demo.sh` to
  verify the install.
- Optionally clones `rc2_subset` and runs `butler query-*` commands against
  it as a further smoke test.
- Recursively fixes group ownership/permissions (`chgrp`, `chmod g+rwX`,
  setgid on directories) so every group member can use the shared install.
- Writes `lsst_install_dir/setup_env.sh` (see "Environment activation
  script" below), a single script users source to fully activate the
  environment.

## Custom DECam filters (separate, opt-in role)

Adding a custom DECam filter (e.g. `M438`) means editing `obs_decam`/`skymap`
source, which shouldn't happen automatically on every `site.yml` run. This
lives in its own role, `lsst_custom_filters`, applied via its own playbook:

```
ansible-playbook custom_filters.yml
```

It is **not** referenced from `site.yml` and must be run explicitly, after
`lsst_pipeline` has already provisioned the shared stack.

**Keep versions in sync**: `lsst_custom_filters_obs_decam_ref` and
`lsst_custom_filters_skymap_ref` (in
`roles/lsst_custom_filters/defaults/main.yml`) should be set to the same
release tag as `lsst_version` (in `group_vars/all.yml`), e.g. both
`v30.0.2`/`30.0.2` for the same release — otherwise the `LOCAL:` checkouts
this role builds against can drift from the `lsst_distrib` version actually
installed. Ansible doesn't enforce this; there's no cross-role default
shared between the two files, so update both by hand when bumping the LSST
version.

What it does:

- Clones `obs_decam` and `skymap` into `lsst_install_dir/repos/`, builds them
  with `scons`, and checks out a local branch (`uzh/custom-decam-filters`) to
  hold the edits.
- Appends the filters listed in `lsst_custom_filters` (see
  `roles/lsst_custom_filters/defaults/main.yml`) as a managed block in
  `decamFilters.py`, and their reference-catalog mapping
  (`config.filterMap`) in `obs_decam/config/filterMap.py`.
- Appends the new bands to `SUPPORTED_FILTERS` in `skymap/python/lsst/skymap/packers.py`.
- Uses `setup -j -r <dir>` to make eups prefer these checkouts (`LOCAL:`)
  over the installed packages for the rest of this play. Activating this in
  new shells/jobs (since `eups setup -j -r` only applies per-shell) is
  handled by `setup_env.sh` (see "Environment activation script" below),
  not by this role — it scans `repos/` for local checkouts at *source*
  time, so it picks these up automatically without needing to be
  regenerated after this playbook runs.
- To add another filter later, add an entry to `lsst_custom_filters` and
  re-run the playbook - it's idempotent (managed blocks get regenerated,
  not duplicated).

**Not included** (needs a butler repo that doesn't exist in this ansible
setup yet): `butler register-instrument $REPO lsst.obs.decam.DarkEnergyCamera
--update`. Run that manually, once, against each butler repo after this role
has run and after the repo exists.

**Worth checking before relying on this**: the upstream anchor lines this
role edits around (`config.filterMap = {` in `filterMap.py`, the narrow-band
list in `packers.py`) are asserted to exist before editing, so the play
fails loudly instead of silently mis-inserting if `obs_decam`/`skymap`
change upstream - but it's still worth diffing the generated files after a
first run.

### Verifying the custom filters

```
ansible-playbook custom_filters_verify.yml
```

Read-only, safe to re-run any time after `custom_filters.yml` has run. Checks
that every entry in `lsst_custom_filters` is actually registered end-to-end,
not just present in the edited source files:

- Present in obs_decam's `DECAM_FILTER_DEFINITIONS` and
  `DarkEnergyCamera.filterDefinitions` (imported, not grepped).
- Present in `config.filterMap` in obs_decam's `config/filterMap.py`.
- Present in skymap's `SkyMapDimensionPacker.SUPPORTED_FILTERS` (imported).
- The `LOCAL:` obs_decam/skymap checkouts are what actually get loaded when
  a fresh shell sources the generated `setup_env.sh` - this doubles as a
  regression test of the `lsst_prepare_env` role's activation script.
- Recognized by a butler registry: creates a throwaway SQLite butler repo,
  runs `butler register-instrument ... lsst.obs.decam.DarkEnergyCamera`
  against it, and queries the `physical_filter`/`band` dimension records to
  confirm the custom filters show up. This is the actual mechanism real
  analysis butler repos depend on to recognize the new filters - the
  throwaway repo is deleted afterward and no real butler repo is touched.

This does **not** check or update any *existing* real butler repo - see
"Not included" above; this project doesn't track any butler repo path, so
there's nothing here to discover and re-register automatically. After
adding a new filter, remember to run `register-instrument --update`
yourself against each real repo that needs it.


## Environment activation script

Users need a single thing to `source` that fully activates the shared
stack, including any locally modified eups packages and correct
permissions on the shared butler repo. This is the `lsst_prepare_env` role,
run automatically as part of `site.yml` (after `lsst_pipeline`). It writes
`lsst_install_dir/setup_env.sh`, which users source in their shell or batch
job:

```
source /disk/groups/des/lsst_pipeline/v30_0_x/setup_env.sh
```

What the generated script does:

- Sources `loadLSST.sh` and runs `setup lsst_distrib`.
- Scans `lsst_install_dir/repos/` for any locally checked-out eups package
  (anything with a `ups/` metadata directory - e.g. the `obs_decam`/`skymap`
  checkouts from `lsst_custom_filters`) and `setup -j -r`'s each one, so
  modified packages are preferred over the versions from `lsst_distrib`
  without having to hardcode which packages exist. `eups setup -j -r` only
  affects the current shell, which is why this has to be re-sourced in
  every new shell/job rather than baked into the install once.
- Sets `umask 0002` so new files/directories created in the shared butler
  repo being processed (`butler ingest`, `pipetask run`, ...) stay group
  read/write instead of only writable by their creator.

**Not included yet**: pointing users at the butler repo itself (e.g.
exporting `REPO`) - where that repo lives is still to be decided, so this
script deliberately only handles the umask for now.

The script is regenerated (not hand-edited) on each run of
`prepare_env.yml`, so update `lsst_prepare_env_script_name` in
`group_vars/all.yml` and re-run rather than editing it directly.
