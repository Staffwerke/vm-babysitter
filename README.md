# virtnbdbackup-docker-scripts

Scripts to automatize tasks through [virtnbdbackup-docker](https://github.com/adrianparilli/virtnbdbackup-docker), such as create backup chains, incremental backups on them, and restore backups into qcow2 disk images.

`virtnbdbackup-docker` is invoked via `'docker run --rm ...'` with user arguments (plus other internal ones,) performing actions and notifying about success or fail at the end, exiting with the correspondent status (0 or 1, respectively.)

Incremental backups can be done in unattended way, per VM or as a batch process.

Batch script is compatible with [UnRaid's User Scripts plugin.](https://forums.unraid.net/topic/48286-plugin-ca-user-scripts/)


## Install/Re-install:

- Run `install.sh` as root or with sudo. After confirming the action, installs / re-installs a subset of tools onto the system, depending on the detected OS.

- Set a cron task


### UnRaid:

When UnRaid is detected, installs `vm-patch`, `vm-inc-backup` and `virtnbdbackup-auto` at `/boot/config/plugins/user.scripts/scripts/virtnbdbackup-auto`

`vm-full-backup`, `vm-restore` and `virtnbdrestore-auto` aren't installed at the above path. You must run them manually, such as from this this same repo, once cloned onto the host at a persistent location.

If a re-install is detected and a configured scheme already exists, the installer will attempt to retrieve all user parameters, and transfer it to the new version of `virtnbdbackup-auto`.


### All other Linux Operating Systems:

Installs `vm-patch` , `vm-full-backup` , `vm-inc-backup` and `vm-restore` at `/usr/local/bin`

`virtnbdbackup-auto` isn't installed at this time. You must configure and run a copy of this script from a chosen location.

Reinstallation updates the scripts already installed at `/usr/local/bin` but doesn't have ways to update update user parameters at copies of `virtnbdbackup-auto`


## Uninstall:

There's no uninstaller at this time, however, the process si quite simple in all cases:

### UnRaid:

- From User Script's panel, simply delete the scipt.

Alternatively you can uninstall it from Shell with: `rm -rf /boot/config/plugins/user.scripts/scripts/virtnbdbackup-auto`

### All other Linux Operating Systems:

- Via Shell, as root: `rm /usr/local/bin/{vm-patch,vm-full-backup,vm-inc-backup,vm-restore}`

- Delete any cron task pointing to your custom copy of `virtnbdbackup-auto`

## Tools Documentation:

### vm-patch

Applies custom changes (a.k.a.) 'patches' onto a given VM definitions, so virtnbdbackup can work. Syntax is:

`vm-patch <vm-name>`

Working the same on both running and stopped VMs, notifying the user if a restart is required (doesn't have effect on already patched VMs.)

Usually, is only needed once per VM, but it has been noticed that UnRaid GUI deletes all custom settings while updated from the 'Form View.' So it can be applied **after** any changes performed onto VM Settings at UnRaid.


### vm-full-backup

Creates a new full backup chain of the given VM, as a subfolder with under the given path. Syntax is:

`vm-full-backup <vm-name> /main-path-to-backups`

Besides of simple checks (VM must exist and running) it scans for a path of the type `/main-path-to-backups/vm-name` and will prompt the user for deletion if finds it and there are files inside (it won't ask if full path exists and is empty.) This action is required since virtnbdbackup won't work on non-empty folders, failing and then leaving more logs into that folder. For instance, the user should check (or be conscious) its content when this occurs before to answer yes. If answers 'yes', the folder with same `vm-name` plus content inside will be deleted, and re-created again.


### vm-inc-backup

Adds an incremental backup to an existing backup chain at a subfolder under the given path. Syntax is:

`vm-inc-backup <vm-name> /main-path-to-backups`

This would be a recurrent operation performed after `vm-full-backup` has created a backup chain for such VM. In the same way as `vm-full-backup`, it will notify about success or fail after create an incremental backup, exiting with corresponent state (0 or 1, respectively.)

It's able to run unattended (e.g. with cron), if the intention is to backup one VM at time.


### vm-restore

(NOTE: This script is obsolete now and in process of rebuilding. For full VM restoration, check [virtnbdrestore-auto](#virtnbdrestore-auto) instead)

Fully restores VM's disk image(s) from a given backup path, onto a given restoration path. Syntax is:

`vm-restore /main-path-to-backups/<vm-name> /restoration-path [checkpoint_number]`

Where:

- First argument is the *full path* to the folder previously created with `vm-full-backup`

- Second argument is the *full path* where you want to restore such VM's disk image(s)

- Third argument is an *optional integer* representing a checkpoint by number. If no argument is passed, all incremental backups will be restored until the last one.

  Checkpoints are the XML files located at `/main-path-to-backups/vm-name/checkpoints` and:

  `'virtnbdbackup.0'` represents the *first* backup (made with `vm-full-backup`)

  `'virtnbdbackup.[1..n]'` represent *incremental* backups made with `vm-inc-backup`

  The optional parameter is that integer number, only.

  This makes possible restore disk image(s) at a specific moment of the past, exactly at the moment when certain backup was made. However, *no checkpoint info is present on restored image disk(s).*

Unlike the other scripts, `vm-restore` is unaware of VM state, since it restores data onto new disk image(s) at the given location, with names like `'vda'`, `'sda'`, `'hdc'` and so on. It doesn't manage or alter VMs in any way. Restorations can be made for different purposes, such as recover a disk state at a given moment, or for migration purposes.

### vm-replicate

Replicates a given virtual machine onto a local or remote endpoint.

It is very similar in functioning with qemu's 'virt-clone' utility, except by the fact it can also replicate virtual machines onto remote hosts running libvirt without the need of a GUI.

Is also able to detect and optionally apply the same modification made by [vm-patch](### vm-patch) directly on the VM to be created (not modifying the source VM if does not have the patch.)

Resulting VMs are 'clones' of the source VM in most of features, exceptin by:

- Virtual machine's UUID
- MAC address(es)
- Disk image paths, in most of scenarios.

Disk image provisioning is an optional step, and the user still can set custom paths for future images them in new VM definitions. When cloned with this script, all disk images are thin provisioned.

For remote replication, it makes use of SSH (remote commnds), SCP (small file transfers) and SSHFS to clone disk images through qemu-img, building then directly onto the remote endpoint.

### virtnbdbackup-auto

It makes use of `vm-inc-backup` and `vm-patch` to run incremental backups of one, or more VMs as a batch operation, logging to STDOUT which VMs were successfuly backed up or failed; exiting with corresponding state (0 if all jobs were successful, 1 if at least one of the jobs failed.)

Unlike other scripts, does not have syntax. You must modify internal settings by following the instructions [inside the script.](virtnbdbackup-auto/script)

It is the ultimate solution to keep several backup chains updated at the same time, unattendedly over long periods via cron

Is compatible with UnRaid's User Scripts plugin. Install instructions are detailed [here.](https://forums.unraid.net/topic/48286-plugin-ca-user-scripts/)

### virtnbdrestore-auto

Restores disk image(s) of a virtual machine from saved backups (made with vm-full-backup, vm-inc-backup or virtnbdbackup-auto) up to a selected checkpoint in time.

Currently works as a 'better' replacement for vm-restore, since does not need arguments to run (it asks all the question questions on screen to source itself with parameters) and is capable of restore a VM automatically,  as much this VM is already defined into the libvirt's host. It also cleans libvirt of past checkpoints, allowing to delete it later if becomes necessary.

More detailed info is available at the same script, by running it with `virtnbdrestore-auto` (press Ctrl+C to cancel the script's run after having read the help)

#### Author: Adrián Parilli <a.parilli@staffwerke.de>
