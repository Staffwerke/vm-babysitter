# Additional Notes:

This information that has become off-topic due the implementation of virtnbdrestore-auto, vm-replicate, etc. but still useful for educational purposes and the understanding of how to operate with libvirt's checkpoints in general.

Except when noticed, applies for all Operating Systems:


### Reusing VMs with resotred disks

In a given scenario where a disk image (e.g. damaged or lost) has to be replaced from backups, re-using the VM with this generated disk image by rename it as the old one *is not enough* if you intend to a new backup chain. If you would attempt to save a full backup now, will end with errors of this kind:

`ERROR libvirthelper - removeAllCheckpoints: internal error: bitmap 'virtnbdbackup.0' not found in backing chain of 'hdc'`
`ERROR virtnbdbackup - main: operation failed: domain moment virtnbdbackup.0 already exists`

Because restored image(s) has no checkpoints inside, but libvirt still holds those belonging to the old image at `/var/lib/libvirt/qemu/checkpoint/<vm-naame>`.

To overcome this issue, open a shell and execute:

`virsh checkpoint-delete <vm-name> virtnbdbackup.0 --children --metadata`

Deleting thus all checkpoints created by libvirt on the server only, not attemtping to delete it from the new disk image.

(*Important:* Attempting the above command without `--metadata` flag, usually results into an immediate VM crash if is it running.)


### Orphaned Images / Fixing disk images after server crash:

After the actions mentioned above, the old disk image (if still exists and is bootable/mountable) is unable to be re-used on the old backup chain, since it will have checkpoints references inside the image, but not on the server (opposed to the above scenario and similar as described [here.)](https://github.com/abbbi/virtnbdbackup/blob/0.22/README.md#transient-virtual-machines-checkpoint-persistency).

If you need to create new backups of this old image, you can rebuild the disk image first with:

`qemu-img convert -O qcow2 <old-vm-image> <new-vm-image>`

in order to delete internal checkpoints references and create a backup chain (or repurpose it with checkpoints with another application.)


In addition, this info can be deleted from the disk image by deleting this info (called 'bitmaps'.) This is useful if you have issues after a server (or libvirt) crash and vm-full-backup refuses to create a backup chain.
(Note: you need to *shutdown* the VM in order to do this!)

Locate the disk image with problems and use:

`qemu-img info /path-to-vm-disk-image/vdisk1.img`


It will show you a summary, including a list with bitmaps with identical names of virtnbdbackup.* checkpoints. You must delete it one by one with:

`qemu-img bitmap --remove /path-to-vm-disk-image <virtnbdbackup.n>` (where 'n' is the checkpoint number)

until the 'info' command shows no bitmaps.


### Quick restoration a failed VM's disk image on UnRaid

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


### Recovering an existing backup to another host:

The case is similar to a quick restoration as described above except steps about checkpoints, since these won't exist on the restored disk image or the new host.

As each backup into the chain includes a copy of the VM definitions as of the moment of such action (all under `vmconfig.virtnbdbackup.*.xml` name, at the backup folder) this images can be used to define a new VM (most likely, the more recent one.)

You might need to install this tool on the new host first, then bring some existing backup (such as mounting it via sshfs / nfs if you have it available via network), then do a `vm-restore` in order to grab a copy of the disk image locally.

To define a new VM instance, would be enough with execute on Shell: `virsh define /path/to/backup/vmconfig.virtnbdbackup.<last-N>.xml` and place the restored disk image to wotk with this new VM. This will be the case for most operating systems.

However, *UnRaid* has issues importing VM definitions in this way (even from another UnRaid instance), so defining one of these backups directly won't work, and starting the VM will throw this error:

`operation failed: unable to find any master var store for loader: /usr/share/qemu/ovmf-x64/OVMF_CODE-pure-efi.fd`

A working solution is [here](https://forums.unraid.net/topic/77912-solved-cant-start-vm-after-restore/), but results much more factible to do the following:

- Create a new VM from scratch (setting same parameters as on backed up VM definitions)

- Apply `vm-patch`

- Replace its disk image with one generated from backups as described in the above section (except steps 5 to 7)

- If after re-creating a VM on UnRaid, by chance you get: `Cannot get interface MTU on 'virbr0': No such device`

  apply [this solution](https://forums.unraid.net/topic/93542-execution-error-cannot-get-interface-mtu-on-virbr0-no-such-device/) by executing on the Shell: `virsh net-start default`

And the VM should start correctly.
