# AGENTS.md

Guidance for AI agents and new contributors working on this repository.

## What this is

Minimal bash tooling that streams incremental btrfs snapshots to S3, encrypted client-side:

- `stream_backup.sh` — snapshot, then `btrfs send | lz4 | mbuffer | split --filter 'age | aws s3 cp'`
- `restore_backup.sh` — walks the S3 layout and feeds chunks to `lz4 -d | btrfs receive`
- `check_deps.sh` — dependency check, executed by both scripts
- `tests/` — mock-based test suite (`./tests/run.sh`)
- `examples/` — reference crontab, IAM policy, CloudFormation lifecycle-cleanup stack

Design goal (see README): **small and auditable beats featureful**. No custom file formats, no
metadata database — all state lives in btrfs snapshot naming on disk and S3 key naming
conventions. Keep it that way: plain bash, and no new runtime dependencies without a good reason.

## Invariants — do not break

These are load-bearing ABI between the backup script, the restore script, and backups already
sitting in users' buckets:

1. **S3 key layout**: `s3://BUCKET/PREFIX/EPOCH/<unix-seconds>_<hex-salt>/` containing chunks named
   by `split` (`x` prefix, 4-letter alphabetic suffix: `xaaaa`, `xaaab`, …) plus
   `snapshot_info.dat`. `restore_backup.sh` enumerates chunks by generating those names rather than
   listing the bucket, so if the backup's `split` flags change, the restore walk must change in
   lockstep. Any format change (compression, encryption, chunking) is only allowed under a **new
   epoch** (README design rule).
2. **Completion-marker-last**: `snapshot_info.dat` is uploaded only after every chunk, and restore
   treats a sequence as valid only if that marker exists and decrypts. Never upload it earlier, and
   never make restore trust a sequence without it. It is also uploaded without `--storage-class`, so
   it stays in STANDARD and can be read without a Glacier thaw.
3. **Local snapshot state is the incremental chain**: the newest snapshot under
   `${SUBV}/.stream_backup_<EPOCH>/` is the next run's `btrfs send -p` parent. A snapshot must never
   become eligible as a parent unless its own upload completed — otherwise restore skips its
   markerless sequence and every later increment fails with "cannot find parent subvolume", while
   the backups keep reporting success.
4. **Stream purity**: stdout of the backup pipeline IS the backup. Diagnostics go to stderr, never
   to the stdout of any pipeline stage. Merging stderr into the stream corrupted real backups once
   already (a130925, reverted in b131551).
5. **Least-privilege IAM is a feature**: the backup identity has `s3:PutObject` only — no List, no
   Delete — and unguessable salted key names are the anti-overwrite control. Don't add anything to
   the backup path that needs broader permission; `stream_backup.sh` deliberately *warns* at runtime
   if listing turns out to work.
6. **Exit codes are a monitoring API**: 0 success, 1 usage error, 2 failure after the snapshot was
   created, 3 missing dependency. Users alert on these, so keep them stable, document any addition
   in the README table, and never let a partial failure exit 0.

## Shell facts this code depends on

- `$PIPESTATUS` unindexed expands to element `[0]` only. Check the whole array
  (`STATUS=("${PIPESTATUS[@]}")`) or rely on `set -o pipefail`.
- `trap ERR` fires only when the *last* stage of a pipeline fails, unless `pipefail` is set. Do not
  add `set -E`: with `errtrace` the ERR trap is inherited by command substitutions, and the cleanup
  handler would run inside subshells.
- GNU `split --filter` runs the filter through `$SHELL -c`, not through the script's own
  interpreter, so `stream_backup.sh` passes an explicit `SHELL=` to `split` rather than letting the
  ambient login shell decide how the filter's error handling behaves. The filter runs as root, so
  its values reach it through the environment instead of being interpolated into its text.
- `$SHELL` is the login-shell variable, not the running interpreter. `$BASH_VERSION` is.
- These scripts run as root and delete subvolumes. Quote every expansion.

## Working on this repo

- **Run `./tests/run.sh`** before and after any change. It stubs every external command (`aws`,
  `btrfs`, `age`, `lz4`, `mbuffer`, `openssl`, `date`) on `PATH`, so it needs neither a btrfs
  filesystem nor an AWS account, and it re-executes itself under `unshare -r` to satisfy the root
  check. `./tests/run.sh <substring>` runs a subset.
- Tests assert **exit status *and* resulting state** (which keys were uploaded, in what order, and
  which snapshots survive). The bug class this project has to defend against is "reported success,
  wrong state", which an exit-code-only assertion cannot catch.
- Never run the real scripts against a real filesystem or real AWS while developing.
- The mocks cannot cover btrfs's own semantics — how snapshot paths are reported for the various
  mount layouts, or the top-level subvolume (id 5). Verify anything that depends on those against a
  real btrfs filesystem.
- Run `shellcheck` on anything you modify.
- Documentation is part of the product: the README's exit-code table and security guidance, and
  everything in `examples/`, are the reference deployment. Change them in the same commit as the
  behaviour they describe.
- `examples/aws/expire-old-backups.cfn.yaml`'s Lambda **replaces** the bucket's entire lifecycle
  configuration on every run — keep that in mind before adding lifecycle advice anywhere else.
- Commit style: short imperative subject lines, no prefixes; PRs are squash-merged with `(#N)`
  appended.
