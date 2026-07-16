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
