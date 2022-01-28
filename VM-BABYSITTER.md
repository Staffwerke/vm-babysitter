# VM-Babysitter


*<< I’m a good babysitter because my last job was cleaning the monkey house in the zoo. >> (promotional blurb)*


Is Docker based service that checks existing Virtual machines running on the local server, and performs the following actions:

- Creates a list of (persistent) VMs registered in QEMU to be backed up regularly
- Sets and internal cron task for scheduled backups
- Verifies/applies QEMU patch for incremental backups
- Checks backup chain consistency for each VM, being able to detect issues and solve them
- Creates new full backup chains when necessary
- Updates the backup chain regularly, via internal cron task
- Rebuilds/recovers backup chains automaticaly from many disaster scenarios, including a server crash on Unraid
- When backup chain gets broken, it can archive it for further restoration, or deletes it when becomes unusable
- Syncs successful backup operations and is able to archive remote backup chain mirrors independently of local ones

## Building an up-to-date docker image:

- Clone/download/pull this repository
- Get into the main folder
- Execute `docker build . -t vm-babysitter`
- Push the generated image to your private docker image repository

## Environment variables:

VM-Babysitter is entirely controlled via ENV variables, passed on runtime:

### Always required:

**`BACKUPS_MAIN_PATH`**: Absolute path where vm-babysitter will search for, and save backup chains of all VMs (container fails if not passed, does not exist or r/w permission issues are found)

### Required when syncing backups to a remote endpoint:
**`REMOTE_BACKUPS_MAIN_PATH`**: SSH syntax of remote absolute path (e.g. user@host:/absolute/path/to/folder) to rsync successful backup chain tasks (default is work with local backups only)

**`SSH_OPTS`**: SSH options for remote communications, including rsync transfers (default is none. Read below for detailed instructions)

### Optional parameters:
**`AUTOSTART_VMS_LIST`**: Space separated list of VMs that will be started along with the container

**`CRON_SCHEDULE**: Cron-like string for incremental backups. E.g. "* 2 * * *" triggers everyday at 2 am local time (default is '@daily')

**`MAX_BACKUP_CHAINS_PER_VM`**: How many old backup chains to keep archived locally under BACKUPS_MAIN_PATH (default is infinite, set to "0" to disable old backups archive)

**`RAM_LIMIT_PER_SCHED_BACKUP`**: How much RAM in KiB to assign a shut down VM temporarily to perform backup tasks (default is no limit)

**`REMOTE_MAX_BACKUP_CHAINS_PER_VM`**: Same as MAX_BACKUP_CHAINS_PER_VM, but for REMOTE_BACKUPS_MAIN_PATH

**`RESTART_VMS_IF_REQUIRED`**: When non-zero lenght string, performs (temporal) shutdown / powercycle of VMs, checking backups or patch VM is needed (default is to notify user to perform these actions, and wait for VM to be shut down)

**`TZ`**: Local timezone (default is 'Etc/UTC')

**`VIRTNBDBACKUP_ARGS`**: Extra arguments passed to virtnbdbackup, in both full and inc backup. E.g. "--compress" (default is no extra arguments)

### Advanced parameters:
**`IGNORED_VMS_LIST`**: Space separated list of VMs to ignore, not checking or adding it to scheduled backups (default is to include all persistent VMs having disk images able to be backed up)

**`MOMITOR_LOGPATH`**: Absolute path for the main log file (default is "/logs/vm-babysitter.log")

**`RSYNC_ARGS`**: Extra arguments for rsync when sends successful backups to REMOTE_BACKUPS_MAIN_PATH. E.g. "--bwlimit=350M" (default is no arguments)

**`SCHEDULED_LOGPATH`**: Absolute path for scheduled backups log file (default is "/logs/scheduled-backups.log")

**`WAIT_TIME`**: Maximum time in seconds to await for VMs to confirm it has reached on/off states in certain scenarios (default is 60 seconds)

## Mount points:

VM-Babysitter relies entirely on correct mounts to find and save all files related with Virtual machines. Not doing this correctly will be the main cause of issues when running the container.

### Backups and disk images:

BACKUPS_MAIN_PATH should be mounted in ways that reflects same path on the host and inside the container. If BACKUPS_MAIN_PATH is "/mnt/user/Backups/vm-backups", a mountpoint should be:

`- v /mnt/user/Backups/vm-backups:/mnt/user/Backups/vm-backups`

The service needs full access to ALL VM's disk images to be backed up, from inside the container. There is no canonical rule about this, but the idea is to mount the folder that contains all disk images of VMs inside, or add different mounts if disk images are spread in different (and unrelated) places.

If, for example all disk images are located in '/mnt/user/VMs', a mountpoint should be:

`-v /mnt/user/VMs:/mnt/user/VMs`

More mountpoints can be added as needed. The trick is to replicate same paths on the host, INSIDE the container, because these paths will be searched during execution.
If some, or none disk images are found (or r/w issues are detected) the container will fail.

### System, libvirt, and virtnbdbackup:

VM-Babysitter uses self provisioned tools for all operations, however it needs access to sockets on the host where it's running (specially for libvirt's API) or else it won't be able to work at allSo, the followng mountpoints are needed:

Required for Virtnbdbackup (all operating systems):

`-v /var/tmp:/var/tmp`

Required to access host libvirt's socket:

- On most operating systems (Debian, RedHat, Archlinux, its derivatives, etc.):

 `-v /run/libvirt:/run/libvirt`

 `-v /run/lock:/run/lock`

- On Unraid:

 `-v var/run/libvirt:/run/libvirt`

 `/var/run/lock:/run/lock`

(Other operating systems may require different mounts, but this software has not been tested outside Debian, Ubuntu and Unraid)

### SSH key and Logs info:

The *best* way to communicate with remote hosts is via SSH RSA key pairs, and VM-babysitter is intended to work in this way.

Assuming you have, or can create a pair of RSA keys (3072 bits or above is recommended) you can install the public key onto the remote host (as the user you want to connect); and make the private key available for VM-Babysitter into a specific folder, just like this:

`-v /mnt/user/apps/vm-baybysitter/private:/private`

And set `SSH_OPTS="-q -i /private/<your-private.key> -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10"`

allowing thus, transparent -and silent- communication between hosts.

(Note, remember to assign 'root' user & group ownership and Unix permissions '600')

Finally, to have persistent logs of what is happening with VM-Babysitter and scheduled backups, create a mountpoint like this:

`-v /mnt/user/apps/vm-babysitter/logs:/logs`

## Using the service:

### Important note about Unraid: Disable VM autostart of the hosts you want to babysit!

Due the Unraid's quirky QEMU implementation, when a server is restarted, local checkpoints are lost. While VM-Babysitter can deal with this (thanks to Virtnbdbackup's resilience restoring lost checkpoints) it will refuse to check backups of VMs if these are running.

### Unraid example for local backups only:

`docker run -d --rm --name vm-babysitter \`

`-e TZ="Europe/Berlin" \`

`-e RESTART_VMS_IF_REQUIRED="yes" \`

`-e CRON_SCHEDULE="* 2 * * *" \`

`-v /mnt/user/VMs:/mnt/user/VMs`

`-e BACKUPS_MAIN_PATH="/mnt/user/Backups/vm-backups" \`

`-v /mnt/user/Backups/vm-backups:/mnt/user/Backups/vm-backups`

`-e MAX_BACKUP_CHAINS_PER_VM="2" \`

`-e RAM_LIMIT_PER_SCHED_BACKUP="8388608" \`

`-e VIRTNBDBACKUP_ARGS="--compress" \`

`-v /var/tmp:/var/tmp \ -v /var/run/libvirt:/run/libvirt -v /var/run/lock:/run/lock \`

`-v /mnt/user/apps/vm-baybysitter/private:/private \`

`-v /mnt/user/apps/vm-babysitter/logs:/logs \`

`vm-babysitter`

### Unraid example for both local and remote backups:

`docker run -d --rm --name vm-babysitter \`

`-e TZ="Europe/Berlin" \`

`-e RESTART_VMS_IF_REQUIRED="yes" \`

`-e CRON_SCHEDULE="* 2 * * *" \`

`-v /mnt/user/VMs:/mnt/user/VMs`

`-e BACKUPS_MAIN_PATH="/mnt/user/Backups/vm-backups" \`

`-v /mnt/user/Backups/vm-backups:/mnt/user/Backups/vm-backups`

`-e MAX_BACKUP_CHAINS_PER_VM="0" \`

`-e REMOTE_BACKUPS_MAIN_PATH="root@192.168.88.10:/mnt/user/Backups/<hostname>/vm-backups" \`

`-e REMOTE_MAX_BACKUP_CHAINS_PER_VM="3" \`

`-e SSH_OPTS="-q -i /private/<your-private.key> -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10" \`

`-e RSYNC_ARGS="-P --bwlimit=40M" \`

`-e RAM_LIMIT_PER_SCHED_BACKUP="8388608" \`

`-e VIRTNBDBACKUP_ARGS="--compress" \`

`-v /var/tmp:/var/tmp \ -v /var/run/libvirt:/run/libvirt -v /var/run/lock:/run/lock \`

`-v /mnt/user/apps/vm-baybysitter/private:/private \`

`-v /mnt/user/apps/vm-babysitter/logs:/logs \`

`vm-babysitter`

## Known Issues/bugs:

When VMs are added to IGNORED_VMS_LIST, and another VM has no image disks able to be backed up the script fails apending this VM to the same list (used internally for same purpose) and falls into a loop, attempting to create a backup chain without success.

## TO DO:
- Send alerts to Unraid's notification system
- Add/Remove VMs on the fly
- Archive backup chain when its total size is too big for certain criteria
- Detect and alert when space in BACKUPS_MAIN_PATH and REMOTE_BACKUPS_MAIN_PATH is getting low
