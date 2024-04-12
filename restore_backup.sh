#!/bin/bash
#
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

./check_deps.sh || exit 3

DELETE_PREVIOUS=false

OPTSTRING="b:p:e:i:s:d"

while getopts ${OPTSTRING} opt; do
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
    ?)
      echo "Invalid option: -${OPTARG}."
      exit 1
      ;;
  esac
done

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

function summarise () {
  if [ "${PREV_SEQ}" != "" ]; then
    echo "Last snapshot successfully restored in: ${DEST}/${PREV_SEQ}"
  fi
}

PREV_SEQ=""

trap summarise ERR
trap summarise INT

for SEQ_PREFIX in $(aws s3api list-objects-v2 --bucket ${BUCKET} --prefix ${PREFIX}/${EPOCH}/ --no-paginate --delimiter '/' --query 'reverse(CommonPrefixes[].[Prefix])' --output text | sort); do
  err=0
  aws s3 cp s3://${BUCKET}/${SEQ_PREFIX}snapshot_info.dat - | age -d -i ${IDENTITY_FILE} >/dev/null || err=1
  if [ ${err} -ne 0 ]; then
    echo "    WARNING: ${SEQ_PREFIX} skipped.
    This is harmless if an incremental backup failed and the backup script handled it gracefully.
    This can also be due to an unexpedcted file being present in the S3 bucket.
    However, if the next snapshot depends on this one, this is the end of it." >&2
  else
    for key in $(aws s3api list-objects-v2 --bucket ${BUCKET} --prefix ${SEQ_PREFIX} --no-paginate --query 'Contents[].Key' --output  text); do
      if [[ ${key} =~ /x[a-z]*$ ]]; then
        aws s3 cp s3://${BUCKET}/${key} - | age -d -i ${IDENTITY_FILE}
      fi
    done | mbuffer -m 1G -q | lz4 -d | btrfs receive ${DEST}
    if [ "${DELETE_PREVIOUS}" == true ] && [ ! -z "${PREV_SEQ}" ]; then
      echo "Deleting previous snapshot ${DEST}/${PREV_SEQ}"
      sudo btrfs subvolume delete ${DEST}/${PREV_SEQ}
    fi
    # Extract the previous' snapshot sequence number without the salt
    PREV_SEQ=$(echo ${SEQ_PREFIX} | sed 's/.*\/\([^_\/]\+\)_[0-9a-f]*\/$/\1/')
  fi
done

summarise