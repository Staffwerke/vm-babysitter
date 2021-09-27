#!/bin/bash

# Takes a list of files as $1 and an installation folder as $2. Returns '0' if success and '1' if failed:
copy_files()
{
local list=$1
local path=$2
local copy_files_status=1

# Install files on host at given path:
for file in $list; do
    cp -f $file $path/ && copy_files_status=0
done

return $copy_files_status
}

# Special install for UnRaid
unraid_install()
{
# UnRaid runs as live distro for most things, so tools has to be provisioned along with the main user script, and executed from there:
local install_path="/boot/config/plugins/user.scripts/scripts/virtnbdbackup-auto"

# Folder name, and also the 'script name' seen through GUI:
local script_name="virtnbdbackup-auto"

# List of files to be copied and processed:
local files_list="vm-patch vm-inc-backup $script_name"

if [ ! -a $install_path/script ]; then

    # Fresh install case

    # Creates folder
    mkdir -p $install_path

    # Install files on host at given path:
    copy_files "$files_list" "$install_path"

    status=$?

    if [ $status == 0 ]; then

        # Includes correct data into the copied script to execute scripts properly.
        # 'bash' command is required since scripts are inside a FAT32 file system:
        sed -i -e "s|script_completion=\"\"|script_completion=\"bash $install_path\"|" $install_path/$script_name

        # Renaming script:
        mv $install_path/$script_name $install_path/script

        # Syncing media (is expected to be USB)
        sync

        message="INFO: $script_name user script successfully installed. You must edit the script and add parameters."

    else

        rm -rf $install_path
    fi

else

    # Reinstall case:

    # Backup the old install in case it fails:
    cp $install_path/ .$install_path.old/

    # Install files on host at given path:
    copy_files "$files_list" "$install_path"

    status=$?

    if [ $status == 0 ]; then

        # Sources existing variables from old script:
        source $install_path/script "--source-user-params"

        # Copies user parameters into the new script:
        sed -i -e "s|domains_list=\"\"|domains_list=\"$domains_list\"|" \
            -e "s|backup_folder=\"\"|backup_folder=\"$backup_folder\"|" \
            -e "s|remote_folder=\"\"|remote_folder=\"$remote_folder\"|" \
            -e "s|max_allowed_memory=\"\"|max_allowed_memory=\"$max_allowed_memory\"|" \
            -e "s|max_attempts=\"\"|max_attempts=\"$max_attempts\"|" \
            -e "s|rsync_args=\"\"|rsync_args=\"$rsync_args\"|" \
            -e "s|script_completion=\"\"|script_completion=\"$script_completion\"|" \
        $install_path/$script_name

        # Removing old script
        rm $install_path/script

        # Renaming new script:
        mv $install_path/$script_name $install_path/script

        # Syncing media (is expected to be USB)
        sync

        message="INFO: $script_name re-installed successfully. Existing user parameters has been migrated to a new version of the script."

    else

        rm -rf $install_path
        mv .$install_path.old $install_path

    fi
fi
}

# Installation on (most) other OSes.
# You might want to improve this code:
generic_install()
{

# Scripts will be installed into this folder:
local install_path="/usr/local/bin"

# Script name to be executed manually, or via Cron:
local script_name="virtnbdbackup-auto"

# List of files to be copied and processed:
local files_list="vm-patch vm-full-backup vm-inc-backup vm-restore"

# Install files on host at given path:
copy_files "$files_list" "$install_path"

status=$?

# Creates success notification:
[ $status == 0 ] && message="INFO: Installation successful. You might want to copy and edit $script_name to add user parameters, and create a cron task to schedule its execution from your preferred location."

}

# Main execution:
# -----------------------------------------------------------------------------
status=1

read -p "Do you want to install virtnbdbackup-docker-scripts? [yes/no]?: " key
while true; do
    case $key in
        yes)
            if [[ -n `uname  -r | grep -e "-Unraid$"` ]]; then
                unraid_install
            else
                generic_install
            fi
            break
        ;;
        no)
            status=0
            message="No changes has been made. (Aborted by the user)"
            break
        ;;
        *)
            read -p "Please, write 'yes' or 'no': " key
        ;;
    esac
done

# Generic message in case of fail:
[[ $status -ne 0 ]] && message="ERROR: Something occured and installation has been cancelled"

# Says the final result and message.
echo $message

exit $status
