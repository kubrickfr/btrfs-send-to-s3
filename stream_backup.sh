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

$(dirname "$0")/check_deps.sh || exit 3

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
DELETE_PREVIOUS=false
CHUNK_SIZE="512M"
SOURCE_EPOCH=""
SNAPSHOT_FROM_OTHER_EPOCH=false

OPTSTRING="r:b:p:e:c:s:B:S:d"

while getopts ${OPTSTRING} opt; do
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
    d) 
      echo "Will delete previous snapshot in the same epoch"
      DELETE_PREVIOUS=true
      ;;
    ?)
      echo "Invalid option: -${OPTARG}."
      exit 1
      ;;
  esac
done

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
  -s path     : path of the subvolume to make a shapshot and backup
                of
  [-B epoch]  : use as a starting point when starting a new epoch.
                This is useful to break long chains of incremental
                backups into epochs of different periodicity
  [-S size]   : size of chunks to send to S3. Default to 512M
                K,M,G suffixes are supported
  [-d]        : when the upload succeedes, delete the older snapshot
                defaults to keep the old snapshot. Does not delete
                the previous snapshot if it is in a different epoch
EOF
        exit 1
fi

function cleanup () {
  echo "Something went wrong, attempting to clean-up temporary files & snapshots" >&2
  if [ -n "${SEND_LOG}" ]; then
    rm -f -- "${SEND_LOG}"
  fi
  btrfs subvolume delete "${NEW_SNAPSHOT}"
  exit 2
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

aws s3 ls s3://${BUCKET}/${PREFIX} >/dev/null 2>&1 \
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

EPOCH_DIR=${SUBV%/}/.stream_backup_${EPOCH}
NEW_SNAPSHOT=${EPOCH_DIR}/${SEQ}

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

if [ -z "${LAST_SNAPSHOT}" ]; then
  echo "No previous snapshot found for this epoch; making a full backup"
  DELETE_PREVIOUS=false
  BTRFS_COMMAND="btrfs send ${NEW_SNAPSHOT}"
else
  PARENT_PATH=${PARENT_DIR}/${LAST_SNAPSHOT}
  BTRFS_COMMAND="btrfs send -p ${PARENT_PATH} ${NEW_SNAPSHOT}"
fi

mkdir -p -- "${EPOCH_DIR}"
btrfs subvolume snapshot -r "${SUBV}" "${NEW_SNAPSHOT}" || exit 1

trap cleanup ERR
trap cleanup INT

SEND_LOG=$(mktemp) || cleanup

S3_SEQ_URL="s3://${BUCKET}/${PREFIX}/${EPOCH}/${SEQ_SALTED}"
export RECIPIENTS_FILE S3_SEQ_URL SCLASS

# stdout is the backup itself, and btrfs send writes progress as well as errors
# to stderr, so its stderr goes to a file and is shown only on failure.
if ! eval ${BTRFS_COMMAND} 2>"${SEND_LOG}" \
	| lz4 \
	| mbuffer -m ${CHUNK_SIZE} -q \
	| SHELL="${SPLIT_SHELL}" split -b ${CHUNK_SIZE} --suffix-length 4 --filter \
	'set -o pipefail; age -R "${RECIPIENTS_FILE}" | aws s3 cp - "${S3_SEQ_URL}/${FILE}" --storage-class "${SCLASS}"'
then
  STATUS=("${PIPESTATUS[@]}")
  echo "ERROR: the backup stream failed (btrfs send=${STATUS[0]} lz4=${STATUS[1]}" \
       "mbuffer=${STATUS[2]} split, age or aws=${STATUS[3]})" >&2
  cat -- "${SEND_LOG}" >&2
  cleanup
fi

rm -f -- "${SEND_LOG}"
SEND_LOG=""

# We only write the subvolume information to S3 at the end, as a marker of completion of the backup
# having the subvolume information might help debuging tricky situations.
SNAPSHOT_INFO=$(btrfs subvolume show "${NEW_SNAPSHOT}")

if [ -z "${SNAPSHOT_INFO}" ]; then
  echo "ERROR: btrfs subvolume show ${NEW_SNAPSHOT} returned nothing" >&2
  cleanup
fi

if ! printf '%s\n' "${SNAPSHOT_INFO}" \
  | age -R "${RECIPIENTS_FILE}" \
  | aws s3 cp - "${S3_SEQ_URL}/snapshot_info.dat"
then
  echo "ERROR: could not upload the completion marker for ${SEQ_SALTED}" >&2
  cleanup
fi

# We delete the snapshot from which we made an incremental backup:
# * If the user asked for it
# * If there is a previous snapshot in the first place
# * If the snapshot is not from another epoch
if     [ "${DELETE_PREVIOUS}" == true ] \
    && [ -n "${LAST_SNAPSHOT}" ] \
    && [ ${SNAPSHOT_FROM_OTHER_EPOCH} == false ]; then
  btrfs subvolume delete "${PARENT_PATH}"
fi

