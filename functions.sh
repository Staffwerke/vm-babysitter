#!/bin/bash

# Checks for backup integrity of a given domain ($1)
# It assumes the backup folder exists and is accessible
# Returns: a message string which determines the result:
#'HEALTHY' (checkpoints in $domain vs. curent backup match)
#'UNHEALTHY' (checkpoints in $domain vs. current backup mismatch!)
#'BROKEN' (current backup for $domain has no checkpoints registry!)
#'UNCHECKED' ($domain has no checkpoints to compare with its current backup)
#------------------------------------------------------------------------------
check_backup_integrity()
{

local check_backup_integrity_status

local domain=$1
local domain_checkpoints_list=($(virsh checkpoint-list $domain --name --topological))
local domain_backup_path=$BACKUP_MAIN_PATH/$domain

if [ ! -f $domain_backup_path/$domain.cpt ] || [ ! -d $domain_backup_path/checkpoints ]

    check_backup_integrity_status="BROKEN"

elif [ -z ${domain_checkpoints_list[@]} ]; then

    check_backup_integrity_status="UNCHECKED"

else

    # Looks for all checkpoints inside the registry:
    local backup_checkpoints_list=(`cat $domain_backup_path/$domain.cpt | sed sed -e 's/\[//g' -e 's/\"//g' -e 's/,//g' -e 's/\]//g'`)

    # Then compares it with domain's checkpoints:
    [ "${domain_checkpoints_list[@]}" == "${backup_checkpoints_list[@]}" ] && check_backup_integrity_status="HEALTHY" || check_backup_integrity_status="UNHEALTHY"
fi

echo $check_backup_integrity_status

}

# Renames backups of a given domain ($1) according to timestamp,
# and deletes old backups chains except given by $MAX_BACKUP_CHAINS_KEEP
#------------------------------------------------------------------------------
archive_backup()
{
local domain=$1

local timestamp=$(date '+%Y-%m-%d.%H:%M:%S')
echo "INFO: Archiving latest known backup for $domain as $BACKUP_MAIN_PATH/$domain.$timestamp"
mv $BACKUP_MAIN_PATH/$domain $BACKUP_MAIN_PATH/$domain.$timestamp

if [[ $MAX_BACKUP_CHAINS_KEEP -gt 0 ]]; then

    # Position of the first folder to delete, ordered from most recent timestamp
    local index=$( expr $MAX_BACKUP_CHAINS_KEEP + 1 )

    # Creates a list with exact match of archived folders to delete (manually archived backup chains without this match aren't touched):
    old_backups_list=($(ls $BACKUP_MAIN_PATH | sort -r | grep -E "^$domain.[0-9]{4}-[0-9]{2}-[0-9]{2}.[0-9]{2}:[0-9]{2}:[0-9]{2}$" | tail -n +$index))

    echo "INFO: Cleaning archived backup chains (latest $MAX_BACKUP_CHAINS_KEEP will be kept)..."
    for old_backup in ${old_backups_list[@]}; do
        echo "$old_backup"
        rm -r $old_backup
    done
    echo "Done."
fi

}

# Check for previously existing backups of VMs in $domains_list, deleting those with internal inconsistencies:
#------------------------------------------------------------------------------
check_backups()
{

local check_backups_status=1

echo "INFO: Checking previous Backups..."

if [ ! -z $(find $BACKUP_MAIN_PATH -maxdepth 0 -empty -exec echo {} empty. \;) ]; then

    # VMs that are in need of a full backup
    full_backup_domains_list=()

    local check_backups_failed
    for domain in $domains_list; do

        local domain_backup_path=$BACKUP_MAIN_PATH/$domain

        if [ ! -e $domain_backup_path ]; then

            echo "INFO: VM $domain does not have previous backups"

            # Adds the VM to $full_backup_domains_list:
            full_backup_domains_list+=($domain)

        elif  [ -d $domain_backup_path ] && [ -r $domain_backup_path ] && [ -w $domain_backup_path ]; then

            local backup_chain_state=$(check_backup_integrity $domain)
            echo "INFO: Found a backup chain for VM $domain and its state is: '$backup_chain_state'"

            if [ $backup_chain_state == "UNCHECKED" ] || [ $backup_chain_state == "UNHEALTHY" ]; then

                # Archive old backup, since it might be able to build a disk image regardless its state:
                 archive_backup $domain

                # Adds the VM to $full_backup_domains_list:
                full_backup_domains_list+=($domain)

            elif [ $backup_chain_state == "BROKEN" ]

                # Removes unreliable backup:
                 echo "INFO: Deleting $backup_chain_state backup for $domain"
                 rm -rf $domain_backup_path

                # Adds the VM to $full_backup_domains_list:
                full_backup_domains_list+=($domain)
            fi
        else

            check_backups_failed=1

            local cause_of_fail=()
            [ ! -d $domain_backup_path ] && cause_of_fail+=('not a directory')
            [ ! -r $domain_backup_path ] && cause_of_fail+=('unreadable')
            [ ! -w $domain_backup_path ] && cause_of_fail+=('unwritable')

            echo "ERROR: Issues detected with $domain_backup_path (${cause_of_fail[@]// /,})"
        fi
    done

    # Only when no issues found with backup subfolders, everything is good to go:
    if [ -z $check_backups_failed ] && check_backups_status=0
else

    # From check_parameters function, it is assumed this folder has enough right permissions, so everything is good to go:
    local check_backups_status=0
    echo "INFO: $BACKUP_MAIN_PATH is empty"
fi

return $check_backups_status

}

