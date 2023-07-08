# VM-Babysitter

Checks existing Virtual machines running on the local server, and performs the following actions:

- Creates a list of (persistent) VMs registered in QEMU to be backed up regularly
- Sets and internal cron task for scheduled backups
- Verifies/applies QEMU patch for incremental backups
- Checks backup chain consistency for each VM, being able to detect some issues and solve them
- Creates new full backup chains when necessary
- Updates the backup chain regularly, via internal cron task
- Rebuilds/recovers backup chains automaticaly from many disaster scenarios, including a server crash
- When backup chain gets broken, it can archive it for further restoration, or deletes it when becomes unusable
- Syncs successful backup operations and is able to archive remote backup chain mirrors independently of local ones
- Sends important notifications (backup start/end) and alerts to Unraid's notification system, when detected.

## Building an up-to-date docker image:

- Clone/download/pull this repository
- Get into the main folder
- Build the image: `docker build . -t docker.staffwerke.de/vm-babysitter:<tag>`
- Push the image: `docker image push docker.staffwerke.de/vm-babysitter:<tag>`

## Environment variables:

VM-Babysitter is entirely controlled via ENV variables, passed on runtime:

| **Variable Name** | **Description** | **Default Value** |
| --- | --- | --- |
|`BACKUP_SCHEDULE`|Cron-like string for incremental backups (e.g. `* 2 * * *` triggers everyday at 2 am local time)|`@daily`|
|`LOCAL_BACKUP_CHAINS_TO_KEEP`|How many old backup chains to keep archived locally under `LOCAL_BACKUP_PATH`. `0` disable backups archiving (default is no limit)||
|`LOCAL_BACKUP_PATH`|Container path where vm-babysitter will search for, and save backup chains of all VMs. The container will fail if does not exist, or r/w permission issues are found|`/backups`|
|`LOGROTATE_CONFIG_PATH`|Container path to place and read log rotation config|`/tmp/logrotate.d/vm-babysitter`|
|`LOGROTATE_SCHEDULE`|Same functioning as `BACKUP_SCHEDULE` but for trigger log rotation (ideally, both variables should run on different schedules)|`@daily`|
|`LOGROTATE_SETTINGS`|Parsed string with *escaped* logrotate config, written in `LOGROTATE_CONFIG_PATH` on startup|`compress\ncopytruncate\ndateext\ndateformat -%Y%m%d-%s\nmissingok\nrotate 30`|
|`LOGFILE_PATH`|Container path for the main log file|`/logs/vm-babysitter.log`|
|`RSYNC_ARGS`|Extra arguments for rsync when sends successful backups to `RSYNC_BACKUP_PATH`, e.g. `-aP --bwlimit=1179648`|`-a`|
|`RSYNC_BACKUP_CHAINS_TO_KEEP`|Same functioning as `LOCAL_BACKUP_CHAINS_TO_KEEP` (default is no limit)||
|`RSYNC_BACKUP_PATH`|SSH syntax of remote absolute path, e.g. `user@host:/absolute/path/to/folder` to rsync successful backup chain tasks (requires r/w permissions)||
|`SSH_OPTIONS`|SSH options for communications with involved hosts, including rsync, and Unraid notifications to localhost|`-q -o IdentityFile=/private/hostname.key -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10`|
|`TZ`|Local timezone. Most likely the same on the server running docker (default is container's time)||
|`VIRTNBDBACKUP_ARGS`|Extra arguments passed to virtnbdbackup, in both full and inc backup, e.g. `--compress`||
|`VM_ALLOW_POWERCYCLE`|When enabled performs a controlled powercycle of VMs, checking incremental backup patch and backup chains as needed. (Default is disabled)||
|`VM_AUTOSTART_LIST`|Case Sensitive space separated list of VMs that will be started along with the container||
|`VM_IGNORED_LIST`|Case Sensitive space separated list of VMs to ignore, so won't be checked or backed up||
|`VM_RAM_LIMIT`|How much RAM to assign temporarily to a shut down VM to perform backup tasks. Accepts multipliers such as k,K,m,M,g,G and similar, e.g. `1048576K`, `2048m`, `4G`, etc. Otherwise assumes Bytes (default is not to touch RAM values)||
|`VM_WAIT_TIME`|Maximum time in seconds to await for VMs to confirm it has reached on/off states in certain scenarios|`60`|

## Mount points:

VM-Babysitter relies entirely on correct mounts to find, manage and save all files related with Virtual machines.

### Backups folder:

The folder where all local backups will be checked and saved is mounted as in this example:

```
    - v /mnt/user/backups/vm-backups:/backups
```

### Disk images:

The service needs full access to ALL VM's disk images to be backed up, from inside the container. There is no canonical rule about this, but the point is to mount the folder that contains all disk images of VMs inside, or add different mounts if disk images are spread in different (and unrelated) places.

If, for example all disk images are located in '/mnt/user/VMs', a mountpoint should be:

```
    -v /mnt/user/vms:/mnt/user/vms
```

Replicating host path exacty inside the container. More mounts can be added as needed. As these paths will be searched via libvirt API during execution, if any disk image isn't found or r/w issues are detected, the container will fail.

### System, libvirt, and virtnbdbackup sockets:

VM-Babysitter uses self provisioned tools for all operations, however it needs access to sockets on the host where it's running (specially for libvirt's API) or it won't be able to work at all. Therefore, the followng mountpoints are needed:

Required for Virtnbdbackup (all operating systems):

```
    -v /var/tmp:/var/tmp
```

Required to access host libvirt's socket:

- On most operating systems (Debian, RedHat, Archlinux and its derivatives):

```
    -v /run/libvirt:/run/libvirt
    -v /run/lock:/run/lock
```

- On Unraid:
```
    -v var/run/libvirt:/run/libvirt
    -v /var/run/lock:/run/lock
```

### Nvram bind mounts:

When VMs boot via OVMF, recent versions of virtnbdbackup, virtnbdrestore, [vm-replicate](#vm-replicate) and [vm-restore](#vm-restore) scripts in general, need access to nvram binaries and templates, otherwise may throw warnings during execution.

For mounting VM specific nvram files, add:
```
    -v /etc/libvirt/qemu/nvram:/etc/libvirt/qemu/nvram
```

Recent versions of Virtnbdbackup will also may fail when not finding global OVMF binary templates. The path varies between Libvirt implementations. The only tested case is for Unraid:
```
    -v /usr/share/qemu/ovmf-x64:/usr/share/qemu/ovmf-x64
```

### SSH key and Logs info:

The *best* way to communicate with remote hosts (including anfitrion, when needed) is via SSH RSA key pairs, and VM-babysitter is intended to work in this way.

Assuming you have, or can create a pair of RSA keys (3072 bits or above is recommended) you can install the public key onto the remote hosts (as the user you want to connect); and make the private key available for VM-Babysitter into a specific folder, just like this:

```
    -v /mnt/user/docker/apps/vm-baybysitter/private/<name-of-your-private-ssh-key>:/private/hostname.key
```
And add this environmental setting:
```
    -e SSH_OPTIONS="-o IdentiyFile=/private/hostname.key -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10"
```

Setting the real name of the key on your side, and allowing transparent -and mostly silent- communication between hosts.
*Note, remember to assign 'root' user & group ownership and Unix permissions '600'*

### Persistent logs:

Finally, to have persistent logs of what is happening with VM-Babysitter and scheduled backups, create a mountpoint like this:

```
    -v /mnt/user/docker/apps/vm-babysitter/logs:/logs
```

## Using the service:

### Notes about Unraid:

- For easier management, import the provisioned [XML template](unraid-template/vm-babysitter.xml) to your `~/.docker/templates-user`

- To see Unraid notifications: 1) edit docker options and switch to advanced view, setting Network type to 'host' 2) Add the pulic SSH key counterpart you're using for remote backups into your local authorized_keys file (normally located at ~/.ssh/ folder)

- **Disable VM autostart of the hosts you want to babysit**: Due the Unraid's quirky QEMU implementation, when a server is restarted, local checkpoints are lost. While VM-Babysitter can deal with this (thanks to Virtnbdbackup's resilience restoring lost checkpoints) it will refuse to check backups of VMs if these are running. Add the VMs you want to start automatically to `VM_AUTOSTART_LIST` option.

### Generic example of full docker command for local backups:

```
    docker run -d --rm --network host --name docker.staffwerke.de/vm-babysitter:latest \
    -e BACKUP_SCHEDULE="* 2 * * *" \
    -e LOCAL_BACKUP_CHAINS_TO_KEEP="2" \
    -e VM_RAM_LIMIT="4096M" \
    -e VM_ALLOW_POWERCYCLE="yes" \
    -e TZ="Europe/Berlin" \
    -e VIRTNBDBACKUP_ARGS="--compress" \
    -v /etc/libvirt/qemu/nvram:/etc/libvirt/qemu/nvram \
    -v /mnt/user/backups/vm-backups:/backups \
    -v /mnt/user/docker/apps/vm-baybysitter/private:/private \
    -v /mnt/user/docker/apps/vm-babysitter/logs:/logs \
    -v /mnt/user/vms:/mnt/user/vms \
    -v /run/libvirt:/run/libvirt\
    -v /run/lock:/run/lock \
    -v /usr/share/qemu/ovmf-x64:/usr/share/qemu/ovmf-x64 \
    -v /var/tmp:/var/tmp \
    <container_name>
```

Scheduling all found VMs for (compressed) incremental backups on local endpoint every day at 2 am (Berlin time) and will save up to 2 backup chains per VM in case one needs to be rebuilt, throttling RAM's VMs to 4096 MiB when its original setting is above this value.

### Generic example of full docker command for local and remote backups:

```
    docker run -d --rm --network host --device /dev/fuse --cap-add SYS_ADMIN --name docker.staffwerke.de/vm-babysitter:latest \
    -e LOCAL_BACKUP_PATH="/mnt/user/Backups/vm-backups" \
    -e BACKUP_SCHEDULE="* */12 * * *" \
    -e LOCAL_BACKUP_CHAINS_TO_KEEP="0" \
    -e VM_RAM_LIMIT="8G" \
    -e RSYNC_BACKUP_PATH="root@10.0.0.2:/mnt/user/vm-backups-mirrors" \
    -e RSYNC_BACKUP_CHAINS_TO_KEEP="3" \
    -e VM_ALLOW_POWERCYCLE="yes" \
    -e RSYNC_ARGS="-aP --bwlimit=1179648" \
    -e SSH_OPTIONS="-q -o IdentiyFile=/private/hostname.key -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10" \
    -e TZ="Europe/Berlin" \
    -e VIRTNBDBACKUP_ARGS="--compress" \
    -v /etc/libvirt/qemu/nvram:/etc/libvirt/qemu/nvram \
    -v /mnt/user/backups/vm-backups:/mnt/user/backups/vm-backups \
    -v /mnt/user/docker/apps/vm-baybysitter/private:/private \
    -v /mnt/user/docker/apps/vm-babysitter/logs:/logs \
    -v /mnt/user/vms:/mnt/user/vms \
    -v /run/libvirt:/run/libvirt\
    -v /run/lock:/run/lock \
    -v /usr/share/qemu/ovmf-x64:/usr/share/qemu/ovmf-x64 \
    -v /var/tmp:/var/tmp \
    <container_name>
```

Scheduling all found VMs for (compressed) incremental backups on both local and remote endpoint (at a max of 1179648 Kbps or 1 Gbps) every 12 hours (Berlin time) and will save up to 3 backup chains per VM remotely, in case one needs to be rebuilt but not saving any backup chain on local endpoint at all; throttling RAM's VMs to 8 GiB when its original setting is above this value.

## Additional tools:

A few tools are provided within the docker image. In order to run, you should start the container first, and then access the internal shell with:

```
    docker exec -it <container-name> /bin/bash
```

### vm-patch

Applies custom changes (a.k.a.) 'patches' onto a given VM definitions, so virtnbdbackup can work. Syntax is:

```
    vm-patch <vm-name>
```

Working the same on both running and stopped VMs, notifying the user if a restart is required (doesn't have effect on already patched VMs.)

Usually, is only needed once per VM, but it has been noticed that UnRaid GUI (at least effective at v6.9.2) deletes all custom settings while updated from the 'Form View.' So it can be applied **after** any changes performed onto VM Settings at UnRaid.

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

For remote replication, it makes use of SSH for execute remote commnds, SCP for small file transfers and SSHFS to mount remote folders (thus allowing direct disk image(s) replication onto the remote endpoint)

**To correctly replicate disk images remotely, docker parameters `--device /dev/fuse` and `--cap-add SYS_ADMIN` must be added to the command line**

As of current state of development, script is interactive, not accepting arguments. Syntax is:

```
    vm-replicate
```

### vm-restore

Restores disk image(s) of a virtual machine from saved backups (made with vm-full-backup, vm-inc-backup or virtnbdbackup-auto) up to a selected checkpoint in time.

Currently works as a 'better' replacement for vm-restore, since does not need arguments to run (it asks all the question questions on screen to source itself with parameters) and is capable of restore a VM automatically,  as much this VM is already defined into the libvirt's host. It also cleans libvirt of past checkpoints, allowing to delete it later if becomes necessary.

More detailed info is available at the same script, by running it with `vm-restore` (press Ctrl+C to cancel the script's run after having read the help)

## Known Issues/bugs:

-  [vm-restore](#vm-restore) hasn't been tested enough to work inside container (work in progress)

- Stopping or killing the container while virtnbdbackup is performing a backup operation may lead to persistent failed status during next runs. It is presumed that dead sockets in `/var/tmp`, `/run/libvirt` and `/run/lock` keep last QEMU image(s) being processed, locked after the crash, therefore unable to be accessed by virtnbdbackup. Deleting such dead sockets (or waiting a few hours) has been proved to be helpful, but the best practice is **DO NOT STOP the container while is performing backup tasks!**

## TO DO:

- Merge with latest Virnbdbackup features (automatic backup mode, remote replication, remote restoration, backup checks, etc)
- vm-replicate: Add modify RAM menu, detach removable units, add menu to keep mac address or set custom one
- Add/Remove VMs on the fly
- Archive backup chain when its total size is too big for certain criteria
- Detect and alert when space in LOCAL_BACKUP_PATH and RSYNC_BACKUP_PATH is low

#### Author: Adrián Parilli <a.parilli@staffwerke.de>
