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
* openssl
* btrfs-tools

# Design
Rather than dealing with the complexity of custom file formats and metadata files, we use exclusively the state managed by btrfs-tools and file name conventions on S3.

As such if you want to change the format (compression, encryption, file container, etc.), please start a new backup _epoch_ so as not to mix the two.

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
The backup script encrypts your data using aes-256-cbc, using a key that is randomly generated at each run. This session key is encrypted using an public RSA PEM key that you must provide. Do *not* put the private key on the same machine, in fact you should generate it on a different machine and store it securely. Key management is left to the user (that's you!).

If you lose the private key (or forgot it's passphrase or whatever), your backup will be rendered completely useless.

## Beware of long chains of incremental backups!
A chain is only as strong as its weakest link. If there is any corruption in an incremental backup, you will not be able to restore your file beyond that point! _See epochs below_ as a tool to handle this

## Deleting old backups
It's a complex and dangerous topic on which we provide no guidance, we merely suggest that it should be automated process (to preven human error), not running on the same machine (for security reasons), and that is has human oversight.

# Making a backup

## RSA Key pair generation
Look it up using your favourite search engine, and don't do it on the same machine.

## Non-RSA Keys:
Worried about Qantum Supremacy? PRs welcomed!

## How to use the commands?
Run them without any argument and a summary of command line parameters will be displayed.

## What is an epoch?
It's an arbitrary string that you use to identify a backup sequence that starts with a full, non-incremental backup.

You can use it to achieve different goals by using multiple epochs in parallel or in sequence, for example:
* You do a backup daily and a new full backup every 6 months, so you start a new epoch every 6 months
* You have a monthly incremental backup on Glacier Deep Archive, with an new full backup (and a new epoch) every year, and a daily backup on S3 Standard with a new epoch every month. In that case you would, for example, have always two active epochs, with names like monthly-glacier-<year> and daily-standard-<month>

When you start a new epoch, the backup script will *not* delete the last snapshot of the previous epoch (as there is no link between epochs) neither on S3 nor on the btrfs filesystem. It is your creative responsibility to decide how you want to handle this.

# Restoring a backup

## Glacier considerations
Before restoring an incremental backup that is on Glacier, the files must first be copied to S3 Standard, this is neither trivial nor instant (or free for that matter), and should be considered carefully before choosing a storage class.

We recommend using an S3 batch operation for this, again you can look it up, but this is a good starting point: https://community.aws/tutorials/s3-batch-operations-restore

## Disk space consideration
Standard behaviour when restoring a backup is that all the data from every snapshot will be restored, including files that have been deleted in later snapshots. This may very well exceed the space that is available on your machine. You can use the `-d` option to mitigate this, if you don't need do go back to a particular point in time.

## Bandwidth consideration
If your target machine is outside of AWS, you will incur Data Transfer Out (DTO) charges, and just like mentioned above, you will download and restore every bid of data ever saved on this subvolume, including files that have been deleted later in the sequence.

It _may_ make financial sense (and even reduce the restoration times), to use an EC2 instance with sufficient local storage (*not* EBS) in the same region as your S3 backup.

You would restore all the backup increments on that machine, and then do one big `btrfs send` via the network of the final result, which should be smaller if files have been deleted between snapshots (piping `btrfs send` into `socat` with encryption is your friend).

NB: DTO from S3 to EC2 in the same region is free, consider using a VPC endpoint as well. DTO from EC2 to a machine outside AWS is the same as DTO from S3 to outside AWS. Please double-check on the relevant AWS pricing pages.

As usual, calculations to see if this makes sense are left to the reader.