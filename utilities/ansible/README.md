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

This role is deliberately independent of `lsst_pipeline`/`lsst_prepare_env`
and their `group_vars/all.yml` entries — all of its config lives in its own
role defaults (`roles/lsst_butler_repo/defaults/main.yml`), not
`group_vars/all.yml`, so it can be pointed at any LSST stack install (not
necessarily the one `lsst_install_dir` names) without other vars needing to
line up:

- `lsst_butler_repo_dir` — where the repo gets created (independent of
  `lsst_install_dir` — a repo should be able to outlive a given pipeline
  version, so it isn't created automatically by `site.yml`).
- `lsst_butler_repo_shared_group` — Linux group for shared read/write
  access to it.
- `lsst_butler_repo_pipeline_dir` /
  `lsst_butler_repo_prepare_env_script_name` — which install's activation
  script to source before running `butler` commands (needs an
  `lsst_prepare_env`-generated `setup_env.sh` to already exist there, so run
  after `lsst_pipeline`/`prepare_env.yml` have provisioned it — but not
  necessarily the same install `site.yml` in this project manages).
- `lsst_butler_repo_postgres_host` (and `_port`/`_db`/`_user`/
  `_namespace`) — optional Postgres registry backend. Leave
  `lsst_butler_repo_postgres_host` empty (the default) to fall back to the
  embedded SQLite registry `butler create` uses with no seed config. The
  registry backend can't be changed after creation, so this only has any
  effect the first time the repo is created. No password var here: auth is
  expected to come from a `~/.pgpass` file on the target host (set up
  separately, outside this ansible project) matching these host/port/db/
  user values — libpq reads it automatically for a connection string with
  no password.

What it does:

- Creates `lsst_butler_repo_dir`, owned by `lsst_butler_repo_shared_group`
  with the setgid bit, same pattern as `lsst_install_dir`.
- *(only if `lsst_butler_repo_postgres_host` is set)* Writes a Postgres seed
  config (`registry.db`/`registry.namespace`) to a remote temp file, which
  `butler create` below is pointed at via `--seed-config`, then deletes the
  temp file afterwards. This doesn't need the pipeline environment sourced,
  so it's its own task rather than folded into the one below.
- Sources the activation script once, then in that same shell: runs `butler
  create` (skipped if a `butler.yaml` is already there) and registers each
  instrument listed in `lsst_butler_repo_instrument_classes` (defaults to
  just `lsst.obs.decam.DarkEnergyCamera`) with `--update`, so re-running is
  a no-op instead of failing on an already-registered instrument. Set
  `lsst_butler_repo_instrument_classes: []` to skip registration entirely.
  `butler create`/`register-instrument` are combined into one task (not one
  task each) because sourcing the pipeline environment is slow and Ansible
  gives every task its own fresh shell, so splitting it up would re-pay
  that cost per task.
- Recursively fixes group ownership/permissions, same as `lsst_pipeline`.

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
After running `custom_filters.yml`, re-register by hand (or re-run
`butler_repo.yml`, which does the same `--update` call) against each repo
that needs the new filters:

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
"Not included" above. After adding a new filter, re-register it against
each real repo that needs it - either by hand (see above) or by re-running
`butler_repo.yml` (see "Butler repo" above), which does the same
`--update` call.


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
