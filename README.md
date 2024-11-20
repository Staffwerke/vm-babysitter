# VM-Babysitter

Automated backup system for QEMU/KVM Virtual Machines

## Abstract:

The reason of existence for this tool was our inherent difficulty to perform portable, concurrent and incremental backups of QEMU based domains while these are running; which is often an essential requirement for domains that are part of production environments. In the same way, compact, easy to copy and/or transfer backups, able to be restored into any host with Libvirt and QEMU.

Although Libvirt offers simpler approaches for backups/snapshots -and its subsequent restoration- none of the existing ones is able provide us all the mentioned requirements, at the same time. In addition, we were in need of a tool that keep domains backed up into specific schedules, and able to alert us about relevant events or when something went wrong.

We paid attention at Michael Ablassmeier's backup utility CLI: [Virtnbdbackup](https://github.com/abbbi/virtnbdbackup), and found it accomplishing our most critical requirements (even at early versions), and potentially all of them if some scripting was done around it. After 3 years of almost uninterrupted usage, the code here has evolved -in part to Virtnbdbackup's constant improvements and new features, and also in part to the need of optimize and extend the initial rudimentary code- into something yet simple, but robust enough to satisfy all our VM backup needs.

This code is intended to work with any GNU/Linux Operating System that has Libvirt, QEMU/KVM, Docker, and little more; however it's necessary to make notice that has been 'field tested' almost exclusively on Unraid OS -which is one the main reason for running inside a container- and some punctual features (Outside container notifications and detection of potential server crash scenarios) only work on Unraid at this moment. We consider it *stable* for its use on Unraid, and *beta* for other Linux Distributions  until it has been tested (and optimized) by other users. Said this, collaborators interested into test and improve this tool for other OSes are welcomed.

## Main Features:

- Manages a list of *non-transient* domains defined in QEMU to be backed up regularly via internal cron task
- Checks backup chains integrity of all listed domains, being able to detect inconsistencies and proceed accordingly (e.g. fixing, discarding, creating new ones, etc.)
- Configurable backup rotation and retention policy
- Ability to create local or remote mirrors and keep them updated with Rsync right after backup schedule or at configurable one, with independent retention policy
- All main tasks (backup, sync, rotation/retention) can be performed manually by the user from inside the container
- Pseudo-interactive tools for domain replication (to local and remote endpoints) and recovery from backups on the same host
- Notifies about backup chain and Rsync start and end of activities, as also when user intervention is required and about errors (Unraid feature)
- Assumes a different behavior when detects the server has been started recently, assuming the possibility of a previous crash, and therefore a more strict check of backup chains (Unraid feature)

## Requirements

### On the Host:
- Docker Engine on the host server. See [Docker Documentation](https://docs.docker.com/get-docker/) for further instructions
- Libvirt >=7.6.0
- Bash and SSH server configured to be accessed via public keys (also required for any remote host intended to serve as backup mirror, or target for domain replication)
- On Unraid OS case, this must be >= v6.10.0. Read the [notes](Unraid Notes) for more details.

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
|`MAX_BACKUPS_PER_CHAIN`|Backups rotation: Number of checkpoints to save incrmentally into a backup chain before to archive it. If set to `0`, backup chain will grow indefinitely (and no retention policies will be applied)|`30`
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
|`VM_ALLOW_POWERCYCLE`|Performs controlled powercycle of running domains under certain scenarios during container startup. If not set, vm-babysitter will ask the user (via logs and Unraid notifications, when available) to manually shut down domains in need of this action. Read documentation for more info (Set a non-empty string to enable)||
|`VM_AUTOSTART_LIST`|Space separated list of domains that will be started along with the container if found powered off (case sensitive)||
|`VM_IGNORED_LIST`|Space separated list of domains to exclude from backup schedule and automatic checks (case sensitive)||
|`VM_WAIT_TIME`|Max amount in seconds that scripts will await for domains responding to libvirt queries during powercycle operations. Increase this value if you get often warnings about scripts 'giving up' awaiting for slow domains|`60`|

## Important Notes:

The thumb rule to make this utility **work correctly**, consists into assume ONE of the following procedures:

- Disable autostart of domains you want to keep backed up periodically, and add them instead in env var `VM_AUTOSTART_LIST` to make them start AFTER the container* when all initial checks and/or fixes has been performed (remommended option)
OR
- Set env var `VM_ALLOW_POWERCYCLE` to a not null value, allowing to powercycle domains when required.

This will ensure backup chains will be always checked, and fixed/rotated/discarded on all scenarios, including when server crashed unexpectedly.

Domains that aren't intended to be backed up (and therefore ignored), must be listed into env var `VM_IGNORED_LIST` and indeed can be perfectly set to autostart on boot when required.

All operations involving remote connections, and in case of Unraid, see notifications on the panel; the user must provide (via bind mount) access to a SSH private key, which public counterpart must be installed on the involved servers (including the Unraid server that will show notifications, even if it's the same where container is running.)

## Install & Basic setup on Unraid OS:

- Download and install the container from [Community Apps](https://unraid.net/community/apps)

- At least provide a valid path for local backups, custom backup schedule, SSH Key and Unraid IP/Host for basic usage

It's highly recommended to set the local backups path to a user share which primary storage it's a fast cache pool (SSD, NVMe, etc) and secondary storage located at designated array. This will speed up backup operations when writing new data, at the same time it will be transfered progressively to the array via the 'Move' function, programmed at different schedule than backups.

## Basics to configure in Other Operating Systems:

As VM-Babysitter runs inside a container, relies entirely on correct bind mounts to find, manage and save all files related with domains.

### Backups Directory:
The main directory where all local backups will be checked and saved is mounted as in this example:

```
    -v /data/vm-backups:/backups
```
Note that host and container paths don't need to be the same, but container's path must match `LOCAL_BACKUP_PATH` always.

### Disk images:
The service needs full access to ALL domains's disk images to be backed up, from inside the container. There is no canonical rule about this, and indeed it may happen that disk images are spread across different (and unrelated) places. Assuming all disk images are stored into a main directory at '/data/domains' the correct bind mount should be:

```
    -v /data/domains:/data/domains
```
Replicating host path inside the container as is.
During container's start, if any disk image isn't found or r/w issues are detected, the container will fail.

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

A thumb rule it's to find out where your Libvirt implementation puts both sockets and lock files.

### Domains with EFI/UEFI Boot:

Unless your scenario involves that all domains use emulated BIOS to boot, is necessary to provide a couple of additional bind mounts.

Allow scripts to read/restore per domain nvram binaries for EFI/UEFI boot:

```
    -v /etc/libvirt/qemu/nvram:/etc/libvirt/qemu/nvram
```

Allow scripts to read/copy common nvram binaries for EFI/UEFI boot:

- Unraid:

```
    -v /usr/share/qemu/ovmf-x64:/usr/share/qemu/ovmf-x64
```

- Debian & based distros:

```
    -v /usr/share/OVMF:/usr/share/OVMF:ro
```

*We welcome contributions about corresponding bind mounts for other GNU/Linux distributions*

### SSH key:

Assuming you have, or can create a pair of RSA keys (3072 bits or above is recommended) you can install the public key onto the remote hosts (as the user you want to connect); and make the private key available for VM-Babysitter into a specific folder, just like this:

```
    -v /data/docker/apps/vm-baybysitter/private/<name-of-your-private-ssh-key>:/private/hostname.key:ro
```

Note that instead of a folder, the private key file is bind mounted read-only, at a container path and name as of env var `SSH_OPTIONS` default value indicates.
In addition, the private key must be owned by 'root' (user & group) and has Unix permissions '0600'

### Persistent logs:

Finally, to have persistent logs of what is happening with VM-Babysitter and all scheduled tasks, create a mount point like this:

```
    -v /data/docker/apps/vm-babysitter/logs:/logs
```

## Deploying and Running:

Simplest example, with most options set to defaults:

```
    docker run -d --rm --network host --name docker.staffwerke.de/vm-babysitter:latest \
    -e BACKUP_SCHEDULE="* 2 * * *" \
    -e TZ="Europe/Berlin" \
    -e VM_AUTOSTART_LIST="domain1 domain2 domain3"
    -v /etc/libvirt/qemu/nvram:/etc/libvirt/qemu/nvram \
    -v /data/docker/apps/vm-babysitter/logs:/logs \
    -v /data/domains:/data/domains \
    -v /data/vm-backups:/backups \
    -v /run/libvirt:/run/libvirt\
    -v /run/lock:/run/lock \
    -v /usr/share/OVMF:/usr/share/OVMF:ro \
    -v /var/tmp:/var/tmp \
    --restart=unless-stopped
    vm-babysitter
```

A more complex example, involving compression of backups, a mirror at local network, and applying specific rentention policies at each endpoint)
```
    docker run -d --rm --network host --device /dev/fuse --cap-add SYS_ADMIN --name docker.staffwerke.de/vm-babysitter:latest \
    -e BACKUP_SCHEDULE="* */12 * * *" \
    -e LOCAL_BACKUP_CHAINS_TO_KEEP="2" \
    -e MAX_BACKUPS_PER_CHAIN="60"
    -e RSYNC_ARGS="-aP --bwlimit=1179648" \
    -e RSYNC_BACKUP_PATH="root@192.168.0.2:/data/vm-backups-mirror" \
    -e RSYNC_BACKUP_CHAINS_TO_KEEP="4" \
    -e TZ="Europe/Berlin" \
    -e VIRTNBDBACKUP_ARGS="--compressed"
    -e VM_AUTOSTART_LIST="domain1 domain2"
    -e VM_IGNORED_LIST="domain3"
    -v /etc/libvirt/qemu/nvram:/etc/libvirt/qemu/nvram \
    -v /data/docker/apps/vm-babysitter/logs:/logs \
    -v /data/docker/apps/vm-baybysitter/private/your-ssh-key.key:/private/hostname.key:ro \
    -v /data/domains:/data/domains \
    -v /data/vm-backups:/backups \
    -v /run/libvirt:/run/libvirt\
    -v /run/lock:/run/lock \
    -v /usr/share/OVMF:/usr/share/OVMF:ro \
    -v /var/tmp:/var/tmp \
    --restart=unless-stopped
    vm-babysitter
```

## Backups Rotation and Retention Policy:

Backup rotation is managed via env var `MAX_BACKUPS_PER_CHAIN` and has effect on both the local backup and the mirror if set.

Everytime virtnbdbackup runs, a new checkpoint is added to the backup chain. This variable allows to set an upper limit so the backup chain can archived and replaced by a new one. It can be set according to your actual needs, and how often is the backup schedule (the more the often, the more checkpoints should be allowed.)

Retention policy is managed by env vars `LOCAL_BACKUP_CHAINS_TO_KEEP` for backups archived locally and `RSYNC_BACKUP_CHAINS_TO_KEEP` for their mirror counterparts, when set.

Everytime a backup chain is rotated, it's saved renaming the folder with a very specific timestamp corresponding to the oldest modified file into the backup sub-folder. The number of archived backup chains per domain will be kept up to the value set on these variables, deleting the oldest ones.

Then, a mirror can contain (ideally) more archived backups than the local pool.

Both rotation and retention policy are automatically checked (and executed, if applies) at 2 moments:

- At container start, if a backup chain has inconsistencies and cannot be fixed (forcing thus rotation despite the number of checkpoints)
- At each backup schedule, checking if has reached the limit imposed by `MAX_BACKUPS_PER_CHAIN`

*Special case:*
When a backup chain creation of a domain is interrupted (crash or container stop), the failed backup is deleted locally on next container's start instead of being rotated. If a mirror is set and any backup chain of that domain is found, is rotated, but no retention policy is applied on the mirror.

*Saving historical/important backups permanently within Backups Path(s):*
As alternative to move them outside of the path(s) set in `<LOCAL-RSYNC>_BACKUP_PATH` you can append some custom tag after the current folder name. VM-Babysitter processes only EXACT matches of the name syntax `<sensitive-case-name-of-domain>+<yyyy-mm-dd.hh:mm:ss...>` and therefore other naming structure won't be taken in count for rotation or retention policy.

## Restoring from Backups:

Eventually, any user will be in need to restore domain from backups, or even to restore a previously deleted domain from backups. The simplest way to perform this task it's via a built-in script called [vm-restore](scripts/vm-restore).

Assuming the container is up and running, open a shell invoke the script with the following command:

```
    docker exec -it vm-babysitter vm-restore
```

Select a specific backup and checkpoint inside, then select an existing domain (or creating a new one, depending the case) and finally select if restore all image disks or a specific one. Then authorize it to proceed and restoration will be performed automatically. If the domain already exists it must be shut down before to proceed (and vm-restore can do this automatically, prior authorization.)

At this moment, only can restore from backups stored locally. Use `--help` option for more details about its usage.

There might be, however, scenarios where vm-restore is not suitable for, e.g. a very custom restoration. Under that cases, please refer to [Virtnbdrestore](https://github.com/abbbi/virtnbdbackup/tree/master?tab=readme-ov-file#restore-examples) main help, which it's the backend tool used by vm-restore.

## Additional tools:

A few tools are provided within the docker image. In order to run, you should start the container first, and then access the internal shell with:

```
    docker exec -it <container-name> /bin/bash
```

### vm-replicate

Replicates a given virtual machine onto a local or remote endpoint.

It is very similar in functioning with qemu's 'virt-clone' utility, except by the fact it can also replicate virtual machines onto remote hosts running libvirt without the need of a GUI.

Is also able to detect and optionally apply the same modification made by [vm-patch](#vm-patch) directly on the VM to be created (not modifying the source VM if does not have the patch.)

Resulting VMs are 'clones' of the source VM in most of features, excepting by:

- Virtual machine's UUID
- MAC address(es)
- Persistent Nvram files (whenever found)
- Disk image paths, in most of scenarios

Disk image provisioning is an optional step, and the user still can set custom paths for future images them in new VM definitions. When cloned with this script, all disk images are thin provisioned.

For remote replication, it makes use of SSH for execute remote commands, SCP for small file transfers and SSHFS to mount remote folders (thus allowing direct disk image(s) replication onto the remote endpoint)

**To correctly replicate disk images remotely, docker parameters `--device /dev/fuse` and `--cap-add SYS_ADMIN` must be added to the command line**

As of current state of development, script is interactive, not accepting arguments. Syntax is:

```
    vm-replicate
```

## Known Issues/bugs:

- Stopping or killing the container while virtnbdbackup is performing a backup operation may lead to persistent failed status during next runs. It is presumed that dead sockets in `/var/tmp`, `/run/libvirt` and `/run/lock` keep last QEMU image(s) being processed, locked after the crash, therefore unable to be accessed by virtnbdbackup. Deleting such dead sockets (or waiting a few hours) has been proved to be helpful, but the best practice is **DO NOT STOP the container while is performing backup tasks!**

## TO DO:

- Merge with latest Virnbdbackup features (automatic backup mode, remote replication, remote restoration, backup checks, etc)
- vm-replicate: Add modify RAM menu, detach removable units, add menu to keep mac address or set custom one
- Add/Remove VMs on the fly
- Detect and alert when space in LOCAL_BACKUP_PATH and RSYNC_BACKUP_PATH is low

#### Author: Adrián Parilli <adrian.parilli@staffwerke.de>
