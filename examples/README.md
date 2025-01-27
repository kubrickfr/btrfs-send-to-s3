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