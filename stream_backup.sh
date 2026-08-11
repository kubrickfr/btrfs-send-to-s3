#!/bin/bash
#
# Before anything else: the shebang can be bypassed with "sh stream_backup.sh",
# and everything below assumes bash, starting with $EUID.
if [ -z "${BASH_VERSION}" ]; then
  echo "Please run with bash" >&2
  exit 3
fi

set -o pipefail

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit 1
fi

"$(dirname "$0")/check_deps.sh" || exit 3

# GNU split runs its --filter through $SHELL, which is the login shell of
# whoever started us and need not even be bash. Pin it to the interpreter
# running this script so the filter's own error handling behaves predictably.
SPLIT_SHELL=${BASH}
if [ ! -x "${SPLIT_SHELL}" ]; then
  SPLIT_SHELL=$(command -v bash)
fi
if [ ! -x "${SPLIT_SHELL}" ]; then
  echo "command not found: bash (needed by 'split --filter')" >&2
  exit 3
fi

SEND_LOG=""
SNAPSHOT_STAGED=""
BACKUP_OK=false
HOUSEKEEPING_FAILED=false
DELETE_PREVIOUS=false
CHUNK_SIZE="512M"
MBUFFER_SIZE="512M"
SOURCE_EPOCH=""
SNAPSHOT_FROM_OTHER_EPOCH=false

OPTSTRING=":r:b:p:e:c:s:B:S:m:d"

while getopts "${OPTSTRING}" opt; do
  case ${opt} in
    r)
      echo "Recipients file path: ${OPTARG}"
      RECIPIENTS_FILE=${OPTARG}
      ;;
    b)
      echo "Bucket: ${OPTARG}"
      BUCKET=${OPTARG}
      ;;
    p)
      echo "User-defined S3 prefix: ${OPTARG}"
      PREFIX=${OPTARG}
      ;;
    e)
      echo "Epoch: ${OPTARG}"
      EPOCH=${OPTARG}
      ;;
    c)
      echo "Storage Class: ${OPTARG}"
      SCLASS=${OPTARG}
      ;;
    s)
      echo "Subvolume to backup: ${OPTARG}"
      SUBV=${OPTARG}
      ;;
    B)
      echo "Branch from epoch: ${OPTARG}"
      SOURCE_EPOCH=${OPTARG}
      ;;
    S)
      echo "Chunks size: ${OPTARG}"
      CHUNK_SIZE=${OPTARG}
      ;;
    m)
      echo "Buffer size: ${OPTARG}"
      MBUFFER_SIZE=${OPTARG}
      ;;
    d) 
      echo "Will delete previous snapshot in the same epoch"
      DELETE_PREVIOUS=true
      ;;
    :)
      echo "Option -${OPTARG} needs an argument." >&2
      exit 1
      ;;
    ?)
      echo "Invalid option: -${OPTARG}." >&2
      exit 1
      ;;
  esac
done

shift $((OPTIND - 1))

if [ $# -ne 0 ]; then
  echo "Unexpected argument: $1" >&2
  exit 1
fi

if [ "" == "$RECIPIENTS_FILE" ] || [ "" == "$BUCKET" ] || [ "" == "$PREFIX" ] || [ "" == "$EPOCH" ] || [ "" == "$SCLASS" ] || [ "" == "$SUBV" ]; then
cat << EOF
Usage:
  -r path     : path to recipients file in age format
                see https://github.com/FiloSottile/age
  -b name     : S3 bucket name where to store the backup
  -p prefix   : a prefix to use in that bucket, use name of the
                machine you want to backup for example
  -e epoch    : a unique identifier for the epoch of the backup,
                if a new epoch is chosen, a full backup will be done,
                subsequent backups with the same epoch will be
                incremental
  -c class    : S3 storage class, see "aws s3 cp help" for
                supported classes
  -s path     : path of the subvolume to make a snapshot and backup
                of
  [-B epoch]  : use as a starting point when starting a new epoch.
                This is useful to break long chains of incremental
                backups into epochs of different periodicity
  [-S size]   : size of chunks to send to S3. Default to 512M
                K,M,G suffixes are supported
  [-m size]   : how much of the stream to hold in memory while
                uploading. Default to 512M, K,M,G suffixes are
                supported
  [-d]        : when the upload succeeds, delete the older snapshot
                defaults to keep the old snapshot. Does not delete
                the previous snapshot if it is in a different epoch
EOF
        exit 1
fi

# Runs however the script ends, including on a signal. A snapshot that is still
# staged is one whose upload did not finish, and the next run must not be able
# to chain from it, so it goes.
function on_exit () {
  local status=$?

  trap - EXIT ERR INT TERM HUP

  if [ -n "${SEND_LOG}" ]; then
    rm -f -- "${SEND_LOG}"
  fi

  if [ "${BACKUP_OK}" != true ]; then
    if [ -n "${SNAPSHOT_STAGED}" ] && [ -e "${SNAPSHOT_STAGED}" ]; then
      echo "Something went wrong, deleting the snapshot this run created" >&2
      btrfs subvolume delete "${SNAPSHOT_STAGED}" >&2 \
        || echo "ERROR: could not delete ${SNAPSHOT_STAGED}, remove it by hand" >&2
      status=2
    elif [ "${status}" -eq 0 ]; then
      status=1
    fi
  elif [ "${HOUSEKEEPING_FAILED}" == true ]; then
    status=4
  else
    status=0
  fi

  exit "${status}"
}

function on_signal () {
  echo "ERROR: caught SIG$1, aborting" >&2
  exit 2
}

# A size in split's notation as a plain number of bytes, or nothing if it is
# written in a way we do not recognise.
function size_to_bytes () {
  local size=$1
  local number=${size%[KkMmGgTt]}

  case ${number} in
    ''|*[!0-9]*) return 0 ;;
  esac

  case ${size} in
    *[0-9]) printf '%s\n' "${number}" ;;
    *[Kk])  printf '%s\n' "$(( number * 1024 ))" ;;
    *[Mm])  printf '%s\n' "$(( number * 1024 ** 2 ))" ;;
    *[Gg])  printf '%s\n' "$(( number * 1024 ** 3 ))" ;;
    *[Tt])  printf '%s\n' "$(( number * 1024 ** 4 ))" ;;
  esac
}

# Name of the newest snapshot in a snapshot directory, or nothing if it holds
# none. Our snapshots are named after the second they were taken in, so anything
# that is not a plain number was not put there by this script.
function latest_snapshot () {
  local dir=$1
  local path name newest=""

  [ -d "${dir}" ] || return 0

  for path in "${dir}"/*; do
    name=${path##*/}
    case ${name} in
      ''|*[!0-9]*) continue ;;
    esac
    btrfs subvolume show "${path}" >/dev/null 2>&1 || continue
    if [ -z "${newest}" ] || [ "${name}" -gt "${newest}" ]; then
      newest=${name}
    fi
  done

  printf '%s\n' "${newest}"
}

# One run at a time per subvolume, and per subvolume rather than per epoch: with
# -B a run in one epoch reads a snapshot belonging to another, and with -d a run
# deletes one. The lock is held by the whole process tree, so a run whose upload
# is stuck still counts as a run in progress.
LOCK_DIR=/run/lock
if [ ! -d "${LOCK_DIR}" ] || [ ! -w "${LOCK_DIR}" ]; then
  LOCK_DIR=${TMPDIR:-/tmp}
fi

LOCK_NAME=${SUBV%/}
LOCK_FILE=${LOCK_DIR}/stream_backup${LOCK_NAME//\//_}.lock

exec 9>"${LOCK_FILE}" || exit 1

if ! flock -n 9; then
  echo "ERROR: another stream_backup.sh run is already working on ${SUBV}" >&2
  echo "       (lock file ${LOCK_FILE}). Refusing to run two at once." >&2
  exit 1
fi

aws s3 ls "s3://${BUCKET}/${PREFIX}" >/dev/null 2>&1 \
  && echo "SECURITY WARNING: current AWS IAM entity is allowed to list bucket contents! This can allow an attacker using the same identity to overwrite files and ruin your backups!" >&2

SEQ=$(date +%s)

# Salting the file names in S3 is important as to prevent malevolent overwriting
SALT=$(openssl rand -hex 8)

if [ -z "${SALT}" ]; then
  echo "ERROR: could not generate a random salt for the object names" >&2
  exit 1
fi

SEQ_SALTED=${SEQ}_${SALT}

if ! btrfs subvolume show "${SUBV}" >/dev/null 2>&1; then
  echo "Subvolume not found" >&2
  exit 1
fi

# Snapshots are not recursive, and neither is the stream: a subvolume nested
# inside this one arrives as an empty directory. Docker's btrfs driver, snapper
# and LXD all create them under paths people back up.
NESTED=$(btrfs subvolume list -o "${SUBV}" 2>/dev/null \
           | grep -v '/\.stream_backup_' || true)

if [ -n "${NESTED}" ]; then
  echo "WARNING: ${SUBV} contains nested subvolumes. They will be backed up as" >&2
  echo "         EMPTY directories, because snapshots do not descend into them." >&2
  echo "         Back them up separately if you need their contents:" >&2
  printf '%s\n' "${NESTED}" >&2
fi

EPOCH_DIR=${SUBV%/}/.stream_backup_${EPOCH}
# A snapshot is only moved out of here once its upload has completed, so
# whatever is left in it is unusable, and being in it is what stops
# latest_snapshot from ever offering it as a parent.
STAGE_DIR=${EPOCH_DIR}/.incomplete
NEW_SNAPSHOT=${EPOCH_DIR}/${SEQ}
SNAPSHOT_STAGED=${STAGE_DIR}/${SEQ}

PARENT_DIR=${EPOCH_DIR}
LAST_SNAPSHOT=$(latest_snapshot "${EPOCH_DIR}")

if [ -z "${LAST_SNAPSHOT}" ] && [ -n "${SOURCE_EPOCH}" ]; then
  PARENT_DIR=${SUBV%/}/.stream_backup_${SOURCE_EPOCH}
  LAST_SNAPSHOT=$(latest_snapshot "${PARENT_DIR}")
  if [ -z "${LAST_SNAPSHOT}" ]; then
    echo "ERROR: Neither the current epoch nor the branch epoch has an existing snapshot" >&2
    exit 1
  fi
  SNAPSHOT_FROM_OTHER_EPOCH=true
fi

# Restoring replays sequences in the order of these numbers, so a snapshot that
# sorts before the one it was made from could never be restored.
if [ -n "${LAST_SNAPSHOT}" ] && [ "${SEQ}" -le "${LAST_SNAPSHOT}" ]; then
  echo "ERROR: this run's sequence number (${SEQ}) is not newer than the last" >&2
  echo "       snapshot's (${LAST_SNAPSHOT}). The clock has gone backwards, or" >&2
  echo "       a backup has already been taken this second. Restoring replays" >&2
  echo "       sequences in numerical order, so this backup could not be" >&2
  echo "       restored after its own parent. Fix the clock and run again." >&2
  exit 1
fi

SEND_ARGS=()

if [ -z "${LAST_SNAPSHOT}" ]; then
  echo "No previous snapshot found for this epoch; making a full backup"
  DELETE_PREVIOUS=false
else
  PARENT_PATH=${PARENT_DIR}/${LAST_SNAPSHOT}
  SEND_ARGS+=(-p "${PARENT_PATH}")
fi

SEND_ARGS+=("${SNAPSHOT_STAGED}")

trap on_exit EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP
trap 'exit 1' ERR

if [ -d "${STAGE_DIR}" ]; then
  for ORPHAN in "${STAGE_DIR}"/*; do
    [ -e "${ORPHAN}" ] || continue
    echo "WARNING: ${ORPHAN} was left behind by an interrupted backup." >&2
    echo "         Its sequence in S3 was never completed and cannot be restored," >&2
    echo "         so it cannot be used as a parent. Deleting it." >&2
    btrfs subvolume delete "${ORPHAN}" >&2 \
      || echo "WARNING: could not delete ${ORPHAN}, remove it by hand" >&2
  done
fi

mkdir -p -- "${STAGE_DIR}"
btrfs subvolume snapshot -r "${SUBV}" "${SNAPSHOT_STAGED}" || exit 1

SEND_LOG=$(mktemp) || exit 2

S3_SEQ_URL="s3://${BUCKET}/${PREFIX}/${EPOCH}/${SEQ_SALTED}"
# Uploading from a stream, the AWS CLI has no idea how much is coming, so it
# uses 8MiB parts and runs into the 10000 part limit a little under 78GiB.
# Telling it how big a chunk is lets it size the parts accordingly.
EXPECTED_SIZE=$(size_to_bytes "${CHUNK_SIZE}")
export RECIPIENTS_FILE S3_SEQ_URL SCLASS EXPECTED_SIZE

# stdout is the backup itself, and btrfs send writes progress as well as errors
# to stderr, so its stderr goes to a file and is shown only on failure.
if ! btrfs send "${SEND_ARGS[@]}" 2>"${SEND_LOG}" \
	| lz4 \
	| mbuffer -m "${MBUFFER_SIZE}" -q \
	| SHELL="${SPLIT_SHELL}" split -b "${CHUNK_SIZE}" --suffix-length 4 --filter \
	'set -o pipefail
	 age -R "${RECIPIENTS_FILE}" \
	   | aws s3 cp - "${S3_SEQ_URL}/${FILE}" --storage-class "${SCLASS}" \
	       ${EXPECTED_SIZE:+--expected-size "${EXPECTED_SIZE}"}'
then
  STATUS=("${PIPESTATUS[@]}")
  echo "ERROR: the backup stream failed (btrfs send=${STATUS[0]} lz4=${STATUS[1]}" \
       "mbuffer=${STATUS[2]} split, age or aws=${STATUS[3]})" >&2
  cat -- "${SEND_LOG}" >&2
  exit 2
fi

rm -f -- "${SEND_LOG}"
SEND_LOG=""

# We only write the subvolume information to S3 at the end, as a marker of completion of the backup
# having the subvolume information might help debuging tricky situations.
SNAPSHOT_INFO=$(btrfs subvolume show "${SNAPSHOT_STAGED}")

if [ -z "${SNAPSHOT_INFO}" ]; then
  echo "ERROR: btrfs subvolume show ${SNAPSHOT_STAGED} returned nothing" >&2
  exit 2
fi

if ! printf '%s\n' "${SNAPSHOT_INFO}" \
  | age -R "${RECIPIENTS_FILE}" \
  | aws s3 cp - "${S3_SEQ_URL}/snapshot_info.dat"
then
  echo "ERROR: could not upload the completion marker for ${SEQ_SALTED}" >&2
  exit 2
fi

# The sequence is complete in S3, so this snapshot is now a valid parent for the
# next run and can leave the staging directory.
mv -T -- "${SNAPSHOT_STAGED}" "${NEW_SNAPSHOT}"
BACKUP_OK=true
trap - ERR
rmdir -- "${STAGE_DIR}" 2>/dev/null

# We delete the snapshot from which we made an incremental backup:
# * If the user asked for it
# * If there is a previous snapshot in the first place
# * If the snapshot is not from another epoch
# The backup is already safe in S3 by now, so failing here is not fatal.
if     [ "${DELETE_PREVIOUS}" == true ] \
    && [ -n "${LAST_SNAPSHOT}" ] \
    && [ "${SNAPSHOT_FROM_OTHER_EPOCH}" == false ]; then
  if ! btrfs subvolume delete "${PARENT_PATH}"; then
    echo "WARNING: the backup completed, but the snapshot it was made from" >&2
    echo "         (${PARENT_PATH}) could not be deleted. Snapshots will pile" >&2
    echo "         up until this is dealt with." >&2
    HOUSEKEEPING_FAILED=true
  fi
fi

