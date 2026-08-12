#!/bin/bash
#
# The shebang can be bypassed with "sh restore_backup.sh", and everything below
# assumes bash, starting with $EUID.
[ -n "${BASH_VERSION}" ] || { echo "Please run with bash" >&2; exit 3; }

set -o pipefail

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit 1
fi

"$(dirname "$0")/check_deps.sh" || exit 3

function die () {
  local code=$1
  shift
  printf '%s\n' "$@" >&2
  exit "${code}"
}

DELETE_PREVIOUS=false

OPTSTRING=":b:p:e:i:s:d"

while getopts "${OPTSTRING}" opt; do
  case ${opt} in
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
    i)
      echo "Identity file path: ${OPTARG}"
      IDENTITY_FILE=${OPTARG}
      ;;
    s)
      echo "Restore path: ${OPTARG}"
      DEST=${OPTARG}
      ;;
    d) 
      echo "Delete all restored snapshots but the last one"
      DELETE_PREVIOUS=true
      ;;
    :)
      die 1 "Option -${OPTARG} needs an argument."
      ;;
    ?)
      die 1 "Invalid option: -${OPTARG}."
      ;;
  esac
done

shift $((OPTIND - 1))
[ $# -eq 0 ] || die 1 "Unexpected argument: $1"

if [ "" == "$IDENTITY_FILE" ] || [ "" == "$BUCKET" ] || [ "" == "$PREFIX" ] || [ "" == "$EPOCH" ] || [ "" == "$DEST" ]; then
cat << EOF
Usage:
  -i path     : path to identity file in age format
                see https://github.com/FiloSottile/age
  -b name     : S3 bucket name where to store the backup
  -p prefix   : a prefix to use in that bucket
  -e epoch    : epoch of the backup we want to restore
  -s path     : BTRFS path were to restore the backup
  [-d]        : after restoring each incremental backup, delete
                the one it's based on to save space, thus
                keeping only the last version
EOF
        exit 1
fi

RESTORED_SEQ=""
EXIT_CODE=0

function summarise () {
  if [ -n "${RESTORED_SEQ}" ]; then
    echo "Last snapshot successfully restored in: ${DEST%/}/${RESTORED_SEQ}"
  else
    echo "No snapshot was restored." >&2
  fi
}

function on_signal () {
  echo "ERROR: caught SIG$1, aborting" >&2
  summarise
  exit 2
}

trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP

# Writes the decrypted chunks of one sequence to stdout, in order, stopping at
# the first name that does not exist: the chunk names are generated, not
# listed. 0: the whole sequence, 1: something failed, 4: still in Glacier.
# head-object answers 200 for an object that is in Glacier and has not been
# restored to S3 Standard, so the storage class tells "not there" from "not
# there yet".
function fetch_chunks () {
  local key head class restore

  for key in "$1"x{a..z}{a..z}{a..z}{a..z}; do
    if ! head=$(aws s3api head-object --bucket "${BUCKET}" --key "${key}" \
                  --query '[StorageClass,Restore]' --output text 2>&1); then
      case ${head} in
        *"(404)"*|*"Not Found"*) return 0 ;;
      esac
      echo "ERROR: could not tell whether ${key} exists: ${head}" >&2
      return 1
    fi

    read -r class restore <<<"${head}"
    if [[ "${class}" == @(GLACIER|DEEP_ARCHIVE) && "${restore}" != *'ongoing-request="false"'* ]]; then
      echo "ERROR: ${key} is still in Glacier or Deep Archive; restore it to S3 Standard first (see examples/README.md)" >&2
      return 4
    fi

    if ! aws s3 cp "s3://${BUCKET}/${key}" - | age -d -i "${IDENTITY_FILE}"; then
      echo "ERROR: chunk ${key} could not be read (aws=${PIPESTATUS[0]} age=${PIPESTATUS[1]})" >&2
      return 1
    fi
  done

  echo "ERROR: $1 holds more chunks than the naming scheme allows" >&2
  return 1
}

SEQ_LIST=$(aws s3api list-objects-v2 --bucket "${BUCKET}" --prefix "${PREFIX}/${EPOCH}/" \
             --delimiter '/' --query 'CommonPrefixes[].[Prefix]' --output text) \
  || die 1 "ERROR: could not list s3://${BUCKET}/${PREFIX}/${EPOCH}/"
if [ -z "${SEQ_LIST}" ] || [ "${SEQ_LIST}" == "None" ]; then
  die 1 "ERROR: no backup found in s3://${BUCKET}/${PREFIX}/${EPOCH}/"
fi

mapfile -t SEQ_PREFIXES < <(printf '%s\n' "${SEQ_LIST}" | LC_ALL=C sort)

for SEQ_PREFIX in "${SEQ_PREFIXES[@]}"; do
  # The sequence number without the salt, which is the name btrfs receive gives
  # the restored snapshot
  SEQ_NAME=$(printf '%s' "${SEQ_PREFIX}" | sed 's/.*\/\([^_\/]\+\)_[0-9a-f]*\/$/\1/')

  if ! aws s3 cp "s3://${BUCKET}/${SEQ_PREFIX}snapshot_info.dat" - 2>/dev/null \
       | age -d -i "${IDENTITY_FILE}" >/dev/null; then
    echo "    WARNING: ${SEQ_PREFIX} skipped.
    This is harmless if an incremental backup failed and the backup script handled it gracefully.
    This can also be due to an unexpected file being present in the S3 bucket.
    However, if the next snapshot depends on this one, this is the end of it." >&2
    continue
  fi

  echo "Restoring ${SEQ_PREFIX}"
  if ! fetch_chunks "${SEQ_PREFIX}" | mbuffer -m 1G -q | lz4 -d | btrfs receive "${DEST}"; then
    STATUS=("${PIPESTATUS[@]}")
    echo "ERROR: restoring ${SEQ_PREFIX} failed (chunks=${STATUS[0]} mbuffer=${STATUS[1]} lz4=${STATUS[2]} btrfs receive=${STATUS[3]})" >&2
    echo "       You may have to delete a partly received ${DEST%/}/${SEQ_NAME} before trying again." >&2
    [ "${STATUS[0]}" -eq 4 ] && EXIT_CODE=4 || EXIT_CODE=2
    # Every later sequence is an increment on this one.
    break
  fi

  # The next link of the chain is on disk, so the one it was built from can go.
  if [ "${DELETE_PREVIOUS}" == true ] && [ -n "${RESTORED_SEQ}" ]; then
    echo "Deleting previous snapshot ${DEST%/}/${RESTORED_SEQ}"
    btrfs subvolume delete "${DEST%/}/${RESTORED_SEQ}" \
      || echo "WARNING: could not delete ${DEST%/}/${RESTORED_SEQ}" >&2
  fi

  RESTORED_SEQ=${SEQ_NAME}
done

if [ -z "${RESTORED_SEQ}" ] && [ "${EXIT_CODE}" -eq 0 ]; then
  EXIT_CODE=2
fi

summarise
exit "${EXIT_CODE}"