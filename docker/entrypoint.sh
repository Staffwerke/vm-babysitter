#!/bin/bash

: << 'end_of specs'
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
                    REMOTE_BACKUPS_MAIN_PATH is set AND has ongoing remote backup AND backup_integrity is ok?
                    yes
                        restarted_server?
                        yes
                            REMOTE BACKUP checkpoints = image bitmaps in ALL disks?
                            yes
                                move VM to RETRIEVE_BACKUPS_LIST
                                break the loop.
                            no
                                Check for disk image(s) bitmaps, delete if any
                                move VM to FULL_BACKUPS_LIST
                                break the loop.
                        no
                            is VM ON?
                                yes
                                    QEMU checkpoints = REMOTE backup checkpoints?
                                    yes
                                        move VM to RETRIEVE_BACKUPS_LIST
                                        break the loop.
                                    no
                                        move VM to FULL_BACKUPS_LIST
                                        break the loop.
                                no
                                    QEMU checkpoints = REMOTE backup checkpoints = image bitmaps in ALL disks?
                                    yes
                                        move VM to RETRIEVE_BACKUPS_LIST
                                        break the loop.
                                    no
                                        Delete checkpoint metadata, if any
                                        Delete image bitmaps, if any
                                        move VM to FULL_BACKUPS_LIST
                                        break the loop.
                    no
                        restarted_server?
                        yes
                            Check for disk image(s) bitmaps, delete if any
                            move to FULL_BACKUPS_LIST
                            break the loop.
                        no
                            is VM ON?
                            yes
                                move to FULL_BACKUPS_LIST
                                break the loop.
                            no
                                Delete checkpoint metadata, if any
                                Delete image bitmaps, if any
                                move to FULL_BACKUPS_LIST
                                break the loop.

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
end_of specs

#------------------------------------------------------------------------------
# All variables and functions are managed via this script:
source ./functions.sh

#------------------------------------------------------------------------------
# Checks user parameters and shows on screen results
# Returns '0' if everything was successful and '1' if something failed:
#------------------------------------------------------------------------------
echo "INFO: Checking parameters..."

check_parameters_status=1

# Checks for domains in $DOMAINS_LIST
if [ -z $DOMAINS_LIST ]; then

    echo "ERROR: ENV \$DOMAINS_LIST was not provisioned!"
else

    # Parses $DOMAINS_LIST into a local variable separated by spaces:
    domains_list=${DOMAINS_LIST//,/ }

    echo "INFO: Querying for domains in \$DOMAINS_LIST via libvirt..."

    # Grabs the list of all persistent domains in host:
    host_domains_list=$(virsh list --all --name --persistent)

    # Initial search value is zero:
    domain_search_failed=0

    for domain in $domains_list; do

        # Searches for each domain and notifies about success/fail:
        [ $(domain_exists $domain) == yes ] && echo "INFO: Domain $domain found" || { ((domain_search_failed++)); echo "WARNING: Domain $domain not found, or is a transient domain"; }
    done

    # Sets $domain_search_status as OK if all domains were found:
    [ $domain_search_failed == 0 ] && domain_search_status="OK"
fi

# Checks $BACKUPS_MAIN_PATH, notifies about errors:
# (It is assumed $BACKUPS_MAIN_PATH exists, since it's automatically created by Docker)
if  [ -r $BACKUPS_MAIN_PATH ] && [ -w $BACKUPS_MAIN_PATH ]; then

    backup_main_path_status="OK"
    echo "INFO: Directory $BACKUPS_MAIN_PATH is accessible"

else
    cause_of_fail=()
    [ ! -d $BACKUPS_MAIN_PATH ] && cause_of_fail+=('not a directory')
    [ ! -r $BACKUPS_MAIN_PATH ] && cause_of_fail+=('unreadable')
    [ ! -w $BACKUPS_MAIN_PATH ] && cause_of_fail+=('unwritable')

    echo "ERROR: Issues detected with $BACKUPS_MAIN_PATH (${cause_of_fail[@]// /,})"
fi

# Checks $REMOTE_BACKUPS_MAIN_PATH: Discards syntax errors, checks if accessible, looks for folder permissions on the remote end:
if [ -z $REMOTE_BACKUPS_MAIN_PATH ]; then

    remote_backup_main_path_status="OK"
    "INFO: ENV \$REMOTE_BACKUPS_MAIN_PATH was not passed. No remote endpoint transfers will be performed"

elif [ $REMOTE_BACKUPS_MAIN_PATH == *@*:/* ]; then

    # Apparently includes correct remote login and path. Separates ssh login from remote path:
    remote_server=$(echo $REMOTE_BACKUPS_MAIN_PATH | cut -d':' -f1)
    remote_backup_main_path=$(echo $REMOTE_BACKUPS_MAIN_PATH | cut -d':' -f2)

    # Attempts to comunicate with the remote host:
    ssh_command $remote_server "exit 0"
    remote_server_status=$?

    if [ $remote_server_status == 0 ]; then

        # Attempts to perform similar checks as with $BACKUPS_MAIN_PATH, except it only returns "OK" if there was success:
        remote_backup_main_path_status=$(ssh_command $remote_server "if [ ! -e $remote_backup_main_path ]; then; mkdir -p $remote_backup_main_path; [ $? == 0 ] && echo OK; elif [ -d $remote_backup_main_path ] && [ -r $remote_backup_main_path ] && [ -w $remote_backup_main_path ]; then; echo OK; fi")

        [ $remote_backup_main_path_status == OK ] && echo "INFO: Remote endpoint: $REMOTE_BACKUPS_MAIN_PATH is accessible (directory just created or already exists)" || echo "ERROR: Issues detected with $REMOTE_BACKUPS_MAIN_PATH (is not a folder or insufficient read/write permissions)"

    else
        echo "ERROR: Connection with $remote_server failed with status $remote_server_status"
    fi
else
    echo "ERROR: '$REMOTE_BACKUPS_MAIN_PATH' has bad syntax formation. Aborted."
fi

if [ $domain_search_status == OK ] && { $backup_main_path_status == OK ] && [ $remote_backup_main_path_status == OK ]; then

    check_parameters_status=0

else
    echo "ERROR: Some of the input parameters is incorrect or another error was found. Please check the logs above to determine the issue."
fi

if [ $check_parameters_status == 0 ]; then;

    #------------------------------------------------------------------------------
    # Checks VMs in $domains_list, patches it for incremental backups as needed:
    #------------------------------------------------------------------------------
    echo "INFO: Checking Virtual Machines..."

    check_vms_status=1

    # Verifies and Attempts to patch every non-patched domain in $domains_list:
    for domain in $domains_list; do

        if [ $(patched_domain $domain) == no ]; then

            # Domain definitions don't allow incremental backups. So it will be patched:
            # TO DO: Convert this into an internal function.
            vm-patch $domain

            if [ $? != 0 ] ; then

                # It was unable to patch at least one domain:
                failed_patch=1

            elif [ $(domain_state $domain) != "shut off" ]; then

                # Domain was patched, but needs a power cycle in order to apply changes:
                powercycle_domains_list+=($domain)
            fi
        fi
    done

    if [ -z $failed_patch ]; then

        # All VMs were patched successfully
        # Checks for domains which are in need of a power cycle:
        if [ -z $restart_domains_list ]; then

            # No one needs for a power cycle, everything is ready to go:
            check_vms_status=0

        elif [ $AUTO_VM_RESTART == yes ]; then

            echo "INFO: \$AUTO_VM_RESTART is set to '$AUTO_VM_RESTART'. It will attempt to power cycle the following VMS: '${powercycle_domains_list[@]}' now!"

            # Restart VMs which are in need of apply the patch:
            for domain in ${powercycle_domains_list[@]}; do

                # Attempts to powercycle $domain:
                powercycle_domain $domain
                if [ $? !=0 ] && powercycle_failed=1
            done

            # When no VM had issues restarting, all of them are ready to go:
            [ -z $powercycle_failed ] && check_vms_status=0
        else
            echo "WARNING: User action required: Power Cycle the following VMs: '${powercycle_domains_list[@]}' and then restart the container (or add '-e \$AUTO_VM_RESTART=yes')"
        fi
    else
        echo "ERROR: At least one domain could not be patched correctly. Check the logs above to determine the possible cause."
    fi
fi

if [ $check_vms_status == 0 ]; then

    # Existing backups
    check_backups
    if [ $? == 0 ]; then

        # If some, or no VM has a full backup chain, will create those first:
        [ ! -z $full_backup_domains_list ] && create_backup_chain

        # Launches cron task to perform SCHEDULED_BACKUPS_LIST:
        scheduled_backups
    fi
fi
