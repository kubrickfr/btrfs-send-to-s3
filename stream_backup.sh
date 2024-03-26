#!/bin/bash
#
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

umask 0600
DELETE_PREVIOUS=false
CHUNK_SIZE="512M"

OPTSTRING="k:b:p:e:c:s:S:d"

while getopts ${OPTSTRING} opt; do
  case ${opt} in
    k)
      echo "Public Key pem file: ${OPTARG}"
      PUBLIC_KEY=${OPTARG}
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

if [ "" == "$PUBLIC_KEY" ] || [ "" == "$BUCKET" ] || [ "" == "$PREFIX" ] || [ "" == "$EPOCH" ] || [ "" == "$SCLASS" ] || [ "" == "$SUBV" ]; then
cat << EOF
Usage:
  -k path     : path to the public key file in PEM format
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
  [-S size]   : size of chunks to send to S3. Default to 512M
                K,M,G suffixes are supported
  [-d]        : when the upload succeedes, delete the older snapshot
                defaults to keep the old snapshot. Does not delete
                the previous snapshot if it is in a different epoch
EOF
        exit 1
fi

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

if [ -z "${SNAPSHOTS}" ]; then
  echo "No previous snapshot found for this epoch; making a full backup" >&2
  mkdir ${SUBV}/.stream_backup_${EPOCH}/ || true
  DELETE_PREVIOUS=false
  BTRFS_COMMAND="btrfs send ${SUBV}/.stream_backup_${EPOCH}/${SEQ}"
else
  LAST_SNAPSHOT=$(echo "${SNAPSHOTS}" | tail -n1)
  BTRFS_COMMAND="btrfs send -p ${SUBV%%${SUBV_PREFIX}*}${LAST_SNAPSHOT} ${SUBV}/.stream_backup_${EPOCH}/${SEQ}"
fi

function cleanup () {
  echo "Something went wrong, attempting to clean-up temporary files & snapshots" >&2
  btrfs subvolume delete ${SUBV}/.stream_backup_${EPOCH}/${SEQ}
  rm /tmp/btrfs_sess_key.dat
  exit 2
}

btrfs subvolume snapshot -r ${SUBV} ${SUBV}/.stream_backup_${EPOCH}/${SEQ}

trap cleanup ERR
trap cleanup INT

openssl rand 32 > /tmp/btrfs_sess_key.dat

eval ${BTRFS_COMMAND} \
	| lz4 \
	| mbuffer -m ${CHUNK_SIZE} -q \
	| split -b ${CHUNK_SIZE} --suffix-length 4 --filter \
	"openssl enc -aes-256-cbc -salt -md sha512 -pbkdf2 -pass file:/tmp/btrfs_sess_key.dat | aws s3 cp - s3://${BUCKET}/${PREFIX}/${EPOCH}/${SEQ_SALTED}/\$FILE --storage-class ${SCLASS}"

# We only write the key to S3 at the end, as a marker of completion of the backup
openssl pkeyutl -encrypt -inkey ${PUBLIC_KEY} -pubin -in /tmp/btrfs_sess_key.dat \
  | aws s3 cp - s3://${BUCKET}/${PREFIX}/${EPOCH}/${SEQ_SALTED}/btrfs_sess_key_enc.dat

rm /tmp/btrfs_sess_key.dat

if [ "${DELETE_PREVIOUS}" == true ]; then
  btrfs subvolume delete ${SUBV%%${SUBV_PREFIX}*}${LAST_SNAPSHOT}
fi

