#!/bin/bash
#
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

DELETE_PREVIOUS=false
CHUNK_SIZE="512M"
SOURCE_EPOCH=""

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
  btrfs subvolume delete ${NEW_SNAPSHOT}
  exit 2
}

aws s3 ls s3://${BUCKET}/${PREFIX} >> /dev/null \
  && echo "SECURITY WARNING: current AWS IAM entity is allowed to list bucket contents! This can allow an attacker using the same identity to overwrite files and ruin your backups!" >&2

SEQ=$(date +%s)

# Salting the file names in S3 is important as to prevent malevolent overwriting
SEQ_SALTED=${SEQ}_$(openssl rand -hex 8)

SUBV_INFO=$(btrfs subvolume show ${SUBV})
SUBV_PREFIX=$(echo "${SUBV_INFO}" | head -n1)

if [ -z "${SUBV_PREFIX}" ]; then
  echo "Subvolume not found" >&2
  exit 1
fi

SNAPSHOTS=$(echo "${SUBV_INFO}" | grep -o "${SUBV_PREFIX}/.stream_backup_${EPOCH}.*")
NEW_SNAPSHOT=${SUBV}/.stream_backup_${EPOCH}/${SEQ}

if [ -z "${SNAPSHOTS}" ] && [ ! -z "${SOURCE_EPOCH}" ]; then
  SNAPSHOTS=$(echo "${SUBV_INFO}" | grep -o "${SUBV_PREFIX}/.stream_backup_${SOURCE_EPOCH}.*")
  if [ -z ${SNAPSHOTS} ]; then
    echo "ERROR: Neither the current epoch nor the branch epoch has an existing snapshot" >&2
    exit 1
  fi
fi
if [ -z "${SNAPSHOTS}" ]; then
  echo "No previous snapshot found for this epoch; making a full backup"
  DELETE_PREVIOUS=false
  BTRFS_COMMAND="btrfs send ${NEW_SNAPSHOT}"
else
  LAST_SNAPSHOT=$(echo "${SNAPSHOTS}" | tail -n1)
  BTRFS_COMMAND="btrfs send -p ${SUBV%%${SUBV_PREFIX}*}${LAST_SNAPSHOT} ${NEW_SNAPSHOT}"
fi

mkdir ${SUBV}/.stream_backup_${EPOCH}/ || true
btrfs subvolume snapshot -r ${SUBV} ${NEW_SNAPSHOT}

trap cleanup ERR
trap cleanup INT

eval ${BTRFS_COMMAND} \
	| lz4 \
	| mbuffer -m ${CHUNK_SIZE} -q \
	| split -b ${CHUNK_SIZE} --suffix-length 4 --filter \
	"age -R ${RECIPIENTS_FILE} | aws s3 cp - s3://${BUCKET}/${PREFIX}/${EPOCH}/${SEQ_SALTED}/\$FILE --storage-class ${SCLASS}"

# We only write the subvolume information to S3 at the end, as a marker of completion of the backup
# having the subvolume information might help debuging tricky situations
btrfs subvolume show ${NEW_SNAPSHOT} \
  | age -R ${RECIPIENTS_FILE} \
  | aws s3 cp - s3://${BUCKET}/${PREFIX}/${EPOCH}/${SEQ_SALTED}/snapshot_info.dat

if [ "${DELETE_PREVIOUS}" == true ] && [ ! -z "${LAST_SNAPSHOT}" ]; then
  btrfs subvolume delete ${SUBV%%${SUBV_PREFIX}*}${LAST_SNAPSHOT}
fi

