#!/bin/bash

: << 'end_of_specs'
#------------------------------------------------------------------------------
# ENV:
#------------------------------------------------------------------------------

Required:
BACKUPS_MAIN_PATH..ok

Optional:
AUTOSTART_VMS_LIST..ok
CRON_SCHEDULE
IGNORED_VMS_LIST..ok
MAX_BACKUP_CHAINS_PER_VM..ok
REMOTE_MAX_BACKUP_CHAINS_PER_VM..ok
VIRTNBDBACKUP_GLOBAL_OPTIONS..ok
RAM_LIMIT_PER_SCHED_BACKUP
REMOTE_BACKUPS_MAIN_PATH..ok
RESTART_VMS_IF_REQUIRED..ok

Advanced options:
MAX_ATTEMPTS
MOMITOR_LOGPATH..ok
RSYNC_ARGS..ok
SCHEDULED_LOGPATH..ok
WAIT_TIME

#------------------------------------------------------------------------------
# TO DO List:
#------------------------------------------------------------------------------
Immediate:
- Input a valid ssh key to communicate with other server(s)
- Check remaining Env variables are correct
- Code orders when REMOTE_BACKUPS_MAIN_PATH and REMOTE_MAX_BACKUP_CHAINS_PER_VM are enabled
- Do proper stop of running processes (e.g. virtnbdbackup) when container is restarted or stopped

Possible improvements:
- Add/Ignore/Remove VMs on the fly
- Archive backup chain when its total size is too big for certain criteria
- Detect and alert when space in BACKUPS_MAIN_PATH and REMOTE_BACKUPS_MAIN_PATH is getting low

#------------------------------------------------------------------------------
end_of_specs

###############################################################################
# Main variables:
###############################################################################

# Temporal crontab file (to be loaded for cron)
crontab_file="/tmp/crontab"

# Storing file for bash like lists shared between this script and the scheduler:
external_vars="/tmp/vm-babysit-vars"

# Main library where common functions and some variables are loaded:
functions_path="functions"

# Log file path for this script:
logpath=${MONITOR_LOGPATH:-"/logs/vm-babysitter.log"}

# Path of the scheduler script (run by cron):
scheduled_backup_script="/usr/local/bin/update_backup_chain"

# Log file path for the scheduler script:
scheuled_logpath=${SCHEDULED_LOGPATH:-"/logs/scheduled-backups.log"}

###############################################################################
# Specific procedures:
###############################################################################

#------------------------------------------------------------------------------
# Attempts to stop the container gracefully in case of receive SIGTERM signal from Docker:
#------------------------------------------------------------------------------
stop_container()
{
    echo "############################################################################################################"
    echo ""
    echo "SIGTERM signal received at: $(date "+%Y-%m-%d %H:%M:%S")"
    # To DO: Terminate or kill background processes before to exit.
    echo "Container Stopped."
    exit 0
}

#------------------------------------------------------------------------------
# Check if VMs in CHECK_PATCH_LIST are patched for incremental backups (and applies it when possible):
#------------------------------------------------------------------------------
check_patch()
{
    # Lists to add VMs (and summarize at the end):
    local domain_shutdown_success
    local domain_shutdown_failed
    local vm_patch_success
    local vm_patch_failed

    echo "___________________________________________________________________________________________________"
    echo ""
    echo "Checking / Patching for incremental backups Virtual machines: ${CHECK_PATCH_LIST[@]}"

    local i=0
    for domain in ${CHECK_PATCH_LIST[@]}; do

        # For each VM, the loop repeats itself as needed until a VM has been successfully patched, or not:
        while true; do

            if [[ -z ${domain_shutdown_failed[$i]} ]] && [[ -z ${vm_patch_failed[$i]} ]]; then

                if [[ $(domain_is_patched $domain ) == yes ]]; then

                    echo "$domain: Patch for incremental backups was found and it is active"
                    vm_patch_success[$i]+=$domain
                    break

                elif [[ $(domain_is_patched $domain --inactive) == yes ]]; then

                    # VM is (presumably) running and was patched before (e.g. in past iteration inside this loop)
                    echo "$domain: Patch for incremental backups was performed, but a power cycle is required to apply changes"

                    if [[ ! -z $RESTART_VMS_IF_REQUIRED ]]; then

                        # When permission is granted, and past iteration over the VM haven't triggered errors, attempts shuts down the VM temporarily:
                        domain_shutdown $domain

                        if [[ $? -eq 0 ]]; then

                            # Adds VM to shutdown success local list:
                            domain_shutdown_success[$i]+=$domain
                        else

                            # Adds VM to failed to shutdown local list
                            # (This VM might shutdown eventually):
                            domain_shutdown_failed[$i]=$domain
                        fi
                    else

                        # Adds VM to failed to shutdown local list
                        # (User must shutdown the VM manually):
                        domain_shutdown_failed[$i]=$domain
                    fi

                    # Restarts the loop (checks VM again under changed conditions):
                    continue

                else

                    echo "$domain: Patch for incremental backups was not found. Attempting to patch now..."

                    vm-patch $domain --quiet

                    # Adds VM to failed to patch local list:
                    [[ $? -ne 0 ]] && vm_patch_failed[$i]=$domain

                    # Restarts the loop (checks VM again under changed condition):
                    continue
                fi
            else

                # Failed either shutting down or applying the patch
                # Nothing else possible to do:
                break
            fi
        done

        # Removes VM from CHECK_PATCH_LIST:
        unset CHECK_PATCH_LIST[$i]

        # Increases the index to check the next VM:
        ((i++))
    done

    # Appends sub-list of (successfully) patched VMs to global CHECK_BACKUPS_LIST:
    CHECK_BACKUPS_LIST+=(${vm_patch_success[@]})
    # Depending on the results, shows a brief summary with VMs with changed state or actions if required:

    # Appends sub-list to the global list of powered OFF VMs:
    POWEREDOFF_VMS_LIST+=(${domain_shutdown_success[@]})

    # Appends sub list of VMs that failed to shutdoen to global SHUTDOWN_REQUIRED_VMS_LIST:
    SHUTDOWN_REQUIRED_VMS_LIST+=(${domain_shutdown_failed[@]})

    # Appends sub list of failed VMs:
    FAILED_VMS_LIST+=(${domain_shutdown_failed[@]})

    echo ""
    echo "VM Patch Summary:"
    echo ""
    echo "Ready for incremental backups: ${vm_patch_success[@]:-"None"}"
    [[ ! -z $RESTART_VMS_IF_REQUIRED ]] && \
    echo "Into automatic power cycle: ${domain_shutdown_success[@]:-"None"}"
    echo "Manual shut down is required: ${domain_shutdown_failed[@]:-"None"}"
    echo "Failed to apply patch: ${vm_patch_failed[@]:-"None"}"

    if [[ -z ${domain_shutdown_failed[@]} ]] && [[ -z ${vm_patch_failed[@]} ]]; then

        echo ""
        echo "All VMs Patched!"
    fi
}

#------------------------------------------------------------------------------
# Checks VMs in CHECK_BACKUPS_LIST for backup chain integrity (and puts VMs at point of create new backup chains, if possible):
#------------------------------------------------------------------------------
check_backups()
{
    # Local variables used for flow control:
    local backup_check_failed
    local bitmaps_list
    local checkpoint_list
    local backup_folder_exists
    local recoverable_backup_chain
    local partial_checkpoint

    # Lists to add VMs (and summarize at the end):
    local broken_backup_chain
    local domain_shutdown_failed
    local domain_shutdown_success
    local preserved_backup_chain

    echo "___________________________________________________________________________________________________"
    echo "Checking backup chain ingtegrity for Virtual machines: ${CHECK_BACKUPS_LIST[@]}"

    local i=0
    for domain in ${CHECK_BACKUPS_LIST[@]}; do

        backup_folder_exists=""
        partial_checkpoint=""
        recoverable_backup_chain=""

        while true; do

            if [[ -z $backup_folder_exists ]]; then

                # Checks once for non existing, corrupted or dummy backup folders:
                if [[ -d $BACKUPS_MAIN_PATH/$domain ]] \
                && [[ -f $BACKUPS_MAIN_PATH/$domain/$domain.cpt ]] \
                && [[ -d $BACKUPS_MAIN_PATH/$domain/checkpoints ]]; then

                    # Backup chain structure seems to be OK. Performs a more comprehensive check:
                    backup_folder_exists="true"
                else

                    # No backup folder, is corrupted or doesn't have backup data:
                    backup_folder_exists="false"
                    echo "$domain: No backup chain folder detected (or backup chain structure is damaged)"
                fi
            fi

            if [[ -z $partial_checkpoint ]] && [[ $backup_folder_exists == true ]]; then

                # Checks once for non cancelled backups::

                if [[ ! -z $(find $BACKUPS_MAIN_PATH/$domain -type f -name "*.partial") ]]; then

                    # Virtnbdbackup was cancelled in the middle of a backup chain task:
                    partial_checkpoint="true"

                    # Gets the list of checkpoints from failed backup chain:
                    local damaged_backup_checkpoint_list=($(backup_checkpoint_list $BACKUPS_MAIN_PATH/$domain))

                    if [[ ${#damaged_backup_checkpoint_list[@]} -gt 1 ]]; then

                        # There is a successful full backup Only the last link in the chain is damaged, so is worth of a recovery attempt:
                        echo "$domain: An incremental backup operation was previously cancelled. It will attempt to fix this backup chain by deleting the last (non recoverable) checkpoint"
                        recoverable_backup_chain="true"
                    else

                        # A full backup chain that was cancelled. Nothing to do but delete it, along with checkpoints and bitmaps:
                        recoverable_backup_chain="false"
                        echo "$domain: A full backup operation was previously cancelled. This backup chain is unrecoverable, therefore will be removed"
                    fi
                else

                    # No cancelled backup operations detected:
                    partial_checkpoint="false"
                fi
            fi

            if [[ $(domain_state $domain) == "shut off" ]]; then

                # Resets control flow variables, if used before:
                checkpoint_list=()
                backup_check_failed=""

                echo "$domain: Is shut down, performing full check into its backup chain..."

                if [[ $recoverable_backup_chain != false ]] || [[ $backup_folder_exists != false ]]; then

                    # Backup chain is worth of being checked:

                    if [[ $RESTARTED_SERVER == true ]] ; then

                        # No QEMU checkpoints are found when server comes from a restart under UnRaid, so uses backup checkpoints in backup
                        echo "$domain: Reading checkpoints list from backup (RESTARTED_SERVER detected)"
                        checkpoint_list=($(backup_checkpoint_list $BACKUPS_MAIN_PATH/$domain))
                    else

                        echo "$domain: Reading checkpoints list from QEMU"
                        checkpoint_list=($(domain_checkpoint_list $domain))
                    fi

                    # Perform a full check of checkpoints vs bitmaps:
                    for image in $(domain_img_paths_list $domain); do

                        bitmaps_list=($(disk_image_bitmap_list $image))
                        if [[ ${bitmaps_list[@]} != ${checkpoint_list[@]} ]]; then

                            # When bitmaps and checkpoint lists aren't identical for ALL disks, marks the entire check as failed:
                            backup_check_failed="yes"

                            echo "$domain's disk $image: Checkpoints and bitmaps lists MISMATCH!"

                            # Cancelling further checks for this VM:
                            break
                        fi
                    done
                fi

                if [[ $backup_check_failed == yes ]] \
                || [[ $recoverable_backup_chain == false ]] \
                || [[ $backup_folder_exists == false ]]; then

                    # Each scenario is exclusive (non recoverable backup chain is implicitly failed):

                    if [[ $RESTARTED_SERVER != true ]]; then

                        echo "$domain: Pruning existing checkpoints in QEMU..."
                        domain_delete_checkpoint_metadata $domain
                    fi

                    for image in $(domain_img_paths_list $domain); do

                        # Then deletes all bitmaps, in all image disks:
                        echo "$domain's disk $image: Deleting bitmaps..."

                        for bitmap in $(disk_image_bitmap_list $image); do

                            disk_image_delete_bitmap $image $bitmap
                        done
                    done

                    # Process old backup chain depending on the case:
                    if [[ $recoverable_backup_chain == false ]] || [[ $backup_folder_exists == false ]]; then

                        # Unrecoverable or unexistent backup chain folder. Delete it:
                        rm -rf $BACKUPS_MAIN_PATH/$domain

                    else
                        # Backup chain is recoverable. Archive it:
                        archive_backup $BACKUPS_MAIN_PATH/$domain
                    fi

                    # Mark backup chain as broken:
                    broken_backup_chain[$i]=$domain

                    # Exits the loop:
                    break

                elif [[ $recoverable_backup_chain == true ]]; then

                    echo "$domain: Attempting backup chain recovery..."
                    # Checkpoints and bitmaps are matching despite the scenario.
                    # Attempts to delete the last checkpoint (even from backup) and bitmap:

                    # Gets the last index in $checkpoint_list:
                    local index=${#checkpoint_list[@]}

                    # Moves the last checkpoint name apart:
                    local damaged_checkpoint=${checkpoint_list[$index]}
                    unset checkpoint_list[$index]

                    # Deletes this checkpoint from and QEMU (if exists), images and backup itself:

                    for image in $(domain_img_paths_list $domain); do

                        disk_image_delete_bitmap $image $damaged_checkpoint
                        echo "$domain's disk $image: Bitmap '$damaged_checkpoint' deleted"
                    done

                    # Deletes QEMU checkpoint when it's supposed to exist:
                    if [[ $RESTARTED_SERVER != true ]] ; then

                        domain_delete_checkpoint_metadata $domain $damaged_checkpoint
                        echo "$domain: Checkpoint '$damaged_checkpoint' metadata removed from QEMU"

                    # Finally, deletes all the files created by the incremental backup (except logs):

                    for drive in $(domain_drives_list); do

                        # Backup incremental data (all drives)
                        rm -f $BACKUPS_MAIN_PATH/$domain/$drive.inc.$damaged_checkpoint.data.partial
                        echo "$domain: Incremental backup $BACKUPS_MAIN_PATH/$domain/$drive.inc.$damaged_checkpoint.data.partial deleted"
                    done

                    # VM definitions XML file:
                    rm -f $BACKUPS_MAIN_PATH/$domain/vmconfig.$damaged_checkpoint.xml
                    echo "$domain: VM definitions XML file $BACKUPS_MAIN_PATH/$domain/vmconfig.$damaged_checkpoint.xml deleted"

                    # Checkpoint in backup:
                    rm -f $BACKUPS_MAIN_PATH/$domain/checkpoints/$damaged_checkpoint.xml
                    echo "$domain: Backup checkpoint $BACKUPS_MAIN_PATH/$domain/checkpoints/$damaged_checkpoint.xml deleted"

                    # Modifying the .cpt file with the new checkpoints list:
                    local new_checkpoint_list="${checkpoint_list[@]}"
                    echo "[\"${new_checkpoint_list// /\", \"}\"\]" > $BACKUPS_MAIN_PATH/$domain/$domain.cpt
                    echo "$domain: Updated checkpoints in $BACKUPS_MAIN_PATH/$domain/$domain.cpt"

                    # Backup chain will be treated as preserved:
                    preserved_backup_chain+=($domain)

                    # Exits the loop:
                    break

                    # To DO: Remote sync after backup repair...
                else

                    preserved_backup_chain+=($domain)
                    echo "$domain: Checkpoints and bitmaps lists MATCH"

                    # Exits the loop:
                    break
                fi

            elif [[ $RESTARTED_SERVER == true ]] || [[ $partial_checkpoint == true ]] || [[ $backup_folder_exists == false ]]; then

                # Even on a non RESTARTED_SERVER scenario, cancelled and non existing / corrupted backups; all demands to shutdown the VM:

                if [[ ! -z $RESTART_VMS_IF_REQUIRED ]]; then

                    # When permission is granted, attempts to shut down the VM temporarily:
                    domain_shutdown $domain

                    if [[ $? -eq 0 ]]; then

                        # Adds VM to shutdown success local list:
                        domain_shutdown_success[$i]=$domain

                        # Restarts the loop (checks backup again under changed condition):
                        continue
                    else

                        # Adds VM to failed to shutdown local list
                        # (This VM might shutdown eventually):
                        domain_shutdown_failed[$i]=$domain

                        # Exits the loop (nothing else can be done):
                        break
                    fi
                else
                    # (User must shutdown the VM manually):
                    echo "$domain: Cannot check backup chain integrity while running"

                    # Adds VM to failed to shutdown local list:
                    domain_shutdown_failed[$i]=$domain

                    # Exits the loop (nothing else can be done):
                    break
                fi

            else

                echo "$domain: VM is (presumably) running, comparing checkpoint lists in both QEMU and backup chain..."

                # Gets both qemu and backup checkpoint lists:
                local qemu_checkpoint_list=($(domain_checkpoint_list $domain))
                local backup_chain_checkpoint_list=($(backup_checkpoint_list $BACKUPS_MAIN_PATH/$domain))


                if [[ ${qemu_checkpoint_list[@]} != ${backup_chain_checkpoint_list[@]} ]]; then

                    # Checkpoint lists in QEMU and backup aren't identical:

                    echo "$domain: QEMU and backup checkpoints lists MISMATCH"

                    # Process old backup and mark backup chain as broken (can't check more in deep for bitmaps / checkpoints to delete:)
                    archive_backup $BACKUPS_MAIN_PATH/$domain
                    broken_backup_chain[$i]=$domain

                    # Exits the loop (nothing else can be done):
                    break

                else

                    echo "$domain: QEMU and Backup Checkpoint lists MATCH"
                    # Backup chain is OK, mark as preserved:
                    preserved_backup_chain+=($domain)

                    # Exits the loop:
                    break
                fi
            fi
        done

        # VM is unlisted from CHECK_BACKUPS_LIST:
         unset CHECK_BACKUPS_LIST[$i]

        # Increases the index to check the next VM:
        ((i++))
    done

    # Send to schedule the VMs which backup integrity is OK
    # (as a string, since sed can't expand arrays correctly):
    SCHEDULED_BACKUPS_LIST+=(${preserved_backup_chain[@]})
    SCHEDULED_BACKUPS_LIST="${SCHEDULED_BACKUPS_LIST[@]}"
    sed -i \
    -e "s/SCHEDULED_BACKUPS_LIST=.*/SCHEDULED_BACKUPS_LIST=($SCHEDULED_BACKUPS_LIST)/" \
    $external_vars

    # Appends sub-list to global list of VMs in need of a new backup chain:
    CREATE_BACKUP_CHAIN_LIST+=(${broken_backup_chain[@]})

    # Appends sub-list to the global list of powered OFF VMs:
    POWEREDOFF_VMS_LIST+=(${domain_shutdown_success[@]})

    # Appends sub-list of failed to shutdown VMs to global list of VMs with issues
    SHUTDOWN_REQUIRED_VMS_LIST+=(${domain_shutdown_failed[@]})


    echo ""
    echo "Backup Chain Integrity Summary:"
    echo ""
    echo "On schedule for incremental backups: ${preserved_backup_chain[@]:-"None"}"
    echo "In need of new backup chain: ${broken_backup_chain[@]:-"None"}"
    [[ ! -z $RESTART_VMS_IF_REQUIRED ]] && \
    echo "Into automatic power cycle: ${domain_shutdown_success[@]:-"None"}"
    echo "Manual shut down is required: ${domain_shutdown_failed[@]:-"None"}"

    if [[ -z ${domain_shutdown_failed[@]} ]]; then

        echo ""
        echo "All Backup Chains Checked!"
    fi
}

#------------------------------------------------------------------------------
# Creates backup chains for VMs in CREATE_BACKUP_CHAIN_LIST, managing temporal RAM limits (when set) and powering on/off as necessary:
#------------------------------------------------------------------------------
create_backup_chain()
{
    # Local variables used for flow control:
    local original_ram_size
    local memlimit_active

    # Lists to add VMs (and summarize at the end):
    local backup_chain_success
    local backup_chain_failed
    local domain_poweron_success
    local domain_poweron_failed

    echo "___________________________________________________________________________________________________"
    echo ""
    echo "Creating new Backup chains for Virtual machines: ${CREATE_BACKUP_CHAIN_LIST[@]}"

    i=0
    for domain in ${CREATE_BACKUP_CHAIN_LIST[@]}; do

        original_ram_size=""
        memlimit_active="no"

        while true; do

            if [[ $(domain_state $domain) == running ]]; then

                # Only when VM is running, attempts to create a new backup chain:
                do_backup_chain $domain "full" $BACKUPS_MAIN_PATH $VIRTNBDBACKUP_GLOBAL_OPTIONS

                if [[ $? -eq 0 ]]; then

                    # Backup chain creation was successful!
                    backup_chain_success[$i]=$domain

                    # To DO: Sync on remote endpoint when REMOTE_BACKUPS_MAIN_PATH is set and bring status.

                    echo "$domain: Backup chain successfully created!"
                else

                    # Failed to create a new backup chain:
                    backup_chain_failed[$i]=$domain

                    # Delete partial files (unusable garbage):
                    rm -rf $BACKUPS_MAIN_PATH/$domain

                    echo "$domain: Failed to create a new backup chain"
                fi

                if [[ ${domain_poweron_success[$i]} -eq $domain ]]; then

                    # VM was previously shut off, revert to its previous state:
                    domain_shutdown $domain --nowait

                    if [[ $memlimit_active == yes ]]; then

                        # RAM was previously throttled. Reverting to its original values:
                        domain_setmem $domain $original_ram_size
                        echo "$domain: Reverted RAM size to its original setting of $original_ram_size KiB"
                    fi
                fi

                # Exits the loop:
                break

            else

                # VM is presumably shut off. Will attempts to start it:

                if [[ ! -z $RAM_LIMIT_PER_SCHED_BACKUP ]]; then

                    # And needs to check how much memory uses by default, throttling it if limits are established:

                    # Gets the original RAM size
                    original_ram_size=$(domain_getmem $domain --max)

                    # If the above value is greater than the established limit, sets the VM RAM temporarily to such limit:
                    if [[ $original_ram_size -gt $RAM_LIMIT_PER_SCHED_BACKUP ]]; then

                        memlimit_active="yes"
                        domain_setmem $domain $RAM_LIMIT_PER_SCHED_BACKUP

                        echo "$domain: RAM size temporarily throttled from $original_ram_size KiB to $RAM_LIMIT_PER_SCHED_BACKUP KiB for this task"
                    fi
                fi

                # Attempts to start the VM (awaits for VM's QEMU agent):
                domain_start $domain
                if [[ $? -eq 0 ]]; then

                    domain_poweron_success[$i]=$domain

                    # Restarts the loop to chech VM under changed conditions:
                    continue
                else

                    # VM failed to power on. This is an abnormal situation:
                    echo "$domain: Failed to proceed (no backup chain could be created)"
                    domain_poweron_failed[$i]=$domain

                    # Breaks the loop:
                    break
                fi
            fi
        done

        # Unlist VM from CREATE_BACKUP_CHAIN_LIST:
         unset CREATE_BACKUP_CHAIN_LIST[$i]

        # Increases the index to check the next VM:
        ((i++))
    done

    # As scheduled backups could happen during creation / sync of several backup chains
    # (including the VMs sent to schedule in check_backups),
    # results necessary to re-read external variables in case some incremental backup failed,
    source $external_vars

    # Appends updated values:
    # (as a string, since sed can't expand arrays correctly):
    SCHEDULED_BACKUPS_LIST+=(${backup_chain_success[@]})
    SCHEDULED_BACKUPS_LIST="${SCHEDULED_BACKUPS_LIST[@]}"

    CHECK_PATCH_LIST+=(${backup_chain_failed[@]})
    CHECK_PATCH_LIST="${CHECK_PATCH_LIST[@]}"

    FAILED_VMS_LIST+=(${domain_poweron_failed[@]})
    FAILED_VMS_LIST="${FAILED_VMS_LIST[@]}"

    # And updates them all at once:
    sed -i \
    -e "s/SCHEDULED_BACKUPS_LIST=.*/SCHEDULED_BACKUPS_LIST=($SCHEDULED_BACKUPS_LIST)/" \
    -e "s/CHECK_PATCH_LIST=.*/CHECK_PATCH_LIST=($CHECK_PATCH_LIST)/" \
    -e "s/FAILED_VMS_LIST=.*/FAILED_VMS_LIST=($FAILED_VMS_LIST)/" \
    $external_vars

    # And shows the summary at the very end:

    echo ""
    echo "Backup Chain Creation Summary:"
    echo ""
    echo "On schedule for incremental backups: ${backup_chain_success[@]:-"None"}"
    echo "Failed to create backup chain: ${backup_chain_failed[@]:-"None"}"
    echo "Failed to power on: ${domain_poweron_failed[@]:-"None"}"

    if [[ -z ${backup_chain_failed[@]} ]] && [[ -z ${domain_poweron_failed[@]} ]]; then

        echo ""
        echo "All Backup Chains Created!"
    fi
}

###############################################################################
# Main execution:
###############################################################################

#------------------------------------------------------------------------------
# Internal global variables and common functions are managed via this script:
source $functions_path
#------------------------------------------------------------------------------
# 1. Check input parameters (exits on error)
#------------------------------------------------------------------------------

# Redirects all output to a log file:
exec &>> $logpath

# Catches the signal sent from docker to stop execution:
# The most gracefully way to stop this container is with:
# 'docker kill --signal=SIGTERM <docker-name-or-id>'
trap 'stop_container' SIGTERM
############################################################################################################
echo "############################################################################################################"
echo "Container started at: $(date "+%Y-%m-%d %H:%M:%S")"
echo "############################################################################################################"

# 1.1 Check DOMAINS_LIST:
#------------------------------------------------------------------------------

# The initial list of VMs to work:
DOMAINS_LIST=($(domains_list))

if [[ ! -z $DOMAINS_LIST ]]; then

    # 1.1.1 Check IGNORED_VMS_LIST:
    #------------------------------------------------------------------------------
    if [[ ! -z $IGNORED_VMS_LIST ]]; then

        # Debugging VMs to be ignored (set into a bash array):
        IGNORED_VMS_LIST=($IGNORED_VMS_LIST)

        for domain in ${IGNORED_VMS_LIST[@]}; do

            if [[ $(domain_exists $domain) == yes ]]; then

                # Remove the VM from DOMAINS_LIST
                unset DOMAINS_LIST[$(item_position $domain "DOMAINS_LIST")]
                echo "Ignoring VM $domain declared into IGNORED_VMS_LIST"
            else

                unset IGNORED_VMS_LIST[$(item_position $domain "IGNORED_VMS_LIST")]
                echo "WARNING: VM $domain declared into IGNORED_VMS_LIST not found!"
            fi
        done
    fi

    # 1.1.2 Check AUTOSTART_VMS_LIST:
    #------------------------------------------------------------------------------

    if [[ ! -z $AUTOSTART_VMS_LIST ]]; then

        # Debugging VMs to be powered on on container's start (set into a bash array):
        AUTOSTART_VMS_LIST=($AUTOSTART_VMS_LIST)

        for domain in ${AUTOSTART_VMS_LIST[@]}; do

            if [[ $(domain_exists $domain) == no ]]; then

                unset AUTOSTART_VMS_LIST[$(item_position $domain "AUTOSTART_VMS_LIST")]
                echo "WARNING: VM $domain declared in AUTOSTART_VMS_LIST not found!"
            fi
        done
    fi

    # 1.1.3 Check DOMAINS_LIST VM's disk images:
    #------------------------------------------------------------------------------
    echo "Querying for persistent Virtual machines from libvirt..."
    i=0
    for domain in ${DOMAINS_LIST[@]}; do

        drives_list=($(domain_drives_list $domain))
        if [[ ! -z ${drives_list[@]} ]]; then

            # Does have drives able to be backed up. Checks if such disk images are reachable inside the container:

            images_list=($(domain_img_paths_list $domain))
            for image in ${images_list[@]}; do

                if [[ ! -f $image ]]; then

                    FAILED_VMS_LIST+=($domain)
                    unset DOMAINS_LIST[$i]
                    echo "ERROR: $domain's disk image: $image not found"

                elif [[ ! -r $image ]] && [[ ! -w $image ]]; then

                    FAILED_VMS_LIST+=($domain)
                    unset DOMAINS_LIST[$i]
                    echo "ERROR: $domain's disk image: $image has permission issues (cannot be read or written)"
                fi
            done
        else
            IGNORED_VMS_LIST+=($domain)
            unset DOMAINS_LIST[$i]
            echo "WARNING: VM $domain has no drives that can be backed up (ignored)"
        fi
        # Increases the counter:
        ((i++))
    done

    if [[ ! -z ${FAILED_VMS_LIST[@]} ]]; then

        echo "ERROR: Issues were detected with VM(s) '${FAILED_VMS_LIST[@]}' that need to be solved before to run this container again."

    else
        # When no VM failed the test AND remained VMs to check (not ignored), then domain_list check is successful:
        domains_list_status="OK"
    fi
else
    echo "ERROR: No persistent Virtual machines found!"
fi

# 1.2 Check BACKUPS_MAIN_PATH
#------------------------------------------------------------------------------

if [[ ! -z $BACKUPS_MAIN_PATH ]]; then

    if  [[ -d $BACKUPS_MAIN_PATH ]]; then

        # $BACKUPS_MAIN_PATH found
        if  [[ -r $BACKUPS_MAIN_PATH ]] && [[ -w $BACKUPS_MAIN_PATH ]]; then

            # $BACKUPS_MAIN_PATH has read/write permissions.
            backups_main_path_status="OK"
            echo "Backups main path set to: $BACKUPS_MAIN_PATH"
            # Check for MAX_BACKUP_CHAINS_PER_VM:

            if [[ $MAX_BACKUP_CHAINS_PER_VM =~ [0-9] ]]; then

                # Is an integer number:
                echo "Max # of backup chains per VM to keep locally: $MAX_BACKUP_CHAINS_PER_VM"

            elif [[ -z $MAX_BACKUP_CHAINS_PER_VM ]]; then

                # Was not set:
                echo "Environment variable MAX_BACKUP_CHAINS_PER_VM not set. ALL backup chains that are recoverable will be kept locally"

            else

                # Invalid value (unsets the 'OK' status):
                unset backups_main_path_status
                echo "ERROR: Incorrect syntax for environment variable MAX_BACKUP_CHAINS_PER_VM (must be a natural integer)"
            fi
        else
            echo "ERROR: Backups main path: $BACKUPS_MAIN_PATH has permission issues (cannot be read or written)"
        fi
    else
        echo "ERROR: Backups main path: $BACKUPS_MAIN_PATH  not found or not a directory (must be an absolute path)"
    fi
else
    echo "ERROR: Environment variable BACKUPS_MAIN_PATH is not set"
fi

# 1.3 Check REMOTE_BACKUPS_MAIN_PATH
#------------------------------------------------------------------------------

if [[ -z $REMOTE_BACKUPS_MAIN_PATH ]]; then

    remote_backups_main_path_status="UNUSED"
    echo "Environment variable REMOTE_BACKUPS_MAIN_PATH not set. No remote backup endpoint will be used"

elif [[ $REMOTE_BACKUPS_MAIN_PATH == *@*:/* ]]; then

    # Apparently includes correct remote login and path. Separates ssh login from remote path:
    remote_server=$(echo $REMOTE_BACKUPS_MAIN_PATH | cut -d':' -f1)
    remote_backups_main_path=$(echo $REMOTE_BACKUPS_MAIN_PATH | cut -d':' -f2)

    # Attempts to comunicate with the remote host:
    ssh_command $remote_server "exit 0"
    remote_server_status=$?

    if [[ $remote_server_status == 0 ]]; then

        # Attempts to perform similar checks as with $BACKUPS_MAIN_PATH, except it only returns "OK" if there was success:
        remote_backups_main_path_status=$(ssh_command $remote_server "if [[ ! -e $remote_backups_main_path ]]; then; mkdir -p $remote_backups_main_path; [[ $? == 0 ]] && echo CREATED; elif [[ -d $remote_backups_main_path ]] && [[ -r $remote_backups_main_path ]] && [[ -w $remote_backups_main_path ]]; then; echo EXISTS; fi")

        case $remote_backups_main_path_status in

        EXISTS|CREATED)

            echo "Remote endpoint $REMOTE_BACKUPS_MAIN_PATH status: '$remote_backups_main_path_status'"

            if [[ $REMOTE_MAX_BACKUP_CHAINS_PER_VM =~ [0-9] ]]; then

                # Is an integer number:
                echo "Max # of backup chains per VM to be kept remotely: $REMOTE_MAX_BACKUP_CHAINS_PER_VM"

            elif [[ -z $REMOTE_MAX_BACKUP_CHAINS_PER_VM ]]; then

                # Was not set:
                echo "Environment variable REMOTE_MAX_BACKUP_CHAINS_PER_VM not set. ALL backup chains that are recoverable will be kept remotely"

            else

                # Unset status variable to prevent keep running:
                unset remote_backups_main_path_status

                echo "ERROR: Incorrect syntax for environment variable REMOTE_MAX_BACKUP_CHAINS_PER_VM (must be a natural integer)"
            fi
        ;;
        *)
            echo "ERROR: Remote endpoint: $REMOTE_BACKUPS_MAIN_PATH has permission issues (cannot be read or written) or is not a directory"
        ;;
        esac

    else
        echo "ERROR: Connection with $remote_server failed with status $remote_server_status"
    fi
else
    echo "ERROR: Incorrect syntax for $REMOTE_BACKUPS_MAIN_PATH (must be an SSH-like absolute path)"
fi

# 1.4 TO DO: Check other ENV variables, and SSH key:
#------------------------------------------------------------------------------
#------------------------------------------------------------------------------
# 2. Only when input parameters doesn't require to restart the container, it continues the rest of the checks:
#------------------------------------------------------------------------------

if [[ $domains_list_status == OK ]] && [[ $backups_main_path_status == OK ]] && [[ ! -z $remote_backups_main_path_status ]]; then

    # 2.1 Create/update Cron task for VMs to be (progressively) included in $scheduled_backups_list:
    #------------------------------------------------------------------------------

    echo "Deploying Cron task..."

    [[ -z $CRON_SCHEDULE ]] && { CRON_SCHEDULE="@daily"; echo "INFO: Environment variable 'CRON_SCHEDULE' is not set. Using default parameter ($CRON_SCHEDULE)"; }

    # Silently deletes any previous cron task:
    &> /dev/null crontab -r

    # Parses the actual cron task needed to run to $crontab_file
    # (Including ENV vars not being read from cron's environment):
    cat << end_of_crontab > $crontab_file
# These values are refreshed upon container's start:
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
BACKUPS_MAIN_PATH="$BACKUPS_MAIN_PATH"
REMOTE_BACKUPS_MAIN_PATH="$REMOTE_BACKUPS_MAIN_PATH"
VIRTNBDBACKUP_GLOBAL_OPTIONS="$VIRTNBDBACKUP_GLOBAL_OPTIONS"
RAM_LIMIT_PER_SCHED_BACKUP="$RAM_LIMIT_PER_SCHED_BACKUP"
$CRON_SCHEDULE $scheduled_backup_script
end_of_crontab

    # Sets the cron task:
    crontab $crontab_file

    # Initializes the log file (in case doesn't exist):
    touch -a $scheuled_logpath

    # Finally, runs cron and sends to background:
    cron -f -l -L2 &

    # Catching its PID:
    #cron_pid=$!

    # 2.2 Check if OS is Unraid and it has just been restarted (checking backups under this scenario assumes missing checkpoints / broken backup chains:
    #------------------------------------------------------------------------------

    if [[ $(os_is_unraid) == yes ]]; then

        echo "OS Unraid detected. Scanning for checkpoints..."

        for domain in ${DOMAINS_LIST[@]}; do

            # Looks for checkpoints in all VMs, only stopping if it finds something
            # (does not rely on expose checkpoints dir inside the container):
            [[ ! -z $(domain_checkpoint_list $domain) ]] && { checkpoints_found="yes"; break; }

        done

        if [[ -z $checkpoints_found ]]; then

            # Exports the variable, since it's modified by the scheduled script:
            export RESTARTED_SERVER="true"
            echo "___________________________________________________________________________________________________"
            echo ""
            echo "Unraid server appears to have been restarted recently or this is the very first usage, since no checkpoints were found by libvirt at all!"
            echo ""
            echo "All Virtual machines (except those ignored by thsi script, and declared in environment variable IGNORED_VMS_LIST) are in need to be Shut Down in order to check backup chains integrity more comprehensively, attempting to fixup or (re)creating as needed"
            echo ""

            for domain in ${DOMAINS_LIST[@]}; do

                if [[ $(domain_state $domain) != "shut off" ]]; then

                    if [[ ! -z $RESTART_VMS_IF_REQUIRED ]]; then

                        domain_shutdown $domain
                        if [[ $? -eq 0 ]]; then

                            # And into this list to be started as checks has been completed:
                            POWEREDOFF_VMS_LIST+=($domain)

                            # Adds successfully shut off VMs to the initial queue:
                            CHECK_PATCH_LIST+=($domain)

                        else

                            # VM Delayed too much without being shutdown. Added to this queue to be checked up periodically:
                            SHUTDOWN_REQUIRED_VMS_LIST+=($domain)
                        fi
                    else
                        # User needs to shutdown this VM before to perform any further checks:
                        SHUTDOWN_REQUIRED_VMS_LIST+=($domain)
                    fi
                else

                    # Adds already shut down VMs to the initial queue:
                    CHECK_PATCH_LIST+=($domain)
                fi
            done

            echo ""
            echo "RESTARTED_SERVER mode Summary:"
            echo ""
            echo "Ready for further checks: ${CHECK_PATCH_LIST[@]:-"None"}"
            [[ ! -z $RESTART_VMS_IF_REQUIRED ]] && \
            echo "Into automatic power cycle: ${POWEREDOFF_VMS_LIST[@]:-"None"}"
            echo "Manual shut down is needed before to proceed: ${SHUTDOWN_REQUIRED_VMS_LIST[@]:-"None"}"

        else
            # Fortunately there's not a 'RESTARTED_SERVER' scenario.
            # Add all remaining VMs in DOMAINS_LIST to the first queue:
            CHECK_PATCH_LIST=(${DOMAINS_LIST[@]})

            # Exports the variable, since it's modified by the scheduled script:
            RESTARTED_SERVER="false"
        fi
    else

        # OS is not Unraid.
        # Add all remaining VMs in DOMAINS_LIST to this queue:
        CHECK_PATCH_LIST=${DOMAINS_LIST[@]}
    fi

    # 2.3 Initializes a file with variables externally stored, to be shared with the scheduler:
    #------------------------------------------------------------------------------
    cat << end_of_external_variables > $external_vars
# These values are shared (and constantly updated) by main and scheduler scripts:
CHECK_PATCH_LIST=(${CHECK_PATCH_LIST[@]})
SCHEDULED_BACKUPS_LIST=()
FAILED_VMS_LIST=()
end_of_external_variables

    # 3. Begin monitorization for VMs in lists, performing operations as required:
    #------------------------------------------------------------------------------

    "############################################################################################################"
    echo "Starting Monitoring mode..."

    while true; do

        # Maximum standby period for monitoring should not exceed 10 seconds in any case,
        # because it could ignore SIGTERM from Docker, thus being killed with SIGKILL:
        sleep 1

        # 3.1 (Re)reads all external variables:
        #------------------------------------------------------------------------------
        source $external_vars

        # TO DO: Pause monitoring when Scheduled backup is running!

        if [[ ! -z ${SHUTDOWN_REQUIRED_VMS_LIST[@]} ]]; then

            # 3.2 Check for VMs which are in need of shutdown first.
            # (This normally happens when the user took the action, or when a VM took long time to shutdown):
            #------------------------------------------------------------------------------
            i=0
            for domain in ${SHUTDOWN_REQUIRED_VMS_LIST[@]}; do

                if [[ $(domain_state $domain) == "shut off" ]]; then

                    # Move to main queue for check:
                    CHECK_PATCH_LIST+=($domain)
                    unset SHUTDOWN_REQUIRED_VMS_LIST[$i]
                fi
            done
        fi

        if [[ ! -z ${CHECK_PATCH_LIST[@]} ]]; then

            # 3.3 Status of at least on VM has changed, and sent to one queue:
            #------------------------------------------------------------------------------

            # Marks an ongoing check starting:
            ongoing_check="true"

            echo "___________________________________________________________________________________________________"
            echo ""
            echo "Status change detected at $(date "+%Y-%m-%d %H:%M:%S")"
            echo "Automatic check for VM(s) '${CHECK_PATCH_LIST[@]} in progress..."

            check_patch
        fi

        # 3.4 Backups of VMs that passed check_patch successfuly will be checked for integrity (and fixed, when possible):
        #------------------------------------------------------------------------------
        [[ ! -z ${CHECK_BACKUPS_LIST[@]} ]] && check_backups


        if [[ ! -z ${AUTOSTART_VMS_LIST[@]} ]]; then

        # 3.5 When debugged AUTOSTART_VMS_LIST is set and VMs in list are shut down,
        # Turns them on:
        #------------------------------------------------------------------------------
        for domain in ${AUTOSTART_VMS_LIST[@]}; do

            if [[ $(domain_state $domain) != running ]]; then

                echo "$domain: Performing Auto start (declared into AUTOSTART_VMS_LIST)"
                domain_start $domain --nowait
            fi
        done
        fi

        if [[ ! -z ${POWEREDOFF_VMS_LIST[@]} ]]; then

            # 3.6 Turns on all VMs that was previously shutdown for checks:
            #------------------------------------------------------------------------------
            echo "Starting (remaining) Virtual machines previously shut down for checks..."
            i=0
            for domain in ${POWEREDOFF_VMS_LIST[@]}; do

                if [[ $(domain_state $domain) != running ]]; then

                    # Turn on the VM. Do not wait for Guest's QEMU agent:
                    domain_start $domain --nowait
                fi

                # Remove the VM from the list is being read:
                unset POWEREDOFF_VMS_LIST[$i]

                # Increases the counter:
                ((i++))
            done
        fi

        # 3.7 Those VMs in need of a full backup chain, will run this process:
        #------------------------------------------------------------------------------
        [[ ! -z ${CREATE_BACKUP_CHAIN_LIST[@]} ]] && create_backup_chain


        if [[ $ongoing_check == true ]]; then

            # Only checked when status changes were initially detected:
            if [[ -z ${CHECK_PATCH_LIST[@]} ]]; then

            # No VMs in CHECK_PATCH_LIST (string or array, as comes up)
            # It means that all checks finished successfully, entering in 'silent' mode:
            ongoing_check="false"

            echo "############################################################################################################"
            echo ""
            echo "All VMs with status changed finished to be processed at $(date "+%Y-%m-%d %H:%M:%S")"
            echo ""
            echo "VM-Babysitter Global Summary:"
            echo ""
            echo "Current Scheduled Backups: ${SCHEDULED_BACKUPS_LIST[@]:-"None"}"
            echo "Manual Shut Down Required: ${SHUTDOWN_REQUIRED_VMS_LIST[@]:-"None"}"
            echo "Failing Virtual Machines: ${FAILED_VMS_LIST[@]:-"None"}"

            if [[ ! -z ${SCHEDULED_BACKUPS_LIST[@]} ]] && \
            [[ -z ${SHUTDOWN_REQUIRED_VMS_LIST[@]} ]] && \
            [[ -z ${FAILED_VMS_LIST[@]} ]]; then

                echo ""
                echo "All Virtual Machines Running Under Incremental Backups!"
                echo ""

            elif [[ ! -z ${SHUTDOWN_REQUIRED_VMS_LIST[@]} ]] || [[ ! -z ${FAILED_VMS_LIST[@]} ]]; then

                echo ""
                echo "WARNING: USER ACTION IS REQUIRED!"
                echo ""

                [[ ! -z ${SHUTDOWN_REQUIRED_VMS_LIST[@]} ]] && \
                echo "Perform a MANUAL SHUT DOWN of the following VM(s):'$SHUTDOWN_REQUIRED_VMS_LIST[@]}' to allow being checked automatically."

                [[ ! -z ${FAILED_VMS_LIST[@]} ]] && \
                echo "VM(s): '${FAILED_VMS_LIST[@]}' FAILED or behave ABNORMALLY during the checks. Do a manual check and ensure proper functioning; then restart this container in order to check again."
            fi

            if [[ -z ${SCHEDULED_BACKUPS_LIST[@]} ]]; then

                echo ""
                echo "At the moment, NO Virtual Machine is on schedule for incremental backup."
                echo ""
            fi
        fi

        # 3.8 Restarts the loop from 3.1, until receives SIGTERM or SIGKILL from Docker
        #------------------------------------------------------------------------------
    done

else
    # Initial checks have proven non-recoverable errors:
    echo "ERROR: Could not start due to errors on input parameters"
    stop_container
fi
