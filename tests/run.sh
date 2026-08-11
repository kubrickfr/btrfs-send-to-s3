#!/bin/bash
#
# Test suite for stream_backup.sh and restore_backup.sh.
#
# Every external command the scripts call is replaced by a stub in tests/stubs,
# so no btrfs filesystem and no AWS account are needed.  The stubs record what
# they were asked to do in ${LOG}, and store "uploaded" objects under ${S3ROOT},
# which lets a backup produced here be replayed through the restore script.
#
# The scripts refuse to run as anything but root, so the suite re-executes
# itself in a user namespace where it is root.
#
# Usage: ./tests/run.sh [name-substring]

if [ "${EUID}" -ne 0 ]; then
  if command -v unshare >/dev/null 2>&1 && unshare -r true 2>/dev/null; then
    exec unshare -r "$0" "$@"
  fi
  echo "This suite must run as root; install util-linux for 'unshare -r' or run it as root." >&2
  exit 1
fi

TESTS_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(dirname -- "${TESTS_DIR}")
FILTER=${1:-}

PASSED=0
FAILED=0
FAILURES=()
CURRENT=""

# ---------------------------------------------------------------- test harness

setup () {
  # The previous test's TMPDIR has been deleted by now.
  unset TMPDIR
  WORK=$(mktemp -d)
  export TEST_SUBV=${WORK}/subv
  export S3ROOT=${WORK}/s3
  export LOG=${WORK}/actions.log
  export BUCKET=bucket
  export PREFIX=host
  mkdir -p "${TEST_SUBV}" "${S3ROOT}/${BUCKET}"
  : >"${LOG}"
  echo "age1exampleexamplerecipientkey" >"${WORK}/recipients.txt"
  echo "AGE-SECRET-KEY-EXAMPLE" >"${WORK}/identity.txt"
  # What cron sets, and therefore what the scripts have to cope with.
  export SHELL=/bin/sh
  # Keeps temporary files, including lock files, inside the test's own directory.
  export TMPDIR=${WORK}
  unset FAIL_STAGE FAIL_CHUNK FAIL_RECEIVE FS_PREFIX AWS_LS_OK AWS_LIST_FAIL \
        AWS_ARCHIVED AWS_HEAD_ERROR AWS_HANG AGE_UNDECRYPTABLE NESTED_SUBVOLS \
        STREAM_BYTES TEST_SALT TEST_NOW
}

teardown () {
  [ -n "${WORK}" ] && rm -rf -- "${WORK}"
}

backup () {
  PATH="${TESTS_DIR}/stubs:${PATH}" \
    "${REPO_DIR}/stream_backup.sh" \
      -r "${WORK}/recipients.txt" -b "${BUCKET}" -p "${PREFIX}" \
      -s "${TEST_SUBV}" "$@" >"${WORK}/stdout" 2>"${WORK}/stderr"
}

restore () {
  PATH="${TESTS_DIR}/stubs:${PATH}" \
    "${REPO_DIR}/restore_backup.sh" \
      -i "${WORK}/identity.txt" -b "${BUCKET}" -p "${PREFIX}" "$@" \
      >"${WORK}/stdout" 2>"${WORK}/stderr"
}

# Keys uploaded to S3, in the order they were uploaded.
uploaded () {
  grep '^UPLOADED: ' "${LOG}" | sed 's|^UPLOADED: ||'
}

# Everything the stubs recorded, for failure diagnostics.
actions () {
  cat "${LOG}"
}

# Snapshots that count as complete: named after their sequence number and
# sitting directly in an epoch directory.
snapshots () {
  find "${TEST_SUBV}" -mindepth 2 -maxdepth 2 -type d -path '*/.stream_backup_*' \
    2>/dev/null | sed "s|${TEST_SUBV}/||" | grep -E '/[0-9]+$' | LC_ALL=C sort
}

# Snapshots still in the staging directory, which no run may chain from.
staged () {
  find "${TEST_SUBV}" -mindepth 3 -maxdepth 3 -type d -path '*/.incomplete/*' \
    2>/dev/null | sed "s|${TEST_SUBV}/||" | LC_ALL=C sort
}

fail () {
  FAILED=$((FAILED + 1))
  FAILURES+=("${CURRENT}")
  echo "  FAIL: ${CURRENT}"
  printf '        %s\n' "$@"
  if [ -s "${WORK}/stderr" ]; then
    echo "        --- stderr ---"
    sed 's/^/        /' "${WORK}/stderr"
  fi
  if [ -s "${LOG}" ]; then
    echo "        --- actions ---"
    sed 's/^/        /' "${LOG}"
  fi
}

pass () {
  PASSED=$((PASSED + 1))
  echo "  ok: ${CURRENT}"
}

assert_status () {
  [ "$1" = "$2" ] && return 0
  fail "expected exit status $2, got $1"
  return 1
}

assert_equal () {
  [ "$1" = "$2" ] && return 0
  fail "expected: $2" "actual:   $1"
  return 1
}

assert_contains () {
  case $1 in
    *"$2"*) return 0 ;;
  esac
  fail "expected to find: $2" "in: $1"
  return 1
}

run_test () {
  CURRENT=$1
  case ${CURRENT} in
    *"${FILTER}"*) ;;
    *) return 0 ;;
  esac
  setup
  if "$2"; then pass; fi
  teardown
}

# ------------------------------------------------------------ backup: the good path

test_full_backup () {
  backup -c STANDARD -e first
  local status=$?
  assert_status "${status}" 0 || return 1

  local keys
  keys=$(uploaded)
  assert_equal "$(printf '%s\n' "${keys}" | head -n1)" \
               "${BUCKET}/${PREFIX}/first/1_00000000deadbeef/xaaaa" || return 1
  # The completion marker must be uploaded last: it is what makes the sequence
  # valid, and restore trusts nothing without it.
  assert_equal "$(printf '%s\n' "${keys}" | tail -n1)" \
               "${BUCKET}/${PREFIX}/first/1_00000000deadbeef/snapshot_info.dat" || return 1
  assert_contains "$(actions)" "SENT: 1 parent=none" || return 1
  assert_equal "$(snapshots)" ".stream_backup_first/1" || return 1
  return 0
}

test_incremental_backup () {
  backup -c STANDARD -e first || { fail "the first backup failed"; return 1; }
  TEST_NOW=2 backup -c STANDARD -e first
  local status=$?
  assert_status "${status}" 0 || return 1
  assert_contains "$(actions)" "SENT: 2 parent=1" || return 1
  assert_equal "$(snapshots)" ".stream_backup_first/1
.stream_backup_first/2" || return 1
  return 0
}

test_delete_previous_snapshot () {
  backup -c STANDARD -e first || { fail "the first backup failed"; return 1; }
  TEST_NOW=2 backup -c STANDARD -e first -d
  local status=$?
  assert_status "${status}" 0 || return 1
  assert_equal "$(snapshots)" ".stream_backup_first/2" || return 1
  return 0
}

test_new_epoch_is_a_full_backup () {
  backup -c STANDARD -e first || { fail "the first backup failed"; return 1; }
  TEST_NOW=2 backup -c STANDARD -e second -d
  local status=$?
  assert_status "${status}" 0 || return 1
  assert_contains "$(actions)" "SENT: 2 parent=none" || return 1
  # -d must not delete across epochs: the other epoch's chain still needs it.
  assert_equal "$(snapshots)" ".stream_backup_first/1
.stream_backup_second/2" || return 1
  return 0
}

test_branch_from_another_epoch () {
  backup -c STANDARD -e monthly || { fail "the first backup failed"; return 1; }
  TEST_NOW=2 backup -c STANDARD -e daily -B monthly -d
  local status=$?
  assert_status "${status}" 0 || return 1
  assert_contains "$(actions)" "SENT: 2 parent=1" || return 1
  # -d must not delete the branch parent, which belongs to the other epoch.
  assert_equal "$(snapshots)" ".stream_backup_daily/2
.stream_backup_monthly/1" || return 1
  return 0
}

test_branch_epoch_missing_is_an_error () {
  backup -c STANDARD -e daily -B nonexistent
  assert_status "$?" 1 || return 1
  assert_contains "$(cat "${WORK}/stderr")" "ERROR" || return 1
  return 0
}

# --------------------------------------------------------------- backup: layouts
#
# 'btrfs subvolume show' reports a subvolume's path relative to the root of the
# filesystem, which has nothing to do with where it is mounted. These are the
# layouts where the two differ.

# What "mount -o subvol=@home" gives you: mounted at /home, called @home inside
# the filesystem.
test_incremental_backup_on_a_subvol_mount () {
  FS_PREFIX="@home" backup -c STANDARD -e first \
    || { fail "the first backup failed"; return 1; }
  FS_PREFIX="@home" TEST_NOW=2 backup -c STANDARD -e first
  local status=$?
  assert_status "${status}" 0 || return 1
  assert_contains "$(actions)" "SENT: 2 parent=1" || return 1
  return 0
}

# The top-level subvolume, id 5, whose path is reported as "/".
test_incremental_backup_of_the_top_level_subvolume () {
  FS_PREFIX="/" backup -c STANDARD -e first \
    || { fail "the first backup failed"; return 1; }
  FS_PREFIX="/" TEST_NOW=2 backup -c STANDARD -e first -d
  local status=$?
  assert_status "${status}" 0 || return 1
  assert_contains "$(actions)" "SENT: 2 parent=1" || return 1
  # -d has to work here too, or snapshots pile up until the disk fills.
  assert_equal "$(snapshots)" ".stream_backup_first/2" || return 1
  return 0
}

# One epoch name being a prefix of another must not make them share snapshots.
test_epoch_names_that_share_a_prefix_stay_separate () {
  backup -c STANDARD -e daily-2026-10 || { fail "the first backup failed"; return 1; }
  TEST_NOW=2 backup -c STANDARD -e daily-2026-1 -d
  local status=$?
  assert_status "${status}" 0 || return 1
  assert_contains "$(actions)" "SENT: 2 parent=none" || return 1
  assert_equal "$(snapshots)" ".stream_backup_daily-2026-1/2
.stream_backup_daily-2026-10/1" || return 1
  return 0
}

# --------------------------------------------------------- backup: failures it catches

test_btrfs_send_failure_is_caught () {
  FAIL_STAGE=send backup -c STANDARD -e first
  assert_status "$?" 2 || return 1
  # No completion marker, so restore will skip the sequence.
  assert_equal "$(uploaded | grep -c snapshot_info.dat)" "0" || return 1
  # The snapshot must be gone so the next run re-chains from the last good one.
  assert_equal "$(snapshots)" "" || return 1
  return 0
}

test_snapshot_failure_leaves_nothing_behind () {
  FAIL_STAGE=snapshot backup -c STANDARD -e first
  assert_status "$?" 1 || return 1
  assert_equal "$(uploaded)" "" || return 1
  assert_equal "$(snapshots)" "" || return 1
  return 0
}

test_missing_dependency_exits_3 () {
  PATH="${TESTS_DIR}/stubs:/nonexistent" \
    "${REPO_DIR}/stream_backup.sh" -r x -b y -p z -e e -c STANDARD -s "${TEST_SUBV}" \
    >"${WORK}/stdout" 2>"${WORK}/stderr"
  assert_status "$?" 3 || return 1
  return 0
}

# systemd timers pass no SHELL at all, and cron passes /bin/sh: neither must
# stop a backup, and neither must change how the split filter behaves.
test_backup_works_without_a_shell_variable () {
  env -u SHELL PATH="${TESTS_DIR}/stubs:${PATH}" \
    TEST_SUBV="${TEST_SUBV}" S3ROOT="${S3ROOT}" LOG="${LOG}" \
    "${REPO_DIR}/stream_backup.sh" \
      -r "${WORK}/recipients.txt" -b "${BUCKET}" -p "${PREFIX}" \
      -s "${TEST_SUBV}" -c STANDARD -e first \
    >"${WORK}/stdout" 2>"${WORK}/stderr"
  assert_status "$?" 0 || return 1
  assert_equal "$(uploaded | tail -n1)" \
               "${BUCKET}/${PREFIX}/first/1_00000000deadbeef/snapshot_info.dat" || return 1
  return 0
}

test_running_under_a_non_bash_shell_is_refused () {
  local shell=""
  local candidate
  for candidate in dash ash sh; do
    command -v "${candidate}" >/dev/null 2>&1 || continue
    [ -z "$("${candidate}" -c 'echo ${BASH_VERSION}' 2>/dev/null)" ] || continue
    shell=${candidate}
    break
  done
  if [ -z "${shell}" ]; then
    echo "  (skipped, every available sh is bash): ${CURRENT}"
    return 1
  fi
  PATH="${TESTS_DIR}/stubs:${PATH}" "${shell}" "${REPO_DIR}/stream_backup.sh" \
    >"${WORK}/stdout" 2>"${WORK}/stderr"
  assert_status "$?" 3 || return 1
  return 0
}

# check_deps.sh only uses shell builtins, so it can be run with a PATH holding
# nothing but the stubs, which is the only way to make a command truly absent.
test_check_deps_reports_a_missing_openssl () {
  local bin="${WORK}/bin"
  mkdir -p "${bin}"
  local stub
  for stub in "${TESTS_DIR}"/stubs/*; do
    [ "$(basename -- "${stub}")" = openssl ] && continue
    ln -s "${stub}" "${bin}/"
  done
  # The tools with no stub of their own still have to be findable.
  local real
  for real in split sed; do
    ln -s "$(command -v "${real}")" "${bin}/"
  done
  PATH="${bin}" "${REPO_DIR}/check_deps.sh" >"${WORK}/stdout" 2>"${WORK}/stderr"
  assert_status "$?" 3 || return 1
  assert_contains "$(cat "${WORK}/stderr")" "openssl" || return 1
  return 0
}

# Without a salt the object names become guessable, which is the whole of the
# defence against a compromised host overwriting earlier backups.
test_a_failing_salt_stops_the_backup () {
  FAIL_STAGE=openssl backup -c STANDARD -e first
  local status=$?
  [ "${status}" -eq 0 ] && { fail "the backup succeeded without a salt"; return 1; }
  assert_equal "$(uploaded)" "" || return 1
  return 0
}

test_no_arguments_prints_usage () {
  PATH="${TESTS_DIR}/stubs:${PATH}" "${REPO_DIR}/stream_backup.sh" \
    >"${WORK}/stdout" 2>"${WORK}/stderr"
  assert_status "$?" 1 || return 1
  assert_contains "$(cat "${WORK}/stdout")" "Usage:" || return 1
  return 0
}

test_unknown_subvolume_is_an_error () {
  backup -c STANDARD -e first -s "${WORK}/nope"
  assert_status "$?" 1 || return 1
  return 0
}

test_warns_when_the_identity_can_list_the_bucket () {
  AWS_LS_OK=1 backup -c STANDARD -e first
  assert_status "$?" 0 || return 1
  assert_contains "$(cat "${WORK}/stderr")" "SECURITY WARNING" || return 1
  return 0
}

# --------------------------------------------------- backup: failures mid-upload
#
# A failure here must never leave the completion marker in S3: that marker is
# what tells a restore the sequence is whole.

# A chunk upload that fails only once the whole chunk has been read is the shape
# a multipart completion failure or an expiring credential takes.
assert_upload_failure_is_reported () {
  assert_status "$1" 2 || return 1
  assert_equal "$(uploaded | grep -c snapshot_info.dat)" "0" || return 1
  assert_equal "$(snapshots)" "" || return 1
  assert_equal "$(staged)" "" || return 1
  return 0
}

test_failing_chunk_upload_fails_the_backup () {
  STREAM_BYTES=4000 FAIL_STAGE=aws FAIL_CHUNK=xaaab \
    backup -c STANDARD -e first -S 1000
  assert_upload_failure_is_reported "$?" || return 1
  return 0
}

test_failing_last_chunk_upload_fails_the_backup () {
  STREAM_BYTES=4000 FAIL_STAGE=aws FAIL_CHUNK=xaaae \
    backup -c STANDARD -e first -S 1000
  assert_upload_failure_is_reported "$?" || return 1
  return 0
}

test_failing_encryption_fails_the_backup () {
  STREAM_BYTES=4000 FAIL_STAGE=age FAIL_CHUNK=xaaab \
    backup -c STANDARD -e first -S 1000
  assert_upload_failure_is_reported "$?" || return 1
  return 0
}

test_failing_compression_fails_the_backup () {
  FAIL_STAGE=lz4 backup -c STANDARD -e first
  assert_upload_failure_is_reported "$?" || return 1
  return 0
}

# mbuffer dying once its producers have finished gives split a clean EOF, so the
# truncated stream looks like a complete one.
test_a_killed_buffer_fails_the_backup () {
  STREAM_BYTES=4000 FAIL_STAGE=mbuffer backup -c STANDARD -e first -S 1000
  assert_upload_failure_is_reported "$?" || return 1
  return 0
}

# Here every chunk uploads cleanly and only the marker's encryption fails, with
# the upload of the resulting nothing succeeding.
test_failing_marker_encryption_fails_the_backup () {
  FAIL_STAGE=age backup -c STANDARD -e first
  assert_status "$?" 2 || return 1
  assert_equal "$(snapshots)" "" || return 1
  return 0
}

test_failing_marker_generation_fails_the_backup () {
  FAIL_STAGE=show backup -c STANDARD -e first
  assert_status "$?" 2 || return 1
  assert_equal "$(uploaded | grep -c snapshot_info.dat)" "0" || return 1
  return 0
}

test_the_error_names_the_stage_that_failed () {
  FAIL_STAGE=lz4 backup -c STANDARD -e first
  assert_contains "$(cat "${WORK}/stderr")" "lz4=1" || return 1
  return 0
}

# btrfs send's diagnostics are the only clue when a send fails, and stdout is
# the backup itself, so they have to come back on stderr.
test_a_failing_send_reports_its_error () {
  FAIL_STAGE=send backup -c STANDARD -e first
  assert_contains "$(cat "${WORK}/stderr")" "cannot find parent subvolume" || return 1
  return 0
}

test_a_successful_backup_is_quiet_about_send () {
  backup -c STANDARD -e first
  assert_status "$?" 0 || return 1
  # "At subvol ..." is normal progress chatter; cron should not see it.
  case $(cat "${WORK}/stderr") in
    *"At subvol"*) fail "btrfs send progress leaked to stderr on a good run"; return 1 ;;
  esac
  return 0
}

# ------------------------------------------------ backup: snapshots left half-done
#
# A snapshot whose upload never finished has no completion marker in S3, so
# restore skips its sequence. Chaining the next backup from it would therefore
# break every backup after it, while each of them still reported success.

test_an_orphaned_snapshot_is_not_used_as_a_parent () {
  backup -c STANDARD -e first || { fail "the first backup failed"; return 1; }
  # What a run killed mid-upload leaves behind.
  mkdir -p "${TEST_SUBV}/.stream_backup_first/.incomplete/5"
  : >"${LOG}"

  TEST_NOW=6 backup -c STANDARD -e first
  local status=$?
  assert_status "${status}" 0 || return 1
  assert_contains "$(actions)" "SENT: 6 parent=1" || return 1
  assert_contains "$(cat "${WORK}/stderr")" "WARNING" || return 1
  assert_equal "$(staged)" "" || return 1
  assert_equal "$(snapshots)" ".stream_backup_first/1
.stream_backup_first/6" || return 1
  return 0
}

test_a_terminated_backup_leaves_nothing_behind () {
  local i=0

  # The backup gets a session of its own so that signalling its process group
  # cannot touch the test suite; setsid --wait still reports its exit status.
  (
    AWS_HANG=1 PGID_FILE="${WORK}/pgid" PATH="${TESTS_DIR}/stubs:${PATH}" \
      setsid --fork --wait "${REPO_DIR}/stream_backup.sh" \
        -r "${WORK}/recipients.txt" -b "${BUCKET}" -p "${PREFIX}" \
        -s "${TEST_SUBV}" -c STANDARD -e first >/dev/null 2>&1
    echo $? >"${WORK}/status"
  ) &

  while [ ! -s "${WORK}/pgid" ]; do
    i=$((i + 1))
    [ "${i}" -gt 200 ] && { fail "the backup never got as far as uploading"; return 1; }
    sleep 0.05
  done

  # systemd signals the whole process group at shutdown, which is what ends the
  # pipeline and lets the trap run.
  kill -TERM -"$(cat "${WORK}/pgid")" 2>/dev/null

  i=0
  while [ ! -f "${WORK}/status" ]; do
    i=$((i + 1))
    [ "${i}" -gt 200 ] && { fail "the backup did not exit after SIGTERM"; return 1; }
    sleep 0.05
  done

  assert_equal "$(cat "${WORK}/status")" "2" || return 1
  assert_equal "$(staged)" "" || return 1
  assert_equal "$(snapshots)" "" || return 1
  assert_equal "$(uploaded | grep -c snapshot_info.dat)" "0" || return 1
  return 0
}

# The backup is safe in S3 by then, so tidying up afterwards must not be able to
# destroy it, and must not be reported as a failed backup either.
test_a_failed_tidy_up_keeps_the_backup () {
  backup -c STANDARD -e first || { fail "the first backup failed"; return 1; }
  : >"${LOG}"

  TEST_NOW=2 FAIL_STAGE=delete backup -c STANDARD -e first -d
  local status=$?
  assert_status "${status}" 4 || return 1
  assert_equal "$(uploaded | tail -n1)" \
               "${BUCKET}/${PREFIX}/first/2_00000000deadbeef/snapshot_info.dat" || return 1
  assert_equal "$(snapshots)" ".stream_backup_first/1
.stream_backup_first/2" || return 1
  return 0
}

# ------------------------------------------------------- backup: runs that overlap

# Two runs at once can both pick the same parent, or one can pick a snapshot the
# other has not finished uploading.
test_a_second_run_on_the_same_subvolume_is_refused () {
  local i=0

  (
    AWS_HANG=1 PGID_FILE="${WORK}/pgid" PATH="${TESTS_DIR}/stubs:${PATH}" \
      setsid --fork --wait "${REPO_DIR}/stream_backup.sh" \
        -r "${WORK}/recipients.txt" -b "${BUCKET}" -p "${PREFIX}" \
        -s "${TEST_SUBV}" -c STANDARD -e first >/dev/null 2>&1
    echo $? >"${WORK}/status"
  ) &

  while [ ! -s "${WORK}/pgid" ]; do
    i=$((i + 1))
    [ "${i}" -gt 200 ] && { fail "the first run never got as far as uploading"; return 1; }
    sleep 0.05
  done

  # A different epoch, because the lock is about the subvolume, not the epoch.
  TEST_NOW=2 backup -c STANDARD -e second
  local status=$?

  kill -TERM -"$(cat "${WORK}/pgid")" 2>/dev/null
  i=0
  while [ ! -f "${WORK}/status" ]; do
    i=$((i + 1))
    [ "${i}" -gt 200 ] && break
    sleep 0.05
  done

  assert_status "${status}" 1 || return 1
  assert_contains "$(cat "${WORK}/stderr")" "Refusing to run two at once" || return 1
  return 0
}

# Restoring replays sequences in the order of their numbers, so a snapshot
# numbered below its own parent could never be restored.
test_a_clock_that_went_backwards_is_refused () {
  TEST_NOW=100 backup -c STANDARD -e first \
    || { fail "the first backup failed"; return 1; }
  : >"${LOG}"

  TEST_NOW=50 backup -c STANDARD -e first
  local status=$?
  assert_status "${status}" 1 || return 1
  assert_equal "$(uploaded)" "" || return 1
  assert_equal "$(snapshots)" ".stream_backup_first/100" || return 1
  return 0
}

test_a_second_backup_in_the_same_second_is_refused () {
  backup -c STANDARD -e first || { fail "the first backup failed"; return 1; }
  : >"${LOG}"

  backup -c STANDARD -e first
  assert_status "$?" 1 || return 1
  assert_equal "$(uploaded)" "" || return 1
  return 0
}

# ------------------------------------------------------------------------ restore

test_restore_replays_every_sequence_in_order () {
  backup -c STANDARD -e first || { fail "the first backup failed"; return 1; }
  TEST_NOW=2 backup -c STANDARD -e first || { fail "the second backup failed"; return 1; }
  mkdir -p "${WORK}/dest"
  : >"${LOG}"

  restore -e first -s "${WORK}/dest"
  local status=$?
  assert_status "${status}" 0 || return 1
  assert_equal "$(grep '^RECEIVED: ' "${LOG}" | sed 's|^RECEIVED: ||' | tr '\n' ' ')" "1 2 " || return 1
  return 0
}

test_restore_skips_a_sequence_with_no_valid_marker () {
  backup -c STANDARD -e first || { fail "the first backup failed"; return 1; }
  TEST_NOW=2 backup -c STANDARD -e first || { fail "the second backup failed"; return 1; }
  # Make the last sequence's marker undecryptable, the way a sequence whose
  # upload was interrupted before the marker looks.
  printf 'GARBAGE' >"${S3ROOT}/${BUCKET}/${PREFIX}/first/2_00000000deadbeef/snapshot_info.dat"
  mkdir -p "${WORK}/dest"
  : >"${LOG}"

  AGE_UNDECRYPTABLE=GARBAGE restore -e first -s "${WORK}/dest"
  local status=$?
  assert_status "${status}" 0 || return 1
  assert_equal "$(grep '^RECEIVED: ' "${LOG}" | sed 's|^RECEIVED: ||' | tr '\n' ' ')" "1 " || return 1
  assert_contains "$(cat "${WORK}/stderr")" "WARNING" || return 1
  return 0
}

test_restore_deletes_previous_snapshots_with_d () {
  backup -c STANDARD -e first || { fail "the first backup failed"; return 1; }
  TEST_NOW=2 backup -c STANDARD -e first || { fail "the second backup failed"; return 1; }
  mkdir -p "${WORK}/dest"
  : >"${LOG}"

  restore -e first -s "${WORK}/dest" -d
  local status=$?
  assert_status "${status}" 0 || return 1
  assert_equal "$(ls "${WORK}/dest")" "2" || return 1
  return 0
}

# ------------------------------------------------------- restore: failures
#
# Every sequence is an increment on the one before it, so a restore that fails
# half way has to stop, say so, and leave the last good snapshot alone: that
# snapshot is the parent the retry will need.

restore_three_sequences () {
  backup -c STANDARD -e first || return 1
  TEST_NOW=2 backup -c STANDARD -e first || return 1
  TEST_NOW=3 backup -c STANDARD -e first || return 1
  mkdir -p "${WORK}/dest"
  : >"${LOG}"
}

test_a_failed_receive_stops_the_restore () {
  restore_three_sequences || { fail "the backups failed"; return 1; }

  FAIL_RECEIVE=2 restore -e first -s "${WORK}/dest" -d
  local status=$?
  assert_status "${status}" 2 || return 1
  assert_equal "$(grep -c '^RECEIVED: ' "${LOG}")" "1" || return 1
  # The snapshot that did restore has to survive: it is what the next attempt
  # will chain from.
  assert_equal "$(ls "${WORK}/dest")" "1" || return 1
  assert_contains "$(cat "${WORK}/stdout")" "restored in: ${WORK}/dest/1" || return 1
  return 0
}

test_a_chunk_that_will_not_decrypt_stops_the_restore () {
  backup -c STANDARD -e first || { fail "the first backup failed"; return 1; }
  TEST_NOW=2 backup -c STANDARD -e first || { fail "the second backup failed"; return 1; }
  mkdir -p "${WORK}/dest"
  : >"${LOG}"

  AGE_UNDECRYPTABLE="subvol=2" restore -e first -s "${WORK}/dest"
  local status=$?
  assert_status "${status}" 2 || return 1
  assert_equal "$(grep -c '^RECEIVED: ' "${LOG}")" "1" || return 1
  return 0
}

# head-object answers 200 for an object still in Glacier, which is easily
# mistaken for a chunk that is simply not there.
test_an_archived_chunk_is_reported_as_such () {
  backup -c STANDARD -e first || { fail "the first backup failed"; return 1; }
  mkdir -p "${WORK}/dest"
  : >"${LOG}"

  AWS_ARCHIVED=xaaaa restore -e first -s "${WORK}/dest"
  local status=$?
  assert_status "${status}" 4 || return 1
  assert_contains "$(cat "${WORK}/stderr")" "Glacier" || return 1
  return 0
}

test_a_failed_listing_is_an_error () {
  mkdir -p "${WORK}/dest"
  AWS_LIST_FAIL=1 restore -e first -s "${WORK}/dest"
  assert_status "$?" 1 || return 1
  return 0
}

test_an_empty_epoch_is_an_error () {
  mkdir -p "${WORK}/dest"
  restore -e nothing-here -s "${WORK}/dest"
  assert_status "$?" 1 || return 1
  assert_contains "$(cat "${WORK}/stderr")" "no backup found" || return 1
  return 0
}

test_restoring_nothing_at_all_is_an_error () {
  backup -c STANDARD -e first || { fail "the first backup failed"; return 1; }
  printf 'GARBAGE' >"${S3ROOT}/${BUCKET}/${PREFIX}/first/1_00000000deadbeef/snapshot_info.dat"
  mkdir -p "${WORK}/dest"

  AGE_UNDECRYPTABLE=GARBAGE restore -e first -s "${WORK}/dest"
  assert_status "$?" 2 || return 1
  assert_contains "$(cat "${WORK}/stderr")" "No snapshot was restored" || return 1
  return 0
}

test_restore_without_arguments_prints_usage () {
  PATH="${TESTS_DIR}/stubs:${PATH}" "${REPO_DIR}/restore_backup.sh" \
    >"${WORK}/stdout" 2>"${WORK}/stderr"
  assert_status "$?" 1 || return 1
  assert_contains "$(cat "${WORK}/stdout")" "Usage:" || return 1
  return 0
}

# ----------------------------------------------------------------------- run them

echo "Running the backup tests"
run_test "a full backup uploads chunks then the completion marker" test_full_backup
run_test "a second backup in the same epoch is incremental"        test_incremental_backup
run_test "-d deletes the snapshot it chained from"                 test_delete_previous_snapshot
run_test "a new epoch starts a full backup"                        test_new_epoch_is_a_full_backup
run_test "-B chains a new epoch from another one"                  test_branch_from_another_epoch
run_test "-B with no snapshot to branch from fails"                test_branch_epoch_missing_is_an_error
run_test "incrementals work on a subvol= mount"                    test_incremental_backup_on_a_subvol_mount
run_test "incrementals work on the top-level subvolume"            test_incremental_backup_of_the_top_level_subvolume
run_test "epoch names sharing a prefix stay separate"              test_epoch_names_that_share_a_prefix_stay_separate
run_test "a failing btrfs send deletes the new snapshot"           test_btrfs_send_failure_is_caught
run_test "a failing snapshot leaves nothing behind"                test_snapshot_failure_leaves_nothing_behind
run_test "a missing dependency exits 3"                            test_missing_dependency_exits_3
run_test "a backup works with no SHELL in the environment"         test_backup_works_without_a_shell_variable
run_test "running under a non-bash shell is refused"               test_running_under_a_non_bash_shell_is_refused
run_test "check_deps reports a missing openssl"                    test_check_deps_reports_a_missing_openssl
run_test "a failing salt stops the backup"                         test_a_failing_salt_stops_the_backup
run_test "no arguments prints the usage"                           test_no_arguments_prints_usage
run_test "an unknown subvolume is an error"                        test_unknown_subvolume_is_an_error
run_test "a listable bucket raises a security warning"             test_warns_when_the_identity_can_list_the_bucket

echo "Running the backup failure tests"
run_test "a failing chunk upload fails the backup"                 test_failing_chunk_upload_fails_the_backup
run_test "a failing last chunk upload fails the backup"            test_failing_last_chunk_upload_fails_the_backup
run_test "a failing encryption fails the backup"                   test_failing_encryption_fails_the_backup
run_test "a failing compression fails the backup"                  test_failing_compression_fails_the_backup
run_test "a killed buffer fails the backup"                        test_a_killed_buffer_fails_the_backup
run_test "a failing marker encryption fails the backup"            test_failing_marker_encryption_fails_the_backup
run_test "a failing marker generation fails the backup"            test_failing_marker_generation_fails_the_backup
run_test "the error names the stage that failed"                   test_the_error_names_the_stage_that_failed
run_test "a failing send reports its error"                        test_a_failing_send_reports_its_error
run_test "a successful backup is quiet about send"                 test_a_successful_backup_is_quiet_about_send

echo "Running the interrupted backup tests"
run_test "an orphaned snapshot is not used as a parent"            test_an_orphaned_snapshot_is_not_used_as_a_parent
run_test "a terminated backup leaves nothing behind"               test_a_terminated_backup_leaves_nothing_behind
run_test "a failed tidy up keeps the backup"                       test_a_failed_tidy_up_keeps_the_backup

echo "Running the overlapping run tests"
run_test "a second run on the same subvolume is refused"           test_a_second_run_on_the_same_subvolume_is_refused
run_test "a clock that went backwards is refused"                  test_a_clock_that_went_backwards_is_refused
run_test "a second backup in the same second is refused"           test_a_second_backup_in_the_same_second_is_refused

echo "Running the restore tests"
run_test "restore replays every sequence in order"                 test_restore_replays_every_sequence_in_order
run_test "restore skips a sequence with no valid marker"           test_restore_skips_a_sequence_with_no_valid_marker
run_test "restore -d keeps only the last snapshot"                 test_restore_deletes_previous_snapshots_with_d
run_test "restore without arguments prints the usage"              test_restore_without_arguments_prints_usage

echo "Running the restore failure tests"
run_test "a failed receive stops the restore"                      test_a_failed_receive_stops_the_restore
run_test "a chunk that will not decrypt stops the restore"         test_a_chunk_that_will_not_decrypt_stops_the_restore
run_test "an archived chunk is reported as such"                   test_an_archived_chunk_is_reported_as_such
run_test "a failed listing is an error"                            test_a_failed_listing_is_an_error
run_test "an empty epoch is an error"                              test_an_empty_epoch_is_an_error
run_test "restoring nothing at all is an error"                    test_restoring_nothing_at_all_is_an_error

echo
echo "${PASSED} passed, ${FAILED} failed"
if [ "${FAILED}" -ne 0 ]; then
  printf 'failed: %s\n' "${FAILURES[@]}"
  exit 1
fi
