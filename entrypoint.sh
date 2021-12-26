#!/bin/bash

: << 'end_of_specs'
#------------------------------------------------------------------------------
# ENV:
#------------------------------------------------------------------------------

Required:
BACKUPS_MAIN_PATH
DOMAINS_LIST

Optional:
AUTOSTART_VMS_LIST
CRON_SCHEDULE
IGNORED_VMS_LIST
MAX_LOCAL_BACKUP_CHAINS_PER_VM
MAX_REMOTE_BACKUP_CHAINS_PER_VM
NO_BACKUP_COMPRESSION
RAM_LIMIT_PER_SCHED_BACKUP
REMOTE_BACKUPS_MAIN_PATH
RESTART_VMS_IF_REQUIRED

Advanced options:
MAX_ATTEMPTS
WAIT_TIME
RSYNC_ARGS

#------------------------------------------------------------------------------
# TO DO:
#------------------------------------------------------------------------------
# (Re) create full backup on any error:
    # PHYSICAL disk usage summa of declared disk images is less than (( $current_backup_chain_disk_usage * $some_multiplier )) (domblklist & domblkinfo)

    # If a remote folder has been set:
        # For each $target_domain with a new full backup:
            # Send the new backup chain with timestamp
            # Change symlink of current backup (for incremental backups operation)
            # If max numb of backups to save

#------------------------------------------------------------------------------
REMAINING PROCEDURE:
#------------------------------------------------------------------------------
4. Initialize:
#------------------------------------------------------------------------------
For each VM in AUTOSTART_VMS_LIST and POWEREDOFF_VMS_LIST
    Is VM OFF?
    yes
        start the VM

Process slacking backup chains:
#------------------------------------------------------------------------------
sleep for DELAY_BACKUP_CHAIN_START

For VMs in FULL_BACKUPS_LIST
    run a full backup chain procedure
    Success?
    yes
        move VM to SCHEDULED_BACKUPS_LIST
    no
        Alert the user about the issue: 'ACTION REQUIRED: Unknown error while attempting to create a full backup chain of this VM'
        move VM to ACTION_REQUIRED_VMS_LIST

# From this point, monitoring ACTION_REQUIRED_VMS_LIST for changes (and trigger correspondent actions) would be viable.
Stand still, and await for termination (SIGSTOP / SIGKILL)

#------------------------------------------------------------------------------
end_of_specs

###############################################################################
# Specific functions and procedures:
###############################################################################

#------------------------------------------------------------------------------
# Check if VMs of a given list (passed by name, along with elements) are patched for incremental backups (and apply when possible):
#------------------------------------------------------------------------------
check_vms_patch()
{
    # Imports the name of the list to process and its items
    #(Bash cannot operate on global arrays by indirect reference):
    local vm_list_name=$1
    shift
    local vm_list_content=($@)

    # Lists to add VMs (and summarize at the end):
    local domain_shutdown_success
    local domain_shutdown_failed
    local vm_patch_success
    local vm_patch_failed

    # Processes each VM. Looks for patch and applies actions as required:
    local i=0
    for domain in ${vm_list_content[@]}; do

        # For each VM, the loop repeats itself as needed until a VM has been successfully patched, or not:
        while true; do

            if [[ -z ${domain_shutdown_failed[$i]} ]] && [[ -z ${vm_patch_failed[$i]} ]]; then

                if [[ $(domain_is_patched $domain ) == yes ]]; then

                    echo "$domain: Already patched"
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

                        echo "$domain: Cannot apply changes about patch for incremental backup while VM running"
                        # Adds VM to failed to shutdown local list
                        # (User must shutdown the VM manually):
                        domain_shutdown_failed[$i]=$domain
                    fi

                    # Restarts the loop (checks VM again under changed conditions):
                    continue

                else

                    echo "$domain: Patch not detected. Attempting to patch for incremental backups..."

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

        # Upon success, depending on the flow control, the global list name and data could be one of the following, so it is removed accordingly:
        [[ $vm_list_name == CHECK_VMS_LIST ]] && unset CHECK_VMS_LIST[$(item_position $domain $vm_list_name)]
        [[ $vm_list_name == ACTION_REQUIRED_VMS_LIST ]] && unset ACTION_REQUIRED_VMS_LIST[$(item_position $domain $vm_list_name)]

        # Increases the index to check the next VM:
        ((i++))
    done

    # Depending on the results, shows a brief summary with VMs with changed state or actions if required:

    if [[ ! -z ${vm_patch_success[@]} ]]; then

        echo "INFO: '${vm_patch_success[@]}': Correctly patched for incremental backups. On queue for backup chain check"

        # Appends sub-list of (successfully) patched VMs to global CHECK_BACKUPS_LIST:
        CHECK_BACKUPS_LIST+=(${vm_patch_success[@]})
    fi

    if [[ ! -z ${domain_shutdown_success[@]} ]]; then

        echo "INFO: '${domain_shutdown_success[@]}': Into automatic powercycle (to apply incremental backup patch, will be powered on shortly)"

        # Appends sub-list to the global list of powered OFF VMs:
        POWEREDOFF_VMS_LIST+=(${domain_shutdown_success[@]})
    fi

    if [[ ! -z ${domain_shutdown_failed[@]} ]]; then

        echo "WARNING: ACTION REQUIRED for '${domain_shutdown_failed[@]}': Perform a manual Shut down of VM(s) to apply incremental backup patch (temporarily ignored)"

        # Appends sub list of VMs that failed to shutdoen to global ACTION_REQUIRED_VMS_LIST:
        ACTION_REQUIRED_VMS_LIST+=(${domain_shutdown_failed[@]})
    fi

    if [[ ! -z ${vm_patch_failed[@]} ]]; then

        echo "ERROR: ACTION REQUIRED for '${vm_patch_failed[@]}': Inconsistent settings, could not patch for incremental bakups. If this is unexpected, use your Graphic UI to redefine VM definitions, or check the README for help (temporarily ignored)"

        # Appends sub list of VMs that failed attempting to be patched to global ACTION_REQUIRED_VMS_LIST:
        ACTION_REQUIRED_VMS_LIST+=(${domain_shutdown_failed[@]})
    fi

}

#------------------------------------------------------------------------------
# Checks backup chains integrity of a given list (passed by name, along with elements) and determines which list each VM must be sent for further actions (incremental, full, retrieve backups):
#------------------------------------------------------------------------------
check_backups()
{

    # Imports the name of the list to process and its items
    #(Bash cannot operate on global arrays by indirect reference):
    local vm_list_name=$1
    shift
    local vm_list_content=($@)

    # Local variables used for flow control:
    local checkpoints_list
    local bitmaps_list
    local backup_check_failed
    local preserved_backup_chain
    local broken_backup_chain

    # Lists to add VMs (and summarize at the end):
    local domain_shutdown_success
    local domain_shutdown_failed

    # Processes each VM. Looks for patch and applies actions as required:
    local i=0
    for domain in ${vm_list_content[@]}; do

        while true; do

            if [[ -d $BACKUPS_MAIN_PATH/$domain ]] \
            && [[ -f $BACKUPS_MAIN_PATH/$domain/$domain.cpt ]] \
            && [[ -d $BACKUPS_MAIN_PATH/$domain/checkpoints ]] \
            && [[ -z $(find $BACKUPS_MAIN_PATH/$domain -type f -name "*.partial") ]]; then

                # - Folder exists
                # - Summary file exists
                # - Checkpoint folder exists
                # - No *.partial files (left after cancel backup or some crash)
                # Backup chain structure seems to be OK. Performs a more comprehensive check.

                # Resets control flow variables, if used before:
                checkpoints_list=()
                backup_check_failed=""

                if [[ $(domain_state $domain) == "shut off" ]]; then

                    echo "$domain: VM is shut down, performing full check in backup chain..."

                    # No QEMU checkpoints are found when server comes from a restart under UnRaid, so uses backup checkpoints in backup
                    if [[ $RESTARTED_SERVER == true ]] ; then

                        echo "$domain: Using Checkpoint list in Backup (RESTARTED_SERVER detected)"
                        checkpoints_list=($(backup_checkpoint_list $BACKUPS_MAIN_PATH/$domain))
                    else

                        echo "$domain: Using Checkpoint list in QEMU"
                        checkpoints_list=($(domain_checkpoint_list $domain))
                    fi


                    # Perform a full check of checkpoints vs bitmaps:
                    for image in $(domain_img_paths_list $domain); do

                        bitmaps_list=($(disk_image_bitmap_list $image))
                        if [[ ${bitmaps_list[@]} != ${checkpoints_list[@]} ]]; then

                            # When bitmaps and checkpoint lists aren't identical for ALL disks, marks the entire check as failed
                            backup_check_failed="yes"

                            echo "$domain.$image: Checkpoint and Bitmap lists mismatch for this image (${#checkpoint_list[@]} vs. ${#bitmaps_list[@]})"

                            # Cancelling further checks for this VM:
                            break
                        fi
                    done

                    if [[ $backup_check_failed == yes ]]; then


                        if [[ $RESTARTED_SERVER != true ]]; then

                            echo "$0 ($domain): Pruning existing Checkpoints in QEMU..."
                            domain_delete_checkpoint_metadata $domain
                        fi

                        for image in $(domain_img_paths_list $domain); do

                            # Then deletes all bitmaps, in all image disks:
                            echo "$0 ($domain.$image): Deleting Bitmaps..."

                            for bitmap in $(disk_image_bitmap_list $image); do

                                disk_image_delete_bitmap $image $bitmap
                            done
                        done

                        # And marks backup chain as broken:
                        broken_backup_chain[$i]=$domain

                        # Exits the loop:
                        break

                    else

                        echo "$domain: Checkpoints and Bitmaps lists match"
                        preserved_backup_chain+=($domain)

                        # Exits the loop:
                        break
                    fi


                elif [[ $RESTARTED_SERVER == true ]]; then

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
                        echo "$domain: Cannot check its backup chain while VM running (RESTARTED_SERVER detected)"

                        # Adds VM to failed to shutdown local list
                        domain_shutdown_failed[$i]=$domain

                        # Exits the loop (nothing else can be done):
                        break
                    fi

                else

                    echo "$domain: VM is (presumably) running, comparing Checkpoint lists in QEMU and Backup..."

                    local qemu_checkpoint_list=($(domain_checkpoint_list $domain))
                    local backup_chain_checkpoint_list=$(backup_checkpoint_list $BACKUPS_MAIN_PATH/$domain)

                    # Checkpoint lists in QEMU and backup aren't identical.

                    if [[ ${qemu_checkpoint_list[@]} != ${backup_chain_checkpoint_list[@]} ]]; then

                        echo "$domain: QEMU and Backup Checkpoint lists mismatch (${#qemu_checkpoint_list[@]} vs. ${#backup_chain_checkpoint_list[@]})"

                        # Mark backup chain as broken (can't check more in deep for bitmaps / checkpoints to delete:)
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

            else

                echo "$domain: No backup chain folder, backup chain structure is damaged or a previous backup operation was unexpectedly cancelled."

                # Mark backup chain as broken:
                broken_backup_chain[$i]=$domain

                # Exits the loop (nothing else can be done):
                break
            fi
        done

        # VM is unlisted from CHECK_BACKUPS_LIST after the while loop is broken:
         unset CHECK_BACKUPS_LIST[$(item_position $domain $vm_list_name)]

        # Increases the index to check the next VM:
        ((i++))
    done

    # Depending on the results, shows a brief summary with VMs with changed states, and appends VMs to its respective lists:

     if [[ ! -z ${preserved_backup_chain[@]} ]]; then

        echo "INFO: '${preserved_backup_chain[@]}': Backup chain(s) appears to be OK! (On schedule for incremental backup)"

        # Appends / exports sub-list to SCHEDULED_BACKUPS_LIST for Cron task:
        export SCHEDULED_BACKUPS_LIST="$SCHEDULED_BACKUPS_LIST ${preserved_backup_chain[@]}"
    fi

    if [[ ! -z ${broken_backup_chain[@]} ]]; then

        echo "INFO: '${broken_backup_chain[@]}': Absent or Broken backup chain(s)! (on queue for backup chain creation)"

        # Appends sub-list to global list of VMs in need of a new backup chain:
        FULL_BACKUPS_LIST+=(${broken_backup_chain[@]})
    fi

    if [[ ! -z ${domain_shutdown_success[@]} ]]; then

        echo "INFO: '${domain_shutdown_success[@]}': Into automatic Powercycle (for backup chain integrity check, will be powered on shortly)"

        # Appends sub-list to the global list of powered OFF VMs:
        POWEREDOFF_VMS_LIST+=(${domain_shutdown_success[@]})
    fi

    if [[ ! -z ${domain_shutdown_failed[@]} ]]; then

        echo "WARNING: ACTION REQUIRED for '${domain_shutdown_failed[@]}': Perform a manual Shut down of VM(s) for backup chain(s) integrity check (temporarily ignored)"

        # Appends sub-list of failed to shutdown VMs to global list of VMs with issues
        ACTION_REQUIRED_VMS_LIST+=(${domain_shutdown_failed[@]})
    fi
}

#------------------------------------------------------------------------------
# Internal global variables and common functions are managed via this script:
source functions
#------------------------------------------------------------------------------
# 1. Check input parameters (exits on error)
#------------------------------------------------------------------------------

echo "Started at: $(date "+%Y-%m-%d %H:%M:%S")"

# 1.1 Check DOMAINS_LIST:
#------------------------------------------------------------------------------
if [[ ! -z $DOMAINS_LIST ]]; then

    echo "INFO: Querying for Virtual Machines listed in \$DOMAINS_LIST via libvirt..."
    for domain in ${DOMAINS_LIST//,/ }; do

        if [[ $(domain_exists $domain) == yes ]]; then

            # Domain exists, checks for drives that can actually be backed up
            drives_list=($(domain_drives_list $domain))
            if [[ ! -z ${drives_list[@]} ]]; then

                # Does have drives able to be backed up. Checks if such disk images are reachable inside the container:
                images_list=($(domain_img_paths_list $domain))
                for image in ${images_list[@]}; do

                    if [[ -f $image ]]; then

                        # Disk images found. Check if has read/write permissions:
                        if [[ -r $image ]] && [[ -w $image ]]; then

                            # All images are reachable. Add to list for next checkup:
                            CHECK_VMS_LIST+=($domain)
                        else
                            FAILED_VMS_LIST+=($domain)
                            echo "ERROR: '$domain': '$image': Permission issues (cannot read or write)"
                        fi
                    else
                        FAILED_VMS_LIST+=($domain)
                        echo "ERROR: '$domain': '$image': Not found"
                    fi
                done
            else
                IGNORED_VMS_LIST+=($domain)
                echo "WARNING: '$domain': No drives that can be backed up (ignored)"
            fi
        else
            IGNORED_VMS_LIST+=($domain)
            echo "WARNING: '$domain': Does not exist or is a transient domain (ignored)"
        fi
    done

    if [[ ! -z ${FAILED_VMS_LIST[@]} ]]; then

        echo "ERROR: Issues detected with VM(s) '${FAILED_VMS_LIST[@]}' that need to be solved before to run this container again."
    elif [[ -z ${CHECK_VMS_LIST[@]} ]]; then

        echo "ERROR: No suitable Virtual machines to be backed up."
    else
        # When no VM failed the test AND remained VMs to check (not ignored), then domain_list check is successful:
        domains_list_status="OK"

        echo "INFO: VMs '${CHECK_VMS_LIST[@]}' able for further checking and monitoring"
    fi
else
    echo "ERROR: Environment variable 'DOMAINS_LIST' not set."
fi

# 1.2 Check BACKUPS_MAIN_PATH
#------------------------------------------------------------------------------

if [[ ! -z $BACKUPS_MAIN_PATH ]]; then

    if  [[ -d $BACKUPS_MAIN_PATH ]]; then

        # $BACKUPS_MAIN_PATH found
        if  [[ -r $BACKUPS_MAIN_PATH ]] && [[ -w $BACKUPS_MAIN_PATH ]]; then

            # $BACKUPS_MAIN_PATH has read/write permissions. backup check is successful:
            backups_main_path_status="OK"

            echo "INFO: Path: '$BACKUPS_MAIN_PATH' found (with right read/write permissions)"
        else
            echo "ERROR: Backups main path: '$BACKUPS_MAIN_PATH': Permission issues (cannot read or write)"
        fi
    else
        echo "ERROR: Backups main path: '$BACKUPS_MAIN_PATH': Not found or not a directory"
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
        remote_backups_main_path_status=$(ssh_command $remote_server "if [[ ! -e $remote_backups_main_path ]]; then; mkdir -p $remote_backups_main_path; [[ $? == 0 ]] && echo CREATED; elif [[ -d $remote_backups_main_path ]] && [[ -r $remote_backups_main_path ]] && [[ -w $remote_backups_main_path ]]; then; echo OK; fi")

        if [[ $remote_backups_main_path_status == OK ]]; then

            echo "INFO: Remote endpoint: $REMOTE_BACKUPS_MAIN_PATH exists and is usable for backups"
        elif [[ $remote_backups_main_path_status == CREATED ]]; then

            echo "INFO: Remote endpoint: $REMOTE_BACKUPS_MAIN_PATH created"
        else
            echo "ERROR: Remote endpoint: $REMOTE_BACKUPS_MAIN_PATH has not insufficient read/write permissions or is not a directory"
        fi

    else
        echo "ERROR: Connection with $remote_server failed with status $remote_server_status"
    fi
else
    echo "ERROR: Incorrect syntax for '$REMOTE_BACKUPS_MAIN_PATH'"
fi

# 1.4 TO DO: Check CRON_SCHEDULE format:
#------------------------------------------------------------------------------
#------------------------------------------------------------------------------
# 2. Only when input parameters doesn't require to restart the container, it continues the rest of the checks:
#------------------------------------------------------------------------------

if [[ $domains_list_status == OK ]] && [[ $backups_main_path_status == OK ]] && [[ ! -z $remote_backups_main_path_status ]]; then

    # 2.1 Create/update Cron task for VMs to be (progressively) included in $scheduled_backups_list:
    #------------------------------------------------------------------------------

    echo "INFO: Deploying Cron task..."

    crontab_file="/tmp/crontab"
    scheduled_logs_file="/logs/scheduled_backups.log"

    [[ -z $CRON_SCHEDULE ]] && { CRON_SCHEDULE="@daily"; echo "INFO: Environment variable 'CRON_SCHEDULE' is not set. Using default parameter ($CRON_SCHEDULE)"; }

    # Silently deletes any previous cron task:
    &> /dev/null crontab -r

    # Parses the actual cron task needed to run to $crontab_file:
    cat << end_of_crontab > $crontab_file
# On run, performs incremental bakups for all VMs in SCHEDULED_BACKUPS_LIST at the moment of its execution:
SHELL=/bin/bash
$CRON_SCHEDULE ./virtnbdbackup-auto "\$SCHEDULED_BACKUPS_LIST" &>> $scheduled_logs_file"
end_of_crontab

    # Sets the cron task:
    crontab $crontab_file

    # Finally, runs cron and sends to background:
    cron -f -l -L2 &

    # 2.2 Check if OS is Unraid and it has just been restarted (checking backups under this scenario assumes missing checkpoints / broken backup chains:
    #------------------------------------------------------------------------------

    if [[ $(os_is_unraid) == yes ]]; then

        echo "INFO: OS Unraid detected. Scanning for checkpoints..."

        for domain in ${CHECK_VMS_LIST[@]}; do

            # Looks for checkpoints in all VMs, only stopping if it finds something
            # (does not rely on expose checkpoints dir inside the container):
            if [[ ! -z $(domain_checkpoint_list $domain) ]]; then

                checkpoints_found="yes"
                break
             fi
        done

        if [[ -z $checkpoints_found ]]; then

            RESTARTED_SERVER="true"
            echo "INFO: Server appears to have been restarted recently or no backup has been ever performed. Checking for running Virtual machines..."

            i=0
            for domain in ${CHECK_VMS_LIST[@]}; do

                if [[ $(domain_state $domain) != "shut off" ]]; then

                    if [[ ! -z $RESTART_VMS_IF_REQUIRED ]]; then

                        domain_shutdown $domain
                        if [[ $? -eq 0 ]]; then

                            # Added VMs list that were on and had to be shutdown temporarily in order to perform further checks:
                            POWEREDOFF_VMS_LIST+=($domain)
                        else

                            # VM Delayed too much without being shutdown
                            ACTION_REQUIRED_VMS_LIST+=($domain)
                            unset CHECK_VMS_LIST[$i]
                        fi
                    else
                        # Uer needs to shutdown this VM before to perform any further checks o backups:
                        ACTION_REQUIRED_VMS_LIST+=($domain)
                        unset CHECK_VMS_LIST[$i]
                    fi
                else
                    ((i++))
                fi
            done

            # Notifies the user bout the result and if needs to perform further actions (VMs are temporarily ignored, but checked periodically if state changes):
            [[ ! -z $POWEREDOFF_VMS_LIST ]] && echo "INFO: VM(s) '${POWEREDOFF_VMS_LIST[@]}' Into automatic Powercycle for further checks (will be powered on shortly)"
            [[ ! -z $ACTION_REQUIRED_VMS_LIST ]] && echo "WARNING: ACTION REQUIRED for '${ACTION_REQUIRED_VMS_LIST[@]}':  Perform a manual Shut down of VM(s) for further checks (temporarily ignored)"

        else
            RESTARTED_SERVER="false"
        fi
    fi

    # 2.3 Perform an initial check of VMs that are -in theory- able to be backed up:
    #------------------------------------------------------------------------------

    echo "INFO: Initial check of VM(s) '${CHECK_VMS_LIST[@]}' in progress..."
    check_vms_patch "CHECK_VMS_LIST" "${CHECK_VMS_LIST[@]}"

    if [[ ! -z ${POWEREDOFF_VMS_LIST[@]} ]]; then

        echo "INFO: Powering on previously shut down, and configured for autostart Virtual machine(s)..."
        for $domain in ${POWEREDOFF_VMS_LIST[@]}; do

            virsh start $domain
        done
    fi

    if [[ ! -z ${CHECK_BACKUPS_LIST[@]} ]]; then

        echo "INFO: Initial check of backup chains(s) of VM(s) '${CHECK_BACKUPS_LIST[@]}' in progress..."
        check_backups "CHECK_BACKUPS_LIST" "${CHECK_BACKUPS_LIST[@]}"
    fi

    # 2.4 Power on VMs marked for autostart, or shut down to perform the initial chacks:
    #------------------------------------------------------------------------------

    #------------------------------------------------------------------------------
    #if [ ! -z ${FULL_BACKUPS_LIST[@]} ]]; then

        #echo "INFO: Creation of new backup chain(s) for VM(s) '${FULL_BACKUPS_LIST[@]}' in progress (this may take some time...)"
        #create_backup_chain ${FULL_BACKUPS_LIST[@]}


    #fi


    # 2.4 Begin monitorization for changes in VMs moved to ACTION_REQUIRED_VMS_LIST,
    # Until SIGSTOP if received, then closes all processes and goes off.
    #------------------------------------------------------------------------------
else
    echo "ERROR: Could not start due to errors on input parameters. Exited."
    echo "#-----------------------------------------------------------------------------------------------------"
fi
    #------------------------------------------------------------------------------
    # The End.
