# btrfs-send-to-s3
This repository provides simple bash scripts to backup and restore BTRFS using incremental snapshots to S3 (on the storage class of your choice, including Glacier and Glacier Deep Archive).

Backup and restore operations are done in a streaming fashion and require no temporary disk space.

# Dependencies
These scripts rely on well known command line tools and the AWS CLI:
* aws cli
* mbuffer
* lz4
* split
* sed
* age (or [rage](https://github.com/str4d/rage/) symlinked to `age` binary in PATH)
* btrfs-tools

# Design
Rather than dealing with the complexity of custom file formats and metadata files, we use exclusively the state managed by btrfs-tools and file name conventions on S3.

As such if you want to change the format (compression, encryption, file container, etc.), please start a new backup _epoch_ so as not to mix the two.

# Return value

It is important that you check the return value of the back-up script for proper monitoring and alerting.

* 0: everything went fine
* 1: a "usage" error occured. You used a unrecognised command switch, or referenced a volume or snapshot that does not exist
* 2: an error occurred after the snapshot was created, **you should pay close attention to these**! The script will have tried to delete the newly created snapshot so that subsequent incremental backups can be made from the last good known state
* 3: a required dependency is not installed

# Important security recommendations
This is all rather common sense, but:

## AWS Credentials
Whether you use locally stored credentials, an EC2 instance role, or IAM Roles Anywhere, an attacker who gains access to your machine will get access to your IAM entity. It is therefore important to reduce the permissions of the polices attacheds to the entity as much as possible. In particular *do not* grant any s3:List* or s3:Delete* permissions to the backup process.

Indeed there is no way of preventing _overwriting_ a file on S3, therefore if you know the file name (either because it's guessable or because you can list the bucket), the s3:PutObject permission (that we can't do without) gives you permission to overwrite and delete/alter the data.

We make sure that the object names in AWS are not guessable using random strings in the key names.

You'll need to create a different role for restoring a backup, that has no s3:PutObject permission, but s3:GetObject and s3:ListBucket.

## Testing your backups
You need to test your backups! Especially after system upgrades or updates to the backup/restore scripts!

## Monitoring your backups
You need to be made aware if your backups fail! Check if the backup script has a non-zero return value, and send an alert in that case.

## Encryption key
The backup script encrypts your data using [age](https://github.com/FiloSottile/age), please refer to their documentation on how to create key pairs. Do *not* put the private key on the same machine, in fact you should generate it on a different machine and store it securely. Key management is left to the user (that's you!).

If you lose the private key, your backup will be rendered completely useless.

## Beware of long chains of incremental backups!
A chain is only as strong as its weakest link. If there is any corruption in an incremental backup, you will not be able to restore your file beyond that point! _See epochs below_ as a tool to handle this

## Deleting old backups
It's a complex and dangerous topic on which we provide no guidance, we merely suggest that it should be automated process (to preven human error), not running on the same machine (for security reasons), and that is has human oversight.

# Making a backup

## How to use the commands?
Run them without any argument and a summary of command line parameters will be displayed.

## What is an epoch?
It's an arbitrary string that you use to identify a backup sequence that starts with a full, non-incremental backup.

When you start a new epoch, the backup script will *not* delete the last snapshot of the previous epoch (as there is no link between epochs) neither on S3 nor on the btrfs filesystem. It is your creative responsibility to decide how you want to handle this.

You can use it to achieve different goals by using multiple epochs in parallel or in sequence, for example:
* You do a backup daily and a new full backup every 6 months, so you start a new epoch every 6 months
* You have a monthly incremental backup on Glacier Deep Archive, with an new full backup (and a new epoch) every year, and a daily backup on S3 Standard with a new epoch every month. In that case you would, for example, have always two active epochs, with names like monthly-glacier-_year_ and daily-standard-_month_
* You can branch your epochs, consider for example this crontab (boring mandatory parameters replaced with \[...\] for clarity):

```
0 3   1   1-9  * stream_backup [...] -c DEEP_ARCHIVE -e monthly-$(date +%Y)
0 3   1  10-12 * stream_backup [...] -c GLACIER      -e monthly-$(date +%Y)
0 3 2-31   *   * stream_backup [...] -c STANDARD_IA  -e daily-$(date +%Y-%m) -B monthly-$(date +%Y)
```

This way you have daily backups, but a maximum chain lenth of 12+30=42 incremental backups instead of 365. We also mix and match storage classes, so that when we start the new year and delete the old epochs, we don't waste too much money on the 180 days of minimum storage duration for Glacier Deep Archive.

# Restoring a backup

## Glacier considerations
Before restoring an incremental backup that is on Glacier, the files must first be copied to S3 Standard, this is neither trivial nor instant (or free for that matter), and should be considered carefully before choosing a storage class.

We recommend using an S3 batch operation for this, again you can look it up, but this is a good starting point: https://community.aws/tutorials/s3-batch-operations-restore

### Deleting backups on glacier
Beware of the minimum storage duration and [pro-rated charge equal to the storage charge for the remaining days](https://aws.amazon.com/s3/pricing/)!

## Disk space consideration
Standard behaviour when restoring a backup is that all the data from every snapshot will be restored, including files that have been deleted in later snapshots. This may very well exceed the space that is available on your machine. You can use the `-d` option to mitigate this, if you don't need do go back to a particular point in time.

## Bandwidth consideration
If your target machine is outside of AWS, you will incur Data Transfer Out (DTO) charges, and just like mentioned above, you will download and restore every bid of data ever saved on this subvolume, including files that have been deleted later in the sequence.

It _may_ make financial sense (and even reduce the restoration times), to use an EC2 instance with sufficient local storage (*not* EBS) in the same region as your S3 backup.

You would restore all the backup increments on that machine, and then do one big `btrfs send` via the network of the final result, which should be smaller if files have been deleted between snapshots (piping `btrfs send` into `socat` with encryption is your friend).

NB: DTO from S3 to EC2 in the same region is free, consider using a VPC endpoint as well. DTO from EC2 to a machine outside AWS is the same as DTO from S3 to outside AWS. Please double-check on the relevant AWS pricing pages.

As usual, calculations to see if this makes sense are left to the reader.

## Branched backups
To restore a branch backup, you just restore the branches in order of precedence. For example, on the 18th of March 2024, to restore the latest backup made with the crontab above, one would, after the restoration from Glacier to S3 is completed, first restore epoch monthly-2024 and then daily-2024-03.
This will bring back the full backup of the 1st of January 2024, then the two monthy increments in February and March, and finally every daily increment since the 2nd of March.