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
  # check_deps.sh refuses to run unless $SHELL names bash, so the suite cannot
  # run under a zsh or sh login shell without this.
  export SHELL=/bin/bash
  unset FAIL_STAGE FAIL_CHUNK FS_PREFIX AWS_LS_OK AWS_LIST_FAIL AWS_ARCHIVED \
        AWS_HEAD_ERROR AGE_UNDECRYPTABLE NESTED_SUBVOLS STREAM_BYTES TEST_SALT \
        TEST_NOW
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

snapshots () {
  find "${TEST_SUBV}" -mindepth 2 -maxdepth 2 -type d -path '*/.stream_backup_*' \
    2>/dev/null | sed "s|${TEST_SUBV}/||" | sort
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
run_test "a failing btrfs send deletes the new snapshot"           test_btrfs_send_failure_is_caught
run_test "a failing snapshot leaves nothing behind"                test_snapshot_failure_leaves_nothing_behind
run_test "a missing dependency exits 3"                            test_missing_dependency_exits_3
run_test "no arguments prints the usage"                           test_no_arguments_prints_usage
run_test "an unknown subvolume is an error"                        test_unknown_subvolume_is_an_error
run_test "a listable bucket raises a security warning"             test_warns_when_the_identity_can_list_the_bucket

echo "Running the restore tests"
run_test "restore replays every sequence in order"                 test_restore_replays_every_sequence_in_order
run_test "restore skips a sequence with no valid marker"           test_restore_skips_a_sequence_with_no_valid_marker
run_test "restore -d keeps only the last snapshot"                 test_restore_deletes_previous_snapshots_with_d
run_test "restore without arguments prints the usage"              test_restore_without_arguments_prints_usage

echo
echo "${PASSED} passed, ${FAILED} failed"
if [ "${FAILED}" -ne 0 ]; then
  printf 'failed: %s\n' "${FAILURES[@]}"
  exit 1
fi
