# TODO

## Replace the anchor-regex patching with git patch files

`custom/apply_custom_filters.py` edits `obs_decam`/`skymap` by regex-
matching anchor lines in their source (mirroring the ansible
`blockinfile` tasks' approach) and inserting text at/after them. This
already broke once (see README.md "Known gaps" - the `skymap` anchor's
trailing `# DECam narrow-bands` comment) and is inherently fragile:
anything upstream changes about the surrounding line silently breaks the
match, and the failure only surfaces as an opaque "anchor not found"
error at build time.

Considered three fixes for this (reviewed in conversation, not
implemented yet - deliberately holding off changing anything for now):

1. **Git patch files** (recommended when this gets picked up): keep
   cloning real upstream at build time as now, but replace the regex
   edits with committed `.patch` files applied via `git apply`. Generated
   once locally (clone, make the edit, `git diff`), then checked into
   e.g. `custom/patches/`. No new hosting needed (unlike #2), no repo
   bloat (unlike #3). `git apply` fails with a precise rejected-hunk diff
   on upstream drift instead of a guessed anchor match - strictly better
   failure mode than today, though patches are still tied to a base
   commit and may need regenerating when `OBS_DECAM_REF`/`SKYMAP_REF`
   bump. Costs a new local workflow step (regenerate the patch) whenever
   `filters.yaml` changes, instead of today's "just edit the YAML" flow.
2. **Real forks with the change committed on a branch**: fork
   `obs_decam`/`skymap`, commit the filter changes for real, clone that
   branch directly - no patching logic at all. Cleanest match to "local
   copy with modifications already made," but needs hosting/maintaining
   two forks and manually rebasing onto each new upstream tag.
3. **Vendor the full patched source trees** into this repo, copied in via
   `%files` instead of `git clone`d - no network dependency at build
   time, fully reproducible regardless of upstream changes, but adds two
   third-party source trees to this repo with no automatic upstream
   tracking; needs manual re-vendor+re-patch on every version bump.
