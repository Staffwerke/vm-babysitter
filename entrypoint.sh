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
    echo "INFO: SIGTERM signal received at: $(date "+%Y-%m-%d %H:%M:%S")"
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
    echo "Checking / patching Virtual machines: ${CHECK_PATCH_LIST[@]}"

    local i=0
    for domain in ${CHECK_PATCH_LIST[@]}; do

        # For each VM, the loop repeats itself as needed until a VM has been successfully patched, or not:
        while true; do

            if [[ -z ${domain_shutdown_failed[$i]} ]] && [[ -z ${vm_patch_failed[$i]} ]]; then

                if [[ $(domain_is_patched $domain ) == yes ]]; then

                    #echo "$domain: Patch for incremental backups is correct"
                    vm_patch_success[$i]+=$domain
                    break

                elif [[ $(domain_is_patched $domain --inactive) == yes ]]; then

                    # VM is (presumably) running and was patched before (e.g. in past iteration inside this loop)
                    # But needs a power cycle so changes can be applied:

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

                        #echo "$domain: Cannot apply changes about patch for incremental backup while VM running"
                        # Adds VM to failed to shutdown local list
                        # (User must shutdown the VM manually):
                        domain_shutdown_failed[$i]=$domain
                    fi

                    # Restarts the loop (checks VM again under changed conditions):
                    continue

                else

                    #echo "$domain: Patch not detected. Attempting to patch for incremental backups..."

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
    echo "Into automatic power cycle, to apply patch: ${domain_shutdown_success[@]:-"None"}"
    echo "Manual power cycle is needed to apply patch: ${domain_shutdown_failed[@]:-"None"}"
    echo "Manual VM definitions check is needed, could not be patched: ${vm_patch_failed[@]:-"None"}"

    if [[ -z ${domain_shutdown_failed[@]} ]] && [[ -z ${vm_patch_failed[@]} ]]; then

        echo ""
        echo "ALL VMs WERE PATCHED SUCCESSFULLY!"
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
                    echo "$domain: No backup chain folder detected or backup chain structure is damaged"
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

                echo "$domain: VM is shut down, performing full check in backup chain..."

                if [[ $recoverable_backup_chain != false ]] || [[ $backup_folder_exists != false ]]; then

                    # Backup chain is worth of being checked:

                    if [[ $RESTARTED_SERVER == true ]] ; then

                        # No QEMU checkpoints are found when server comes from a restart under UnRaid, so uses backup checkpoints in backup
                        echo "$domain: Reading Checkpoint list in Backup (RESTARTED_SERVER detected)"
                        checkpoint_list=($(backup_checkpoint_list $BACKUPS_MAIN_PATH/$domain))
                    else

                        echo "$domain: Reading Checkpoint list in QEMU"
                        checkpoint_list=($(domain_checkpoint_list $domain))
                    fi

                    # Perform a full check of checkpoints vs bitmaps:
                    for image in $(domain_img_paths_list $domain); do

                        bitmaps_list=($(disk_image_bitmap_list $image))
                        if [[ ${bitmaps_list[@]} != ${checkpoint_list[@]} ]]; then

                            # When bitmaps and checkpoint lists aren't identical for ALL disks, marks the entire check as failed:
                            backup_check_failed="yes"

                            echo "$domain.$image: Checkpoint and Bitmap lists mismatch for this image"

                            # Cancelling further checks for this VM:
                            break
                        fi
                    done
                fi

                if [[ $backup_check_failed == yes ]] || [[ $recoverable_backup_chain == false ]] || [[ $backup_folder_exists == false ]]; then

                    # Each scenario is exclusive (non recoverable backup chain is implicitly failed):

                    if [[ $RESTARTED_SERVER != true ]]; then

                        echo "$domain: Pruning existing Checkpoints in QEMU..."
                        domain_delete_checkpoint_metadata $domain
                    fi

                    for image in $(domain_img_paths_list $domain); do

                        # Then deletes all bitmaps, in all image disks:
                        echo "$domain.$image: Deleting Bitmaps..."

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

                    # Checkpoints and bitmaps are matching despite the scenario.
                    # Attempts to delete the last checkpoint (even from backup) and bitmap:

                    # Gets the last index in $checkpoint_list:
                    local index=${#checkpoint_list[@]}

                    # Moves the last checkpoint name apart:
                    local damaged_checkpoint=${checkpoint_list[$index]}
                    unset checkpoint_list[$index]

                    # Deletes this checkpoint from and QEMU (if exists), images and backup itself:

                    for image in $(domain_img_paths_list $domain); do

                        # Deletes this bitmap name from all drives in this VM
                        disk_image_delete_bitmap $image $damaged_checkpoint
                    done

                    # Deletes QEMU checkpoint when it's supposed to exist:
                    [[ $RESTARTED_SERVER != true ]] && domain_delete_checkpoint_metadata $domain $damaged_checkpoint

                    # Finally, deletes all the files created by the incremental backup (except logs):

                    for drive in $(domain_drives_list); do

                        # Backup incremental data (all drives)
                        rm -f $BACKUPS_MAIN_PATH/$domain/$drive.inc.$damaged_checkpoint.data.partial
                    done

                    # VM definitions XML file:
                    rm -f $BACKUPS_MAIN_PATH/$domain/vmconfig.$damaged_checkpoint.xml

                    # Checkpoint in backup:
                    rm -f $BACKUPS_MAIN_PATH/$domain/checkpoints/$damaged_checkpoint.xml

                    # Modifying the .cpt file with the new checkpoints list:
                    local new_checkpoint_list="${checkpoint_list[@]}"
                    echo "[\"${new_checkpoint_list// /\", \"}\"\]" > $BACKUPS_MAIN_PATH/$domain/$domain.cpt

                    # Backup chain will be treated as preserved:
                    preserved_backup_chain+=($domain)

                    echo "$domain: Backup repaired (incomplete checkpoint '$damaged_checkpoint' removed from both VM and backup chain)"

                    # Exits the loop:
                    break

                    # To DO: Remote sync after backup repair...
                else

                    preserved_backup_chain+=($domain)
                    echo "$domain: Checkpoints and Bitmaps lists match"

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
                    echo "$domain: Cannot check its backup chain while running (Restarted server, cancelled checkpoint, backup folder corrupt or doesn't exist)"

                    # Adds VM to failed to shutdown local list:
                    domain_shutdown_failed[$i]=$domain

                    # Exits the loop (nothing else can be done):
                    break
                fi

            else

                echo "$domain: VM is (presumably) running, comparing Checkpoint lists in QEMU and Backup..."

                # Gets both qemu and backup checkpoint lists:
                local qemu_checkpoint_list=($(domain_checkpoint_list $domain))
                local backup_chain_checkpoint_list=($(backup_checkpoint_list $BACKUPS_MAIN_PATH/$domain))


                if [[ ${qemu_checkpoint_list[@]} != ${backup_chain_checkpoint_list[@]} ]]; then

                    # Checkpoint lists in QEMU and backup aren't identical:

                    echo "$domain: QEMU and Backup Checkpoint lists mismatch (${#qemu_checkpoint_list[@]} vs ${#backup_chain_checkpoint_list[@]})"

                    # Process old backup and mark backup chain as broken (can't check more in deep for bitmaps / checkpoints to delete:)
                    archive_backup $BACKUPS_MAIN_PATH/$domain
                    broken_backup_chain[$i]=$domain

                    # Exits the loop (nothing else can be done):
                    break

                else

                    echo "$domain: QEMU and Backup Checkpoint lists match (${#qemu_checkpoint_list[@]} vs. ${#backup_chain_checkpoint_list[@]})"
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
    echo "Backup chain integrity summary:"
    echo ""
    echo "On schedule for incremental backups: ${preserved_backup_chain[@]:-"None"}"
    echo "In need of new backup chain (current is absent or was broken): ${broken_backup_chain[@]:-"None"}"
    [[ ! -z $RESTART_VMS_IF_REQUIRED ]] && \
    echo "Into automatic power cycle, allowed to check backup integrity: ${domain_shutdown_success[@]:-"None"}"
    echo "Manual power cycle is needed to check backup integrity: ${domain_shutdown_failed[@]:-"None"}"

    if [[ -z ${domain_shutdown_failed[@]} ]]; then

        echo ""
        echo "ALL BACKUP CHAINS WERE CHECKED SUCCESSFULLY!"
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

                    echo "$domain: Backup chain successfully created"
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
                    echo "$domain: failed to start (no backup chain could be created)"
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
    echo "Backup chain creation Summary:"
    echo ""
    echo "Successful Backups (on schedule): ${backup_chain_success[@]:-"None"}"
    echo "Failed Backups (will be checked ASAP): ${backup_chain_failed[@]:-"None"}"
    echo "Failed Virtual machines (user action is required): ${domain_poweron_failed[@]:-"None"}"

    if [[ -z ${backup_chain_failed[@]} ]] && [[ -z ${domain_poweron_failed[@]} ]]; then

        echo ""
        echo "ALL BACKUP CHAINS WERE CREATED SUCCESSFULLY!"
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

echo "###############################################################################"
echo "Container started at: $(date "+%Y-%m-%d %H:%M:%S")"
echo "###############################################################################"

# 1.1 Check DOMAINS_LIST:
#------------------------------------------------------------------------------

# The initial list of VMs to work:
DOMAINS_LIST=($(domains_list))

if [[ ! -z $DOMAINS_LIST ]]; then

    if [[ ! -z $IGNORED_VMS_LIST ]]; then

        # Debugging VMs to be ignored (set into a bash array):
        IGNORED_VMS_LIST=($IGNORED_VMS_LIST)

        for domain in ${IGNORED_VMS_LIST[@]}; do

            if [[ $(domain_exists $domain) == yes ]]; then

                # Remove the VM from DOMAINS_LIST
                unset DOMAINS_LIST[$(item_position $domain "DOMAINS_LIST")]
                echo "INFO: Ignoring VM '$domain' (into IGNORED_VMS_LIST)"
            else

                unset IGNORED_VMS_LIST[$(item_position $domain "IGNORED_VMS_LIST")]
                echo "WARNING: VM '$domain' declared in IGNORED_VMS_LIST was not found"
            fi
        done
    fi

    echo "INFO: Querying for Virtual Machines listed by libvirt..."
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
                    echo "ERROR: '$domain': '$image': Not found"

                elif [[ ! -r $image ]] && [[ ! -w $image ]]; then

                    FAILED_VMS_LIST+=($domain)
                    unset DOMAINS_LIST[$i]
                    echo "ERROR: '$domain': '$image': Permission issues (cannot read or write)"
                fi
            done
        else
            IGNORED_VMS_LIST+=($domain)
            unset DOMAINS_LIST[$i]
            echo "WARNING: '$domain': No drives that can be backed up (ignored)"
        fi
        # Increases the counter:
        ((i++))
    done

    if [[ ! -z ${FAILED_VMS_LIST[@]} ]]; then

        echo "ERROR: Issues detected with VM(s) '${FAILED_VMS_LIST[@]}' that need to be solved before to run this container again."

    else
        # When no VM failed the test AND remained VMs to check (not ignored), then domain_list check is successful:
        domains_list_status="OK"
    fi
else
    echo "ERROR: No persistent Virtual machines to check!"
fi

# 1.2 Check BACKUPS_MAIN_PATH
#------------------------------------------------------------------------------

if [[ ! -z $BACKUPS_MAIN_PATH ]]; then

    if  [[ -d $BACKUPS_MAIN_PATH ]]; then

        # $BACKUPS_MAIN_PATH found
        if  [[ -r $BACKUPS_MAIN_PATH ]] && [[ -w $BACKUPS_MAIN_PATH ]]; then

            # $BACKUPS_MAIN_PATH has read/write permissions.
            backups_main_path_status="OK"
            # Check for MAX_BACKUP_CHAINS_PER_VM:

            if [[ $MAX_BACKUP_CHAINS_PER_VM =~ [0-9] ]]; then

                # Is an integer number:
                echo "INFO: Max # of backup chains per VM to be kept locally: $MAX_BACKUP_CHAINS_PER_VM"

            elif [[ -z $MAX_BACKUP_CHAINS_PER_VM ]]; then

                # Was not set:
                echo "INFO: Environment variable 'MAX_BACKUP_CHAINS_PER_VM' not set (all backup chains will be kept locally)"

            else

                # Invalid value (unsets the 'OK' status):
                unset backups_main_path_status
                echo "ERROR: Incorrect syntax for environment variable MAX_BACKUP_CHAINS_PER_VM (must be a natural integer)"
            fi
        else
            echo "ERROR: Backups main path: '$BACKUPS_MAIN_PATH': Permission issues (cannot be read or written)"
        fi
    else
        echo "ERROR: Backups main path: '$BACKUPS_MAIN_PATH': Not found or not a directory (must be an absolute path)"
    fi
else
    echo "ERROR: Environment variable 'BACKUPS_MAIN_PATH' is not set"
fi

# 1.3 Check REMOTE_BACKUPS_MAIN_PATH
#------------------------------------------------------------------------------

if [[ -z $REMOTE_BACKUPS_MAIN_PATH ]]; then

    remote_backups_main_path_status="OK"
    echo "INFO: Environment variable REMOTE_BACKUPS_MAIN_PATH not set (no remote backup endpoint will be used)"

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

        OK|CREATED)

            echo "INFO: Remote endpoint $REMOTE_BACKUPS_MAIN_PATH status: '$remote_backups_main_path_status'"

            if [[ $REMOTE_MAX_BACKUP_CHAINS_PER_VM =~ [0-9] ]]; then

                # Is an integer number:
                echo "INFO: Max # of backup chains per VM to be kept remotely: $REMOTE_MAX_BACKUP_CHAINS_PER_VM"

            elif [[ -z $REMOTE_MAX_BACKUP_CHAINS_PER_VM ]]; then

                # Was not set:
                echo "INFO: Environment variable 'REMOTE_MAX_BACKUP_CHAINS_PER_VM' not set (all backup chains will be kept remotely)"

            else

                # Unset status variable to prevent keep running:
                unset remote_backups_main_path_status

                echo "ERROR: Incorrect syntax for environment variable REMOTE_MAX_BACKUP_CHAINS_PER_VM (must be a natural integer)"
            fi
        ;;
        *)
            echo "ERROR: Remote endpoint: $REMOTE_BACKUPS_MAIN_PATH has not insufficient read/write permissions or is not a directory"
        ;;
        esac

    else
        echo "ERROR: Connection with $remote_server failed with status $remote_server_status"
    fi
else
    echo "ERROR: Incorrect syntax for '$REMOTE_BACKUPS_MAIN_PATH'"
fi

# 1.4 TO DO: Check other ENV variables, and SSH key:
#------------------------------------------------------------------------------
#------------------------------------------------------------------------------
# 2. Only when input parameters doesn't require to restart the container, it continues the rest of the checks:
#------------------------------------------------------------------------------

if [[ $domains_list_status == OK ]] && [[ $backups_main_path_status == OK ]] && [[ ! -z $remote_backups_main_path_status ]]; then

    # 2.1 Create/update Cron task for VMs to be (progressively) included in $scheduled_backups_list:
    #------------------------------------------------------------------------------

    echo "INFO: Deploying Cron task..."

    [[ -z $CRON_SCHEDULE ]] && { CRON_SCHEDULE="@daily"; echo "INFO: Environment variable 'CRON_SCHEDULE' is not set. Using default parameter ($CRON_SCHEDULE)"; }

    # Silently deletes any previous cron task:
    &> /dev/null crontab -r

    # Parses the actual cron task needed to run to $crontab_file:
    cat << end_of_crontab > $crontab_file
# On run, performs incremental bakups for all VMs in SCHEDULED_BACKUPS_LIST at the moment of its execution:
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

    # Finally, runs cron and sends to background, catching its PID:
    cron -f -l -L2 &
    #cron_pid=$!

    # 2.2 Initializes a file with variables externally stored, to be shared with the scheduler
    # (This aren't used until when enters in Monitoring mode:)
    #------------------------------------------------------------------------------
    cat << 'end of external variables' > $external_vars
# DO NOT EDIT THIS FILE
CHECK_PATCH_LIST=()
SCHEDULED_BACKUPS_LIST=()
FAILED_VMS_LIST=()
end of external variables

    # 2.3 Check if OS is Unraid and it has just been restarted (checking backups under this scenario assumes missing checkpoints / broken backup chains:
    #------------------------------------------------------------------------------

    if [[ $(os_is_unraid) == yes ]]; then

        echo "INFO: OS Unraid detected. Scanning for checkpoints..."

        for domain in ${DOMAINS_LIST[@]}; do

            # Looks for checkpoints in all VMs, only stopping if it finds something
            # (does not rely on expose checkpoints dir inside the container):
            [[ ! -z $(domain_checkpoint_list $domain) ]] && { checkpoints_found="yes"; break; }

        done

        if [[ -z $checkpoints_found ]]; then

            # Exports the variable, since it's modified by the scheduled script:
            export RESTARTED_SERVER="true"
            echo "INFO: Server appears to have been restarted recently or no backup has been ever performed. Checking for running Virtual machines..."

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
                fi
            done

            # Notifies the user about the result and if needs to perform further actions (VMs are temporarily ignored, but checked periodically if state changes):
            [[ ! -z $POWEREDOFF_VMS_LIST ]] && echo "INFO: VM(s) '${POWEREDOFF_VMS_LIST[@]}' Into automatic Powercycle for further checks (will be powered on shortly)"
            [[ ! -z $SHUTDOWN_REQUIRED_VMS_LIST ]] && echo "WARNING: ACTION REQUIRED for '${SHUTDOWN_REQUIRED_VMS_LIST[@]}':  Perform a manual Shut down of for further checks (will be checked periodically for changes)"

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

    # 2.4 Perform an initial check of VMs that are -in theory- able to be backed up:
    #------------------------------------------------------------------------------

    echo "INFO: Initial check of VM(s) '${CHECK_PATCH_LIST[@]}' in progress..."
    check_patch

    if [[ ! -z ${CHECK_BACKUPS_LIST[@]} ]]; then

        echo "INFO: Initial check of backup chains(s) of VM(s) '${CHECK_BACKUPS_LIST[@]}' in progress..."
        check_backups
    fi

    # 2.5 If any, start VMs marked for autostart (debugging the list at the same time):
    #------------------------------------------------------------------------------

    if [[ ! -z $AUTOSTART_VMS_LIST ]]; then

        # Debugging VMs to be powered on on container's start (set into a bash array):
        AUTOSTART_VMS_LIST=($AUTOSTART_VMS_LIST)

        for domain in ${AUTOSTART_VMS_LIST[@]}; do

            if [[ $(domain_exists $domain) == yes ]]; then

                if [[ $(domain_state $domain) != running ]]; then

                    echo "INFO: Starting VM '$domain' (into AUTOSTART_VMS_LIST)"
                    domain_start $domain --nowait
                fi
            else

                echo "WARNING: VM '$domain' declared in AUTOSTART_VMS_LIST was not found"
                unset AUTOSTART_VMS_LIST[$(item_position $domain "AUTOSTART_VMS_LIST")]
            fi
        done
    fi

    # 2.6.1 If any, start VMs previiously shut down for checks:
    #------------------------------------------------------------------------------

    if [[ ! -z ${POWEREDOFF_VMS_LIST[@]} ]]; then

        echo "INFO: Starting Virtual machines previously Shut down to perform checks..."

        i=0
        for domain in ${POWEREDOFF_VMS_LIST[@]}; do

            if [[ $(domain_state $domain) != running ]]; then

                # Turn on the VM. Do not wait for Guest's QEMU agent:
                domain_start $domain --nowait

            fi

            # Remove the VM from the list is being read:
            [[ $? -eq 0 ]] && unset POWEREDOFF_VMS_LIST[$i]

            # Increases the counter:
            ((i++))
        done
    fi

    # 2.7 Begin monitorization for changes in lists:
    #------------------------------------------------------------------------------

    echo "------------------------------------------------------------------------------"
    echo "Starting Monitoring mode..."
    echo "------------------------------------------------------------------------------"

    while true; do

        # Maximum standby period for monitoring should not exceed 10 seconds in any case,
        # because it could ignore SIGTERM from Docker, thus being killed with SIGKILL:
        sleep 1

        # Reads all external variables, once per iteration:
        source $external_vars

        # TO DO: Pause monitoring when Scheduled backup is running!

        # Check for VMs which are in need of shutdown first.
        # (This normally happens when the user took the action, or when a VM took long time to shutdown):
        if [[ ! -z ${SHUTDOWN_REQUIRED_VMS_LIST[@]} ]]; then

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

            ongoing_check="true"

            # Status of at least on VM has changed, and sent to one queue:
            echo "------------------------------------------------------------------------------"
            echo "Status change detected at $(date "+%Y-%m-%d %H:%M:%S")"
            echo "Automatic check for VM(s) '${CHECK_PATCH_LIST[@]} in progress..."
            echo "------------------------------------------------------------------------------"

            check_patch
        fi

        # Backups of VMs that passed check_patch successfuly will be checked for integrity (and fixed, when possible):
        [[ ! -z ${CHECK_BACKUPS_LIST[@]} ]] && check_backups

        if [[ ! -z ${POWEREDOFF_VMS_LIST[@]} ]]; then

            # Turn off all VMs that was previously shutdown for checks
            #(RESTART_VMS_IF_REQUIRED is set):

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

        # Those VMs in need of a full backup chain, will run this process:
        [[ ! -z ${CREATE_BACKUP_CHAIN_LIST[@]} ]] && create_backup_chain


        if [[ $ongoing_check == true ]] && [[ -z ${CHECK_PATCH_LIST[@]} ]] && [[ -z ${CHECK_BACKUPS_LIST[@]} ]] && [[ ! -z ${POWEREDOFF_VMS_LIST[@]} ]] && [[ -z ${CREATE_BACKUP_CHAIN_LIST[@]} ]]; then

            # All checks finished successfully:
            ongoing_check="false"

            echo "------------------------------------------------------------------------------"
            echo "Finished processing all VMs with status changed at $(date "+%Y-%m-%d %H:%M:%S")"
        fi

        # And run infinitely, until receives SIGTERM or SIGKILL from Docker...
        #------------------------------------------------------------------------------
    done

else
    # Initial checks have proven non-recoverable errors:
    echo "ERROR: Could not start due to errors on input parameters. Exited."
fi
    # The End.
