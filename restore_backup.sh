#!/bin/bash
#
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

umask 0600
DELETE_PREVIOUS=false

OPTSTRING="b:p:e:k:s:d"

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
    k)
      echo "Private Key (PEM format): ${OPTARG}"
      PRIVATE_KEY=${OPTARG}
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

if [ "" == "$PRIVATE_KEY" ] || [ "" == "$BUCKET" ] || [ "" == "$PREFIX" ] || [ "" == "$EPOCH" ] || [ "" == "$DEST" ]; then
cat << EOF
Usage:
  -k path     : path to the private key file in PEM format
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


PREV_SEQ=""

for SEQ_PREFIX in $(aws s3api list-objects-v2 --bucket ${BUCKET} --prefix ${PREFIX}/${EPOCH}/ --no-paginate --delimiter '/' --query 'reverse(CommonPrefixes[].[Prefix])' --output text | sort); do
  aws s3 cp s3://${BUCKET}/${SEQ_PREFIX}btrfs_sess_key_enc.dat - | openssl pkeyutl -decrypt -inkey ${PRIVATE_KEY} -out /tmp/btrfs_sess_key.dat
  if [ $? -ne 0 ]; then
    echo "    WARNING: ${SEQ_PREFIX} skipped.
    This is harmless if an incremental backup failed and the backup script handled it gracefully.
    This can also be due to an unexpedcted file being present in the S3 bucket." >&2
  else
    for key in $(aws s3api list-objects-v2 --bucket ${BUCKET} --prefix ${SEQ_PREFIX} --no-paginate --query 'Contents[].Key' --output  text); do
      if [[ ${key} =~ /x[a-z]*$ ]]; then
        aws s3 cp s3://${BUCKET}/${key} - | openssl enc -d -aes-256-cbc -salt -md sha512 -pbkdf2 -pass file:/tmp/btrfs_sess_key.dat
      fi
    done | mbuffer -m 1G -q | lz4 -d | btrfs receive ${DEST}
    if [ "${PREV_SEQ}" != "" ]; then
      echo "Deleting previous snapshot ${DEST}/${PREV_SEQ}"
      sudo btrfs subvolume delete ${DEST}/${PREV_SEQ}
    fi
    # Extract the previous' snapshot sequence number without the salt
    PREV_SEQ=$(echo ${SEQ_PREFIX} | sed 's/.*\/\([^_\/]\+\)_[0-9a-f]*\/$/\1/')
  fi
done
rm /tmp/btrfs_sess_key.dat