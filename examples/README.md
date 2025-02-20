Here you will find some examples on how to use btrfs-send-to-s3 in an automated way

# Warning

These are _for illustrations purposes_, they may not do what _you_ want to do.

# Full working example

Create an S3 bucket, choose a prefix you want to write the backups to.

## IAM Permissions

`./aws/backup-IAM-policy.json` contains an example of policy that should be suitable for the backup process. You need to attach it as the (preferably unique) policy for a user or role that the backup script will have access to. In the policy **replace `bucket-name` with your actual bucket name**

## Crontab with incremental daily backups with monthly epochs

`./crontabs/daily-and-monthly.txt` is an example crontab that performs daily backups of `SUBVOLUME` in s3://`BUCKET`/`PREFIX`/, branched from the latest monthly *epoch*.

### Cleanup of old epochs on s3

`./aws/expire-old-backups.cfn.yaml` is a CloudFormation template that deploys a lambda function, triggered by a CloudWatch EventBridge cron schedule, that creates Lifecycle policies compatible with the crontab in `./crontabs/daily-and-monthly.txt`.

Every month on the 10th, at 0507UTC, it creates new lifecycle rules for the s3 bucket and prefix:
* On the 4th of each month, it deletes the incremental daily backups of the previous month.
* On the 4th of february every year, it deletes the incremental montly backups of the previous year.

# Restoring

If you have files on Glacier or Deep Archive, you will first need to restore those files to S3 Standard.

## Create an inventory

The first step is to list all the files you need to restore. Unless you have PiB of data, it is unlikely that you will have more than a few thousand files to restore, so the inventory should be easy to create from the aws cli. If you have bigger needs, you can look into S3 creating inventories for you but you cannot trigger them manually, so it's going to take a long time anyways (24h).

Assuming an already set `AWS_PROFILE` and `AWS_DEFAULT_REGION` environment variable, you can generate a CSV like this

```
export BUCKET="mybucketname"
export PREFIX="my/prefix"
export STORAGE_CLASS="DEEP_ARCHIVE"
aws s3api list-objects-v2 --bucket $BUCKET --prefix $PREFIX --query "Contents[?StorageClass=='$STORAGE_CLASS']" --output text | awk "{print \"$BUCKET,\"\$2}" > job.csv
```

This should produce a `job.csv` file that you need to put on the S3 bucket at `s3://$BUCKET/$PREFIX/restore/job.csv`. Make a note of the object's  ETAG (MD5 sum). In theory you can use any bucket and prefix, but the preivous path aligns with the permissions given by the `./aws/expire-old-backups.cfn.yaml` CloudFormation template.

## Create a restore job

In the following example, replace:
* `REGION`, self explanatory
* `ACCOUNT_ID`, self explanatory
* `JOB_TIER`, can be `Expedited`, `Standard` or `Bulk` (See [documentation](https://docs.aws.amazon.com/AmazonS3/latest/API/API_RestoreObject.html) and [princing](https://aws.amazon.com/s3/pricing/))
* `BUCKET`, self explanatory, *multiple occurences*
* `PREFIX`, self explanatory, *multiple occurences*
* `BulkRetrievalRole_ARN`, is an IAM role created by the `./aws/expire-old-backups.cfn.yaml` CloudFormation template

```
aws s3control create-job \
    --region REGION \
    --account-id ACCOUNT_ID \
    --operation '{"S3InitiateRestoreObject": { "ExpirationInDays": 3, "GlacierJobTier": "JOB_TIER"}}' \
    --manifest '{"Spec":{"Format":"S3BatchOperations_CSV_20180820","Fields":["Bucket","Key"]},"Location":{"ObjectArn":"arn:aws:s3:::BUCKET/PREFIX/restore/job.csv","ETag":"60e460c9d1046e73f7dde5043ac3ae85"}}' \
    --report '{"Bucket":"arn:aws:s3:::BUCKET","Prefix":"PREFIX/restore", "Format":"Report_CSV_20180820","Enabled":true,"ReportScope":"AllTasks"}' \
    --priority 10 \
    --role-arn BulkRetrievalRole_ARN \
    --client-request-token $(uuidgen) \
    --description "job description" \
    --no-confirmation-required
```