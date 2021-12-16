#!/bin/bash

: << 'end_of_specs'
#------------------------------------------------------------------------------
# ENV:
#------------------------------------------------------------------------------

DOMAINS_LIST
BACKUPS_MAIN_PATH
REMOTE_BACKUPS_MAIN_PATH
RESTART_VMS_IF_REQUIRED

MAX_BACKUP_CHAINS_KEEP
BACKUP_COMPRESSION

MAX_ALLOWED_MEMORY
MAX_ATTEMPTS
WAIT_TIME

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
PROCEDURE:
#------------------------------------------------------------------------------


1. Check parameters:
#------------------------------------------------------------------------------
    is DOMAINS_LIST defined?
    yes
        filter transient, diskless and unexistent domains (Warns the user about such VMs if any, it will be just ignored)
        add the rest to check_vms_list, if no VMs in check_vms_list, it will fail with error: 'None of the VMs in DOMAINS_LIST can be backed up.'
    no
        It will fail with error: 'undefined DOMAINS_LIST'

    For VMs in check_vms_list:
        Were ALL specified image disks (if any) in DOMAINS_LIST found?
        yes
            are ALL rw?
            yes
                add VM to check_VMs list
            no
                add the image(s) to permission_issues_list
                It will fail with error: 'Permission issues with image(s) in permission_issues_list)'
        no
            add the image(s) not found to not_found_list
            It will fail with error: ('Not found image(s) in not_found_list)'

    is BACKUPS_MAIN_PATH defined?
    yes
        is it a r/w folder?
        yes
            will be used as main path for backups
        no
            It will fail with error: 'Permission issues with BACKUPS_MAIN_PATH'
    no
        it will fail with error 'Undefined BACKUPS_MAIN_PATH'

    REMOTE_BACKUPS_MAIN_PATH is defined?
    yes
        its syntax is correct?
        yes
            remote server is reachable?
            yes
                REMOTE_BACKUPS_MAIN_PATH exists on the remote server?
                yes
                    is r/w?
                    yes
                        It will be used as main path for remote backups
                    no
                        It will fail with error: 'permission issues on REMOTE_BACKUPS_MAIN_PATH'
                no
                    Attempts to create REMOTE_BACKUPS_MAIN_PATH remotely
                    Success?
                    yes
                        It will be used as main path for remote backups
                    no
                        It will fail with error: 'REMOTE_BACKUPS_MAIN_PATH doesn't exist and can't be created on the remote server'
            no
                It will fail with error: 'Remote server is unreachable'
        no
            It will fail with error 'Incorrect syntax for REMOTE_BACKUPS_MAIN_PATH'
    no
        Don't use REMOTE_BACKUPS_MAIN_PATH at all

    OS is Unraid AND /var/lib/libvirt/qemu/checkpoint is empty?
    yes
        Any VM in check_vms_list is ON?
        yes
            It will fail with error: 'UnRaid: Server has just been restarted (or 1st time run): Power OFF all VMs you plan to backup, disable autostart and restart the container.'
        no
            restarted_server=true
    no
        restarted_server=false

    Any error occured above OR no VMs in check_vms_list?
        yes
            List all the errors and exit
        no
            2. Check VMs:
            #------------------------------------------------------------------------------
            For VMs in check_vms_list:
                is VM CURRENTLY patched for incremental backups?
                yes
                    move VM to check_backups_list
                    break the loop.
                no
                    is VM ON?
                    yes
                        is VM patched for incremental backups in INACTIVE state?
                        yes
                            RESTART_VMS_IF_REQUIRED?
                            yes
                                Alert the user: 'VM is about to get a full power cycle'
                                powercycle the VM
                                Success?
                                yes
                                    break the loop.
                                no
                                    Alert the user: 'ACTION REQUIRED: VM powercycle was not successful. Check the VM for possible issues'
                                    move VM to VMS_ISSUES_LIST
                                    break the loop.
                            no
                                Alert the user: 'ACTION REQUIRED: 'VM requires a full power cycle in order to create any backup from it'
                                move VM to VMS_ISSUES_LIST
                                break the loop.
                        no
                            patch the VM
                            patch successful?
                            yes
                                restart the loop.
                            no
                                Alert the user about the issue: 'ACTION REQUIRED: Unknown error when attempting to patch this VM. Redefine the VM, and keep it off.'
                                break the loop.
                    is VM set to autostart?
                    yes
                        set autostart to off
                        Remind the user that VMs to be backed up must be kept with autostart off

            Any VM in check_backups_list?
            yes
            3. Check Backups:
            #------------------------------------------------------------------------------
            For ALL VMs in check_backups_list:
                has ongoing local backup AND backup_integrity is ok?
                yes
                    restarted_server?
                    yes
                        LOCAL BACKUP checkpoints = image bitmaps in ALL disks?
                        yes
                            move VM to SCHEDULED_BACKUPS_LIST
                            break the loop.
                        no
                            Check for disk image(s) bitmaps, delete if any
                            move VM to FULL_BACKUPS_LIST
                            break the loop.
                    no
                        is VM ON?
                        yes
                            move VM to SCHEDULED_BACKUPS_LIST
                            break the loop.
                        no
                            QEMU checkpoints = image bitmaps in ALL disks?
                            yes
                                move VM to SCHEDULED_BACKUPS_LIST
                                break the loop.
                            no
                                Delete checkpoint metadata, if any
                                Delete image bitmaps, if any
                                move VM to FULL_BACKUPS_LIST
                                break the loop.
                no
                    Dummy folder OR failed full backup
                    yes
                        delete backup
                    move VM to FULL_BACKUPS_LIST


            4. Initialize:
            #------------------------------------------------------------------------------
            For each VM in AUTOSTART_VMS_LIST
                Is VM OFF?
                yes
                    start the VM

            Is Cron task set for SCHEDULED_BACKUPS_LIST?
            yes
                Current cron schedule != CRON_SCHEDULE?
                yes
                    update cron task with current CRON_SCHEDULE
            no
                Create a new cron task with current CRON_SCHEDULE

            5. Process slacking backup chains:
            #------------------------------------------------------------------------------
            sleep for DELAY_BACKUP_CHAIN_START

            For VMs in FULL_BACKUPS_LIST
                run a full backup chain procedure
                Success?
                yes
                    move VM to SCHEDULED_BACKUPS_LIST
                no
                    Alert the user about the issue: 'ACTION REQUIRED: Unknown error while attempting to create a full backup chain of this VM'
                    move VM to VMS_ISSUES_LIST

                For VMs in RETRIEVE_BACKUPS_LIST
                    Restore local backup chain from remote endpoint
                    Success?
                    yes
                        move VM to SCHEDULED_BACKUPS_LIST
                    no
                        Alert the user about the issue: 'ACTION REQUIRED: Communication error while attempting to retrieve a full backup chain of this VM from remote endpoint'
                        move VM to VMS_ISSUES_LIST

            # From this point, monitoring VMS_ISSUES_LIST for changes (and trigger correspondent actions) would be viable.
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

    # Lists to add VMs is something fails (and summarize at the end):
    local domain_shutdown_failed=()
    local vm_patch_failed=()

    # Processes each VM. Looks for patch and applies actions as required:
    local i=0
    for domain in ${vm_list_content[@]}; do


        # For each VM, the loop repeats itself as needed until a VM has been successfully patched, or not:
        while true; do
            if [ -z ${domain_shutdown_failed[$i]} ] && [ -z ${vm_patch_failed[$i]} ]; then

                # First loop iteration, or no errors has occured:
                if [ $(domain_is_patched $domain --current) == yes ]; then

                    # VM is patched. Move to $check_backups_list (from wherever is listed):
                    check_backups_list+=($domain)

                    [ $vm_list_name == check_vms_list ] && unset check_vms_list[$(item_position $domain $vm_list_name)]

                    [ $vm_list_name == action_required_vms_list ] && unset action_required_vms_list[$(item_position $domain $vm_list_name)]

                    # Exits the loop:
                    break

                elif [ $(domain_is_patched $domain --inactive) == yes ]; then

                    # VM is (presumably) running and was patched before, but needs a power cycle so changes can be applied:

                    if [ ! -z $RESTART_VMS_IF_REQUIRED ]; then

                        # When permission is granted, and past iteration over the VM haven't triggered errors, attempts shuts down the VM temporarily:
                        domain_shutdown $domain

                        # Success. Include into powered off VMs list
                        # Fail: Triggers control variable for next iteration:
                        [[ $? -eq 0 ]] && poweredroff_vms_list+=($domain) || domain_shutdown_failed+=($domain)
                    else
                        # User must shutdown $domain manually:
                        domain_shutdown_failed+=($domain)
                    fi

                        # Restarts the loop (checks VM again under changed conditions):
                        continue
                else
                    # VM is not patched (or lost its patch at some point.)
                    # Apply the patch for incremental backup:
                    vm-patch $domain --quiet

                    # Fail: Triggers control variable for next iteration:
                    [[ $? -ne 0 ]] vm_patch_failed+=($domain)

                    # Restarts the loop (checks VM again under changed condition):
                    continue
                fi
            else

                # Cannot perform any actions on this VM.

                if [ $vm_list_name == check_vms_list ]; then

                    # Move from $check_vms_list to $action_required_vms_list:
                    action_required_vms_list+=($domain)
                    unset check_vms_list[$(item_position $domain $vm_list_name)]
                fi
                    # Exits the loop:
                    break
            fi
        done
        # Increases the index to check the next VM:
        ((i++))
    done

    # Depending on the results, shows a brief summary with VMs with changed state or actions if required:
    [ ! -z ${check_backups_list[@]} ] && \

        echo "INFO: '${check_backups_list[@]}': On queue for backup chain check"

    [ ! -z ${poweredroff_vms_list[@]} ] && \

        echo "INFO: '${poweredroff_vms_list[@]}': Temporarily shutdown to apply incremental backup patch (will be powered on shortly)"

    [ ! -z ${domain_shutdown_failed[@]} ] && \

        echo "WARNING: ACTION REQUIRED for '${domain_shutdown_failed[@]}': Powercycle to apply incremental backup patch (temporarily skipped)"

    [ ! -z ${vm_patch_failed[@]} ] && \

        echo "WARNING: ACTION REQUIRED for '${vm_patch_failed[@]}': 'Inconsistent settings, could not patch for incremental bakups. If this isn't expected, Run 'virsh edit <vm-name>' or use your Graphic UI to verify XML definitions (temporarily skipped)"

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

    local backup_chain_status=()

    # Processes each VM. Looks for patch and applies actions as required:
    local i=0
    for domain in ${vm_list_content[@]}; do

        while true; do

            if [ ! -f $BACKUPS_MAIN_PATH/$domain/$domain.cpt ] || \
               [ ! -d $BACKUPS_MAIN_PATH/$domain/checkpoints ]; then

                # Discard dummy backups immediately:
                rm -rf $BACKUPS_MAIN_PATH/$domain
                continue

            elif  [ ! -z $(find $BACKUPS_MAIN_PATH/$domain -type f -name "*.partial") ]; then

                if [[ $(backup_checkpoint_list $BACKUPS_MAIN_PATH/$domain) -le 1 ]]; then

                    # Also discard aborted full backups:
                    rm -rf $BACKUPS_MAIN_PATH/$domain
                    continue
                else
                    # Mark backup as corrupted and continue
                fi
            else
            fi
        done
    done
}

#------------------------------------------------------------------------------
# Internal global variables and common functions are managed via this script:
source ./functions
#------------------------------------------------------------------------------
# 1. Check input parameters (exits on error)
#------------------------------------------------------------------------------

# 1.1 Check DOMAINS_LIST:
#------------------------------------------------------------------------------

if [ ! -z $DOMAINS_LIST ]; then

    echo "INFO: Querying for domains in \$DOMAINS_LIST via libvirt..."
    for domain in ${DOMAINS_LIST//,/ }; do

        if [ $(domain_exists $domain) == yes ]; then

            # Domain exists, checks for drives that can actually be backed up
            drives_list=($(domain_drives_list $domain))
            if [ ! -z ${drives_list[@]} ]; then

                # Does have drives able to be backed up. Checks if such disk images are reachable inside the container:
                images_list=($(domain_img_paths_list $domain))
                for image in ${images_list[@]}; do

                    if [ -f $image ]; then

                        # Dick images found. Check if has read/write permissions:
                        if [ -r $image ] && [ -w $image ]; then

                            # All images are reachable. Add to list for next checkup:
                            check_vms_list+=($domain)
                            message=""
                        else
                            failed_vms_list+=($domain)
                            message="ERROR: '$domain': '$image': Permission issues (cannot read or write)"
                        fi
                    else
                        failed_vms_list+=($domain)
                        message="ERROR: '$domain': '$image': Not found"
                    fi
                done
            else
                ignored_vms_list+=($domain)
                message="WARNING: '$domain': No drives that can be backed up (ignored)"
            fi
        else
            ignored_vms_list+=($domain)
            message+="WARNING: '$domain': Does not exist or is a transient domain (ignored)"
        fi

        [ ! -z $message ] && echo $message
    done

    if [ ! -z $failed_vms_list ]; then

        echo "ERROR: One or more domains (${failed_vms_list[@]}) have issues that need to be solved before to run this container again."
    elif [ -z $check_vms_list ]; then

        echo "ERROR: No suitable domains to be backed up."
    else
        # When no VM failed the test AND remained VMs to check (not ignored), then domain_list check is successful:
        domains_list_status="OK"
        message=""

else
    echo "ERROR: Environment variable 'DOMAINS_LIST' is undefined."
fi

# 1.2 Check BACKUPS_MAIN_PATH
#------------------------------------------------------------------------------

if [ ! -z $BACKUPS_MAIN_PATH ]; then

    echo "INFO: Checking for BACKUPS_MAIN_PATH..."
    if  [ -d $BACKUPS_MAIN_PATH ]; then

        # $BACKUPS_MAIN_PATH found
        if  [ -r $BACKUPS_MAIN_PATH ] && [ -w $BACKUPS_MAIN_PATH ]; then

            # $BACKUPS_MAIN_PATH has read/write permissions. backup check is successful:
            backups_main_path_status="OK"
        else
            message="ERROR: Backups main path: '$BACKUPS_MAIN_PATH': Permission issues (cannot read or write)"
        fi
    else
        message="ERROR: Backups main path: '$BACKUPS_MAIN_PATH': Not found or not a directory"
    fi
else
    echo "ERROR: Environment variable 'BACKUPS_MAIN_PATH' is undefined."
fi

# 1.3 Check REMOTE_BACKUPS_MAIN_PATH
#------------------------------------------------------------------------------

if [ -z $REMOTE_BACKUPS_MAIN_PATH ]; then

    remote_backups_main_path_status="OK"
    "INFO: Environment variable REMOTE_BACKUPS_MAIN_PATH is undefined. No remote backup endpoint will be used"

elif [ $REMOTE_BACKUPS_MAIN_PATH == *@*:/* ]; then

    # Apparently includes correct remote login and path. Separates ssh login from remote path:
    remote_server=$(echo $REMOTE_BACKUPS_MAIN_PATH | cut -d':' -f1)
    remote_backups_main_path=$(echo $REMOTE_BACKUPS_MAIN_PATH | cut -d':' -f2)

    # Attempts to comunicate with the remote host:
    ssh_command $remote_server "exit 0"
    remote_server_status=$?

    if [ $remote_server_status == 0 ]; then

        # Attempts to perform similar checks as with $BACKUPS_MAIN_PATH, except it only returns "OK" if there was success:
        remote_backups_main_path_status=$(ssh_command $remote_server "if [ ! -e $remote_backups_main_path ]; then; mkdir -p $remote_backups_main_path; [ $? == 0 ] && echo CREATED; elif [ -d $remote_backups_main_path ] && [ -r $remote_backups_main_path ] && [ -w $remote_backups_main_path ]; then; echo OK; fi")

        if [ $remote_backups_main_path_status == OK ]; then

            echo "INFO: Remote endpoint: $REMOTE_BACKUPS_MAIN_PATH exists and is usable for backups"
        elif [ $remote_backups_main_path_status == CREATED ]; then

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

#------------------------------------------------------------------------------
# 2. Only when input parameters doesn't require to restart the container, it continues the rest of the checks:
#------------------------------------------------------------------------------

if [ $domains_list_status == OK ] && [ $backups_main_path_status == OK ] && [ ! -z $remote_backups_main_path_status ]; then

    # 2.1 Check if OS is Unraid and it has just been restarted (checking backups under this scenario assumes missing checkpoints / broken backup chains:
    #------------------------------------------------------------------------------
    if [ $(os_is_unraid) == yes ]; then

        echo "INFO: OS Unraid detected"
        for domain in ${check_vms_list[@]}; do

            # Looks for checkpoints in all VMs, only stopping if it finds something
            # (does nto rely on expose checkpoints dir inside the container):
            if [ ! -z $(domain_checkpoint_list $domain) ];

                checkpoints_found="true"
                break
            else
                checkpoints_found="false"
            fi
        done

        if [ $checkpoints_found == true ]; then

            restarted_server="true"
            echo "INFO: Unraid host has just been restarted recently or no backups has been performed yet on the server. Checking for running domains..."

            i=0
            for domain in ${check_vms_list[@]}; do

                if [ $(domain_state $domain) != "shut off" ]; then

                    if [ ! -z $RESTART_VMS_IF_REQUIRED ]; then

                        domain_shutdown $domain
                        if [[ $? -eq 0 ]]

                            # Added VMs list that were on and had to be shutdown temporarily in order to perform further checks:
                            poweredroff_vms_list+=($domain)
                        else

                            # VM Delayed too much without being shutdown
                            action_required_vms_list+=($domain)
                            unset check_vms_list[i]
                    else
                        # Uer needs to shutdown this VM before to perform any further checks o backups:
                        action_required_vms_list+=($domain)
                        unset check_vms_list[i]
                    fi
                else
                    ((i++))
                fi
            done

            # Notifies the user bout the result and if needs to perform further actions (VMs are temporarily ignored, but checked periodically if state changes):

            [ ! -z $poweredroff_vms_list ] && echo "WARNING: Virtual machine(s) '${poweredroff_vms_list[@]}' has been temporarily shutdown in order to verify its correspondent backup chain integrity"

            [ ! -z $action_required_vms_list ] && echo "WARNING: ACTION REQUIRED: Virtual machine(s) '${action_required_vms_list[@]} need to be SHUTDOWN in order to verify its correspondent backup chain integrity (state will be checked periodically)"

        else
            restarted_server="false"
        fi

    fi
# Rest of the initial checkup between these lines:
#------------------------------------------------------------------------------
        # Check / apply VM patch:
        check_vms_patch "check_vms_list" "${check_vms_list[@]}"

        # When any VM is, or has been successfully patched, Check VM backups:
        [ ! -z ${check_backups_list[@]} ] && check_backups "check_backups_list" "${check_backups_list[@]}"
#------------------------------------------------------------------------------
fi

# Create/update the scheduler
# Begin monitorization (user action required and slack VMs)
# Awaits for SIGSTOP, then closes all processes and goes off.
#------------------------------------------------------------------------------
