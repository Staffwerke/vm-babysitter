# VM-Babysitter

Automatic Backup & Monitoring utility for QEMU/KVM Virtual Machines (powered by Virtnbdbackup)

## Abstract:

The reason of existence for this tool was our inherent difficulty to perform portable, concurrent and incremental backups of QEMU based domains while these are running; which is often an essential requirement for domains that are part of production environments. In the same way, compact, easy to copy and/or transfer backups, able to be restored into any host with Libvirt and QEMU.

Although Libvirt offers simpler approaches for backups/snapshots -and its subsequent restoration- none of the existing ones is able provide us all the mentioned requirements, at the same time. In addition, we were in need of a tool that keep domains backed up into specific schedules, and able to alert us about relevant events or when something went wrong.

We paid attention at Michael Ablassmeier's backup utility CLI: [Virtnbdbackup](https://github.com/abbbi/virtnbdbackup), and found it accomplishing our most critical requirements (even at early versions), and potentially all of them if some scripting was done around it. After 3 years of almost uninterrupted usage, the code here has evolved -in part to Virtnbdbackup's constant improvements and new features, and also in part to the need of optimize and extend the initial rudimentary code- into something yet simple, but robust enough to satisfy all our VM backup needs.

This code is intended to work with any GNU/Linux Operating System that has Libvirt, QEMU/KVM, Docker, and little more; however it's necessary to make notice that has been 'field tested' almost exclusively on Unraid OS -which is one the main reason for running inside a container- and some punctual features (visible out-of-logs notifications and detection of potential server crash scenarios) only work on Unraid at this moment. We consider it *stable* for its use on Unraid, and *beta* for other Linux Distributions  until it has been tested (and optimized) by other users. Said this, collaborators interested into test and improve this tool for other OSes are welcomed.

## Features:

- Manages a list of *non-transient* domains defined in QEMU to be backed up regularly via internal cron task
- Checks backup chains integrity of all listed domains, being able to detect inconsistencies and proceed accordingly (e.g. fixing, discarding, creating new ones, etc.)
- Configurable backup rotation and retention policy
- Ability to create a mirror and keep it updated with Rsync right after backup schedule or at configurable one, with independent retention policy
- All main tasks (backup, sync, rotation/retention) can be performed manually by the user from inside the container
- Pseudo-interactive tools for domain replication (to local and remote endpoints) and recovery from backups on the local host
- Notify about backup chain and Rsync start and end of activities, as also when user intervention is required and about errors (Unraid feature)
- Assume a different behavior when detects the server has been started recently, assuming the possibility of a previous crash, and therefore a more strict check of backup chains (Unraid feature)

## Requirements

### On the Main Host:

- GNU/Linux
- Bash
- Libvirt >=7.6.0
- Docker Engine

*It's fully compatible with Unraid OS starting from version v6.10.0*

### On Guest Domains:

- Qemu Guest Agent installed and running. For *NIX guests, use the latest available version according the distro. For Windows guests, install latest [VirtIO drivers](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/)

## Environment variables:

VM-Babysitter is entirely controlled via ENV variables, passed on runtime. Here's the detailed explanation for each one:

| **Variable Name** | **Description** | **Default Value** |
| --- | --- | --- |
|`BACKUP_SCHEDULE`|Cron expression to schedule incremental backups|`@daily`|
|`CHECK_BACKUPS_INTEGRITY`|Verify data integrity of backups. This operation may take long time, delaying container's full initialization. Only useful under suspect of data corruption (Set a non-empty value to enable)||
|`LOCAL_BACKUP_CHAINS_TO_KEEP`|Local retention policy: How many backup chains to keep archived at `LOCAL_BACKUP_PATH`. If set to `0`, disables retention policy on the local endpoint|`1`|
|`LOCAL_BACKUP_PATH`|Container path where vm-babysitter will save and vm-restore will search for backups. Container will not start if not set, or if not mounted in r/w mode|`/backups`|
|`LOGROTATE_CONFIG_PATH`|Container path to place and read log rotation config|`/tmp/logrotate.d/vm-babysitter`|
|`LOGROTATE_SCHEDULE`|Cron expression to schedule internal logs rotation|`@daily`|
|`LOGROTATE_SETTINGS`|Parsed string with *escaped* logrotate config to `LOGROTATE_CONFIG_PATH` during container (re)start|`  compress\n  copytruncate\n  daily\n  dateext\n  dateformat .%Y-%m-%d.%H:%M:%S\n  missingok\n  notifempty\n  rotate 30`|
|`LOGFILE_PATH`|Container path for the main log file|`/logs/vm-babysitter.log`|
|`MAX_BACKUPS_PER_CHAIN`|Backups rotation: Number of checkpoints to save incrementally into a backup chain before to archive it. If set to `0`, backup chain will grow indefinitely (and no retention policies will be applied)|`30`
|`RSYNC_ARGS`|Extra arguments passed to Rsync|`-a`|
|`RSYNC_BACKUP_CHAINS_TO_KEEP`|Mirror's retention policy: How many backup chains to keep archived at `RSYNC_BACKUP_PATH`. If set to `0`, disables retention policy on the mirror|`2`|
|`RSYNC_BACKUP_PATH`|Usually, a SSH address to a path into another host, where backup chains will be mirrored. Requires r/w permissions at the remote host. If not set, this feature remains disabled and `RSYNC_` env vars have no effect. (Read documentation for advanced usage)||
|`RSYNC_SCHEDULE`|When a cron expression is set, backup mirrors are updated at this specific schedule, instead of immediately after backups schedule||
|`SCHEDULE_LOGFILE_PATH`|Container path for scheduled tasks log file|`/logs/scheduled-tasks.log`|
|`SSH_OPTIONS`|Common SSH options for communications with remote, and the unraid hosts (expert use only)|`-q -o IdentityFile=/private/hostname.key -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10`|
|`TZ`|Set container to a desired timezone (usually, same as this host)||
|`UNRAID_NOTIFY_HOST`|Unraid IP/Hostname to send notifications (usually, same as this host). It has no effect on non-Unraid OS|`localhost`|
|`VIRTNBDBACKUP_ARGS`|Extra arguments passed to virtnbdbackup (only tested with `--start-domain`, `--compress` and `--no-color`. Other combinations usually lead to unexpected results)||
|`VM_ALLOW_BACKUP_CHAIN_FIX`|Attempts to repair backup chains when virtnbdbackup was interrupted in the middle of an operation, by removing the last checkpoint at both backup and domain, avoiding thus a forced rotation and creation of a new backup chain. (Set a non-empty value to enable)||
|`VM_ALLOW_POWERCYCLE`|Performs controlled power cycle of running domains under certain scenarios during container startup. If not set, vm-babysitter will ask the user (via logs and Unraid notifications, when available) to manually shut down domains in need of this action. Read documentation for more info (Set a non-empty string to enable)||
|`VM_AUTOSTART_LIST`|Space separated list of domains that will be started along with the container if found powered off (case sensitive)||
|`VM_IGNORED_LIST`|Space separated list of domains to exclude from backup schedule and automatic checks (case sensitive)||
|`VM_WAIT_TIME`|Max amount in seconds that scripts will await for domains responding to libvirt queries during power cycle operations. Increase this value if you get often warnings about scripts 'giving up' awaiting for slow domains|`60`|

## Important Notes:

The thumb rule to make this utility **work correctly**, consists into assume ONE of the following procedures:

- Disable auto start of domains you want to keep backed up periodically, and list them instead into env var `VM_AUTOSTART_LIST` to make them start AFTER the container when all initial checks and/or fixes has been performed (recommended option)

or

- Set env var `VM_ALLOW_POWERCYCLE` to a not null value, allowing to power cycle domains when required.

This will ensure backup chains will be always checked, and confirmed/fixed/rotated/discarded under all scenarios, including when server crashed unexpectedly.

Domains that aren't intended to be backed up (and therefore ignored) must be listed into env var `VM_IGNORED_LIST`. They could be perfectly set to auto start on server's boot if required.

For any operation involving remote connection, and in case of Unraid, to see notifications on the panel; the user must provide (via bind mount) access to an SSH private key, which public counterpart must be installed onto the involved servers (including the Unraid server showing notifications.)

## Install & Basic setup on Unraid OS:

- Download and install the container from [Community Apps](https://unraid.net/community/apps)

- Provide at least a valid path for local backups, a custom backup schedule, an SSH Key and the Unraid IP/Host

- If you use shares different than Unraid defaults for Docker (/mnt/user/appdata) and Libvirt (/mnt/user/domains) review all options (general & advanced) and replace the host paths according with your custom setup

It's highly recommended to set the local backups path to a user share which primary storage it's a fast cache pool (SSD, NVMe, etc) and secondary storage located at designated array. This will speed up backup process, at the same time the new data will be suddenly transferred to the array (via the 'Move' function, programmed at different schedule than backups.)

## Basics to configure in Other Operating Systems

As VM-Babysitter runs inside a container, relies entirely on correct bind mounts to find, manage and save all files related with domains, as well to communicate correctly with Libvirt.

### Backups Directory:
The main directory where all local backups will be checked and saved is mounted as in this example:

```
    -v /data/vm-backups:/backups
```
Container's path always must match `LOCAL_BACKUP_PATH`.

### Disk images:
The service needs full access to ALL domain's disk images, from inside the container. There is no canonical rule about this, and indeed it may happen that disk images are spread across different (and unrelated) places, requiring more than one bind mound for this.

Assuming all disk images are stored into a main directory at '/data/domains' the correct bind mount should be:

```
    -v /data/domains:/data/domains
```
Replicating host path inside the container as is. During container's start, if any disk image isn't found or r/w issues are detected, the container will fail.

### System, libvirt, and virtnbdbackup sockets:
VM-Babysitter uses self provisioned tools for all operations, however it needs access to sockets on the host where it's running (specially for libvirt's API) or it won't be able to work at all. Therefore, the following mount points are needed:

Required for Virtnbdbackup (all operating systems):

```
    -v /var/tmp:/var/tmp
```

Required to access host libvirt's socket:

- On most modern operating systems:

```
    -v /run/libvirt:/run/libvirt
    -v /run/lock:/run/lock
```

- On older or less common operating systems you might try:

```
    -v var/run/libvirt:/run/libvirt
    -v /var/run/lock:/run/lock
```

Another thumb rule it's to find out where your Libvirt implementation puts both sockets and lock files onto the root file system.

### Domains with EFI/UEFI Boot:
Unless your scenario involves domains booting with emulated BIOS only, it's necessary to provide a couple of additional bind mounts:

Allow scripts to read/restore per domain nvram binaries for EFI/UEFI boot:

```
    -v /etc/libvirt/qemu/nvram:/etc/libvirt/qemu/nvram
```

Allow scripts to read/copy common nvram binaries for EFI/UEFI boot:

- Unraid:

```
    -v /usr/share/qemu/ovmf-x64:/usr/share/qemu/ovmf-x64:ro
```

- Debian & based distros:

```
    -v /usr/share/OVMF:/usr/share/OVMF:ro
```

*We welcome contributions about corresponding bind mounts for other GNU/Linux distributions*

### SSH key:
Assuming you have, or can create a pair of RSA or any SSH compatible keys, you can install the public key onto the involved hosts (as the user you want to connect) and make the private key available for VM-Babysitter into a specific folder, just like this:

```
    -v /data/docker/apps/vm-baybysitter/private/<name-of-your-private-ssh-key>:/private/hostname.key:ro
```

Note that instead of the folder, the private key file is bind mounted instead (as read-only), at container's path and file name stated in env var `SSH_OPTIONS`.

In addition, the private key must be owned by 'root' (both user & group) and must have Unix permissions '0600'

### Persistent logs:
Finally, to have persistent logs of what is happening with VM-Babysitter and all scheduled tasks, create a mount point like this:

```
    -v /data/docker/apps/vm-babysitter/logs:/logs
```

## Deploying and Running:

The simplest user case example:

```
    docker run -d --rm --network host --name docker.staffwerke.de/vm-babysitter:latest \
    -e BACKUP_SCHEDULE="* 2 * * *" \
    -e TZ="Europe/Berlin" \
    -e VM_ALLOW_POWERCYCLE="y" \
    -v /etc/libvirt/qemu/nvram:/etc/libvirt/qemu/nvram \
    -v /data/docker/apps/vm-babysitter/logs:/logs \
    -v /data/domains:/data/domains \
    -v /data/vm-backups:/backups \
    -v /run/libvirt:/run/libvirt \
    -v /run/lock:/run/lock \
    -v /usr/share/OVMF:/usr/share/OVMF:ro \
    -v /var/tmp:/var/tmp \
    --restart=unless-stopped \
    vm-babysitter
```

The command above involves local backups only, and most options set to default.

A more complex example, closer to a production environment:

```
    docker run -d --rm --network host --device /dev/fuse --cap-add SYS_ADMIN --name docker.staffwerke.de/vm-babysitter:latest \
    -e BACKUP_SCHEDULE="* */12 * * *" \
    -e LOCAL_BACKUP_CHAINS_TO_KEEP="2" \
    -e MAX_BACKUPS_PER_CHAIN="60" \
    -e RSYNC_ARGS="-aP --bwlimit=1179648" \
    -e RSYNC_BACKUP_PATH="root@192.168.0.2:/data/vm-backups-mirror" \
    -e RSYNC_BACKUP_CHAINS_TO_KEEP="4" \
    -e TZ="Europe/Berlin" \
    -e VIRTNBDBACKUP_ARGS="--compressed" \
    -e VM_AUTOSTART_LIST="domain1 domain2" \
    -e VM_IGNORED_LIST="domain3" \
    -v /etc/libvirt/qemu/nvram:/etc/libvirt/qemu/nvram \
    -v /data/docker/apps/vm-babysitter/logs:/logs \
    -v /data/docker/apps/vm-baybysitter/private/your-ssh-key.key:/private/hostname.key:ro \
    -v /data/domains:/data/domains \
    -v /data/vm-backups:/backups \
    -v /run/libvirt:/run/libvirt \
    -v /run/lock:/run/lock \
    -v /usr/share/OVMF:/usr/share/OVMF:ro \
    -v /var/tmp:/var/tmp \
    --restart=unless-stopped \
    vm-babysitter
```

The command above involves, to auto start some domains and ignore others, the ability to replicate domains onto remote endpoints, backups compression, a mirror at the local network, and specific retention policies for each endpoint.

## Backups Rotation and Retention Policy:

Backup rotation is managed via env var `MAX_BACKUPS_PER_CHAIN` and has effect on both the local backup and the mirror, if set.

Every time virtnbdbackup runs, a new checkpoint is added to the backup chain. This variable allows to set an upper limit so the backup chain can be archived and replaced by a new one. It can be tuned according to your actual needs, and depending on how often is the backup schedule (ideally, the more often, the more checkpoints should be allowed.)

Retention policy is managed by env vars `LOCAL_BACKUP_CHAINS_TO_KEEP` for backups archived locally and `RSYNC_BACKUP_CHAINS_TO_KEEP` for their mirror counterparts, when set.

Every time a backup chain is rotated, its folder becomes renamed with a (very specific) local timestamp corresponding to the oldest modified file into the entire backup sub-folder. The number of archived backup chains per domain will be kept up to the value set on these variables, deleting the older ones.

Then, a mirror can contain (ideally) more archived backups than the local pool.

Both rotation and retention policy are automatically checked (and executed, if applies) at 2 moments:

- At container start, if a backup chain has inconsistencies and cannot be fixed (forcing thus rotation despite the number of checkpoints)
- At each backup schedule, checking if has reached the limit imposed by `MAX_BACKUPS_PER_CHAIN`

### Rotation/Retention Special scenario:
While a backup chain is being created and the process is interrupted (e.g. container stop or server crash), the partial backup chain is deleted locally at next container's start instead of being rotated (because the only checkpoint is faulty, and this cannot be fixed).

If a mirror is set and a non-archived backup chain for that domain is found, it becomes rotated, but no retention policy is applied on the mirror.

### Calculating Rotation and Retention Times:

When no schedule/rotation/retention settings are set, VM-Babysitter works with the following defaults:

```
BACKUP_SCHEDULE="@daily"
MAX_BACKUPS_PER_CHAIN=30
LOCAL_BACKUP_CHAINS_TO_KEEP=1
RSYNC_BACKUP_CHAINS_TO_KEEP=2
```
By default, it will perform one backup per day, allowing 30 checkpoints before to rotate. Which means that rotation will occur each 30 days, starting from backup chain's creation day.

The locally archived backup chain will remain for another 30 days more, being deleted when the current one becomes rotated.

If a local mirror is set, the copy of the archived backup chain won't be deleted, but kept during 60 days counting from its archiving day before to be deleted.

Summarizing, with default settings, a backup chain will remain 60 days on local backup pool, and 90 days on mirror (when set) counting from the day of its creation.

You can use this example to extrapolate, and set rotation and retention policies according with your actual needs.

### Forcing Backup Rotation on Domains that remain Shut Down:
There will be cases when a domain is kept shut off most of the time, being just used occasionally.

Although this domain will be backed up as any other, the number of checkpoints made by virtnbdbackup won't grow if the server has been down between 2 backup schedules, therefore backup rotation (hence retention policy) won't be triggered as in the past example.

To force backup rotation on domains as in this example, set env var `VIRTNBDBACKUP_ARGS="--start-domain"`, indicating virtnbdbackup to start the domain if it's shut off (actually, it will start it in paused mode, so no boot is even performed) and thus it will create a new checkpoint and backup rotation will occur just as expected.

### Saving Important Backup Chains Permanently within Backups Paths:
As alternative to move them off the paths set in `LOCAL_BACKUP_PATH` and/or `RSYNC_BACKUP_PATH`, you can append some custom tag before or after the current folder name. VM-Babysitter processes only EXACT matches of the syntax `<sensitive-case-domain-name>+<yyyy-mm-dd.hh:mm:ss.ssssssssss>` and therefore other naming structure is ignored for retention policy apply.

## Restoring from Backups:

Eventually, any user will be in need to restore a domain from its backups, or even to restore a previously deleted domain, which backups still exists somewhere. The simplest way to perform this task it's via a built-in script called [vm-restore](scripts/vm-restore).

Assuming the container is up and running, open a shell invoke the script with the following command:

```
    docker exec -it vm-babysitter vm-restore
```

And do the following:

- Select a specific backup from the backups pool
- If available, select a specific point in time (checkpoint) to restore.
- Then select either existing domain, or create a new one (depends on the scenario. Vm-restore builds the list based on matches between chosen backup and existing domains)
- And select if restore all image disks or a specific one. (depending on the scenario, it will propose a new path based on new domain's name or allow to choose a custom one)

The script will ask for authorization to proceed, and restoration will be performed automatically.
If the domain already exists and it's currently running, it must be shut down before to proceed (and vm-restore can detect and do this automatically under your authorization.)

At this moment, vm-restore only works with backups stored locally (read rsync section below for alternatives.)

If the restoration scenario you face cannot be managed by vm-restore use [Virtnbdrestore](https://github.com/abbbi/virtnbdbackup/tree/master?tab=readme-ov-file#restore-examples) instead (included within the container), to perform a custom restoration of, e.g. image disk(s) on backup not matching with an existing target domain.

## Advanced Features:

VM-Babysitter is not limited to perform backups automatically or allow a manual restoration. It has been developed according the use and needs we have had during years of managing several (non-clustered) pools of Virtual Machines.

### vm-backup vm-rsync and vm-retention-policy:
These scripts are responsible of main backup tasks, as their names suggest. Although are primarily invoked by VM-Babysitter, the user can invoke them separately to, e.g. perform backups, trigger sync mirroring and even trigger rotation / retention policy outside of schedule. This is possible for any domain, even if included into `VM_IGNORED_LIST`.

The use of these commands it's considered an expert feature, and must be done with care, since literally *override* VM-Babysitter's schedules and may cause alterations on planned schemes, such as backup rotation /retention policy outside planned timetables.

For more details, Use `--help` option on each script to understand more about its usage. Example:

```
    docker exec -it vm-babysitter vm-backup --help
```

### vm-replicate:
Replicates a given domain onto a local or remote endpoint.

It's very similar in functioning with QEMU's [virt-clone](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/7/html/virtualization_deployment_and_administration_guide/cloning-a-vm#Cloning_VMs_with_virt-manager) utility, except it can also replicate virtual machines onto remote hosts running libvirt without the need of a GUI.

*To correctly replicate disk images remotely, docker parameters `--device /dev/fuse` and `--cap-add SYS_ADMIN` must be added to the run command*

Similar to vm-restore, it shows a series of options:

- Select the domain on the list to be replicated
- Indicate where to replicate, either on the same or at another host (in which case, the other endpoint needs to have installed the public counterpart of private key in use)
- Select and action to perform with MAC address(es) (either insert custom one, randomize or keep)
- Choose if replicate disk images or not
- And select which disk image(s) to replicate, and where (or configure the destination domain with such paths)

Finally, authorize vm-replicate to start the process. Replication will take place automatically.

At this moment, vm-replicate only can copy disk images when source domain is shut off. Note that if it finds the domain running, it will shut it down before to proceed, and will start it again once the disk image copy finishes.


### Rsync Mirror in a Directory Mounted Locally:
The backup mirror can be set into a container's path folder (ideally, a host's directory bind mounted to this location), and let Rsync work 'locally' instead of using SSH keys to connect to remote servers. An additional bind mount should be necessary, for example:

```
-e RSYNC_BACKUP_PATH="/backups-mirror"
-v /data/shares/backups-mirror:/backups-mirror
```

Where '/data/shares/backups-mirror' could be a NFS or CIFS/SMB share, mounted from another host. Thus, rsync would transfer changes on backups across servers transparently.

In case of needing to restore a backup located at another server, this workaround might work, invoking vm-restore like this:

```
    docker exec -it vm-babysitter vm-restore --source /backups-mirror
```

*Please note, that this has not been field tested with actual remote mounts. There might be additional settings to perform on `docker run`. Scripts are only able to work under this possibility, so any contribution about this topic is welcomed.*

## Known Issues Caveats & Troubleshooting:

- VM-Babysitter only uses a subset of features of Virtnbdbackup. The env var `VIRTNBDBACKUP_ARGS` has been tested only with flags `--start-domain`, `--compress` and `--no-color` and other options usually lead to unexpected results. However, it's still possible to create custom backups and even templates by using virtnbdbackup command from inside the container. It applies the same with other commands, but those aren't been even tested or used, so do it at your own risk.

- VM-Babysitter has been tested on Unraid v7. It has been determined that is not possible to make snapshots of domains being backed up with VM-Babysitter. By the other hand, making backups of domains with snapshots it's possible, and when restored, they seem to be OK. Nevertheless, and considering both approaches part from different strategies, it's highly encouraged to **use only one at the same time for a given domain, and do not mix snapshots with checkpoint based backups together**.

- When trying to delete a domain with checkpoints, Libvirt will warn you with the following message:

```
Execution error
Requested operation is not valid: cannot delete inactive domain with xx checkpoints
```

If you want to delete a domain that gives you the above message, the easiest way is running the following command from a shell (would work the same from inside the container):

```
    virsh checkpoint-delete <domain-name> virtnbdbackup.0 --children --metadata
```
This deletes all checkpoints metadata created by virtnbdbackup on the main host, allowing you to delete the domain (and optionally, image disks) without warnings.

- Stopping or killing the container while virtnbdbackup is performing a backup operation may lead to persistent failed status during next runs. This is due to 'dead' sockets in `/var/tmp`, `/run/libvirt` and `/run/lock`, stuck after the interruption. To solve the situation, read [this](https://github.com/abbbi/virtnbdbackup/tree/master?tab=readme-ov-file#backup-fails-with-timed-out-during-operation-cannot-acquire-state-change-lock).

#### Maintainer: Adrián Parilli <adrian.parilli@staffwerke.de>
