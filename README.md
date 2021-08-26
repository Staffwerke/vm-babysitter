# virtnbdbackup-docker-scripts

Scripts to automatize tasks through [virtnbdbackup-docker](https://github.com/adrianparilli/virtnbdbackup-docker), such as create backup chains, incremental backups on them, and restore backups into qcow2 disk images.

`virtnbdbackup-docker` is invoked via `'docker run --rm ...'` with user arguments (plus other internal ones,) performing actions and notifying about success or fail at the end, exiting with the correspondent status (0 or 1, respectively.)

Incremental backups can be done in unattended way, per VM or as a batch process.

Batch script is compatible with [UnRaid's User Scripts plugin.](https://forums.unraid.net/topic/48286-plugin-ca-user-scripts/)

## vm-patch

Applies custom changes (a.k.a.) 'patches' onto a given VM definitions, so virtnbdbackup can work. Syntax is:

`vm-patch <vm-name>`

Working the same on both running and stopped VMs, notifying the user if a restart is required (doesn't have effect on already patched VMs.)

Usually, is only needed once per VM, but it has been noticed that UnRaid GUI deletes all custom settings while updated from the 'Form View.' So it can be applied **after** any changes performed onto VM Settings at UnRaid.

## vm-full-backup

Creates a new full backup chain of the given VM, as a subfolder with under the given path. Syntax is:

`vm-full-backup <vm-name> /main-path-to-backups`

Besides of simple checks (VM must exist and running) it scans for a path of the type `/main-path-to-backups/vm-name` and will prompt the user for deletion if finds it and there are files inside (it won't ask if full path exists and is empty.) This action is required since virtnbdbackup won't work on non-empty folders, failing and then leaving more logs into that folder. For instance, the user should check (or be conscious) its content when this occurs before to answer yes. If answers 'yes', the folder with same `vm-name` plus content inside will be deleted, and re-created again.

## vm-inc-backup

Adds an incremental backup to an existing backup chain at a subfolder under the given path. Syntax is:

`vm-inc-backup <vm-name> /main-path-to-backups`

This would be a recurrent operation performed after `vm-full-backup` has created a backup chain for such VM. In the same way as `vm-full-backup`, it will notify about success or fail after create an incremental backup, exiting with corresponent state (0 or 1, respectively.)

It's able to run unattended (e.g. with cron), if the intention is to backup one VM at time.

## virtnbdbackup-auto

It makes use of `vm-inc-backup` to run incremental backups of one, or more VMs as a batch operation, logging to STDOUT which VMs were successfuly backed up or failed; exiting with corresponding state (0 if all jobs were successful, 1 if at least one of the jobs failed.)

Unlike other scripts, does not have syntax. You must modify internal settings by following the instructions [inside the script.](virtnbdbackup-auto/script)

It is the ultimate solution to keep several backup chains updated at the same time, unattendedly over long periods via cron

Is compatible with UnRaid's User Scripts plugin. Install instructon are detailed [here.](https://forums.unraid.net/topic/48286-plugin-ca-user-scripts/)


## vm-restore

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


### Notes about reusing VMs with resotred disks

In a given scenario where a disk image (e.g. damaged or lost) has to be replaced from backups, re-using the VM with this generated disk image by rename it as the old one *is not enough* if you intend to a new backup chain. If you would attempt to save a full backup now, will end with errors of this kind:

`ERROR libvirthelper - removeAllCheckpoints: internal error: bitmap 'virtnbdbackup.0' not found in backing chain of 'hdc'`
`ERROR virtnbdbackup - main: operation failed: domain moment virtnbdbackup.0 already exists`

Because restored image(s) has no checkpoints inside, but libvirt still holds those belonging to the old image at `/var/lib/libvirt/qemu/checkpoint/<vm-naame>`.

To overcome this issue, open a shell and execute:

`virsh checkpoint-delete <vm-name> virtnbdbackup.0 --children --metadata`

Deleting thus all checkpoints created by libvirt on the server only, not attemtping to delete it from the new disk image.

(*Important:* Attempting the above command without `--metadata` flag, usually results into an immediate VM crash if is it running.)

### Orphaned Images:

After the actions mentioned above, the old disk image (if still exists and is bootable/mountable) is unable to be re-used on the old backup chain, since it will have checkpoints inside the image, but not on the server (opposed to the above scenario and similar as described [here.)](https://github.com/abbbi/virtnbdbackup/blob/0.22/README.md#transient-virtual-machines-checkpoint-persistency).

If you need to create new backups of this old image, you need to rebuild the disk image first with:

`qemu-img convert -O qcow2 <old-vm-image> <new-vm-image>`

in order to delete checkpoints internally and create a backup chain (or repurpose it with checkpoints with another application.)


## Quick restoration a failed VM's disk image on UnRaid

1. Disable `virtnbdbackup-auto` cron scheduling

2. Run `vm-restore /mnt/user/Backups/<vm-name> /mnt/user/VM/<vm-name> [checkpoint_number]` and await for termination.

3. If the failing VM is still running, stop it.

4. On destination path, normally you will have two files:

   `vmdisk1.img`: The old disk image. Rename this file as `'vmdisk1.img.bak'` or move it to another folder.

   `hdc`: The restored disk image. Rename it as `'vmdisk1.img'`

5. Run `virsh checkpoint-list <vm-name>` and verify all libvirt checkpoints are called `virtnbdbackup.*` in a sequence

6. Run `virsh checkpoint-delete <vm-name> virtnbdbackup.0 --children --metadata` (be aware of the consequences mentioned in previous section)

7. Repeat step 5 and verify no checkpoints are present.

8. Start the VM. Verify it started and everything is correct (E.g. ensure services are up and running, run chkdsk, etc.)

9. Go back to `/mnt/user/Backups` and rename the old backup chain folder corresponding with the VM as `<vm-name>.bak`

10. Run `vm-full-backup <vm-name> /mnt/user/Backups/<vm-name>` and await for its termination

11. You can re-enable `virtnbdbackup-auto` cron scheduling to keep making incremental backups automatically.

12. Only when you're sure restoration was good, a new backup chain was made and incremental backups are running, you can safely delete the old images and backups.
