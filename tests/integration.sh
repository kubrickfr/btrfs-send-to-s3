#!/bin/bash
#
# Integration check against a real btrfs filesystem.
#
# tests/run.sh replaces btrfs with a stub, so it cannot say anything about how
# btrfs itself behaves. This does the opposite: real btrfs on a loopback image,
# with only the S3 and encryption side stubbed out. It is what backs the two
# assumptions the unit tests take on trust:
#
#   * moving a read-only snapshot out of the staging directory is a plain
#     rename, and the snapshot it produces is still usable as the parent of the
#     next incremental send;
#   * the top-level subvolume, whose path btrfs reports as "/", is backed up and
#     restored like any other.
#
# Needs root, because it makes a filesystem and mounts it. Nothing outside its
# own temporary directory and loop device is touched.
#
# Usage: sudo ./tests/integration.sh

set -o pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "This has to run as root: it makes a filesystem and mounts it." >&2
  echo "Try: sudo $0" >&2
  exit 1
fi

for cmd in mkfs.btrfs btrfs losetup mount umount; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "command not found: ${cmd}" >&2
    exit 3
  fi
done

TESTS_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(dirname -- "${TESTS_DIR}")

WORK=$(mktemp -d)
MOUNT=${WORK}/mnt
IMAGE=${WORK}/btrfs.img
LOOP=""
FAILED=0

cleanup () {
  cd /
  umount "${MOUNT}" 2>/dev/null
  if [ -n "${LOOP}" ]; then
    losetup -d "${LOOP}" 2>/dev/null
  fi
  rm -rf -- "${WORK}"
}
trap cleanup EXIT

report () {
  if [ "$1" = 0 ]; then
    echo "  ok: $2"
  else
    echo "  FAIL: $2"
    FAILED=$((FAILED + 1))
  fi
}

# Everything except btrfs is stubbed, so the S3 side and the encryption stay out
# of the way while btrfs does the real work.
BIN=${WORK}/bin
mkdir -p "${BIN}"
for stub in "${TESTS_DIR}"/stubs/*; do
  [ "$(basename -- "${stub}")" = btrfs ] && continue
  ln -s "${stub}" "${BIN}/"
done

export PATH="${BIN}:${PATH}"
export S3ROOT=${WORK}/s3
export LOG=${WORK}/actions.log
export TMPDIR=${WORK}
mkdir -p "${S3ROOT}/bucket" "${MOUNT}"
: >"${LOG}"
echo "age1exampleexamplerecipientkey" >"${WORK}/recipients.txt"
echo "AGE-SECRET-KEY-EXAMPLE" >"${WORK}/identity.txt"

truncate -s 2G "${IMAGE}"
LOOP=$(losetup --find --show "${IMAGE}")
mkfs.btrfs -q "${LOOP}"
mount "${LOOP}" "${MOUNT}"

backup () {
  "${REPO_DIR}/stream_backup.sh" \
    -r "${WORK}/recipients.txt" -b bucket -p host "$@"
}

restore () {
  "${REPO_DIR}/restore_backup.sh" \
    -i "${WORK}/identity.txt" -b bucket -p host "$@"
}

echo "Backing up and restoring a subvolume"

btrfs subvolume create "${MOUNT}/data" >/dev/null
echo "first" >"${MOUNT}/data/one.txt"

TEST_NOW=1001 backup -s "${MOUNT}/data" -c STANDARD -e e1 >/dev/null
report $? "a full backup of a subvolume"

# The promotion is the assumption under test: the snapshot has to have left the
# staging directory and be a real subvolume where the next run will look.
[ -d "${MOUNT}/data/.stream_backup_e1/1001" ] \
  && btrfs subvolume show "${MOUNT}/data/.stream_backup_e1/1001" >/dev/null 2>&1
report $? "the snapshot was promoted out of .incomplete and is still a subvolume"

echo "second" >"${MOUNT}/data/two.txt"
TEST_NOW=1002 backup -s "${MOUNT}/data" -c STANDARD -e e1 >"${WORK}/out" 2>&1
report $? "an incremental backup chained from the promoted snapshot"

# An increment carrying one small file is much smaller than a full copy, which
# is the observable difference between the two.
FULL=$(stat -c %s "${S3ROOT}"/bucket/host/e1/1001_*/xaaaa)
INCR=$(stat -c %s "${S3ROOT}"/bucket/host/e1/1002_*/xaaaa)
[ "${INCR}" -lt "${FULL}" ]
report $? "the second backup was an increment, not another full copy (${INCR} < ${FULL} bytes)"

btrfs subvolume create "${MOUNT}/restored" >/dev/null
restore -e e1 -s "${MOUNT}/restored" >/dev/null
report $? "restoring the whole epoch"

[ -f "${MOUNT}/restored/1002/one.txt" ] && [ -f "${MOUNT}/restored/1002/two.txt" ]
report $? "the restored snapshot holds both files"

diff -q "${MOUNT}/data/two.txt" "${MOUNT}/restored/1002/two.txt" >/dev/null
report $? "the restored contents match"

echo "Backing up the top-level subvolume"

TEST_NOW=2001 backup -s "${MOUNT}" -c STANDARD -e e2 >/dev/null
report $? "a full backup of the top-level subvolume"

TEST_NOW=2002 backup -s "${MOUNT}" -c STANDARD -e e2 >/dev/null
report $? "an incremental backup of the top-level subvolume"

FULL=$(stat -c %s "${S3ROOT}"/bucket/host/e2/2001_*/xaaaa)
INCR=$(stat -c %s "${S3ROOT}"/bucket/host/e2/2002_*/xaaaa)
[ "${INCR}" -lt "${FULL}" ]
report $? "the top-level subvolume chained rather than starting over (${INCR} < ${FULL} bytes)"

echo
if [ "${FAILED}" -ne 0 ]; then
  echo "${FAILED} failed"
  exit 1
fi
echo "all good"
