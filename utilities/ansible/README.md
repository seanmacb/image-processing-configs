# LSST Pipeline install (Ansible)

Installs the LSST Science Pipelines into a shared, group-accessible directory
on a remote server.

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

Install the shared pipeline stack (creates `lsst_install_dir`, runs
`lsstinstall`/`eups distrib install`, writes `setup_env.sh`):

```
ansible-playbook site.yml -v
```

`-v` shows the stdout/stderr of each command (`lsstinstall`, `eups distrib
install`, the demo run), which is hidden otherwise — drop it for quieter
output.

All steps are idempotent (guarded with `creates:`/marker files), so
re-running the playbook only performs work that hasn't happened yet, except
the demo smoke test, which always re-runs when enabled.

Everything below is optional and separate from this install — run it
afterwards, once the shared stack above is in place:

- Register custom DECam filters on top of the shared stack — see "Custom
  DECam filters" below:

  ```
  ansible-playbook custom_filters.yml -v
  ```

- Verify the custom filters registered correctly — see "Verifying the
  custom filters" below (run after `custom_filters.yml`):

  ```
  ansible-playbook custom_filters_verify.yml -v
  ```

- Create a butler repo in its own location — see "Butler repo" below:

  ```
  ansible-playbook butler_repo.yml -v
  ```


## Note: SSH on `linux.physik.uzh.ch` hosts

These hosts require a second, silent `keyboard-interactive` auth step after
the certificate, which Ansible disables by default. Run with a dummy
password to enable it (needs `sshpass` installed: `sudo apt install sshpass`).
This applies to **every** playbook in this project, not just `site.yml`:

```
ansible-playbook site.yml -e ansible_ssh_pass=x -v
ansible-playbook custom_filters.yml -e ansible_ssh_pass=x -v
ansible-playbook custom_filters_verify.yml -e ansible_ssh_pass=x -v

ansible-playbook butler_repo.yml -e ansible_ssh_pass=x -v
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

- Creates `lsst_install_dir`, `lsst_install_dir/lsst_stack`, and
  `lsst_testing_dir` (a home for standalone check scripts written by other
  roles, e.g. `lsst_custom_filters`), owned by `lsst_shared_group` with the
  setgid bit so new files inherit the group.
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


## Butler repo (separate, opt-in role)

Creates and initializes a butler repo. Applied via its own playbook:

```
ansible-playbook butler_repo.yml
```

Independent of `lsst_pipeline`/`lsst_prepare_env` and `group_vars/all.yml` -
all config lives in `roles/lsst_butler_repo/defaults/main.yml`, so it can
target any LSST stack install, not just the one `lsst_install_dir` names.

- `lsst_butler_repo_dir` — where the repo gets created.
- `lsst_butler_repo_shared_group` — group for shared read/write access.
- `lsst_butler_repo_pipeline_dir` / `lsst_butler_repo_prepare_env_script_name`
  — which install's `setup_env.sh` to source before running `butler`.
- `lsst_butler_repo_instrument_classes` — instruments registered right
  after `butler create` (`register-instrument ... --update`). `[]` to skip.
- `lsst_butler_repo_curated_calibrations` — instruments run through
  `write-curated-calibrations` right after that, each an `{instrument,
  collection}` pair (butler requires `--collection`). `[]` to skip.
- `lsst_butler_repo_skymaps` — skymaps registered after that
  (`register-skymap ... -C <config> -c name=<name>`), each a `{name,
  config}` pair. `[]` to skip.
- `lsst_butler_repo_postgres_host` (+ `_port`/`_db`/`_user`/`_namespace`) —
  optional Postgres registry backend, only used the moment the repo is
  created. Empty `_host` (default) falls back to SQLite. No password var:
  auth comes from a `~/.pgpass` file on the target host (set up separately)
  matching these values.
- `lsst_butler_repo_setup_script_name` — name of the repo activation
  script written to `lsst_butler_repo_dir` (see below).

What it does:

- Creates `lsst_butler_repo_dir`, owned by `lsst_butler_repo_shared_group`,
  setgid, same as `lsst_install_dir`.
- **Fails if `lsst_butler_repo_dir` isn't empty.** This role only creates
  brand new repos and never touches an existing one — re-running
  `butler_repo.yml` against an already-created repo is an error, not a
  no-op. Register a new instrument/curated calibration/skymap on an
  existing repo by hand instead (`butler register-instrument ... --update`
  / `write-curated-calibrations ...` / `register-skymap ...`).
- *(Postgres only)* Writes a seed config to a remote temp file and points
  `butler create` at it via `--seed-config`, then removes the temp file.
- Sources the activation script once, then in that same shell: `butler
  create`, `register-instrument --update` for each instrument,
  `register-skymap` for each skymap, and `write-curated-calibrations` for
  each `lsst_butler_repo_curated_calibrations` entry — combined into one
  task since sourcing
  the pipeline env is slow and every task gets its own shell.
- Writes `lsst_butler_repo_dir/setup_repo.sh` (see below).
- Recursively fixes group ownership/permissions, same as `lsst_pipeline`.

### Repo activation script

Written once, alongside the repo, to `lsst_butler_repo_dir/setup_repo.sh`
(name via `lsst_butler_repo_setup_script_name`). Users source it to work
against this specific repo:

```
source /disk/groups/des/butler_repos/main/setup_repo.sh
```

What it does:

- Fails with a clear message if `butler` isn't already on `PATH` — it
  deliberately does **not** source the pipeline itself (source that
  first, consistent with this role's independence, see above).
- Exports `REPO` and sets `umask 0002` (shared repo, keep group read/write).
- *(Postgres only)* Checks `.pgpass` (`$PGPASSFILE` or `~/.pgpass`) exists
  with mode `0600`, then tries an actual connection via `psql` (falling
  back to a reachability-only `pg_isready` check, or skipping if neither
  is installed) — warns (doesn't abort the source) if any of this fails.

Not regenerated on a later run, so update the template
(`roles/lsst_butler_repo/templates/setup_repo.sh.j2`) before creating a
repo, not after.

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
- Writes `check_butler_filter_registration.sh` into `lsst_testing_dir` (see
  "What it does" for `site.yml` above - created by `lsst_pipeline`, not this
  role), a standalone script (no ansible needed) users can run themselves to
  check that the shared install activates correctly and that the custom filters
  are recognized by a butler registry - see "Verifying the custom filters"
  below, which runs this same script.

**Not included**: registering these custom filters against a real butler
repo. `lsst_butler_repo` (see "Butler repo" above) registers
`lsst.obs.decam.DarkEnergyCamera` for you when it creates a repo, but that
happens before any custom filters exist yet, so it won't know about them.
`butler_repo.yml` only ever runs repo creation/registration once (it's a
no-op against an already-created repo, see "Butler repo" above), so
re-running it won't pick up filters added later either. After running
`custom_filters.yml`, re-register by hand against each repo that needs the
new filters:

```
butler register-instrument <REPO> lsst.obs.decam.DarkEnergyCamera --update
```

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
- Recognized by a butler registry: runs
  `lsst_install_dir/testing/check_butler_filter_registration.sh` (written by
  `custom_filters.yml`, see "What it does" above), which creates a throwaway
  SQLite butler repo, runs `butler register-instrument ...
  lsst.obs.decam.DarkEnergyCamera` against it, and queries the
  `physical_filter`/`band` dimension records to confirm the custom filters
  show up. This is the actual mechanism real analysis butler repos depend on
  to recognize the new filters - the throwaway repo is deleted afterward and
  no real butler repo is touched. Since it's a standalone script, users can
  run it directly to spot-check their own shell/job setup without going
  through ansible at all.

This does **not** check or update any *existing* real butler repo - see
"Not included" above. After adding a new filter, re-register it by hand
(see above) against each real repo that needs it.


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

**Not included**: pointing users at a butler repo itself (e.g. exporting
`REPO`) - `lsst_butler_repo` (see "Butler repo" above) is deliberately
independent of this role/script, so it doesn't wire into it automatically.

The script is regenerated (not hand-edited) on each run of
`prepare_env.yml`, so update `lsst_prepare_env_script_name` in
`group_vars/all.yml` and re-run rather than editing it directly.
