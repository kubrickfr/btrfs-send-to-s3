# btrfs-send-to-s3
This repository provides simple bash scripts to backup and restore BTRFS using incremental snapshots to S3 (on the storage class of your choice, including Glacier and Glacier Deep Archive).

Backup and restore operations are done in a streaming fashion and require no temporary disk space.

# Dependencies
These scripts rely on well known command line tools and the AWS CLI:
* aws cli
* mbuffer
* lz4
* split, sed, numfmt (all in coreutils except sed)
* age (or [rage](https://github.com/str4d/rage/) symlinked to `age` binary in PATH)
* btrfs-tools
* openssl
* flock (from util-linux)

# Design
Rather than dealing with the complexity of custom file formats and metadata files, we use exclusively the state managed by btrfs-tools and file name conventions on S3.

As such if you want to change the format (compression, encryption, file container, etc.), please start a new backup _epoch_ so as not to mix the two.

Only one backup runs at a time per subvolume, whatever the epoch: a run takes an exclusive lock (in `/run/lock`, or `$TMPDIR` if that is not writable) and gives up with a return value of 1 if another already holds it. Two runs at once could otherwise pick the same parent snapshot and produce two branches of the same chain, which restores badly. Backups are also refused if the clock has gone backwards since the last snapshot, because restoring replays the sequences in numerical order.

Snapshots live in `.stream_backup_<epoch>/` inside the subvolume, named after the second they were taken in. A new snapshot is created in `.stream_backup_<epoch>/.incomplete/` and only moved next to the others once every chunk *and* the completion marker have reached S3. That is what makes an interrupted backup safe: the next run can only ever chain from a snapshot whose upload finished, because a sequence with no completion marker is skipped when restoring, and anything chained from it could not be restored either. A snapshot found in `.incomplete/` at the start of a run is reported and deleted.

# Return values

It is important that you check the return value of these scripts for proper monitoring and alerting.

## stream_backup.sh

* 0: everything went fine
* 1: a "usage" error occurred. You used an unrecognised command switch, or referenced a volume or snapshot that does not exist
* 2: an error occurred after the snapshot was created, **you should pay close attention to these**! The script will have tried to delete the newly created snapshot so that subsequent incremental backups can be made from the last good known state
* 3: a required dependency is not installed
* 4: the backup itself completed and is safe in S3, but tidying up afterwards did not. Nothing is at risk and there is nothing to re-run, but snapshots will accumulate on disk until you look into it

## restore_backup.sh

* 0: every sequence of the epoch was restored
* 1: a "usage" error, or the epoch could not be listed, or it holds no backup
* 2: the restore stopped part way. The last snapshot that *was* restored is named at the end of the output, and is the one a new attempt will carry on from
* 3: a required dependency is not installed
* 4: the restore stopped because objects are still in Glacier or Deep Archive and have to be copied to S3 Standard first

A restore stops at the first sequence it cannot replay, because every later one is an increment on it.

# Important security recommendations
This is all rather common sense, but:

## AWS Credentials
Whether you use locally stored credentials, an EC2 instance role, or IAM Roles Anywhere, an attacker who gains access to your machine will get access to your IAM entity. It is therefore important to reduce the permissions of the policies attached to the entity as much as possible. In particular *do not* grant any s3:List* or s3:Delete* permissions to the backup process.

The backup cannot do without s3:PutObject, and that permission alone is enough to write over an object whose name you know. So if the names are guessable, or the bucket can be listed, whoever reaches the machine can destroy the backups by overwriting them. We make the object names unguessable by putting a random string in every key.

Unguessable names are worth having, but treat them as defence in depth rather than as the control: the name of the object being written is visible in the process list for as long as the upload runs. The control is on the bucket, and costs these scripts nothing:

* **Enable versioning**, and grant s3:DeleteObjectVersion to nobody. An overwrite then only adds a version, and the original object is still there.
* For a stronger guarantee, **S3 Object Lock** in compliance mode makes objects genuinely immutable until they expire — including to you, so read up on it before turning it on.

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
It's a complex and dangerous topic on which we provide no guidance, we merely suggest that it should be an automated process (to prevent human error), not running on the same machine (for security reasons), and that it has human oversight.

# Making a backup

## How to use the commands?
Run them without any argument and a summary of command line parameters will be displayed.

## What is an epoch?
It's an arbitrary string that you use to identify a backup sequence that starts with a full, non-incremental backup.

When you start a new epoch, the backup script will *not* delete the last snapshot of the previous epoch (as there is no link between epochs) neither on S3 nor on the btrfs filesystem. It is your creative responsibility to decide how you want to handle this.

You can use it to achieve different goals by using multiple epochs in parallel or in sequence, for example:
* You do a backup daily and a new full backup every 6 months, so you start a new epoch every 6 months
* You have a monthly incremental backup on Glacier Deep Archive, with a new full backup (and a new epoch) every year, and a daily backup on S3 Standard with a new epoch every month. In that case you would, for example, have always two active epochs, with names like monthly-glacier-_year_ and daily-standard-_month_
* You can branch your epochs, consider for example this crontab (boring mandatory parameters replaced with \[...\] for clarity):

```
0 3   1   1-9  * stream_backup [...] -c DEEP_ARCHIVE -e monthly-$(date +%Y)
0 3   1  10-12 * stream_backup [...] -c GLACIER      -e monthly-$(date +%Y)
0 3 2-31   *   * stream_backup [...] -c STANDARD_IA  -e daily-$(date +%Y-%m) -B monthly-$(date +%Y)
```

This way you have daily backups, but a maximum chain length of 12+30=42 incremental backups instead of 365. We also mix and match storage classes, so that when we start the new year and delete the old epochs, we don't waste too much money on the 180 days of minimum storage duration for Glacier Deep Archive.

# Restoring a backup

## Glacier considerations
Before restoring an incremental backup that is on Glacier, the files must first be copied to S3 Standard, this is neither trivial nor instant (or free for that matter), and should be considered carefully before choosing a storage class.

We recommend using an S3 batch operation for this, again you can look it up, but this is a good starting point: https://community.aws/tutorials/s3-batch-operations-restore

### Deleting backups on glacier
Beware of the minimum storage duration and [pro-rated charge equal to the storage charge for the remaining days](https://aws.amazon.com/s3/pricing/)!

## Disk space consideration
Standard behaviour when restoring a backup is that all the data from every snapshot will be restored, including files that have been deleted in later snapshots. This may very well exceed the space that is available on your machine. You can use the `-d` option to mitigate this, if you don't need to go back to a particular point in time.

## Bandwidth consideration
If your target machine is outside of AWS, you will incur Data Transfer Out (DTO) charges, and just like mentioned above, you will download and restore every bit of data ever saved on this subvolume, including files that have been deleted later in the sequence.

It _may_ make financial sense (and even reduce the restoration times), to use an EC2 instance with sufficient local storage (*not* EBS) in the same region as your S3 backup.

You would restore all the backup increments on that machine, and then do one big `btrfs send` via the network of the final result, which should be smaller if files have been deleted between snapshots (piping `btrfs send` into `socat` with encryption is your friend).

NB: DTO from S3 to EC2 in the same region is free, consider using a VPC endpoint as well. DTO from EC2 to a machine outside AWS is the same as DTO from S3 to outside AWS. Please double-check on the relevant AWS pricing pages.

As usual, calculations to see if this makes sense are left to the reader.

## Branched backups
To restore a branch backup, you just restore the branches in order of precedence. For example, on the 18th of March 2024, to restore the latest backup made with the crontab above, one would, after the restoration from Glacier to S3 is completed, first restore epoch monthly-2024 and then daily-2024-03.
This will bring back the full backup of the 1st of January 2024, then the two monthly increments in February and March, and finally every daily increment since the 2nd of March.