#!/bin/bash
#
# Before anything else: the shebang can be bypassed with "sh restore_backup.sh",
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

DELETE_PREVIOUS=false
MBUFFER_SIZE="1G"

OPTSTRING=":b:p:e:i:s:m:d"

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
    m)
      echo "Buffer size: ${OPTARG}"
      MBUFFER_SIZE=${OPTARG}
      ;;
    d) 
      echo "Delete all restored snapshots but the last one"
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

if [ "" == "$IDENTITY_FILE" ] || [ "" == "$BUCKET" ] || [ "" == "$PREFIX" ] || [ "" == "$EPOCH" ] || [ "" == "$DEST" ]; then
cat << EOF
Usage:
  -i path     : path to identity file in age format
                see https://github.com/FiloSottile/age
  -b name     : S3 bucket name where to store the backup
  -p prefix   : a prefix to use in that bucket
  -e epoch    : epoch of the backup we want to restore
  -s path     : BTRFS path were to restore the backup
  [-m size]   : how much of the stream to hold in memory while
                restoring. Default to 1G, K,M,G suffixes are
                supported
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

# Whether a chunk can be read right now: present, missing, archived or error.
# head-object answers 200 for an object that is in Glacier and has not been
# restored to S3 Standard, so the storage class has to be looked at to tell
# "not there" from "not there yet".
function chunk_state () {
  local key=$1
  local out status class restore

  out=$(aws s3api head-object --bucket "${BUCKET}" --key "${key}" \
          --query '[StorageClass,Restore]' --output text 2>&1)
  status=$?

  if [ ${status} -ne 0 ]; then
    case ${out} in
      *"(404)"*|*"Not Found"*)
        printf 'missing\n'
        ;;
      *)
        printf '%s\n' "${out}" >&2
        printf 'error\n'
        ;;
    esac
    return 0
  fi

  read -r class restore <<<"${out}"

  case ${class} in
    GLACIER|DEEP_ARCHIVE)
      case ${restore} in
        *'ongoing-request="false"'*) printf 'present\n' ;;
        *)                           printf 'archived\n' ;;
      esac
      ;;
    *)
      printf 'present\n'
      ;;
  esac
}

# Writes the decrypted chunks of one sequence to stdout, in order.
# 0: the whole sequence, 1: something failed, 4: still in Glacier.
function fetch_chunks () {
  local seq_prefix=$1
  local key state
  local -a status

  for key in "${seq_prefix}"x{a..z}{a..z}{a..z}{a..z}; do
    state=$(chunk_state "${key}")

    case ${state} in
      missing)
        # The end of the sequence: the chunk names are generated, not listed.
        return 0
        ;;
      archived)
        echo "ERROR: ${key} is still in Glacier or Deep Archive." >&2
        echo "       Restore the objects under ${seq_prefix} to S3 Standard" >&2
        echo "       first (see examples/README.md), then run this again." >&2
        return 4
        ;;
      error)
        echo "ERROR: could not tell whether ${key} exists, stopping rather than" >&2
        echo "       feeding btrfs receive a stream that stops halfway." >&2
        return 1
        ;;
    esac

    aws s3 cp "s3://${BUCKET}/${key}" - | age -d -i "${IDENTITY_FILE}"
    status=("${PIPESTATUS[@]}")

    if [ "${status[0]}" -ne 0 ] || [ "${status[1]}" -ne 0 ]; then
      echo "ERROR: chunk ${key} could not be read" \
           "(aws=${status[0]} age=${status[1]})" >&2
      return 1
    fi
  done

  echo "ERROR: ${seq_prefix} holds more chunks than the naming scheme allows" >&2
  return 1
}

if ! SEQ_LIST=$(aws s3api list-objects-v2 --bucket "${BUCKET}" \
      --prefix "${PREFIX}/${EPOCH}/" --delimiter '/' \
      --query 'CommonPrefixes[].[Prefix]' --output text); then
  echo "ERROR: could not list s3://${BUCKET}/${PREFIX}/${EPOCH}/" >&2
  exit 1
fi

if [ -z "${SEQ_LIST}" ] || [ "${SEQ_LIST}" == "None" ]; then
  echo "ERROR: no backup found in s3://${BUCKET}/${PREFIX}/${EPOCH}/" >&2
  exit 1
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
  fetch_chunks "${SEQ_PREFIX}" | mbuffer -m "${MBUFFER_SIZE}" -q | lz4 -d | btrfs receive "${DEST}"
  STATUS=("${PIPESTATUS[@]}")

  if [ "${STATUS[0]}" -ne 0 ] || [ "${STATUS[1]}" -ne 0 ] \
     || [ "${STATUS[2]}" -ne 0 ] || [ "${STATUS[3]}" -ne 0 ]; then
    echo "ERROR: restoring ${SEQ_PREFIX} failed (chunks=${STATUS[0]}" \
         "mbuffer=${STATUS[1]} lz4=${STATUS[2]} btrfs receive=${STATUS[3]})" >&2
    echo "       You may have to delete a partly received ${DEST%/}/${SEQ_NAME}" >&2
    echo "       before trying again." >&2
    if [ "${STATUS[0]}" -eq 4 ]; then
      EXIT_CODE=4
    else
      EXIT_CODE=2
    fi
    # Every later sequence is an increment on this one, so there is no point
    # carrying on.
    break
  fi

  # The next snapshot in the chain is on disk, so the one it was built from can
  # go.
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