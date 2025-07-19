#!/bin/bash

# ============================
# Log Rotation Script
# ============================

# Set the log directory path
Log_Dir="/var/log/myapp"

# Set the maximum log file size in bytes (5 MB)
max_log_size=5000000

# Set the maximum age of compressed logs before deletion (30 days)
max_log_age=30

# ----------------------------
# Function to rotate log files
# ----------------------------
rotatelogs() {
    # Loop through all .log files in the log directory
    for log_file in "$Log_Dir"/*.log; do
        # Get the size of the log file and compare it to the max size
        if [ $(stat -c%s "$log_file") -gt "$max_log_size" ]; then
            # Create a new name for the rotated file with today's date
            rotated_name="$log_file.$(date +%Y%m%d)"

            # Rename (move) the original log file
            mv "$log_file" "$rotated_name"

            # Compress the rotated log file
            gzip "$rotated_name"

            # Print a message to confirm rotation
            echo "Log rotated: $log_file"
        fi
    done
}

# -----------------------------------------
# Function to delete old compressed log files
# -----------------------------------------
clean_old_logs() {
    # Find all compressed .gz log files older than max_log_age and delete them
    find "$Log_Dir" -name "*.gz" -mtime +"$max_log_age" -exec rm {} \;

    # Print a message to confirm cleanup
    echo "Old logs cleaned up"
}

# ---------------------
# Run the script actions
# ---------------------
rotatelogs     # Rotate oversized logs
clean_old_logs # Clean up old compressed logs
