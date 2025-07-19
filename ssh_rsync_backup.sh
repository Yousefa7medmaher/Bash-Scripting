#!/bin/bash
#

# variables 
src="/etc/passwd"
logFile="backup.log"
Remote_host="server3@"  # Add your remote username and IP (e.g., server3@192.168.1.10)
remote_dir="/home/server3/backups/"

# functions 
perform_backup() {
    rsync -avz "$src" "$Remote_host":"$remote_dir" >> "$logFile" 2>&1
    if [ $? -eq 0 ]; then
        echo "backup successful $(date)" >> "$logFile"
    else
        echo "backup failed $(date)" >> "$logFile"
    fi
}

# Run the backup 
perform_backup
